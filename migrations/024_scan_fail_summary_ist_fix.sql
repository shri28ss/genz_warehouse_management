-- ============================================================
-- Migration: fix scan_fail_summary to bucket by India date, not UTC
-- Same root cause fixed earlier in reconcile_and_dispatch() —
-- o.created_at::date casts using the session/UTC timezone, so an
-- order created any time during the India business day could land
-- in the wrong "order_date" bucket relative to what operators
-- actually select in the UI (which is always an India-local date).
-- ============================================================

drop view if exists scan_fail_summary;
create view scan_fail_summary as
select
  s.product_id,
  p.name as product_name,
  s.id as sku_id,
  s.sku_code,
  (o.created_at AT TIME ZONE 'Asia/Kolkata')::date as order_date,
  count(*) filter (where o.status = 'scan_failed') as scan_failed_orders,
  coalesce(sum(ol.quantity) filter (where o.status = 'scan_failed'), 0) as scan_failed_units,
  count(*) filter (where o.status = 'dispatched') as total_orders,
  coalesce(sum(ol.quantity) filter (where o.status = 'dispatched'), 0) as total_units
from orders o
join order_lines ol on ol.order_id = o.id
join skus s on s.id = ol.sku_id
join products p on p.id = s.product_id
group by s.product_id, p.name, s.id, s.sku_code, (o.created_at AT TIME ZONE 'Asia/Kolkata')::date
order by order_date desc, s.sku_code;
