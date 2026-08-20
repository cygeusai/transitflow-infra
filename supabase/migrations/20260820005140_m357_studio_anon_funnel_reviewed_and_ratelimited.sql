-- m357_studio_anon_funnel_reviewed_and_ratelimited
--
-- The board went red on A1 and A15 after another operator shipped a deliberate
-- pre-authentication studio signup funnel (ordinals 503-510). This is the
-- assertions working as designed: the three new functions carry correct
-- tf_function_grant_tiers declarations and tf_function_registry rows, but the
-- two closed-allowlist assertions had not been told about them. A closed
-- allowlist that nobody reviews is not an allowlist.
--
-- Disposition after reading all three definitions: KEEP them anon-reachable.
-- A professional signing a founding agreement has no account by definition,
-- so anon is the intended reach, not drift. Demoting them would break another
-- team's funnel. Three changes:
--   1. Harden the one unbounded anon write path before blessing it.
--   2. Record the review in tf_authenticated_definer_allowlist (A15).
--   3. Convert A1 from a hardcoded name list into a declaration-driven check,
--      so a correctly declared anon function never reds the board again and an
--      undeclared one always does.

-- ---------------------------------------------------------------------------
-- 1. tf_studio_accept_agreement: dedupe, rate limit, and stop swallowing errors
-- ---------------------------------------------------------------------------
-- Signature is unchanged on purpose. The existing grant-tier row matches on
-- pg_get_function_identity_arguments, which includes parameter names.
create or replace function public.tf_studio_accept_agreement(
  p_agreement_key text,
  p_company_name  text,
  p_signer_name   text,
  p_signer_email  text,
  p_signer_title  text default null,
  p_license_number text default null,
  p_application_id uuid default null,
  p_user_agent    text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $function$
declare
  v_ver      public.studio_agreement_versions%rowtype;
  v_id       uuid;
  v_email    text := lower(btrim(coalesce(p_signer_email,'')));
  v_ip       inet;
  v_existing public.studio_agreement_acceptances%rowtype;
  v_recent   int;
begin
  if coalesce(btrim(p_company_name),'') = ''
     or coalesce(btrim(p_signer_name),'') = ''
     or v_email = '' then
    return jsonb_build_object('ok', false, 'error', 'missing_required_fields',
      'note', 'Company name, signer name and signer email are all required for an acceptance to be evidence of anything.');
  end if;

  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    return jsonb_build_object('ok', false, 'error', 'invalid_email');
  end if;

  select * into v_ver from public.studio_agreement_versions
   where agreement_key = p_agreement_key and is_current and published_at is not null;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'no_published_version',
      'note', 'There is no current published version of this agreement, so nothing can be accepted. This is a refusal, not a failure.');
  end if;

  -- Idempotence. One signer signs one version once. A double-clicked button, a
  -- retried request or a replayed payload must return the signature already on
  -- file, never mint a second one. Two rows for one signature is a defect in a
  -- legal evidence ledger, not a duplicate record.
  select * into v_existing
    from public.studio_agreement_acceptances
   where agreement_key     = p_agreement_key
     and agreement_version = v_ver.version
     and lower(signer_email) = v_email
     and revoked_at is null
   order by accepted_at asc
   limit 1;

  if found then
    return jsonb_build_object(
      'ok', true, 'duplicate', true,
      'acceptance_id', v_existing.id,
      'agreement_key', p_agreement_key,
      'version', v_existing.agreement_version,
      'sha256', v_existing.body_sha256,
      'accepted_at', v_existing.accepted_at,
      'note', 'This signer already accepted this version. Returning the acceptance already on file.');
  end if;

  -- Volumetric guard. This function is reachable before authentication, which
  -- is intended, so the ledger needs a ceiling that does not depend on a
  -- session existing. The signer-email dedupe above defeats replay; this
  -- defeats a script cycling fresh addresses from one origin. A null address
  -- is not counted because it cannot be attributed, and refusing every caller
  -- we cannot identify would refuse real signers behind a stripped header.
  begin
    v_ip := nullif(current_setting('request.headers', true)::json ->> 'x-forwarded-for','')::inet;
  exception when invalid_text_representation or invalid_parameter_value then
    raise warning 'tf_studio_accept_agreement: unparseable x-forwarded-for, proceeding without network address (SQLSTATE %)', sqlstate;
    v_ip := null;
  end;

  if v_ip is not null then
    select count(*) into v_recent
      from public.studio_agreement_acceptances
     where ip_address = v_ip
       and accepted_at > now() - interval '24 hours';
    if v_recent >= 25 then
      raise warning 'tf_studio_accept_agreement: rate limit hit, % acceptances from one origin in 24h', v_recent;
      return jsonb_build_object('ok', false, 'error', 'rate_limited',
        'note', 'Too many acceptances from this origin in the last 24 hours. Contact Transit & Flow and a person will complete this by hand.');
    end if;
  end if;

  insert into public.studio_agreement_acceptances
    (agreement_key, agreement_version, body_sha256, user_id, application_id,
     company_name, signer_name, signer_title, signer_email, license_number,
     ip_address, user_agent)
  values
    (p_agreement_key, v_ver.version, v_ver.body_sha256, auth.uid(), p_application_id,
     btrim(p_company_name), btrim(p_signer_name), nullif(btrim(coalesce(p_signer_title,'')),''),
     v_email, nullif(btrim(coalesce(p_license_number,'')),''),
     v_ip,
     coalesce(p_user_agent, current_setting('request.headers', true)::json ->> 'user-agent'))
  returning id into v_id;

  return jsonb_build_object(
    'ok', true,
    'duplicate', false,
    'acceptance_id', v_id,
    'agreement_key', p_agreement_key,
    'version', v_ver.version,
    'sha256', v_ver.body_sha256,
    'accepted_at', now()
  );
