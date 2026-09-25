-- ============================================================
-- Warehouse Management System — Ghee Packaging & Stock
-- Supabase (Postgres) schema
-- ============================================================

-- ---------- ROLES ----------
-- Using Supabase Auth (auth.users) + a profiles table for role mapping.
-- 'pending' = signed up but not yet approved/assigned a real role by super_admin.
create type user_role as enum ('pending', 'super_admin', 'operation_incharge', 'client');

create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text not null,
  email text not null unique,
  role user_role not null default 'pending',
  approved_by uuid references profiles(id),
  approved_at timestamptz,
  created_at timestamptz not null default now()
);

-- Auto-create a 'pending' profile row whenever someone signs up via Supabase Auth.
-- full_name/email come from the signup call's user_metadata / auth.users.email.
create or replace function handle_new_auth_user()
returns trigger as $$
begin
  insert into public.profiles (id, full_name, email, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', new.email),
    new.email,
    'pending'
  );
  return new;
end;
$$ language plpgsql security definer set search_path = public;

create trigger trg_handle_new_auth_user
after insert on auth.users
for each row execute function handle_new_auth_user();

-- ============================================================
-- PRODUCTS & SKUs
-- Every sellable unit (bottle/tin size) is its own SKU.
-- Stock is always counted in whole SKU units — never in "liters".
-- ============================================================

create table products (
  id uuid primary key default gen_random_uuid(),
  name text not null,              -- e.g. 'Agam Gold', 'Sahyadri', 'Agam Buffalo'
  created_at timestamptz not null default now(),
  unique (name)
);

