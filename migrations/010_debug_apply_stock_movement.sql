create or replace function apply_stock_movement()
returns trigger as $$
declare
  v_before integer;
begin
  select quantity into v_before from stock_levels where sku_id = new.sku_id;
  raise notice 'BEFORE: sku_id=%, existing_quantity=%, incoming_change=%', new.sku_id, v_before, new.quantity_change;

  insert into stock_levels as sl (sku_id, quantity, updated_at)
  values (new.sku_id, new.quantity_change, now())
  on conflict (sku_id)
  do update set
    quantity = sl.quantity + new.quantity_change,
    updated_at = now();

  raise notice 'AFTER: sku_id=%, new_quantity=%', new.sku_id, (select quantity from stock_levels where sku_id = new.sku_id);

  return new;
end;
$$ language plpgsql security definer set search_path = public;
