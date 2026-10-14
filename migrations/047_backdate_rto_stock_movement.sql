-- ============================================================
-- Migration: backdate the RTO's stock_movements row to its return_date
-- log_rto_return() correctly dates the packaging_daily_log entry to
-- return_date, but its stock_movements insert never specified
-- created_at, so it defaulted to now() — meaning an RTO backdated to an
-- earlier date updated packaging for that date immediately, but live
-- stock's historical balance for that same date didn't move until
-- today. Same bug class as migration 046 (orders), now fixed for RTO.
-- ============================================================

create or replace function log_rto_return()
returns trigger as $$
declare
  v_movement_id uuid;
  v_effective_at timestamptz;
begin
  v_effective_at := (new.return_date::text || ' 23:59:59.999+05:30')::timestamptz;

  insert into stock_movements (sku_id, movement_type, quantity_change, note, created_by, created_at)
  values (
    new.sku_id,
    'rto_return',
    new.quantity_returned,
    coalesce(new.note, 'RTO return'),
    new.recounted_by,
    v_effective_at
  )
  returning id into v_movement_id;

  new.stock_movement_id := v_movement_id;

  insert into packaging_daily_log (log_date, sku_id, stage, quantity, recorded_by)
  values (
    new.return_date,
    new.sku_id,
    'box_bubble_wrap'::packaging_stage,
    new.quantity_returned,
    new.recounted_by
  );

  return new;
end;
$$ language plpgsql security definer set search_path = public;
