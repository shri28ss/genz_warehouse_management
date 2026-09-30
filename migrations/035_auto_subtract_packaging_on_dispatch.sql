-- ============================================================
-- Migration: auto-subtract packaging stage totals when an order dispatches
-- Dispatching an order already reduces live stock_levels, but the
-- Packaging Tally's per-stage totals (raw_unpacked/wraps/boxing/labeled)
-- were never reduced — so "Copy previous day" (or just time passing)
-- kept carrying forward stage counts that included bottles that had
-- already left the warehouse. This made Total > Warehouse Stock by
-- exactly the dispatched quantity.
--
-- Fix: when reconcile_and_dispatch marks orders dispatched, also insert
-- negative packaging_daily_log entries for the dispatched quantity,
-- taken from box_bubble_wrap first (the stage dispatched bottles are
-- actually pulled from) and cascading through the other stages if that
-- one doesn't have enough logged for the day — so the pipeline's
-- running total stays honest without ever going negative on a single
-- stage unnecessarily.
-- ============================================================

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
  v_remaining integer;
  v_stage packaging_stage;
  v_available integer;
  v_take integer;
  v_stages packaging_stage[] := array['box_bubble_wrap', 'box_labeled', 'box_packed', 'bottle_bubble_wrap', 'bottle_plastic_wrap', 'raw_unpacked']::packaging_stage[];
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

  if v_dispatched_units > 0 then
    v_remaining := v_dispatched_units;
    foreach v_stage in array v_stages loop
      exit when v_remaining <= 0;

      select coalesce(sum(quantity), 0) into v_available
      from packaging_daily_log
      where sku_id = p_sku_id and log_date = p_date and stage = v_stage;

      if v_available > 0 then
        v_take := least(v_available, v_remaining);
        insert into packaging_daily_log (log_date, sku_id, stage, quantity, recorded_by)
        values (p_date, p_sku_id, v_stage, -v_take, p_actor_id);
        v_remaining := v_remaining - v_take;
      end if;
    end loop;

    if v_remaining > 0 then
      insert into packaging_daily_log (log_date, sku_id, stage, quantity, recorded_by)
      values (p_date, p_sku_id, 'box_bubble_wrap'::packaging_stage, -v_remaining, p_actor_id);
    end if;
  end if;

  return query select v_reconciled_orders, v_reconciled_units, v_dispatched_orders, v_dispatched_units;
end;
$$ language plpgsql security definer set search_path = public;
