-- ============================================================
-- Migration: allow negative quantity deltas in packaging_daily_log
-- Editing a Packaging Tally cell down (e.g. correcting 50 to 30)
-- inserts a negative-delta row (-20). The original check constraint
-- (quantity > 0) rejected this, silently breaking "edit down" while
-- "edit up" kept working — fixed to just disallow zero.
-- ============================================================

alter table packaging_daily_log drop constraint packaging_daily_log_quantity_check;
alter table packaging_daily_log add constraint packaging_daily_log_quantity_check check (quantity != 0);
