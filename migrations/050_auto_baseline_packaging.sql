-- ============================================================
-- Migration: auto-create a packaging baseline when one doesn't exist yet
-- Order fulfillment, RTO, and leak all adjust a SKU's packaging stages
-- on a specific date. If nobody had opened the Packaging Tally for that
-- date yet (no "Copy previous day" run), the adjustment landed on an
-- empty day — going deeply negative — and then a later manual "Copy
-- previous day" would add the real baseline on top, leaving Total out
-- of sync with Warehouse Stock until someone noticed and fixed it by
-- hand. This happened repeatedly.
--
-- Fix: subtract_packaging_cascade and add_packaging_ripple now call
-- ensure_packaging_baseline first, which checks whether the target
-- date already has ANY packaging_daily_log rows for this SKU — if not,
-- it finds the most recent earlier date that does and copies that
-- date's ending per-stage totals forward automatically, exactly like
-- clicking "Copy previous day" would. The adjustment then applies on
-- top of a real baseline instead of nothing, so Total stays correct
-- without anyone needing to click the button first.
-- ============================================================

create or replace function ensure_packaging_baseline(
  p_sku_id uuid,
  p_date date,
  p_actor_id uuid
)
returns void as $$
declare
  v_has_entries boolean;
  v_prev_date date;
  v_row record;
begin
  select exists(
    select 1 from packaging_daily_log where sku_id = p_sku_id and log_date = p_date
  ) into v_has_entries;

  if v_has_entries then
    return;
  end if;

  select max(log_date) into v_prev_date
  from packaging_daily_log
  where sku_id = p_sku_id and log_date < p_date;

  if v_prev_date is null then
    return;
  end if;

  for v_row in
    select stage, sum(quantity)::integer as total
    from packaging_daily_log
    where sku_id = p_sku_id and log_date = v_prev_date
    group by stage
    having sum(quantity) != 0
  loop
    insert into packaging_daily_log (log_date, sku_id, stage, quantity, recorded_by)
    values (p_date, p_sku_id, v_row.stage, v_row.total, p_actor_id);
  end loop;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function subtract_packaging_cascade(
  p_sku_id uuid,
  p_date date,
  p_amount integer,
  p_actor_id uuid
)
returns void as $$
declare
  v_remaining integer := p_amount;
  v_available integer;
  v_take integer;
  v_box_taken integer := 0;
  v_raw_taken integer := 0;
  v_later_date date;
begin
  if p_amount <= 0 then
    return;
  end if;

  perform ensure_packaging_baseline(p_sku_id, p_date, p_actor_id);

  select coalesce(sum(quantity), 0) into v_available
  from packaging_daily_log
  where sku_id = p_sku_id and log_date = p_date and stage = 'box_bubble_wrap'::packaging_stage;

  if v_available > 0 then
    v_take := least(v_available, v_remaining);
    insert into packaging_daily_log (log_date, sku_id, stage, quantity, recorded_by)
    values (p_date, p_sku_id, 'box_bubble_wrap'::packaging_stage, -v_take, p_actor_id);
    v_remaining := v_remaining - v_take;
    v_box_taken := v_take;
  end if;

  if v_remaining > 0 then
    insert into packaging_daily_log (log_date, sku_id, stage, quantity, recorded_by)
    values (p_date, p_sku_id, 'raw_unpacked'::packaging_stage, -v_remaining, p_actor_id);
    v_raw_taken := v_remaining;
  end if;

  -- Ripple the same net change into every later date that already has a
  -- packaging baseline, so a "Copy previous day" snapshot taken before
  -- this correction doesn't silently fall out of sync.
  for v_later_date in
    select distinct log_date from packaging_daily_log
    where sku_id = p_sku_id and log_date > p_date
    order by log_date
  loop
    if v_box_taken > 0 then
      insert into packaging_daily_log (log_date, sku_id, stage, quantity, recorded_by)
      values (v_later_date, p_sku_id, 'box_bubble_wrap'::packaging_stage, -v_box_taken, p_actor_id);
    end if;
    if v_raw_taken > 0 then
      insert into packaging_daily_log (log_date, sku_id, stage, quantity, recorded_by)
      values (v_later_date, p_sku_id, 'raw_unpacked'::packaging_stage, -v_raw_taken, p_actor_id);
    end if;
  end loop;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function add_packaging_ripple(
  p_sku_id uuid,
  p_date date,
  p_stage packaging_stage,
  p_amount integer,
  p_actor_id uuid
)
returns void as $$
declare
  v_later_date date;
begin
  if p_amount = 0 then
    return;
  end if;

  perform ensure_packaging_baseline(p_sku_id, p_date, p_actor_id);

  insert into packaging_daily_log (log_date, sku_id, stage, quantity, recorded_by)
  values (p_date, p_sku_id, p_stage, p_amount, p_actor_id);

  for v_later_date in
    select distinct log_date from packaging_daily_log
    where sku_id = p_sku_id and log_date > p_date
    order by log_date
  loop
    insert into packaging_daily_log (log_date, sku_id, stage, quantity, recorded_by)
    values (v_later_date, p_sku_id, p_stage, p_amount, p_actor_id);
  end loop;
end;
$$ language plpgsql security definer set search_path = public;
