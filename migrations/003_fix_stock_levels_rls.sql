-- ============================================================
-- Migration: fix RLS block on stock_levels auto-update trigger
-- The apply_stock_movement() trigger writes to stock_levels on
-- behalf of any caller who inserts into stock_movements, but
-- stock_levels only has a SELECT policy — so the trigger's write
-- was being blocked by RLS. Making the function SECURITY DEFINER
-- lets it write regardless of the caller's own stock_levels access.
-- ============================================================

create or replace function apply_stock_movement()
returns trigger as $$
begin
  insert into stock_levels (sku_id, quantity, updated_at)
  values (new.sku_id, new.quantity_change, now())
  on conflict (sku_id)
  do update set
    quantity = stock_levels.quantity + new.quantity_change,
    updated_at = now();
  return new;
end;
$$ language plpgsql security definer set search_path = public;