create table skus (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references products(id) on delete restrict,
  size_ml integer not null,        -- 500, 1000, 5000 etc — always in ml for exact math
  sku_code text not null unique,   -- e.g. 'AGAM-GOLD-500', 'AGAM-GOLD-1L' — the real identifier;
                                    -- a product+size can have more than one SKU (e.g. bottle vs pouch)
  units_per_box integer not null check (units_per_box > 0), -- raw bottles per carton, e.g. 30
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

-- Current stock, one row per SKU. Updated only via stock_movements (see trigger below)
-- so this always reflects the ledger — never edited directly by the app.
create table stock_levels (
  sku_id uuid primary key references skus(id) on delete restrict,
  quantity integer not null default 0 check (quantity >= 0),
  updated_at timestamptz not null default now()
);

-- ============================================================
-- STOCK MOVEMENT LEDGER
-- Single source of truth for every +/- change to stock.
-- Raw material inward, order fulfillment, scan-fail returns —
-- everything is a row here. stock_levels is a derived cache.
-- ============================================================

create type movement_type as enum (
  'raw_inward',        -- super admin adds new stock
  'order_fulfillment', -- bottles allocated to an order (negative)
  'scan_fail_return',  -- bottles returned to stock after failed dispatch scan (positive)
  'rto_return',        -- bottles returned to stock after RTO (dispatched order came back)
  'adjustment'         -- manual correction (daily count mismatch fix)
);

create table stock_movements (
  id uuid primary key default gen_random_uuid(),
  sku_id uuid not null references skus(id) on delete restrict,
  movement_type movement_type not null,
  quantity_change integer not null,   -- positive or negative
  reference_order_id uuid,            -- nullable FK to orders, set for fulfillment/return
  note text,
  created_by uuid not null references profiles(id),
  created_at timestamptz not null default now()
);

create index idx_stock_movements_sku on stock_movements(sku_id);
create index idx_stock_movements_order on stock_movements(reference_order_id);
create index idx_stock_movements_created_at on stock_movements(created_at);

-- Keep stock_levels in sync automatically
-- security definer: this runs with the function owner's privileges so it can
-- write to stock_levels regardless of the caller's RLS policies on that table
-- (callers only ever get INSERT rights on stock_movements, never direct
-- write access to stock_levels).
create or replace function apply_stock_movement()
returns trigger as $$
begin
  insert into stock_levels (sku_id, quantity, updated_at)
  values (new.sku_id, new.quantity_change, now())
  on conflict (sku_id)
  do update set
    quantity = stock_levels.quantity + new.quantity_change,
    updated_at = now();
  return new;
end;
$$ language plpgsql security definer set search_path = public;

create trigger trg_apply_stock_movement
after insert on stock_movements
for each row execute function apply_stock_movement();

-- ============================================================
-- RAW STOCK BATCHES (carton-level inward tracking)
-- Raw material never arrives bottle-by-bottle — it arrives in
-- cartons/boxes, and box size is fixed per SKU (skus.units_per_box).
-- Super admin logs "N boxes of SKU X arrived today"; a trigger
-- converts that into the bottle-count stock_movements entry
-- automatically. This table is the batch record (which delivery,
-- how many boxes, when) — stock_movements/stock_levels stay the
-- single source of truth for bottle counts.
-- ============================================================

create table raw_stock_batches (
  id uuid primary key default gen_random_uuid(),
  sku_id uuid not null references skus(id) on delete restrict,
  box_count integer not null default 0 check (box_count >= 0),
  loose_units integer not null default 0 check (loose_units >= 0), -- extra pieces outside a full box
  units_per_box_at_time integer not null, -- snapshot, in case box size changes later
  total_units integer generated always as (box_count * units_per_box_at_time + loose_units) stored,
  received_date date not null default current_date,
  supplier_note text,
  received_by uuid not null references profiles(id),
  stock_movement_id uuid references stock_movements(id), -- linked ledger entry
  created_at timestamptz not null default now(),
  check (box_count > 0 or loose_units > 0)
);

create index idx_raw_stock_batches_date on raw_stock_batches(received_date);
create index idx_raw_stock_batches_sku on raw_stock_batches(sku_id);

-- Auto-create the corresponding stock_movements ('raw_inward') row
-- whenever a carton batch is logged, using the SKU's current units_per_box.
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

create trigger trg_log_raw_stock_batch
before insert on raw_stock_batches
for each row execute function log_raw_stock_batch();

-- ============================================================
-- ORDERS
-- An order comes in as a total requested volume (e.g. "1L")
-- but is FULFILLED as a specific set of SKU/qty lines chosen
-- manually by the Operation Incharge. order_ml must equal the
-- sum of fulfilled line volumes (enforced in app layer / check below).
-- ============================================================

create type order_status as enum (
  'pending',         -- created, not yet fulfilled/packed
  'fulfilled',       -- bottles allocated from stock
  'dispatched',      -- scanned out successfully
  'scan_failed'      -- left packaging but didn't scan out; stock returned, record kept for reporting
);

create table orders (
  id uuid primary key default gen_random_uuid(),
  order_code text not null unique,       -- human-friendly order number
  client_id uuid references profiles(id),
  requested_ml integer not null check (requested_ml > 0), -- total volume ordered
  status order_status not null default 'pending',
  created_by uuid not null references profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- The actual bottle/tin mix chosen to fulfill an order.
-- sum(quantity * skus.size_ml) across an order's lines should equal orders.requested_ml.
create table order_lines (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders(id) on delete cascade,
  sku_id uuid not null references skus(id) on delete restrict,
  quantity integer not null check (quantity > 0),
  created_at timestamptz not null default now(),
  unique (order_id, sku_id)
);

-- Convenience view: does an order's fulfilled volume match what was requested?
create view order_fulfillment_check as
select
  o.id as order_id,
  o.order_code,
  o.requested_ml,
  coalesce(sum(ol.quantity * s.size_ml), 0) as fulfilled_ml,
  o.requested_ml = coalesce(sum(ol.quantity * s.size_ml), 0) as is_matched
from orders o
left join order_lines ol on ol.order_id = o.id
left join skus s on s.id = ol.sku_id
group by o.id, o.order_code, o.requested_ml;

-- ============================================================
-- DAILY PACKAGING TALLY
-- Not tied to individual orders — just running counts per day
-- per activity, punched in by Operation Incharge through the day.
-- ============================================================

create type packaging_stage as enum (
  'bottle_plastic_wrap',
  'bottle_bubble_wrap',
  'box_packed',
  'box_bubble_wrap',
  'box_labeled',
  'dispatched'
);

create table packaging_daily_log (
  id uuid primary key default gen_random_uuid(),
  log_date date not null default current_date,
  sku_id uuid not null references skus(id),
  stage packaging_stage not null,
  quantity integer not null check (quantity > 0), -- count added in this entry (incremental punch)
  recorded_by uuid not null references profiles(id),
  created_at timestamptz not null default now()
);

create index idx_packaging_log_date_stage on packaging_daily_log(log_date, stage);
create index idx_packaging_log_sku on packaging_daily_log(sku_id);

-- Rollup view: today's (or any day's) totals per SKU per stage
create view packaging_daily_totals as
select
  pl.log_date,
  pl.sku_id,
  s.sku_code,
  p.name as product_name,
  pl.stage,
  sum(pl.quantity) as total_quantity
from packaging_daily_log pl
join skus s on s.id = pl.sku_id
join products p on p.id = s.product_id
group by pl.log_date, pl.sku_id, s.sku_code, p.name, pl.stage
order by pl.log_date desc, s.sku_code, pl.stage;

-- ============================================================
-- SCAN-FAIL RECONCILIATION
-- Simple quantity-only reconciliation, not tied to a specific order.
-- e.g. "today 200 dispatched, 3 of SKU X didn't scan" — Operation
-- Incharge logs 3 against that SKU, and it's added back to stock.
-- A trigger creates the matching stock_movements ('scan_fail_return')
-- entry automatically.
-- ============================================================

create table scan_fail_returns (
  id uuid primary key default gen_random_uuid(),
  sku_id uuid not null references skus(id),
  quantity_returned integer not null check (quantity_returned > 0),
  return_date date not null default current_date,
  recounted_by uuid not null references profiles(id),
  note text,
  stock_movement_id uuid references stock_movements(id),
  created_at timestamptz not null default now()
);

create index idx_scan_fail_returns_date on scan_fail_returns(return_date);
create index idx_scan_fail_returns_sku on scan_fail_returns(sku_id);

create or replace function log_scan_fail_return()
returns trigger as $$
declare
  v_movement_id uuid;
begin
  insert into stock_movements (sku_id, movement_type, quantity_change, note, created_by)
  values (
    new.sku_id,
    'scan_fail_return',
    new.quantity_returned,
    coalesce(new.note, 'Scan-fail return'),
    new.recounted_by
  )
  returning id into v_movement_id;

  new.stock_movement_id := v_movement_id;
  return new;
end;
$$ language plpgsql security definer set search_path = public;

create trigger trg_log_scan_fail_return
before insert on scan_fail_returns
for each row execute function log_scan_fail_return();

-- ============================================================
-- RTO (RETURN TO ORIGIN)
-- Simple quantity-only reconciliation, same pattern as scan-fail
-- returns. A dispatched order came back (delivery failed) — log
-- the product/SKU + quantity that physically returned to the
-- warehouse, and it's added back to stock automatically.
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

-- ============================================================
-- DAILY STOCK REPORT (date-wise, per SKU)
-- One row per (date, sku): stock movement breakdown for that day
-- plus running closing balance. This is the main report view
-- for "date-wise bottle tracking".
-- ============================================================
create view daily_stock_report as
select
  sm.created_at::date as report_date,
  s.sku_code,
  p.name as product_name,
  s.size_ml,
  sum(case when sm.movement_type = 'raw_inward' then sm.quantity_change else 0 end) as raw_inward_qty,
  sum(case when sm.movement_type = 'order_fulfillment' then -sm.quantity_change else 0 end) as dispatched_qty,
  sum(case when sm.movement_type = 'scan_fail_return' then sm.quantity_change else 0 end) as returned_qty,
  sum(case when sm.movement_type = 'adjustment' then sm.quantity_change else 0 end) as adjustment_qty,
  sum(sm.quantity_change) as net_change,
  sum(sum(sm.quantity_change)) over (
    partition by s.id order by sm.created_at::date
  ) as closing_balance
from stock_movements sm
join skus s on s.id = sm.sku_id
join products p on p.id = s.product_id
group by sm.created_at::date, s.id, s.sku_code, p.name, s.size_ml
order by report_date desc, sku_code;

-- Combined daily ops report: stock movement + packaging activity, side by side per date.
-- Query with `where report_date = '2026-09-22'` (or a range) for a specific day's full picture.
create view daily_ops_summary as
select
  d.report_date,
  d.sku_code,
  d.product_name,
  d.size_ml,
  d.raw_inward_qty,
  d.dispatched_qty,
  d.returned_qty,
  d.adjustment_qty,
  d.closing_balance
from daily_stock_report d
order by d.report_date desc, d.sku_code;

-- ============================================================
-- INDEXES for common lookups
-- ============================================================
create index idx_orders_status on orders(status);
create index idx_orders_client on orders(client_id);
create index idx_order_lines_order on order_lines(order_id);
create index idx_skus_product on skus(product_id);

-- ============================================================
-- ROW LEVEL SECURITY (enable + basic policies)
-- ============================================================
alter table profiles enable row level security;
alter table products enable row level security;
alter table skus enable row level security;
alter table stock_levels enable row level security;
alter table stock_movements enable row level security;
alter table orders enable row level security;
alter table order_lines enable row level security;
alter table packaging_daily_log enable row level security;
alter table scan_fail_returns enable row level security;
alter table raw_stock_batches enable row level security;
alter table rto_returns enable row level security;

-- Helper: current user's role
create or replace function current_role_name()
returns user_role as $$
  select role from profiles where id = auth.uid();
$$ language sql stable security definer;

-- Super admin: full access everywhere
create policy super_admin_all_profiles on profiles for all
  using (current_role_name() = 'super_admin') with check (current_role_name() = 'super_admin');
create policy super_admin_all_products on products for all
  using (current_role_name() = 'super_admin') with check (current_role_name() = 'super_admin');
create policy super_admin_all_skus on skus for all
  using (current_role_name() = 'super_admin') with check (current_role_name() = 'super_admin');
create policy super_admin_all_stock_movements on stock_movements for all
  using (current_role_name() = 'super_admin') with check (current_role_name() = 'super_admin');

-- Everyone authenticated can read products/skus/stock levels (needed for dashboard)
create policy read_products on products for select using (auth.role() = 'authenticated');
create policy read_skus on skus for select using (auth.role() = 'authenticated');
create policy read_stock_levels on stock_levels for select using (auth.role() = 'authenticated');

-- Operation incharge: manage orders, order_lines, packaging log, scan-fail returns, stock movements
create policy ops_manage_orders on orders for all
  using (current_role_name() in ('operation_incharge', 'super_admin'))
  with check (current_role_name() in ('operation_incharge', 'super_admin'));
create policy ops_manage_order_lines on order_lines for all
  using (current_role_name() in ('operation_incharge', 'super_admin'))
  with check (current_role_name() in ('operation_incharge', 'super_admin'));
create policy ops_manage_packaging_log on packaging_daily_log for all
  using (current_role_name() in ('operation_incharge', 'super_admin'))
  with check (current_role_name() in ('operation_incharge', 'super_admin'));
create policy ops_manage_scan_fail on scan_fail_returns for all
  using (current_role_name() in ('operation_incharge', 'super_admin'))
  with check (current_role_name() in ('operation_incharge', 'super_admin'));
create policy ops_manage_raw_stock_batches on raw_stock_batches for all
  using (current_role_name() in ('operation_incharge', 'super_admin'))
  with check (current_role_name() in ('operation_incharge', 'super_admin'));
create policy ops_manage_rto_returns on rto_returns for all
  using (current_role_name() in ('operation_incharge', 'super_admin'))
  with check (current_role_name() in ('operation_incharge', 'super_admin'));
create policy ops_insert_stock_movements on stock_movements for insert
  with check (current_role_name() in ('operation_incharge', 'super_admin'));
create policy ops_read_stock_movements on stock_movements for select
  using (current_role_name() in ('operation_incharge', 'super_admin'));

-- Client: read-only aggregate dispatch overview (orders aren't linked
-- to individual clients in this workflow, so clients see all orders'
-- dispatch data, read-only, for the stock+dispatch overview dashboard)
create policy client_read_all_orders on orders for select
  using (current_role_name() = 'client');
create policy client_read_all_order_lines on order_lines for select
  using (current_role_name() = 'client');

-- Profiles: users can read their own row
create policy read_own_profile on profiles for select using (id = auth.uid());
