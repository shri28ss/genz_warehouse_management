-- ============================================================
-- Migration: client read-only access to Packaging Tally, Order Log,
-- RTO, and Leak data
-- These were previously Operation/Admin-only. Clients get SELECT-only
-- RLS policies (no insert/update/delete) so they can view the same
-- data read-only, with date filters, on their own dashboard.
-- order_log_summary and scan_fail_summary are views over orders/
-- order_lines/skus/products, which already allow client SELECT, so no
-- additional grant is needed there — only the underlying tables with
-- Operation-only policies need a client read policy added.
-- ============================================================

create policy client_read_packaging_log on packaging_daily_log
  for select
  using (current_role_name() = 'client'::user_role);

create policy client_read_rto_returns on rto_returns
  for select
  using (current_role_name() = 'client'::user_role);

create policy client_read_leak_entries on leak_entries
  for select
  using (current_role_name() = 'client'::user_role);
