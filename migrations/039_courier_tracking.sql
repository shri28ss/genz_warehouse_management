-- ============================================================
-- Migration: courier tracking on orders
-- Adds a free-text courier column to orders (Ekart/Delhivery/Shadowfax/
-- DTDC as default suggestions in the UI, but not a strict enum — other
-- courier names can still be typed), wires it through order creation,
-- and exposes it (plus lets it be edited after the fact) in Order Log.
-- ============================================================

alter table orders add column if not exists courier text;

-- bulk_fulfill_orders gains an optional p_courier param (defaults to
-- null so existing callers/signatures-in-spirit keep working; the
-- frontend is updated alongside this migration to always pass it).
create or replace function bulk_fulfill_orders(
  p_order_code_prefix text,
  p_count integer,
  p_mix jsonb,
  p_created_by uuid,
  p_order_date date default null,
  p_courier text default null
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
  v_created_at timestamptz;
begin
  if p_count < 1 then
    raise exception 'Count must be at least 1';
  end if;
  if jsonb_array_length(p_mix) = 0 then
    raise exception 'Bottle mix cannot be empty';
  end if;

  v_created_at := case
    when p_order_date is not null then
      (p_order_date::text || ' ' || ((now() AT TIME ZONE 'Asia/Kolkata')::time)::text || '+05:30')::timestamptz
    else now()
  end;

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

  select coalesce(sum((l->>'quantity')::integer * s.size_ml), 0)
  into v_mix_ml
  from jsonb_array_elements(p_mix) l
  join skus s on s.id = (l->>'sku_id')::uuid;

  for v_i in 1..p_count loop
    insert into orders (order_code, requested_ml, status, created_by, created_at, updated_at, courier)
    values (
      coalesce(p_order_code_prefix, 'BULK') || '-' || v_timestamp || '-' || v_i,
      v_mix_ml,
      'fulfilled',
      p_created_by,
      v_created_at,
      v_created_at,
      p_courier
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

-- order_log_summary needs to surface courier. Since a "batch" (one Bulk/
-- Manual submission) always shares one courier value per the insert above,
-- min(o.courier) gives the batch's courier without changing the grouping.
drop view if exists order_log_summary;
create view order_log_summary as
select
  regexp_replace(o.order_code, '-[0-9]+$', '') as batch_key,
  min((o.created_at AT TIME ZONE 'Asia/Kolkata')::date) as order_date,
  min(o.created_at) as batch_created_at,
  min(o.courier) as courier,
  p.id as product_id,
  p.name as product_name,
  s.id as sku_id,
  s.sku_code,
  s.size_ml,
  count(distinct o.id) as order_count,
  sum(ol.quantity) as bottle_count,
  sum(ol.quantity * s.size_ml) as total_ml
from orders o
join order_lines ol on ol.order_id = o.id
join skus s on s.id = ol.sku_id
join products p on p.id = s.product_id
group by regexp_replace(o.order_code, '-[0-9]+$', ''), p.id, p.name, s.id, s.sku_code, s.size_ml
order by min(o.created_at) desc, p.name, s.sku_code;

grant select on order_log_summary to authenticated;

-- Lets Operation staff set/update the courier for an existing batch
-- (every order sharing that batch_key) after the fact.
create or replace function set_batch_courier(p_batch_key text, p_courier text)
returns void as $$
begin
  update orders
  set courier = p_courier, updated_at = now()
  where order_code like p_batch_key || '-%';
end;
$$ language plpgsql security definer set search_path = public;
