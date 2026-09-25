-- ============================================================
-- Migration: bulk delete raw stock batches with stock reversal
-- Deleting a batch also reverses its stock addition (an
-- 'adjustment' movement subtracting total_units), so a mistaken
-- or duplicate raw-stock entry can be cleanly undone from the UI.
-- ============================================================

create or replace function delete_raw_stock_batches_bulk(p_batch_ids uuid[])
returns void as $$
declare
  v_batch record;
begin
  for v_batch in
    select id, sku_id, total_units
    from raw_stock_batches
    where id = any(p_batch_ids)
  loop
    insert into stock_movements (sku_id, movement_type, quantity_change, note, created_by)
    values (
      v_batch.sku_id,
      'adjustment',
      -v_batch.total_units,
      'Reversal: raw stock batch ' || v_batch.id || ' deleted',
      auth.uid()
    );

    delete from raw_stock_batches where id = v_batch.id;
  end loop;
end;
$$ language plpgsql security definer set search_path = public;

grant execute on function delete_raw_stock_batches_bulk(uuid[]) to authenticated;
