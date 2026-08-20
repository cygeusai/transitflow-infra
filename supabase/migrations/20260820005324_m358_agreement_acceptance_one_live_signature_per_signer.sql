-- m358_agreement_acceptance_one_live_signature_per_signer
--
-- m357 made tf_studio_accept_agreement idempotent by reading before writing.
-- That leaves a check-then-act window: two concurrent submissions from the same
-- signer both read "no acceptance on file" and both insert. In a legal evidence
-- ledger, two live signatures for one signer on one version is not a duplicate
-- row, it is an ambiguous record. The guarantee belongs in the database, where
-- concurrency cannot route around it.
--
-- The index is partial on revoked_at is null so a revoked signature does not
-- block a genuine re-signing of the same version.

create unique index if not exists studio_agreement_acceptances_one_live_per_signer
  on public.studio_agreement_acceptances (agreement_key, agreement_version, lower(signer_email))
  where revoked_at is null;

comment on index public.studio_agreement_acceptances_one_live_per_signer is
  'One live acceptance per signer per agreement version. Closes the check-then-act race in tf_studio_accept_agreement, which handles the resulting unique_violation by returning the signature already on file.';

-- Teach the function to lose that race gracefully. A signer who double-submits
-- must see their signature, not an error, and must never see a second one.
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
  -- file, never mint a second one.
  select * into v_existing
    from public.studio_agreement_acceptances
   where agreement_key     = p_agreement_key
     and agreement_version = v_ver.version
     and lower(signer_email) = v_email
     and revoked_at is null
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

  -- Volumetric guard. Reachable before authentication by design, so the ledger
  -- needs a ceiling that does not depend on a session existing. The signer
  -- dedupe above defeats replay; this defeats a script cycling fresh addresses
  -- from one origin. A null address is not counted because it cannot be
  -- attributed, and refusing every caller we cannot identify would refuse real
  -- signers behind a stripped header.
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

  begin
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
  exception when unique_violation then
    -- Lost the race against a concurrent submission from the same signer. The
    -- other transaction's row is the signature. Return it. This is the only
    -- exception this function absorbs, it absorbs exactly one condition, and it
    -- still says so in the response.
    raise warning 'tf_studio_accept_agreement: concurrent acceptance for the same signer and version, returning the row already committed';
    select * into v_existing
      from public.studio_agreement_acceptances
     where agreement_key     = p_agreement_key
       and agreement_version = v_ver.version
       and lower(signer_email) = v_email
       and revoked_at is null
     limit 1;
    if not found then
      raise;
    end if;
    return jsonb_build_object(
      'ok', true, 'duplicate', true,
      'acceptance_id', v_existing.id,
      'agreement_key', p_agreement_key,
      'version', v_existing.agreement_version,
      'sha256', v_existing.body_sha256,
      'accepted_at', v_existing.accepted_at,
      'note', 'This signer already accepted this version. Returning the acceptance already on file.');
  end;

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

update public.tf_function_registry
   set rationale = 'Records a binding agreement acceptance. Callable by anon because a professional signs before holding an account; the rows it writes carry PII and are never anon-readable. Version and hash are read from the database, never accepted from the caller. m357 added per-signer idempotence, a 25-per-origin-per-24h ceiling, and removed the blanket exception retry that could report a failed insert as success. m358 backed the idempotence with a partial unique index and made the function return the committed row when it loses a concurrent race.',
       updated_at = now()
 where proname = 'tf_studio_accept_agreement';