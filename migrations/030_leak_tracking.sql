-- ============================================================
-- Migration: leak/damage tracking
-- Standalone log (like RTO) for bottles that leaked/damaged during
-- packaging. Does NOT touch stock_levels automatically (tracking
-- only, per the user's explicit choice) — but IS pulled into the
-- Packaging Tally / warehouse closure reconciliation, same way
-- "Dispatched" is pulled from scan_fail_summary.
-- ============================================================

create table leak_entries (
  id uuid primary key default gen_random_uuid(),
  sku_id uuid not null references skus(id),
  quantity integer not null check (quantity > 0),
  leak_date date not null default current_date,
  note text,
  recorded_by uuid not null references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index idx_leak_entries_date on leak_entries(leak_date);
create index idx_leak_entries_sku on leak_entries(sku_id);

alter table leak_entries enable row level security;

create policy ops_manage_leak_entries on leak_entries for all
  using (current_role_name() in ('operation_incharge', 'super_admin'))
  with check (current_role_name() in ('operation_incharge', 'super_admin'));

-- Daily per-SKU totals, same shape as scan_fail_summary, so the
-- Packaging Tally can pull "Leak" the same way it pulls "Dispatched".
create or replace view leak_daily_totals as
select
  sku_id,
  leak_date,
  sum(quantity) as total_quantity
from leak_entries
group by sku_id, leak_date;
