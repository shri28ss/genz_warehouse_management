-- ============================================================
-- Migration: reconcile_and_dispatch now marks scan-failed orders
-- as status 'scan_failed' (record preserved) instead of deleting
-- them, so per-product "how many out of total scan-failed" reporting
-- is possible. Stock is still restored via an 'adjustment' movement.
-- Must run AFTER 013_scan_failed_status.sql (enum value must be
-- committed before it can be used here).
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
  -- mark enough of them 'scan_failed' to cover the count, and
  -- restore their stock. Records are kept, not deleted.
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

-- ============================================================
-- Reporting view: per-product, how many orders/units total vs
-- how many scan-failed, so "out of total, how many didn't scan" works.
-- ============================================================
drop view if exists scan_fail_summary;
create view scan_fail_summary as
select
  s.product_id,
  p.name as product_name,
  s.id as sku_id,
  s.sku_code,
  o.created_at::date as order_date,
  count(*) filter (where o.status = 'scan_failed') as scan_failed_orders,
  coalesce(sum(ol.quantity) filter (where o.status = 'scan_failed'), 0) as scan_failed_units,
  count(*) filter (where o.status in ('fulfilled', 'dispatched', 'scan_failed')) as total_orders,
  coalesce(sum(ol.quantity) filter (where o.status in ('fulfilled', 'dispatched', 'scan_failed')), 0) as total_units
from orders o
join order_lines ol on ol.order_id = o.id
join skus s on s.id = ol.sku_id
join products p on p.id = s.product_id
group by s.product_id, p.name, s.id, s.sku_code, o.created_at::date
order by order_date desc, s.sku_code;
