-- ============================================================
-- Migration: historical stock balance as of a given date
-- Packaging Tally's "Warehouse Stock" column was always showing
-- the LIVE current stock, even when a past date was selected —
-- so a later RTO/order retroactively changed what a past date's
-- column showed, which is wrong (the number for a closed/past
-- date should be frozen to what it was at that date's end).
--
-- This function sums stock_movements up through the end of the
-- given date (IST), per SKU, giving the balance as of that date.
-- For today's date this naturally equals the live current stock,
-- since all movements so far are included.
-- ============================================================

create or replace function stock_balance_as_of(p_date date)
returns table (sku_id uuid, quantity integer) as $$
  select sm.sku_id, sum(sm.quantity_change)::integer as quantity
  from stock_movements sm
  where (sm.created_at AT TIME ZONE 'Asia/Kolkata') <= (p_date::text || ' 23:59:59.999')::timestamp
  group by sm.sku_id;
$$ language sql security definer set search_path = public;

grant execute on function stock_balance_as_of(date) to authenticated;
