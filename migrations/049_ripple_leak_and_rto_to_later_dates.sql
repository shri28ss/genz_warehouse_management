-- ============================================================
-- Migration: ripple leak and RTO adjustments forward to later dates too
-- Migration 048 made subtract_packaging_cascade (fulfillment) ripple a
-- backdated correction into every later date that already has a
-- packaging baseline. Leak and RTO insert/update/delete directly into
-- packaging_daily_log rather than through that helper, so they need
-- the same ripple logic applied separately.
-- ============================================================

create or replace function add_packaging_ripple(
  p_sku_id uuid,
  p_date date,
  p_stage packaging_stage,
  p_amount integer,
  p_actor_id uuid
)
returns void as $$
declare
  v_later_date date;
begin
  if p_amount = 0 then
    return;
  end if;

  insert into packaging_daily_log (log_date, sku_id, stage, quantity, recorded_by)
  values (p_date, p_sku_id, p_stage, p_amount, p_actor_id);

  for v_later_date in
    select distinct log_date from packaging_daily_log
    where sku_id = p_sku_id and log_date > p_date
    order by log_date
  loop
    insert into packaging_daily_log (log_date, sku_id, stage, quantity, recorded_by)
    values (v_later_date, p_sku_id, p_stage, p_amount, p_actor_id);
  end loop;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function sync_leak_to_packaging()
returns trigger as $$
begin
  if TG_OP = 'INSERT' then
    perform add_packaging_ripple(new.sku_id, new.leak_date, 'raw_unpacked'::packaging_stage, -new.quantity, new.recorded_by);
    return new;
  elsif TG_OP = 'UPDATE' then
    -- Undo the old entry's effect, then apply the new one — simplest way to
    -- handle a changed quantity and/or a changed leak_date correctly.
    perform add_packaging_ripple(old.sku_id, old.leak_date, 'raw_unpacked'::packaging_stage, old.quantity, coalesce(new.recorded_by, old.recorded_by));
    perform add_packaging_ripple(new.sku_id, new.leak_date, 'raw_unpacked'::packaging_stage, -new.quantity, coalesce(new.recorded_by, old.recorded_by));
    return new;
  elsif TG_OP = 'DELETE' then
    perform add_packaging_ripple(old.sku_id, old.leak_date, 'raw_unpacked'::packaging_stage, old.quantity, old.recorded_by);
    return old;
  end if;
  return null;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function delete_orders_bulk(p_order_ids uuid[])
returns void as $$
declare
  v_order_id uuid;
  v_order_status text;
  v_order_date date;
  v_line record;
begin
  foreach v_order_id in array p_order_ids
  loop
    select status, (created_at AT TIME ZONE 'Asia/Kolkata')::date
    into v_order_status, v_order_date
    from orders where id = v_order_id;

    for v_line in
      select ol.sku_id, ol.quantity
      from order_lines ol
      where ol.order_id = v_order_id
        and v_order_status in ('fulfilled', 'dispatched')
    loop
      insert into stock_movements (sku_id, movement_type, quantity_change, note, created_by)
      values (
        v_line.sku_id,
        'adjustment',
        v_line.quantity,
        'Reversal: order ' || v_order_id || ' deleted',
        auth.uid()
      );

      perform add_packaging_ripple(v_line.sku_id, v_order_date, 'box_bubble_wrap'::packaging_stage, v_line.quantity, auth.uid());
    end loop;

    delete from orders where id = v_order_id;
  end loop;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function reconcile_and_dispatch(
  p_sku_id uuid,
  p_date date,
  p_scan_fail_count integer,
  p_actor_id uuid
)
returns table (
  reconciled_orders integer,
  reconciled_units integer,
  dispatched_orders integer,
  dispatched_units integer
) as $$
declare
  v_order record;
  v_line2 record;
  v_reconciled_units integer := 0;
  v_reconciled_orders integer := 0;
  v_dispatched_units integer := 0;
  v_dispatched_orders integer := 0;
begin
  if p_scan_fail_count < 0 then
    raise exception 'Scan-fail count cannot be negative';
  end if;

  for v_order in
    select o.id, ol.quantity
    from orders o
    join order_lines ol on ol.order_id = o.id
    where ol.sku_id = p_sku_id
      and o.status = 'fulfilled'
      and (o.created_at AT TIME ZONE 'Asia/Kolkata')::date = p_date
    order by o.created_at asc
  loop
    exit when v_reconciled_units >= p_scan_fail_count;

    insert into stock_movements (sku_id, movement_type, quantity_change, note, created_by)
    select ol2.sku_id, 'adjustment', ol2.quantity,
           'Scan-fail: order ' || v_order.id || ' did not scan out',
           p_actor_id
    from order_lines ol2
    where ol2.order_id = v_order.id;

    -- Scan-fail returns the bottle to the warehouse's good stock, so its
    -- packaging-stage count needs to come back too (it was subtracted at
    -- fulfillment time, same as a dispatched-then-deleted order).
    for v_line2 in select sku_id, quantity from order_lines where order_id = v_order.id
    loop
      perform add_packaging_ripple(v_line2.sku_id, p_date, 'box_bubble_wrap'::packaging_stage, v_line2.quantity, p_actor_id);
    end loop;

    update orders set status = 'scan_failed', updated_at = now() where id = v_order.id;

    v_reconciled_units := v_reconciled_units + v_order.quantity;
    v_reconciled_orders := v_reconciled_orders + 1;
  end loop;

  for v_order in
    select o.id, ol.quantity
    from orders o
    join order_lines ol on ol.order_id = o.id
    where ol.sku_id = p_sku_id
      and o.status = 'fulfilled'
      and (o.created_at AT TIME ZONE 'Asia/Kolkata')::date = p_date
  loop
    update orders set status = 'dispatched', updated_at = now() where id = v_order.id;
    v_dispatched_units := v_dispatched_units + v_order.quantity;
    v_dispatched_orders := v_dispatched_orders + 1;
  end loop;

  return query select v_reconciled_orders, v_reconciled_units, v_dispatched_orders, v_dispatched_units;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function log_rto_return()
returns trigger as $$
declare
  v_movement_id uuid;
  v_effective_at timestamptz;
begin
  v_effective_at := (new.return_date::text || ' 23:59:59.999+05:30')::timestamptz;

  insert into stock_movements (sku_id, movement_type, quantity_change, note, created_by, created_at)
  values (
    new.sku_id,
    'rto_return',
    new.quantity_returned,
    coalesce(new.note, 'RTO return'),
    new.recounted_by,
    v_effective_at
  )
  returning id into v_movement_id;

  new.stock_movement_id := v_movement_id;

  perform add_packaging_ripple(new.sku_id, new.return_date, 'box_bubble_wrap'::packaging_stage, new.quantity_returned, new.recounted_by);

  return new;
end;
$$ language plpgsql security definer set search_path = public;
