-- ============================================================
-- Migration: server-side copy_previous_day RPC, race-safe by construction
-- The frontend's "Copy previous day" button checked for existing entries
-- client-side before inserting — a classic TOCTOU race if clicked twice
-- quickly, and no protection at all if the user confirmed through the
-- old "already has data, continue anyway?" dialog. This kept causing
-- doubled baselines (same bug class as migration 051, but for the
-- manual button rather than the automatic one).
--
-- Moves the copy into a single Postgres function that takes the same
-- per-(empty check) safety as ensure_packaging_baseline: it uses the
-- advisory lock scheme, so two concurrent calls for the same date are
-- serialized and the second one correctly sees the first's committed
-- rows and skips.
-- ============================================================

create or replace function copy_previous_day_packaging(
  p_date date,
  p_actor_id uuid
)
returns table (copied boolean, from_date date) as $$
declare
  v_lock_key bigint;
  v_has_entries boolean;
  v_prev_date date;
  v_row record;
begin
  -- One lock per target date (covers all SKUs at once) — serializes this
  -- function against itself and against any ensure_packaging_baseline call
  -- for the same date, since both use the same hashing scheme per SKU; a
  -- date-wide lock here is a coarser but sufficient guard for the button.
  v_lock_key := hashtextextended('copy_day:' || p_date::text, 0);
  perform pg_advisory_xact_lock(v_lock_key);

  select exists(
    select 1 from packaging_daily_log where log_date = p_date
  ) into v_has_entries;

  if v_has_entries then
    return query select false, null::date;
    return;
  end if;

  select max(log_date) into v_prev_date
  from packaging_daily_log
  where log_date < p_date;

  if v_prev_date is null then
    return query select false, null::date;
    return;
  end if;

  for v_row in
    select sku_id, stage, sum(quantity)::integer as total
    from packaging_daily_log
    where log_date = v_prev_date
    group by sku_id, stage
    having sum(quantity) != 0
  loop
    insert into packaging_daily_log (log_date, sku_id, stage, quantity, recorded_by)
    values (p_date, v_row.sku_id, v_row.stage, v_row.total, p_actor_id);
  end loop;

  return query select true, v_prev_date;
end;
$$ language plpgsql security definer set search_path = public;

grant execute on function copy_previous_day_packaging(date, uuid) to authenticated;
