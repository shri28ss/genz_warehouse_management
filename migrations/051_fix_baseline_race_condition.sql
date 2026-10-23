-- ============================================================
-- Migration: fix race condition in ensure_packaging_baseline
-- ensure_packaging_baseline checked "does this SKU/date have any
-- entries yet" and then inserted the copied baseline — but if two
-- calls landed close together (e.g. several orders fulfilled in quick
-- succession, or the manual "Copy previous day" button racing with an
-- automatic baseline copy), both could see "no entries yet" before
-- either had committed, and both would copy the full baseline —
-- doubling it. This is exactly the same class of bug as clicking
-- "Copy previous day" twice, just triggered automatically instead of
-- by hand, and it's why gaps kept reappearing even after migration 050.
--
-- Fix: take a Postgres advisory transaction lock keyed on (sku_id,
-- date) before the check. The lock serializes concurrent calls for the
-- same SKU/date — whichever commits first is immediately visible to
-- the next one waiting on the lock, so only one copy ever happens.
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
  v_lock_key bigint;
begin
  -- Hash sku_id + date into a single bigint lock key. xact-scoped advisory
  -- lock: held until the calling transaction commits or rolls back, and
  -- blocks any other transaction trying to lock the same key meanwhile.
  v_lock_key := hashtextextended(p_sku_id::text || ':' || p_date::text, 0);
  perform pg_advisory_xact_lock(v_lock_key);

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
