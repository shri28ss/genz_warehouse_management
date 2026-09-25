-- ============================================================
-- Migration: raw_stock_batches was missing RLS entirely — it had
-- no "enable row level security" and no policy, so every insert/
-- select on it was being blocked once RLS is on (default-deny).
-- ============================================================

alter table raw_stock_batches enable row level security;

create policy ops_manage_raw_stock_batches on raw_stock_batches for all
  using (current_role_name() in ('operation_incharge', 'super_admin'))
  with check (current_role_name() in ('operation_incharge', 'super_admin'));