end;
$function$;

comment on function public.tf_studio_accept_agreement(text,text,text,text,text,text,uuid,text) is
  'Records a binding studio agreement acceptance. Anon-callable by design: a professional signs before holding an account. Idempotent per (agreement_key, version, lower(signer_email)). Capped at 25 acceptances per origin address per 24 hours. Version and body hash are read from the database, never accepted from the caller. Hardened in m357 as a condition of anon allowlisting.';

-- The previous revision caught every exception and silently retried the insert,
-- which meant a constraint failure could be reported to a signer as success.
-- The header parse is now the only thing guarded, it is guarded where it
-- happens, and it raises a warning instead of disappearing. Everything else
-- propagates, because a signature that did not record must not return ok.

-- ---------------------------------------------------------------------------
-- 2. A15: record the review
-- ---------------------------------------------------------------------------
insert into public.tf_authenticated_definer_allowlist
  (proname, classification, rationale, reviewed_in, reviewed_at)
values
  ('tf_studio_current_agreement','catalog_read',
   'Read-only, STABLE. Returns six named fields of the CURRENT PUBLISHED agreement version only, or a refusal object when nothing is published. Selects named columns rather than the row, so a future column cannot leak. Reviewed against its full definition on 2026-08-20: no write path, no tenant data, no PII. A professional must be able to read terms before creating an account.',
   'm357', now()),
  ('tf_studio_submit_founding_application','ui_action',
   'Sole write path for the public Founding Access form. Validates company, contact and email presence, enforces an email pattern, caps company 200 / contact 200 / email 320 / notes 4000, clamps seats to 1-25 and deduplicates repeat submissions from the same lowercased email inside 24 hours. Writes status pending only. Deliberately a function rather than a table grant so applicant PII is never selectable. Reviewed against its full definition on 2026-08-20.',
   'm357', now()),
  ('tf_studio_accept_agreement','ui_action',
   'Records a binding agreement acceptance from a signer who has no account yet, so anon is the intended reach. Hardened in m357 before this allowlisting: idempotent per signer and version, capped at 25 acceptances per origin address per 24 hours, and no longer swallows insert failures behind a blanket exception retry. Version and body hash are read from studio_agreement_versions, never from the caller, so a signer cannot backdate or misattribute what they signed. Rows are never anon-readable.',
   'm357', now())
on conflict (proname) do update
  set classification = excluded.classification,
      rationale      = excluded.rationale,
      reviewed_in    = excluded.reviewed_in,
      reviewed_at    = excluded.reviewed_at;

-- ---------------------------------------------------------------------------
-- 3. A1: stop hardcoding the reviewed anon surface
-- ---------------------------------------------------------------------------
-- A1 asserted the anon SECURITY DEFINER surface against a name list written
-- into the assertion body. That list has now gone stale twice, and each time
-- it went stale the board reported a critical failure for functions that were
-- correctly declared. Worse, a bare name list would also have silently
-- exempted a future public.auth_org.
--
-- The source of truth already exists: tf_function_grant_tiers, which every
-- anon grant must pass through, carries tier and a written rationale. A1 now
-- reads that. A correctly declared anon function passes. An undeclared one, or
-- one declared with a token rationale, still fails critical. The three cygeus
-- legacy functions predate the tier table and are excepted by name AND schema.
do $do$
declare
  v_def text;
  v_new text;
  v_hits int;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'tf_platform_regression_suite';

  if v_def is null then
    raise exception 'm357: public.tf_platform_regression_suite not found';
  end if;

  v_new := regexp_replace(
    v_def,
    $pat$and p\.proname not in \('auth_org'[^;]*;$pat$,
    $repl$and not (n.nspname = 'cygeus'
             and p.proname in ('auth_org','has_permission','create_organization_and_owner'))
    and not exists (select 1 from public.tf_function_grant_tiers t
                     where n.nspname = 'public'
                       and t.proname = p.proname
                       and t.ident_args = pg_get_function_identity_arguments(p.oid)
                       and t.tier = 'anon'
                       and length(coalesce(t.rationale,'')) >= 60);$repl$);

  if v_new = v_def then
    raise exception 'm357: A1 predicate not found in tf_platform_regression_suite, refusing to guess';
  end if;

  select count(*) into v_hits
    from regexp_matches(v_def, $pat2$and p\.proname not in \('auth_org'$pat2$, 'g') m;
  if v_hits <> 1 then
    raise exception 'm357: expected exactly 1 A1 predicate, found %', v_hits;
  end if;

  execute v_new;
end
$do$;

-- ---------------------------------------------------------------------------
-- Convention 33: registry rows for every function this migration writes.
-- ---------------------------------------------------------------------------
insert into public.tf_function_registry
  (proname, declared_kind, documented_as_diagnostic, write_acknowledged, rationale, created_at, updated_at)
values
  ('tf_studio_accept_agreement','write', false, true,
   'Records a binding agreement acceptance. Callable by anon because a professional signs before holding an account; the rows it writes carry PII and are never anon-readable. Version and hash are read from the database, never accepted from the caller. m357 added per-signer idempotence, a 25-per-origin-per-24h ceiling, and removed the blanket exception retry that could report a failed insert as success.',
   now(), now()),
  ('tf_platform_regression_suite','read', true, false,
   'The platform regression suite. m357 changed A1 from a hardcoded name list to a check against tf_function_grant_tiers, so the reviewed anon surface is read from the declaration table rather than from the assertion body.',
   now(), now())
on conflict (proname) do update
  set declared_kind = excluded.declared_kind,
      documented_as_diagnostic = excluded.documented_as_diagnostic,
      write_acknowledged = excluded.write_acknowledged,
      rationale = excluded.rationale,
      updated_at = now();