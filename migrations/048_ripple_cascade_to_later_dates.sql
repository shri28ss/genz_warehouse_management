-- ============================================================
-- Migration: ripple packaging corrections forward to later dates
-- When an order/RTO/leak is backdated to a past date, its
-- box_bubble_wrap (or raw_unpacked) adjustment only applied to that
-- one date. But "Copy previous day" carries a date's ending totals
-- forward as a snapshot — so any date AFTER the backdated one that
-- already had its baseline copied in is now stale by exactly that
-- adjustment, until someone notices the mismatch and manually
-- corrects it (as happened repeatedly before this fix).
--
-- Fix: subtract_packaging_cascade now applies the same net change to
-- every later log_date that already has packaging entries, not just
-- the backdated date itself — keeping every day's tally in sync
-- automatically regardless of when corrections land.
-- ============================================================

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
