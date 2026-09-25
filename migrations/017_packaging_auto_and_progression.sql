-- ============================================================
-- Migration: auto-log first packaging stage on order fulfillment,
-- plus a "move to next stage" RPC for one-click progression.
--
-- Design: packaging_daily_totals already sums quantity per
-- (date, sku, stage) as an independent running total per stage —
-- NOT a pipeline where moving forward removes from the prior stage.
-- "Pending in stage N" is a derived value = total(stage N) - total(stage N+1)
-- for the same sku/date (i.e. how much has reached this stage but not
-- yet the next one). "Move to next stage" logs a new packaging_daily_log
-- row for stage N+1 with quantity = pending-in-stage-N, for a given
-- sku/date. This keeps every stage's total an honest historical sum
-- (so daily reports stay simple) while letting the UI show/advance
-- a single "current pending count" per SKU.
-- ============================================================

-- 1. bulk_fulfill_orders now also logs the bottle-mix into
--    packaging_daily_log under 'bottle_plastic_wrap' for the order's
--    creation date, once per SKU per call (summed across the p_count
--    orders), instead of leaving packaging tracking fully separate.
create or replace function bulk_fulfill_orders(
  p_order_code_prefix text,
  p_count integer,
  p_mix jsonb,
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

  -- Auto-log the whole batch's bottle-mix into packaging tally as
  -- 'bottle_plastic_wrap', one row per SKU (summed over p_count orders).
  for v_line in select * from jsonb_array_elements(p_mix)
  loop
    v_sku_id := (v_line->>'sku_id')::uuid;
    v_qty := (v_line->>'quantity')::integer;

    insert into packaging_daily_log (log_date, sku_id, stage, quantity, recorded_by)
    values (current_date, v_sku_id, 'bottle_plastic_wrap', v_qty * p_count, p_created_by);
  end loop;

  return;
end;
$$ language plpgsql security definer set search_path = public;

-- 2. One-click stage progression: move whatever is "pending" in the
--    given stage for a sku/date into the next stage.
create or replace function advance_packaging_stage(
  p_sku_id uuid,
  p_date date,
  p_from_stage packaging_stage,
  p_to_stage packaging_stage,
  p_actor_id uuid
)
returns integer as $$
declare
  v_from_total integer;
  v_to_total integer;
  v_pending integer;
begin
  select coalesce(sum(quantity), 0) into v_from_total
  from packaging_daily_log
  where sku_id = p_sku_id and log_date = p_date and stage = p_from_stage;

  select coalesce(sum(quantity), 0) into v_to_total
  from packaging_daily_log
  where sku_id = p_sku_id and log_date = p_date and stage = p_to_stage;

  v_pending := v_from_total - v_to_total;

  if v_pending <= 0 then
    raise exception 'Nothing pending in % to move to %', p_from_stage, p_to_stage;
  end if;

  insert into packaging_daily_log (log_date, sku_id, stage, quantity, recorded_by)
  values (p_date, p_sku_id, p_to_stage, v_pending, p_actor_id);

  return v_pending;
end;
$$ language plpgsql security definer set search_path = public;

grant execute on function advance_packaging_stage(uuid, date, packaging_stage, packaging_stage, uuid) to authenticated;
