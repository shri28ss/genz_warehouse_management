-- ============================================================
-- Migration: atomic order deletion with stock reversal
-- Deleting a 'fulfilled'/'dispatched' order must also reverse its
-- stock deduction (an 'adjustment' movement undoing the earlier
-- order_fulfillment), otherwise deleted orders leave stock
-- permanently short. order_lines cascade-delete with the order;
-- stock_movements rows are kept (audit trail) but the order_id
-- link is cleared since the order no longer exists.
-- ============================================================

create or replace function delete_orders_bulk(p_order_ids uuid[])
returns void as $$
declare
  v_order_id uuid;
  v_line record;
begin
  foreach v_order_id in array p_order_ids
  loop
    -- Reverse stock for every line on orders that had already deducted stock
    for v_line in
      select ol.sku_id, ol.quantity
      from order_lines ol
      join orders o on o.id = ol.order_id
      where ol.order_id = v_order_id
        and o.status in ('fulfilled', 'dispatched')
    loop
      insert into stock_movements (sku_id, movement_type, quantity_change, note, created_by)
      values (
        v_line.sku_id,
        'adjustment',
        v_line.quantity,
        'Reversal: order ' || v_order_id || ' deleted',
        auth.uid()
      );
    end loop;

    delete from orders where id = v_order_id;
  end loop;
end;
$$ language plpgsql security definer set search_path = public;

grant execute on function delete_orders_bulk(uuid[]) to authenticated;
