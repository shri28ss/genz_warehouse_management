-- ============================================================
-- Migration: order log view — product-wise, date-wise summary of
-- all orders created, showing the bottle-mix breakdown that
-- fulfilled them. IST-bucketed (same fix as scan_fail_summary).
-- ============================================================

create or replace view order_log_summary as
select
  (o.created_at AT TIME ZONE 'Asia/Kolkata')::date as order_date,
  p.id as product_id,
  p.name as product_name,
  s.id as sku_id,
  s.sku_code,
  s.size_ml,
  count(distinct o.id) as order_count,
  sum(ol.quantity) as bottle_count,
  sum(ol.quantity * s.size_ml) as total_ml
from orders o
join order_lines ol on ol.order_id = o.id
join skus s on s.id = ol.sku_id
join products p on p.id = s.product_id
group by (o.created_at AT TIME ZONE 'Asia/Kolkata')::date, p.id, p.name, s.id, s.sku_code, s.size_ml
order by order_date desc, p.name, s.sku_code;
