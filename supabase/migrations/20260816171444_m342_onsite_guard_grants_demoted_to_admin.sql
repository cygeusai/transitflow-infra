-- m342_onsite_guard_grants_demoted_to_admin
--
-- At 17:06:43 UTC another operator applied onsite_scope_verification_gate,
-- creating public.tf_guard_onsite_verification: a SECURITY DEFINER trigger
-- function, correctly declared in tf_function_registry, but left holding the
-- Supabase default EXECUTE grants to anon and authenticated. A1 and A15 went
-- red on the next suite run, which is the ratchet working exactly as built:
-- an unreviewed definer surface may not appear silently.
--
-- The right disposition is DEMOTION, not allowlisting. A trigger function is
-- fired by its trigger, which runs regardless of the calling role's EXECUTE
-- privilege on the function; no browser session ever needs to call it
-- directly, so there is nothing to review INTO the authenticated surface.
-- Revoking anon and authenticated leaves the trigger fully functional and
-- returns both assertions to green.
--
-- Applied via tf_apply_grant_tier because revoke-from-public alone is a no-op
-- against Supabase's ALTER DEFAULT PRIVILEGES; anon and authenticated must be
-- named, and the tier table keeps the decision on the record.
--
-- This migration refuses to run if the function has vanished, and is a no-op
-- if a later migration already demoted it.

do $$
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'tf_guard_onsite_verification'
  ) then
    raise exception 'tf_guard_onsite_verification no longer exists; this migration is stale and must not be replayed blindly';
  end if;
end $$;

select public.tf_apply_grant_tier('tf_guard_onsite_verification', '', 'admin',
  'SECURITY DEFINER trigger function shipped by onsite_scope_verification_gate with default grants. Triggers fire regardless of caller EXECUTE privilege, so no browser role needs this; demoted rather than allowlisted. Closes the A1/A15 red of 2026-08-16 17:13 UTC.');
