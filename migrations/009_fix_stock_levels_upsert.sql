-- ============================================================
-- Migration: fix ON CONFLICT DO UPDATE referencing the wrong row
-- apply_stock_movement() wrote `quantity = stock_levels.quantity + ...`
-- inside the ON CONFLICT SET clause. That table-qualified reference
-- was resolving to the incoming (excluded) row instead of the
-- existing stored row, so every conflict update silently used the
-- new value instead of adding to the old one — e.g. stock at 300,
-- deduct 2, result became -2 instead of 298.
-- Fix: alias the existing row explicitly so there's no ambiguity.
-- ============================================================

create or replace function apply_stock_movement()
returns trigger as $$
begin
  insert into stock_levels as sl (sku_id, quantity, updated_at)
  values (new.sku_id, new.quantity_change, now())
  on conflict (sku_id)
  do update set
    quantity = sl.quantity + new.quantity_change,
    updated_at = now();
  return new;
end;
$$ language plpgsql security definer set search_path = public;
