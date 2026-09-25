-- ============================================================
-- Migration: track daily packaging counts per SKU, not just per stage
-- Existing rows (if any) get backfilled to a placeholder — in
-- practice this table was just being tested, so backfill picks
-- any one active SKU as a safe default; delete/re-enter old test
-- rows with the correct SKU afterwards if needed.
-- ============================================================

alter table packaging_daily_log add column if not exists sku_id uuid references skus(id);

-- Backfill any existing rows to the first active SKU so the NOT NULL
-- constraint below doesn't fail (safe: this project has only test data).
update packaging_daily_log
set sku_id = (select id from skus where is_active = true order by sku_code limit 1)
where sku_id is null;

alter table packaging_daily_log alter column sku_id set not null;

create index if not exists idx_packaging_log_sku on packaging_daily_log(sku_id);

drop view if exists packaging_daily_totals;
create view packaging_daily_totals as
select
  pl.log_date,
  pl.sku_id,
  s.sku_code,
  p.name as product_name,
  pl.stage,
  sum(pl.quantity) as total_quantity
from packaging_daily_log pl
join skus s on s.id = pl.sku_id
join products p on p.id = s.product_id
group by pl.log_date, pl.sku_id, s.sku_code, p.name, pl.stage
order by pl.log_date desc, s.sku_code, pl.stage;
