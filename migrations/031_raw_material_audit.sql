-- ============================================================
-- Migration: raw material audit log (Super Admin only)
-- Standalone historical record-keeping — batch number + product +
-- date + quantity. Completely independent of stock_levels/
-- stock_movements; does not affect current stock in any way.
-- Purpose: track/trace raw material batches (including pre-system
-- history) for reference, grouped and never mixed across batches.
-- ============================================================

create table raw_material_audit_entries (
  id uuid primary key default gen_random_uuid(),
  batch_label text not null,        -- free text, e.g. "Batch 1"
  product_id uuid not null references products(id),
  entry_date date not null,
  quantity integer not null check (quantity > 0),
  note text,
  recorded_by uuid not null references profiles(id),
  created_at timestamptz not null default now()
);

create index idx_raw_material_audit_batch on raw_material_audit_entries(batch_label);
create index idx_raw_material_audit_date on raw_material_audit_entries(entry_date);
create index idx_raw_material_audit_product on raw_material_audit_entries(product_id);

alter table raw_material_audit_entries enable row level security;

-- Super Admin only — this is explicitly an admin-only audit tool
create policy admin_manage_raw_material_audit on raw_material_audit_entries for all
  using (current_role_name() = 'super_admin')
  with check (current_role_name() = 'super_admin');
