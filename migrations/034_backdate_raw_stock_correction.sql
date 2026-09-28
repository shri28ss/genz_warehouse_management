-- ============================================================
-- Migration: backdate raw-stock-batch corrections to received_date
-- Editing a batch's total (Admin > Raw Stock Inward > Edit) created
-- its correcting 'adjustment' stock_movements row with created_at
-- defaulting to now() — so the correction only affected "today
-- forward" in historical reports (Packaging Tally's per-date
-- Warehouse Stock column), not the batch's actual arrival date.
-- Now the correction is timestamped to the end of the batch's
-- received_date (IST), so every date on/after arrival reflects the
-- corrected total, matching what actually happened historically.
-- ============================================================

create or replace function edit_raw_stock_batch_total(
  p_batch_id uuid,
  p_new_total integer,
  p_actor_id uuid
)
returns table (
  old_total integer,
  new_total integer,
  new_box_count integer,
  new_loose_units integer
) as $$
declare
  v_batch raw_stock_batches;
  v_delta integer;
  v_box_count integer;
  v_loose_units integer;
  v_effective_at timestamptz;
begin
  select * into v_batch from raw_stock_batches where id = p_batch_id;
  if v_batch is null then
    raise exception 'Raw stock batch % not found', p_batch_id;
  end if;
  if p_new_total <= 0 then
    raise exception 'Total must be greater than zero';
  end if;

  v_box_count := p_new_total / v_batch.units_per_box_at_time;
  v_loose_units := p_new_total % v_batch.units_per_box_at_time;

  v_delta := p_new_total - v_batch.total_units;

  update raw_stock_batches
  set box_count = v_box_count,
      loose_units = v_loose_units
  where id = p_batch_id;

  if v_delta != 0 then
    v_effective_at := (v_batch.received_date::text || ' 23:59:59.999+05:30')::timestamptz;

    insert into stock_movements (sku_id, movement_type, quantity_change, note, created_by, created_at)
    values (
      v_batch.sku_id,
      'adjustment',
      v_delta,
      'Raw stock batch ' || p_batch_id || ' corrected: ' || v_batch.total_units || ' -> ' || p_new_total,
      p_actor_id,
      v_effective_at
    );
  end if;

  return query select v_batch.total_units, p_new_total, v_box_count, v_loose_units;
end;
$$ language plpgsql security definer set search_path = public;
