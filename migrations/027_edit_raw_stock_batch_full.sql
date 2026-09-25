-- ============================================================
-- Migration: replace edit_raw_stock_batch_total with a full-row
-- editor — box_count and loose_units both directly editable
-- (not just total), since correcting boxes alone was previously
-- blocked by the "total can't go below box-only minimum" guard.
-- Same delta-to-stock-levels mechanism as before.
-- ============================================================

create or replace function edit_raw_stock_batch(
  p_batch_id uuid,
  p_new_box_count integer,
  p_new_loose_units integer,
  p_actor_id uuid
)
returns table (
  old_total integer,
  new_total integer
) as $$
declare
  v_batch raw_stock_batches;
  v_new_total integer;
  v_delta integer;
begin
  select * into v_batch from raw_stock_batches where id = p_batch_id;
  if v_batch is null then
    raise exception 'Raw stock batch % not found', p_batch_id;
  end if;
  if p_new_box_count < 0 or p_new_loose_units < 0 then
    raise exception 'Box count and loose units cannot be negative';
  end if;
  if p_new_box_count = 0 and p_new_loose_units = 0 then
    raise exception 'Box count and loose units cannot both be zero';
  end if;

  v_new_total := p_new_box_count * v_batch.units_per_box_at_time + p_new_loose_units;
  v_delta := v_new_total - v_batch.total_units;

  update raw_stock_batches
  set box_count = p_new_box_count,
      loose_units = p_new_loose_units
  where id = p_batch_id;

  if v_delta != 0 then
    insert into stock_movements (sku_id, movement_type, quantity_change, note, created_by)
    values (
      v_batch.sku_id,
      'adjustment',
      v_delta,
      'Raw stock batch ' || p_batch_id || ' corrected: ' || v_batch.total_units || ' -> ' || v_new_total,
      p_actor_id
    );
  end if;

  return query select v_batch.total_units, v_new_total;
end;
$$ language plpgsql security definer set search_path = public;

grant execute on function edit_raw_stock_batch(uuid, integer, integer, uuid) to authenticated;

-- old single-field function no longer used by the app; drop it
drop function if exists edit_raw_stock_batch_total(uuid, integer, uuid);
