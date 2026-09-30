-- ============================================================
-- Migration: add RTO returns to box_bubble_wrap on their return date
-- An RTO (Return to Origin) already added its quantity back to
-- stock_movements (so live/historical stock correctly goes up), but
-- never touched packaging_daily_log — so after an RTO, Total would sit
-- below Warehouse Stock by exactly the returned quantity, on the RTO's
-- own return_date and every date after it.
--
-- Fix: the same trigger that logs the stock_movements reversal now also
-- inserts a positive packaging_daily_log entry for box_bubble_wrap on
-- the RTO's return_date, so the packaging pipeline total stays in sync
-- with the stock the RTO actually put back in the warehouse.
-- ============================================================

create or replace function log_rto_return()
returns trigger as $$
declare
  v_movement_id uuid;
begin
  insert into stock_movements (sku_id, movement_type, quantity_change, note, created_by)
  values (
    new.sku_id,
    'rto_return',
    new.quantity_returned,
    coalesce(new.note, 'RTO return'),
    new.recounted_by
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
