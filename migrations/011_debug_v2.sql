create or replace function apply_stock_movement()
returns trigger as $$
declare
  v_before integer;
  v_after integer;
begin
  select quantity into v_before from stock_levels where sku_id = new.sku_id;

  insert into stock_levels as sl (sku_id, quantity, updated_at)
  values (new.sku_id, new.quantity_change, now())
  on conflict (sku_id)
  do update set
    quantity = sl.quantity + new.quantity_change,
    updated_at = now()
  returning sl.quantity into v_after;

  if v_after != coalesce(v_before, 0) + new.quantity_change then
    raise exception 'MISMATCH: before=%, change=%, expected=%, actual_after=%',
      v_before, new.quantity_change, coalesce(v_before, 0) + new.quantity_change, v_after;
  end if;

  return new;
end;
$$ language plpgsql security definer set search_path = public;
