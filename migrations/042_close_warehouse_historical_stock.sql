-- ============================================================
-- Migration: close_warehouse compares against the closure date's
-- historical stock, not always-live stock_levels
-- close_warehouse() always read stock_levels (today's live total) to
-- check the match, regardless of which date was being closed. So
-- closing a PAST date (logDate != today) could show "all matched" in
-- the frontend (which correctly uses stock_balance_as_of for past
-- dates) but then fail server-side with a stale mismatch, because live
-- stock had moved since due to later activity — leaving a contradictory
-- error message stuck on screen even after the data was actually fine.
--
-- Fix: compare packaging totals against stock_balance_as_of(p_closure_date)
-- when closing a past date, and live stock_levels only when closing today
-- (where they're equivalent anyway).
-- ============================================================

create or replace function close_warehouse(
  p_closure_date date,
  p_manual_stage_totals jsonb,
  p_note text,
  p_actor_id uuid
)
returns table (closure_id uuid, all_matched boolean) as $$
declare
  v_sku record;
  v_manual_sum integer;
  v_packaging_total integer;
  v_stock integer;
  v_matched boolean;
  v_all_matched boolean := true;
  v_closure_id uuid;
  v_lines jsonb := '[]'::jsonb;
  v_is_today boolean;
begin
  v_is_today := p_closure_date = (now() AT TIME ZONE 'Asia/Kolkata')::date;

  -- p_manual_stage_totals carries everything that's still physically in
  -- the warehouse: raw_unpacked + the 5 packaging stages + leak.
  -- 'dispatched' is intentionally NOT part of this sum — those bottles
  -- already left the warehouse, so including them would make the total
  -- exceed the actual warehouse stock.
  for v_sku in select id from skus where is_active = true
  loop
    select coalesce(sum(value::text::integer), 0) into v_manual_sum
    from jsonb_each(coalesce(p_manual_stage_totals -> v_sku.id::text, '{}'::jsonb));

    v_packaging_total := v_manual_sum;

    if v_is_today then
      select quantity into v_stock from stock_levels where sku_id = v_sku.id;
    else
      select quantity into v_stock from stock_balance_as_of(p_closure_date) where sku_id = v_sku.id;
    end if;
    v_stock := coalesce(v_stock, 0);

    v_matched := (v_packaging_total = v_stock);
    if not v_matched then
      v_all_matched := false;
    end if;

    v_lines := v_lines || jsonb_build_object(
      'sku_id', v_sku.id,
      'packaging_total', v_packaging_total,
      'warehouse_stock', v_stock,
      'matched', v_matched
    );
  end loop;

  if not v_all_matched and (p_note is null or trim(p_note) = '') then
    raise exception 'Mismatch found — a note is required to close the warehouse anyway.';
  end if;

  insert into warehouse_closures (closure_date, all_matched, note, closed_by)
  values (p_closure_date, v_all_matched, nullif(trim(p_note), ''), p_actor_id)
  returning id into v_closure_id;

  insert into warehouse_closure_lines (closure_id, sku_id, packaging_total, warehouse_stock, matched)
  select
    v_closure_id,
    (line->>'sku_id')::uuid,
    (line->>'packaging_total')::integer,
    (line->>'warehouse_stock')::integer,
    (line->>'matched')::boolean
  from jsonb_array_elements(v_lines) line;

  return query select v_closure_id, v_all_matched;
end;
$$ language plpgsql security definer set search_path = public;
