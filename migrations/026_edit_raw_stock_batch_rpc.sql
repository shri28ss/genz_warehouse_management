-- ============================================================
-- Migration: edit a raw stock batch's total count directly.
-- User enters a corrected total (pieces); this adjusts loose_units
-- so box_count * units_per_box_at_time + loose_units = new total
-- (box_count itself is unchanged — only the "extra pieces" figure
-- absorbs the correction). The stock delta (new_total - old_total)
-- is applied to stock_levels via a compensating 'adjustment'
-- stock_movements row, so existing order fulfillments/dispatches
-- etc. are untouched and the running balance just shifts by the
-- correction amount.
-- ============================================================

create or replace function edit_raw_stock_batch_total(
  p_batch_id uuid,
  p_new_total integer,
  p_actor_id uuid
)
returns table (
  old_total integer,
  new_total integer,
  new_loose_units integer
) as $$
declare
  v_batch raw_stock_batches;
  v_delta integer;
  v_new_loose integer;
begin
  select * into v_batch from raw_stock_batches where id = p_batch_id;
  if v_batch is null then
    raise exception 'Raw stock batch % not found', p_batch_id;
  end if;
  if p_new_total < 0 then
    raise exception 'Total cannot be negative';
  end if;

  v_new_loose := p_new_total - (v_batch.box_count * v_batch.units_per_box_at_time);
  if v_new_loose < 0 then
    raise exception 'New total (%) is too low for % boxes at % units/box — minimum possible total is %',
      p_new_total, v_batch.box_count, v_batch.units_per_box_at_time, v_batch.box_count * v_batch.units_per_box_at_time;
  end if;

  v_delta := p_new_total - v_batch.total_units;

  update raw_stock_batches
  set loose_units = v_new_loose
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

  return query select v_batch.total_units, p_new_total, v_new_loose;
end;
$$ language plpgsql security definer set search_path = public;

grant execute on function edit_raw_stock_batch_total(uuid, integer, uuid) to authenticated;
