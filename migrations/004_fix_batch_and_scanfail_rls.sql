-- ============================================================
-- Migration: fix RLS block on raw_stock_batches / scan_fail_returns
-- Same root cause as 003: these trigger functions insert into
-- stock_movements on the caller's behalf but weren't SECURITY
-- DEFINER, so RLS blocked the write. Making them SECURITY DEFINER
-- lets the trigger write regardless of the caller's own direct
-- access to stock_movements.
-- ============================================================

create or replace function log_raw_stock_batch()
returns trigger as $$
declare
  v_units_per_box integer;
  v_movement_id uuid;
begin
  select units_per_box into v_units_per_box from skus where id = new.sku_id;
  new.units_per_box_at_time := v_units_per_box;

  insert into stock_movements (sku_id, movement_type, quantity_change, note, created_by)
  values (
    new.sku_id,
    'raw_inward',
    new.box_count * v_units_per_box,
    'Raw stock batch: ' || new.box_count || ' boxes',
    new.received_by
  )
  returning id into v_movement_id;

  new.stock_movement_id := v_movement_id;
  return new;
end;
$$ language plpgsql security definer set search_path = public;

create or replace function log_scan_fail_return()
returns trigger as $$
declare
  v_movement_id uuid;
begin
  insert into stock_movements (sku_id, movement_type, quantity_change, note, created_by)
  values (
    new.sku_id,
    'scan_fail_return',
    new.quantity_returned,
    coalesce(new.note, 'Scan-fail return'),
    new.recounted_by
  )
  returning id into v_movement_id;

  new.stock_movement_id := v_movement_id;
  return new;
end;
$$ language plpgsql security definer set search_path = public;
