-- ============================================================
-- Migration: allow clients to read aggregate dispatch data
-- Clients need a read-only "how much of each product shipped on
-- date X" overview — not tied to a specific client_id (orders
-- aren't linked to individual clients in the current workflow).
-- Grant clients SELECT on orders/order_lines broadly (still
-- read-only, no write access) so the scan_fail_summary view
-- resolves for them, and so they could query order-level detail
-- if ever needed. The old "only their own client_id" policies
-- are dropped since they no longer match how orders are created.
-- ============================================================

drop policy if exists client_read_own_orders on orders;
drop policy if exists client_read_own_order_lines on order_lines;

create policy client_read_all_orders on orders for select
  using (current_role_name() = 'client');

create policy client_read_all_order_lines on order_lines for select
  using (current_role_name() = 'client');
