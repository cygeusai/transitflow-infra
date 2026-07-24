# Transit & Flow — Platform Repository

Enterprise field-service and property-management platform. This repository is the
version-controlled source of truth for the Transit & Flow Hub (frontend) and the
Supabase backend (database, functions, security, and edge functions).

> Brand: **Transit & Flow**. Premium, modern, operationally excellent.

## What lives where

| Layer | System | In this repo |
|-------|--------|--------------|
| Frontend app (the Hub) | Lovable (TanStack Start + Tailwind + shadcn/ui) | Synced via Lovable → GitHub (see below). Lives under `/app` once connected. |
| Backend database | Supabase Postgres (project `kjooyhvynkzuvsixsutt`) | `supabase/migrations/` |
| Edge functions | Supabase Edge (Deno) | `supabase/functions/` |
| Ops docs / SOPs | Notion + ClickUp | Linked from `docs/` (not code) |

## First-time setup

This repo is a clean scaffold. Populate the full backend from the live Supabase
project with one command set (requires the Supabase CLI and a login):

```bash
./scripts/pull-backend.sh
```

That links the project, pulls the complete migration history into
`supabase/migrations/`, and downloads every edge function into
`supabase/functions/`. See `scripts/pull-backend.sh` for details.

## Frontend (Lovable → GitHub)

Connect the Hub app to this GitHub org from the Lovable editor:
**Lovable → GitHub → Connect to GitHub**. Lovable then two-way syncs the app code
to a repository automatically on every edit. Recommended repo name: `transitflow-hub`.

## Structure

```
.
├── README.md
├── ARCHITECTURE.md          High-level system + data-domain overview
├── CONTRIBUTING.md          Branching, migrations, review workflow
├── .env.example             Required environment variables (no secrets)
├── .github/workflows/ci.yml Migration + basic checks on every PR
├── scripts/pull-backend.sh  One-command backend export from Supabase
├── supabase/
│   ├── migrations/          Ordered SQL migrations (source of truth)
│   └── functions/           Edge functions (Deno)
└── docs/                    Links to the Notion documentation suite
```

## Environments

- Production Supabase project ref: `kjooyhvynkzuvsixsutt`
- App (published): https://goqtf.lovable.app

## Security

Secrets are never committed. All keys (QuickBooks, Twilio, Stripe, Housecall Pro,
ClickUp) live in Supabase Vault and are referenced by name at runtime. See
`.env.example` for the variable contract and `CONTRIBUTING.md` for the rules.
