-- ============================================================
-- Migration: atomic bulk-fulfill RPC
-- The app was creating orders + order_lines + stock_movements as
-- three separate REST calls. If the stock_movements insert failed
-- (e.g. not enough stock), the orders/order_lines from the earlier
-- calls had already committed — leaving "fulfilled" orders with no
-- matching stock deduction. This function does the whole thing in
-- one transaction: if stock is insufficient, nothing is created.
-- ============================================================

create or replace function bulk_fulfill_orders(
  p_order_code_prefix text,
  p_count integer,
  p_mix jsonb, -- [{ "sku_id": "...", "quantity": 2 }, ...]
  p_created_by uuid
)
returns setof orders as $$
declare
  v_mix_ml integer;
  v_line jsonb;
  v_sku_id uuid;
  v_qty integer;
  v_available integer;
  v_timestamp bigint := extract(epoch from now()) * 1000;
  v_order orders;
  v_i integer;
begin
  if p_count < 1 then
    raise exception 'Count must be at least 1';
  end if;
  if jsonb_array_length(p_mix) = 0 then
    raise exception 'Bottle mix cannot be empty';
  end if;

  -- Check stock availability for every SKU in the mix before creating anything
  for v_line in select * from jsonb_array_elements(p_mix)
  loop
    v_sku_id := (v_line->>'sku_id')::uuid;
    v_qty := (v_line->>'quantity')::integer;

    select quantity into v_available from stock_levels where sku_id = v_sku_id;
    if v_available is null or v_available < v_qty * p_count then
      raise exception 'Insufficient stock for SKU %: need %, have %',
        v_sku_id, v_qty * p_count, coalesce(v_available, 0);
    end if;
  end loop;

  -- Compute total requested ml for this mix (one order's worth)
  select coalesce(sum((l->>'quantity')::integer * s.size_ml), 0)
  into v_mix_ml
  from jsonb_array_elements(p_mix) l
  join skus s on s.id = (l->>'sku_id')::uuid;

  -- Create N orders + their order_lines, and one stock_movements row per SKU per order
  for v_i in 1..p_count loop
    insert into orders (order_code, requested_ml, status, created_by)
    values (
      coalesce(p_order_code_prefix, 'BULK') || '-' || v_timestamp || '-' || v_i,
      v_mix_ml,
      'fulfilled',
      p_created_by
    )
    returning * into v_order;

    for v_line in select * from jsonb_array_elements(p_mix)
    loop
      v_sku_id := (v_line->>'sku_id')::uuid;
      v_qty := (v_line->>'quantity')::integer;

      insert into order_lines (order_id, sku_id, quantity)
      values (v_order.id, v_sku_id, v_qty);

      insert into stock_movements (sku_id, movement_type, quantity_change, reference_order_id, created_by)
      values (v_sku_id, 'order_fulfillment', -v_qty, v_order.id, p_created_by);
    end loop;

    return next v_order;
  end loop;

  return;
end;
$$ language plpgsql security definer set search_path = public;

grant execute on function bulk_fulfill_orders(text, integer, jsonb, uuid) to authenticated;
