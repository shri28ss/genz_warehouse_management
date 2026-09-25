-- ============================================================
-- Migration: RTO (Return to Origin) tracking
-- Same pattern as scan_fail_returns: log a SKU + quantity that
-- physically returned to the warehouse (a dispatched order came
-- back), and stock is automatically added back via a trigger.
-- ============================================================

alter type movement_type add value if not exists 'rto_return';
