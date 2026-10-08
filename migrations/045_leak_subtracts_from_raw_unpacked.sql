-- ============================================================
-- Migration: leak subtracts directly from raw_unpacked, not box_bubble_wrap
-- User clarified leak should come straight from raw bottles (raw_unpacked),
-- not go through the box_bubble_wrap-first cascade used by dispatch/RTO/
-- order fulfillment. A leaked bottle is treated as never having made it
-- into the packaging pipeline at all.
-- ============================================================

create or replace function sync_leak_to_packaging()
returns trigger as $$
begin
  if TG_OP = 'INSERT' then
    insert into packaging_daily_log (log_date, sku_id, stage, quantity, recorded_by)
    values (new.leak_date, new.sku_id, 'raw_unpacked'::packaging_stage, -new.quantity, new.recorded_by);
    return new;
  elsif TG_OP = 'UPDATE' then
    -- Undo the old entry's effect, then apply the new one — simplest way to
    -- handle a changed quantity and/or a changed leak_date correctly.
    insert into packaging_daily_log (log_date, sku_id, stage, quantity, recorded_by)
    values (old.leak_date, old.sku_id, 'raw_unpacked'::packaging_stage, old.quantity, coalesce(new.recorded_by, old.recorded_by));
    insert into packaging_daily_log (log_date, sku_id, stage, quantity, recorded_by)
    values (new.leak_date, new.sku_id, 'raw_unpacked'::packaging_stage, -new.quantity, coalesce(new.recorded_by, old.recorded_by));
    return new;
  elsif TG_OP = 'DELETE' then
    insert into packaging_daily_log (log_date, sku_id, stage, quantity, recorded_by)
    values (old.leak_date, old.sku_id, 'raw_unpacked'::packaging_stage, old.quantity, old.recorded_by);
    return old;
  end if;
  return null;
end;
$$ language plpgsql security definer set search_path = public;
