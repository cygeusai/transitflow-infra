# Contributing

## Branching

- `main` is protected and always deployable.
- Branch per change: `feat/…`, `fix/…`, `chore/…`, `docs/…`.
- Open a pull request; CI must pass and one review is required before merge.
- Commits stranded in a session that cannot push are recovered with a git
  bundle: see [`docs/PHONE_BUNDLE_HANDOFF.md`](docs/PHONE_BUNDLE_HANDOFF.md).
  Bundled work lands on a branch and goes through review like anything else.

## Database changes (migrations)

All schema, RLS, functions, and triggers are **migration-first**. Never change the
production database by hand outside a named migration.

1. Create a migration with the Supabase CLI:
   ```bash
   supabase migration new my_change
   ```
2. Write idempotent, forward-only SQL. Prefer `create or replace`, `if not exists`,
   and additive RLS policies. Keep one active policy set per table + role + command.
3. Test locally (`supabase db reset`) or against a preview branch.
4. Commit the file under `supabase/migrations/` and open a PR.

### RLS rules

- Every new table gets RLS enabled and explicit policies before it ships.
- Cross-table lookups inside a policy must go through a `SECURITY DEFINER` helper
  (never inline-subquery another RLS-protected table) to avoid policy recursion.
- New `SECURITY DEFINER` functions: `revoke execute … from public, anon;` and grant
  only to `authenticated` and/or `service_role` as appropriate.

## Edge functions

- Live under `supabase/functions/<name>/index.ts` (Deno).
- Webhooks verify signatures and set `verify_jwt = false`; user-facing functions
  verify the JWT and check the caller's identity.
- Deploy: `supabase functions deploy <name>`.

## Secrets

- Never commit secrets. Store them in Supabase Vault and read them at runtime with
  `get_secret`. `.env.example` documents the contract only.

## Money + safety gates

- Payment processors and outbound customer messaging are gated behind explicit
  configuration flags. Do not enable live money movement without owner sign-off.
