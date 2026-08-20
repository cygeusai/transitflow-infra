-- ============================================================================
-- Transit Entitlements: the server-side entitlement resolver.
-- A tf_* function, so it is declared in tf_function_registry in the same
-- transaction (Convention 33) and given a grant tier. SECURITY INVOKER, so RLS
-- scopes reads to the caller's company.
-- ============================================================================

create or replace function public.tf_company_has_entitlement(cid uuid, ent_key text)
returns boolean
language sql
stable
security invoker
set search_path to 'public', 'pg_catalog'
as $fn$
  select
    exists (
      select 1
      from public.tf_subscriptions s
      join public.tf_plans p on p.id = s.plan_id
      where s.company_id = cid
        and s.status = 'active'
        and coalesce((p.entitlements ->> ent_key)::boolean, false)
    )
    or exists (
      select 1
      from public.tf_entitlement_overrides o
      where o.company_id = cid
        and o.entitlement_key = ent_key
        and coalesce((o.value #>> '{}')::boolean, false)
        and (o.expires_at is null or o.expires_at > now())
    );
$fn$;

comment on function public.tf_company_has_entitlement(uuid, text) is
  'Transit Entitlements resolver: is company cid entitled to module ent_key? Reads active subscription plan entitlements plus non-expired overrides. SECURITY INVOKER so RLS scopes reads to the caller company. Called server-side in RPC and RLS, never the frontend alone.';

-- Convention 33: declare in the same migration as the creation.
insert into public.tf_function_registry (proname, declared_kind, rationale)
select 'tf_company_has_entitlement', 'read',
       'Read-only entitlement resolver for Transit Entitlements. Returns whether a company holds a module entitlement via an active subscription plan or a non-expired override. No writes.'
where not exists (
  select 1 from public.tf_function_registry where proname = 'tf_company_has_entitlement'
);

-- Grant tier staff: postgres, service_role, authenticated. Any authenticated
-- member may resolve their own company's entitlement; RLS scopes the rows read.
select public.tf_apply_grant_tier(
  'tf_company_has_entitlement',
  pg_get_function_identity_arguments(oid),
  'staff',
  'Entitlement resolver, safe for authenticated callers; RLS scopes reads to the caller company.'
)
from pg_proc
where proname = 'tf_company_has_entitlement'
  and pronamespace = 'public'::regnamespace;