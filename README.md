# Warehouse Management System

Ghee warehouse ke liye stock, packaging, dispatch, aur reconciliation track karne ka system. React + Vite frontend, Supabase (Postgres) backend.

## Roles

- **Super Admin** — products/SKUs manage, users approve, raw stock inward, raw stock edit
- **Operation Incharge** — bulk/manual orders, daily packaging tally, dispatch, RTO, scan-fail reconciliation
- **Client** — read-only stock overview + dispatch summary

## Local setup

```bash
npm install
cp .env.example .env   # fill in your Supabase URL + anon key
npm run dev
```

## Database

`schema.sql` has the full schema (run once on a fresh Supabase project). `migrations/` has the incremental changes applied since, in order — useful as a history/reference, not required for a fresh setup (schema.sql already reflects the latest state... verify before relying on this for a from-scratch deploy).

## Deployment

Deployed via Vercel, connected to this GitHub repo. Push to `main` auto-deploys. Environment variables (`VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`) are set in the Vercel project settings, not committed to the repo.
