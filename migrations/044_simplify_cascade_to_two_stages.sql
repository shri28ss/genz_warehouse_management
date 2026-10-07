-- ============================================================
-- Migration: simplify subtract_packaging_cascade to two stages
-- Previously cascaded through all 6 manual stages (box_bubble_wrap,
-- box_labeled, box_packed, bottle_bubble_wrap, bottle_plastic_wrap,
-- raw_unpacked) when the first stage didn't have enough quantity.
-- User wants only two stages involved: try box_bubble_wrap first, and
-- if that's not enough, take the remainder directly from raw_unpacked
-- (raw bottles) — skip the middle stages entirely.
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
  end if;

  if v_remaining > 0 then
    insert into packaging_daily_log (log_date, sku_id, stage, quantity, recorded_by)
    values (p_date, p_sku_id, 'raw_unpacked'::packaging_stage, -v_remaining, p_actor_id);
  end if;
end;
$$ language plpgsql security definer set search_path = public;
