-- ============================================================
-- Migration: allow loose/partial units alongside full boxes on
-- raw stock inward (e.g. "5 boxes + 8 loose bottles").
-- ============================================================

alter table raw_stock_batches alter column box_count set default 0;
alter table raw_stock_batches drop constraint if exists raw_stock_batches_box_count_check;
alter table raw_stock_batches add constraint raw_stock_batches_box_count_check check (box_count >= 0);

alter table raw_stock_batches add column if not exists loose_units integer not null default 0 check (loose_units >= 0);

alter table raw_stock_batches drop constraint if exists raw_stock_batches_box_or_loose_check;
alter table raw_stock_batches add constraint raw_stock_batches_box_or_loose_check check (box_count > 0 or loose_units > 0);

-- total_units must be dropped and recreated since it's a generated column
alter table raw_stock_batches drop column total_units;
alter table raw_stock_batches add column total_units integer generated always as (box_count * units_per_box_at_time + loose_units) stored;

create or replace function log_raw_stock_batch()
returns trigger as $$
declare
  v_units_per_box integer;
  v_movement_id uuid;
  v_total integer;
begin
  select units_per_box into v_units_per_box from skus where id = new.sku_id;
  new.units_per_box_at_time := v_units_per_box;
  v_total := new.box_count * v_units_per_box + new.loose_units;

  insert into stock_movements (sku_id, movement_type, quantity_change, note, created_by)
  values (
    new.sku_id,
    'raw_inward',
    v_total,
    'Raw stock batch: ' || new.box_count || ' boxes + ' || new.loose_units || ' loose units',
    new.received_by
  )
  returning id into v_movement_id;

  new.stock_movement_id := v_movement_id;
  return new;
end;
$$ language plpgsql security definer set search_path = public;
