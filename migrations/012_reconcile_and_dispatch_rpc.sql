-- ============================================================
-- Migration: SKU-level dispatch reconciliation
-- Workflow: orders get created "fulfilled" (packed, ready) via
-- Bulk/Manual Order. Before actual dispatch, the operator counts
-- scan-fails for a SKU on a given day. This function:
--   1. Picks fulfilled orders for that SKU (created that day) whose
--      line quantities sum up to at least p_scan_fail_count units,
--      and deletes them (order_lines cascade-delete; their stock is
--      restored via an 'adjustment' movement — same pattern as
--      delete_orders_bulk).
--   2. Marks all REMAINING fulfilled orders for that SKU/day as
--      'dispatched'.
-- Returns how many orders were reconciled away vs dispatched, and
-- the resulting dispatched unit count, so the UI can show a summary.
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
begin
  if p_scan_fail_count < 0 then
    raise exception 'Scan-fail count cannot be negative';
  end if;

  -- Step 1: pick fulfilled orders for this SKU/date, oldest first,
  -- and delete enough of them to cover the scan-fail count.
  for v_order in
    select o.id, ol.quantity
    from orders o
    join order_lines ol on ol.order_id = o.id
    where ol.sku_id = p_sku_id
      and o.status = 'fulfilled'
      and o.created_at::date = p_date
    order by o.created_at asc
  loop
    exit when v_reconciled_units >= p_scan_fail_count;

    -- Restore stock for every line on this order (it may contain other SKUs too)
    insert into stock_movements (sku_id, movement_type, quantity_change, note, created_by)
    select ol2.sku_id, 'adjustment', ol2.quantity,
           'Scan-fail reconciliation: order ' || v_order.id || ' cancelled',
           p_actor_id
    from order_lines ol2
    where ol2.order_id = v_order.id;

    delete from orders where id = v_order.id;

    v_reconciled_units := v_reconciled_units + v_order.quantity;
    v_reconciled_orders := v_reconciled_orders + 1;
  end loop;

  -- Step 2: dispatch everything else still fulfilled for this SKU/date
  for v_order in
    select o.id, ol.quantity
    from orders o
    join order_lines ol on ol.order_id = o.id
    where ol.sku_id = p_sku_id
      and o.status = 'fulfilled'
      and o.created_at::date = p_date
  loop
    update orders set status = 'dispatched', updated_at = now() where id = v_order.id;
    v_dispatched_units := v_dispatched_units + v_order.quantity;
    v_dispatched_orders := v_dispatched_orders + 1;
  end loop;

  return query select v_reconciled_orders, v_reconciled_units, v_dispatched_orders, v_dispatched_units;
end;
$$ language plpgsql security definer set search_path = public;

grant execute on function reconcile_and_dispatch(uuid, date, integer, uuid) to authenticated;
