-- ============================================================
-- Migration: restore box_bubble_wrap on deleting a dispatched order
-- Deleting an order already reverses stock_movements (adds the
-- quantity back to stock_levels). But if the order had been dispatched,
-- migration 035 had already subtracted its quantity from box_bubble_wrap
-- (cascading through other stages if needed) at dispatch time — deleting
-- the order never added that back, so Total would fall permanently
-- behind Warehouse Stock by the dispatched-then-deleted quantity.
--
-- Fix: when delete_orders_bulk removes a 'dispatched' order, also insert
-- a positive packaging_daily_log entry for box_bubble_wrap on the
-- order's own (IST) date, undoing exactly what dispatch had subtracted.
-- Orders still only 'fulfilled' (never dispatched) never touched
-- packaging_daily_log in the first place, so they're left alone here.
-- ============================================================

create or replace function delete_orders_bulk(p_order_ids uuid[])
returns void as $$
declare
  v_order_id uuid;
  v_order_status text;
  v_order_date date;
  v_line record;
begin
  foreach v_order_id in array p_order_ids
  loop
    select status, (created_at AT TIME ZONE 'Asia/Kolkata')::date
    into v_order_status, v_order_date
    from orders where id = v_order_id;

    for v_line in
      select ol.sku_id, ol.quantity
      from order_lines ol
      where ol.order_id = v_order_id
        and v_order_status in ('fulfilled', 'dispatched')
    loop
      insert into stock_movements (sku_id, movement_type, quantity_change, note, created_by)
      values (
        v_line.sku_id,
        'adjustment',
        v_line.quantity,
        'Reversal: order ' || v_order_id || ' deleted',
        auth.uid()
      );

      if v_order_status = 'dispatched' then
        insert into packaging_daily_log (log_date, sku_id, stage, quantity, recorded_by)
        values (
          v_order_date,
          v_line.sku_id,
          'box_bubble_wrap'::packaging_stage,
          v_line.quantity,
          auth.uid()
        );
      end if;
    end loop;

    delete from orders where id = v_order_id;
  end loop;
end;
$$ language plpgsql security definer set search_path = public;
