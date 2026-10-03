-- ============================================================
-- Migration: leak entries subtract from box_bubble_wrap
-- A leaked/damaged bottle was already sitting in some packaging stage
-- before it got logged as a leak — it doesn't vanish or get a fresh
-- source, it's an already-counted bottle that just left the "good"
-- pipeline. Logging a leak added its quantity to Total (via the Leak
-- column) without removing it from wherever it actually was, so Total
-- grew above Warehouse Stock by exactly the leaked quantity every time
-- a leak was logged — same bug class as dispatch/RTO/order-delete,
-- now fixed for leak too.
--
-- Fix: a trigger on leak_entries mirrors the leaked quantity into
-- box_bubble_wrap (cascading through other stages if that one doesn't
-- have enough logged for the leak's date) on insert, reverses it on
-- delete, and adjusts by the delta on update (quantity or leak_date
-- change) — the same cascade helper used by dispatch (migration 035).
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
  v_stage packaging_stage;
  v_available integer;
  v_take integer;
  v_stages packaging_stage[] := array['box_bubble_wrap', 'box_labeled', 'box_packed', 'bottle_bubble_wrap', 'bottle_plastic_wrap', 'raw_unpacked']::packaging_stage[];
begin
  if p_amount <= 0 then
    return;
  end if;

  foreach v_stage in array v_stages loop
    exit when v_remaining <= 0;

    select coalesce(sum(quantity), 0) into v_available
    from packaging_daily_log
    where sku_id = p_sku_id and log_date = p_date and stage = v_stage;

    if v_available > 0 then
      v_take := least(v_available, v_remaining);
      insert into packaging_daily_log (log_date, sku_id, stage, quantity, recorded_by)
      values (p_date, p_sku_id, v_stage, -v_take, p_actor_id);
      v_remaining := v_remaining - v_take;
    end if;
  end loop;

  if v_remaining > 0 then
    insert into packaging_daily_log (log_date, sku_id, stage, quantity, recorded_by)
    values (p_date, p_sku_id, 'box_bubble_wrap'::packaging_stage, -v_remaining, p_actor_id);
  end if;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function sync_leak_to_packaging()
returns trigger as $$
begin
  if TG_OP = 'INSERT' then
    perform subtract_packaging_cascade(new.sku_id, new.leak_date, new.quantity, new.recorded_by);
    return new;
  elsif TG_OP = 'UPDATE' then
    -- Undo the old entry's effect, then apply the new one — simplest way to
    -- handle a changed quantity and/or a changed leak_date correctly.
    insert into packaging_daily_log (log_date, sku_id, stage, quantity, recorded_by)
    values (old.leak_date, old.sku_id, 'box_bubble_wrap'::packaging_stage, old.quantity, coalesce(new.recorded_by, old.recorded_by));
    perform subtract_packaging_cascade(new.sku_id, new.leak_date, new.quantity, coalesce(new.recorded_by, old.recorded_by));
    return new;
  elsif TG_OP = 'DELETE' then
    insert into packaging_daily_log (log_date, sku_id, stage, quantity, recorded_by)
    values (old.leak_date, old.sku_id, 'box_bubble_wrap'::packaging_stage, old.quantity, old.recorded_by);
    return old;
  end if;
  return null;
end;
$$ language plpgsql security definer set search_path = public;

drop trigger if exists trg_sync_leak_to_packaging on leak_entries;
create trigger trg_sync_leak_to_packaging
  after insert or update or delete on leak_entries
  for each row execute function sync_leak_to_packaging();
