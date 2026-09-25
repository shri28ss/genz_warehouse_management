-- ============================================================
-- Migration: add 'scan_failed' order status; reconcile_and_dispatch
-- now marks scan-failed orders as 'scan_failed' (keeping the record
-- for per-product reporting) instead of deleting them. Stock is
-- still restored, same as before.
-- ============================================================

-- 1. Add the new status value
alter type order_status add value if not exists 'scan_failed';
