-- ============================================================
-- Migration: warehouse closure with packaging/stock reconciliation
--
-- Design:
-- - "Dispatched" packaging stage is no longer manually punched —
--   it's derived live from actual dispatched units for that SKU/day
--   (same source as the Dispatch tab's scan_fail_summary view).
-- - Closing the warehouse for a date checks, per active SKU:
--     sum(5 manual stages) + dispatched_units_today  ==  current stock_levels.quantity
--   If every SKU matches, the closure is logged as matched (no note
--   needed). If any SKU mismatches, a note is required to close anyway
--   — the closure is still logged, just flagged with the mismatch
--   detail and the operator's note.
-- - Each close attempt is a new row (closing multiple times a day is
--   normal and each is its own log entry), so warehouse_closures is
--   an append-only log, never updated/deleted.
-- ============================================================

create table warehouse_closures (
  id uuid primary key default gen_random_uuid(),
  closure_date date not null default current_date,
  all_matched boolean not null,
  note text,
  closed_by uuid not null references profiles(id),
  created_at timestamptz not null default now()
);

create index idx_warehouse_closures_date on warehouse_closures(closure_date);

-- One row per SKU per closure attempt, recording what was compared.
create table warehouse_closure_lines (
  id uuid primary key default gen_random_uuid(),
  closure_id uuid not null references warehouse_closures(id) on delete cascade,
  sku_id uuid not null references skus(id),
  packaging_total integer not null,  -- sum of 5 manual stages + dispatched-today
  warehouse_stock integer not null,  -- stock_levels.quantity at close time
  matched boolean not null
);

create index idx_warehouse_closure_lines_closure on warehouse_closure_lines(closure_id);

alter table warehouse_closures enable row level security;
alter table warehouse_closure_lines enable row level security;

create policy ops_manage_warehouse_closures on warehouse_closures for all
  using (current_role_name() in ('operation_incharge', 'super_admin'))
  with check (current_role_name() in ('operation_incharge', 'super_admin'));

create policy ops_manage_warehouse_closure_lines on warehouse_closure_lines for all
  using (current_role_name() in ('operation_incharge', 'super_admin'))
  with check (current_role_name() in ('operation_incharge', 'super_admin'));

-- ============================================================
-- close_warehouse: computes per-SKU packaging-total vs stock,
-- inserts the closure + line rows, and enforces the note-required
-- rule (raises if there's a mismatch and no note was given).
-- p_manual_stage_totals: jsonb like {"<sku_id>": {"bottle_plastic_wrap": 10, ...}}
-- covering the 5 manual stages only (not 'dispatched').
-- ============================================================
create or replace function close_warehouse(
  p_closure_date date,
  p_manual_stage_totals jsonb,
  p_note text,
  p_actor_id uuid
)
returns table (
  closure_id uuid,
  all_matched boolean
) as $$
declare
  v_sku record;
  v_manual_sum integer;
  v_dispatched integer;
  v_packaging_total integer;
  v_stock integer;
  v_matched boolean;
  v_all_matched boolean := true;
  v_closure_id uuid;
  v_lines jsonb := '[]'::jsonb;
begin
  -- First pass: compute match status per active SKU without writing anything,
  -- so we can bail out before persisting if a note is required but missing.
  for v_sku in select id from skus where is_active = true
  loop
    select coalesce(sum(value::text::integer), 0) into v_manual_sum
    from jsonb_each(coalesce(p_manual_stage_totals -> v_sku.id::text, '{}'::jsonb));

    select coalesce(sum(total_units), 0) into v_dispatched
    from scan_fail_summary
    where sku_id = v_sku.id and order_date = p_closure_date;

    v_packaging_total := v_manual_sum + coalesce(v_dispatched, 0);

    select quantity into v_stock from stock_levels where sku_id = v_sku.id;
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

grant execute on function close_warehouse(date, jsonb, text, uuid) to authenticated;

-- ============================================================
-- Closure log view: readable join for the UI (date-filterable list
-- of every closure attempt, with per-SKU breakdown).
-- ============================================================
create or replace view warehouse_closure_log as
select
  wc.id as closure_id,
  wc.closure_date,
  wc.all_matched,
  wc.note,
  wc.created_at,
  p.full_name as closed_by_name,
  wcl.sku_id,
  s.sku_code,
  wcl.packaging_total,
  wcl.warehouse_stock,
  wcl.matched
from warehouse_closures wc
join profiles p on p.id = wc.closed_by
join warehouse_closure_lines wcl on wcl.closure_id = wc.id
join skus s on s.id = wcl.sku_id
order by wc.created_at desc, s.sku_code;
