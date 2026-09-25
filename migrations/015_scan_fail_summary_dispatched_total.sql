-- ============================================================
-- Migration: scan_fail_summary "total" now means dispatched-only,
-- not the grand total including scan-failed orders. Scan-failed
-- stays as its own separate count next to it.
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
  count(*) filter (where o.status = 'dispatched') as total_orders,
  coalesce(sum(ol.quantity) filter (where o.status = 'dispatched'), 0) as total_units
from orders o
join order_lines ol on ol.order_id = o.id
join skus s on s.id = ol.sku_id
join products p on p.id = s.product_id
group by s.product_id, p.name, s.id, s.sku_code, o.created_at::date
order by order_date desc, s.sku_code;
