-- ============================================================
-- Migration: RTO returns table + trigger + RLS (run AFTER 019)
-- ============================================================

create table rto_returns (
  id uuid primary key default gen_random_uuid(),
  sku_id uuid not null references skus(id),
  quantity_returned integer not null check (quantity_returned > 0),
  return_date date not null default current_date,
  recounted_by uuid not null references profiles(id),
  note text,
  stock_movement_id uuid references stock_movements(id),
  created_at timestamptz not null default now()
);

create index idx_rto_returns_date on rto_returns(return_date);
create index idx_rto_returns_sku on rto_returns(sku_id);

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
  return new;
end;
$$ language plpgsql security definer set search_path = public;

create trigger trg_log_rto_return
before insert on rto_returns
for each row execute function log_rto_return();

alter table rto_returns enable row level security;

create policy ops_manage_rto_returns on rto_returns for all
  using (current_role_name() in ('operation_incharge', 'super_admin'))
  with check (current_role_name() in ('operation_incharge', 'super_admin'));
