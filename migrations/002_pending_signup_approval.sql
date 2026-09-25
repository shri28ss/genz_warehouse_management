-- ============================================================
-- Migration: in-app signup + admin approval flow
-- Run this in Supabase SQL Editor (schema.sql was already applied
-- without this — this adds the 'pending' role state and the
-- auto-profile-creation trigger on top of it).
-- ============================================================

-- 1. Add 'pending' to the role enum
alter type user_role add value if not exists 'pending';

-- 2. Relax profiles.role default + add approval tracking columns
alter table profiles alter column role set default 'pending';
alter table profiles add column if not exists approved_by uuid references profiles(id);
alter table profiles add column if not exists approved_at timestamptz;

-- 3. Auto-create a 'pending' profile row on every new auth signup
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

drop trigger if exists trg_handle_new_auth_user on auth.users;
create trigger trg_handle_new_auth_user
after insert on auth.users
for each row execute function handle_new_auth_user();

-- 4. Allow a signed-up (even 'pending') user to read their own profile row
--    so the app can show "waiting for approval". Already covered by
--    read_own_profile policy from schema.sql — no change needed there.
