-- ============================================================
-- Migration: subtract packaging at order FULFILLMENT, not dispatch
-- A bottle physically leaves the "available in warehouse" pool the
-- moment it's packed into a fulfilled order (stock_levels already
-- drops at that point) — not only once the courier actually picks it
-- up. Packaging's Total was only being reduced at dispatch time, so
-- any order sitting in 'fulfilled' status (created but not yet
-- dispatched) left Total higher than Warehouse Stock until dispatch.
--
-- Moves the box_bubble_wrap cascade-subtract from dispatch time
-- (reconcile_and_dispatch) to fulfillment time (bulk_fulfill_orders),
-- since an order is only subtracted once in its lifecycle — dispatch no
-- longer repeats it. delete_orders_bulk's restoration now applies to
-- 'fulfilled' orders too, not just 'dispatched' ones, since both have
-- now had packaging reduced by the time they'd be deleted.
-- ============================================================

create or replace function bulk_fulfill_orders(
  p_order_code_prefix text,
  p_count integer,
  p_mix jsonb,
  p_created_by uuid,
  p_order_date date default null,
  p_courier text default null
)
returns setof orders as $$
declare
  v_mix_ml integer;
  v_line jsonb;
  v_sku_id uuid;
  v_qty integer;
  v_available integer;
  v_timestamp bigint := extract(epoch from now()) * 1000;
  v_order orders;
  v_i integer;
  v_created_at timestamptz;
  v_order_date date;
begin
  if p_count < 1 then
    raise exception 'Count must be at least 1';
  end if;
  if jsonb_array_length(p_mix) = 0 then
    raise exception 'Bottle mix cannot be empty';
  end if;

  v_created_at := case
    when p_order_date is not null then
      (p_order_date::text || ' ' || ((now() AT TIME ZONE 'Asia/Kolkata')::time)::text || '+05:30')::timestamptz
    else now()
  end;
  v_order_date := (v_created_at AT TIME ZONE 'Asia/Kolkata')::date;

  for v_line in select * from jsonb_array_elements(p_mix)
  loop
    v_sku_id := (v_line->>'sku_id')::uuid;
    v_qty := (v_line->>'quantity')::integer;

    select quantity into v_available from stock_levels where sku_id = v_sku_id;
    if v_available is null or v_available < v_qty * p_count then
      raise exception 'Insufficient stock for SKU %: need %, have %',
        v_sku_id, v_qty * p_count, coalesce(v_available, 0);
    end if;
  end loop;

  select coalesce(sum((l->>'quantity')::integer * s.size_ml), 0)
  into v_mix_ml
  from jsonb_array_elements(p_mix) l
  join skus s on s.id = (l->>'sku_id')::uuid;

  for v_i in 1..p_count loop
    insert into orders (order_code, requested_ml, status, created_by, created_at, updated_at, courier)
    values (
      coalesce(p_order_code_prefix, 'BULK') || '-' || v_timestamp || '-' || v_i,
      v_mix_ml,
      'fulfilled',
      p_created_by,
      v_created_at,
      v_created_at,
      p_courier
    )
    returning * into v_order;

    for v_line in select * from jsonb_array_elements(p_mix)
    loop
      v_sku_id := (v_line->>'sku_id')::uuid;
      v_qty := (v_line->>'quantity')::integer;

      insert into order_lines (order_id, sku_id, quantity)
      values (v_order.id, v_sku_id, v_qty);

      insert into stock_movements (sku_id, movement_type, quantity_change, reference_order_id, created_by)
      values (v_sku_id, 'order_fulfillment', -v_qty, v_order.id, p_created_by);

      perform subtract_packaging_cascade(v_sku_id, v_order_date, v_qty, p_created_by);
    end loop;

    return next v_order;
  end loop;

  return;
end;
$$ language plpgsql security definer set search_path = public;

-- Dispatch no longer touches packaging — that already happened at
-- fulfillment time, and an order is only fulfilled once in its lifecycle.
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
    insert into packaging_daily_log (log_date, sku_id, stage, quantity, recorded_by)
    select p_date, ol2.sku_id, 'box_bubble_wrap'::packaging_stage, ol2.quantity, p_actor_id
    from order_lines ol2
    where ol2.order_id = v_order.id;

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

-- Restoration now applies to 'fulfilled' orders too, not just
-- 'dispatched' — both have had packaging reduced by now.
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

      insert into packaging_daily_log (log_date, sku_id, stage, quantity, recorded_by)
      values (
        v_order_date,
        v_line.sku_id,
        'box_bubble_wrap'::packaging_stage,
        v_line.quantity,
        auth.uid()
      );
    end loop;

    delete from orders where id = v_order_id;
  end loop;
end;
$$ language plpgsql security definer set search_path = public;
