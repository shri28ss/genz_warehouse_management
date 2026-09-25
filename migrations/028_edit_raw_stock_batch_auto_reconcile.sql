-- ============================================================
-- Migration: edit a raw stock batch by total only — auto-reconciled
-- into boxes + loose pieces. User enters the corrected total count;
-- box_count = total / units_per_box (floor), loose_units = remainder.
-- No lower-bound restriction (unlike the old total-only version,
-- which kept box_count fixed and could reject a lower total).
-- Stock delta applied the same way as before.
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
    insert into stock_movements (sku_id, movement_type, quantity_change, note, created_by)
    values (
      v_batch.sku_id,
      'adjustment',
      v_delta,
      'Raw stock batch ' || p_batch_id || ' corrected: ' || v_batch.total_units || ' -> ' || p_new_total,
      p_actor_id
    );
  end if;

  return query select v_batch.total_units, p_new_total, v_box_count, v_loose_units;
end;
$$ language plpgsql security definer set search_path = public;

grant execute on function edit_raw_stock_batch_total(uuid, integer, uuid) to authenticated;

-- the full box/loose editor from the previous migration is no
-- longer used by the app; drop it
drop function if exists edit_raw_stock_batch(uuid, integer, integer, uuid);
