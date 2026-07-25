-- 252: note_drift_control_and_register_reconciliation
--
-- Migration 251 created public.tf_automation_note_drift() and did not declare
-- it. tf_function_safety_audit() immediately reported undeclared_total = 1,
-- which is CM-FNDRIFT-018 doing exactly what it was built to do: catch a
-- function that exists in the catalog and not in the register, in the same
-- session that created it. This migration closes that gap and finishes the
-- five-part convention shape for note drift.
--
-- The shape, for reference: a table of rules (tf_automation_registry), a
-- function that applies them (tf_automation_arm, tf_automation_readiness), a
-- checker that compares live state to the table (tf_automation_note_drift), a
-- GRC control that fails on disagreement (CM-NOTEDRIFT-022, added here), and an
-- auto-ticket key (safety:note_drift, added here). Migration 251 delivered
-- three of the five. This one delivers the other two.
--
-- The control is observed going to failing under induced drift and back to
-- passing after cleanup, inside this transaction. House rule 6.

------------------------------------------------------------------
-- 1. The auto-ticket
------------------------------------------------------------------
create or replace function public.tf_automation_note_autoticket()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $fn$
declare
  v_company constant uuid := 'ff000000-0000-4000-b000-000000000001';
  v_nd     jsonb;
  v_n      int;
  v_names  text;
  v_body   text;
  v_t      uuid;
  v_opened int := 0;
  v_closed int := 0;
begin
  -- Cron reaches this through tf_safety_autoticket as postgres, where
  -- auth.uid() is null. A real authenticated non-staff session is refused
  -- outright: this function writes to ClickUp.
  if auth.uid() is not null and not public.user_is_internal_staff(v_company) then
    raise exception 'tf_automation_note_autoticket: not authorized';
  end if;

  v_nd := public.tf_automation_note_drift();
  v_n  := coalesce((v_nd->>'drift_count')::int, 0);

  if v_n > 0 then
    select string_agg((d->>'automation_key')||' - '||(d->>'rule'), E'\n  - ')
      into v_names
    from jsonb_array_elements(coalesce(v_nd->'drifted', '[]'::jsonb)) d;

    v_body := 'The automation registry describes the platform incorrectly.'
      ||E'\n\nDrifted rows: '||v_n
      ||E'\n\nFindings:\n  - '||coalesce(v_names, '(see tf_automation_note_drift())')
      ||E'\n\nWhy this matters. tf_automation_readiness() projects '
      ||'tf_automation_registry.notes into the readiness payload, so the note is the '
      ||'text an operator reads at the moment they decide whether to arm a '
      ||'customer-reaching automation. A note that says a guard is missing when the '
      ||'guard is present teaches the operator to distrust a control that works. A note '
      ||'that says a bound exists when it does not is worse: it authorises a send '
      ||'nobody sized. Both are the same defect, the register drifting away from the '
      ||'system it describes.'
      ||E'\n\nDiagnose: select public.tf_automation_note_drift();'
      ||E'\n          select public.tf_automation_readiness();'
      ||E'\nFix: update tf_automation_registry.notes in the same migration that '
      ||'changed the sweep, the predicate or the bounding. The note is part of the '
      ||'change, not documentation of it.'
      ||E'\n\nThis ticket closes automatically once every note agrees with the catalog.';

    begin
      v_t := public.tf_request_ticket('safety:note_drift', 'safety',
        'Automation registry: '||v_n||' note(s) contradict the catalog', v_body, 2);
      if v_t is not null then v_opened := v_opened + 1; end if;
    exception when others then null; end;
  else
    begin
      perform public.tf_resolve_ticket('safety:note_drift',
        'Every automation registry note agrees with the live catalog: zero rows claim '
        ||'a missing predicate, cutover key or company predicate that is actually '
        ||'present, and every bounded_by classification matches the presence of a sweep '
        ||'function. Closed automatically.');
      v_closed := v_closed + 1;
    exception when others then null; end;
  end if;

  return jsonb_build_object('ok', true, 'checked_at', now(),
    'drift_count', v_n, 'opened', v_opened, 'resolved', v_closed);
end
$fn$;

revoke all on function public.tf_automation_note_autoticket() from public, anon, authenticated;
grant execute on function public.tf_automation_note_autoticket() to postgres, service_role;

comment on function public.tf_automation_note_autoticket() is
  'Files and auto-closes the safety:note_drift ticket from tf_automation_note_drift(). Writes to ClickUp, so it refuses an authenticated non-staff caller by raise.';

------------------------------------------------------------------
-- 2. Declare both functions in the safety register and the grant register
------------------------------------------------------------------
insert into public.tf_function_registry
  (proname, declared_kind, documented_as_diagnostic, write_acknowledged, rationale)
values
  ('tf_automation_note_drift', 'read', true, false,
   'Checker for tf_automation_registry.notes. Reads the registry and pg_get_functiondef, writes nothing. Documented as a diagnostic, so tf_function_safety_audit will raise a diagnostic violation the moment it gains a write.'),
  ('tf_automation_note_autoticket', 'write', false, true,
   'Files and resolves the safety:note_drift ClickUp ticket through tf_request_ticket and tf_resolve_ticket. Writes transitively, acknowledged.')
on conflict (proname) do update
  set declared_kind = excluded.declared_kind,
      documented_as_diagnostic = excluded.documented_as_diagnostic,
      write_acknowledged = excluded.write_acknowledged,
      rationale = excluded.rationale,
      updated_at = now();

select public.tf_apply_grant_tier('tf_automation_note_drift', '', 'staff',
  'Read path with an in-body user_is_internal_staff predicate that refuses by return value. Staff tier so the governance dashboard can call it under the caller session.');

select public.tf_apply_grant_tier('tf_automation_note_autoticket', '', 'admin',
  'Writes to ClickUp. Cron calls it as postgres through tf_safety_autoticket. No authenticated caller has any reason to reach it directly.');

------------------------------------------------------------------
-- 3. The GRC control
------------------------------------------------------------------
insert into public.it_controls
  (company_id, control_key, title, domain, description, frameworks, owner_role, automated, signal, status)
values
  ('ff000000-0000-4000-b000-000000000001',
   'CM-NOTEDRIFT-022',
   'Automation registry notes agree with the catalog',
   'Change Management',
   'tf_automation_registry.notes is projected into tf_automation_readiness() and is the text an operator reads before arming a customer-reaching automation. This control fails when a note claims a blast-radius predicate, cutover key or tenant predicate is missing that is actually present, or when the bounded_by classification disagrees with the presence of a sweep function.',
   '["SOC2 CC8.1","SOC2 CC7.2","ISO27001 A.12.1.2"]'::jsonb,
   'Enterprise Architect',
   true,
   'tf_automation_note_drift drift_count',
   'attention')
-- it_controls carries UNIQUE (control_key), not (company_id, control_key). The
-- arbiter must name the actual constraint or Postgres raises 42P10.
on conflict (control_key) do update
  set title = excluded.title,
      domain = excluded.domain,
      description = excluded.description,
      frameworks = excluded.frameworks,
      owner_role = excluded.owner_role,
      automated = excluded.automated,
      signal = excluded.signal,
      updated_at = now();

------------------------------------------------------------------
-- 4. Teach tf_controls_evaluate to evaluate it, by anchored catalog patch
------------------------------------------------------------------
do $patch$
declare
  v_def text;
  v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'tf_controls_evaluate';
  if v_def is null then raise exception '252: tf_controls_evaluate not found'; end if;
  v_new := v_def;

  -- 4a. declare
  v_new := replace(v_new,
    E'  v_fn_bad int; v_bool_haz int; v_oob int; v_gt int;\n  v_summary jsonb;',
    E'  v_fn_bad int; v_bool_haz int; v_oob int; v_gt int;\n  v_ndj jsonb; v_nd int;\n  v_summary jsonb;');

  -- 4b. compute, with the same fail-to-attention discipline as the others
  v_new := replace(v_new,
    E'  v_gt := case when v_gtj is null then null else coalesce((v_gtj->>''violation_total'')::int,0) end;',
    E'  v_gt := case when v_gtj is null then null else coalesce((v_gtj->>''violation_total'')::int,0) end;\n\n  begin v_ndj := public.tf_automation_note_drift(); exception when others then v_ndj := null; end;\n  v_nd := case when v_ndj is null then null else coalesce((v_ndj->>''drift_count'')::int,0) end;');

  -- 4c. status
  v_new := replace(v_new,
    E'      when ''CM-GRANT-021''     then case when v_gt is null then ''attention''\n                                         when v_gt=0 then ''passing'' else ''failing'' end\n      else status end,',
    E'      when ''CM-GRANT-021''     then case when v_gt is null then ''attention''\n                                         when v_gt=0 then ''passing'' else ''failing'' end\n      when ''CM-NOTEDRIFT-022''  then case when v_nd is null then ''attention''\n                                         when v_nd=0 then ''passing'' else ''failing'' end\n      else status end,');

  -- 4d. evidence
  v_new := replace(v_new,
    E'      when ''CM-GRANT-021''     then coalesce(v_gt::text,''?'')||'' function grant-tier violation(s): live EXECUTE grants versus tf_function_grant_tiers''\n      else evidence end',
    E'      when ''CM-GRANT-021''     then coalesce(v_gt::text,''?'')||'' function grant-tier violation(s): live EXECUTE grants versus tf_function_grant_tiers''\n      when ''CM-NOTEDRIFT-022''  then coalesce(v_nd::text,''?'')||'' automation registry note(s) contradicting the catalog''\n      else evidence end');

  if v_new = v_def then raise exception '252: tf_controls_evaluate, no anchor matched'; end if;
  execute v_new;

  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'tf_controls_evaluate';
  if position('CM-NOTEDRIFT-022' in v_def) = 0 then
    raise exception '252: the CM-NOTEDRIFT-022 branches did not land'; end if;
  if position('tf_automation_note_drift()' in v_def) = 0 then
    raise exception '252: the note drift signal call did not land'; end if;
  -- pre-existing landmarks must survive
  if position('CM-GRANT-021' in v_def) = 0
     or position('tf_security_scan()' in v_def) = 0
     or position('manual_never_attested' in v_def) = 0
     or position('and automated;' in v_def) = 0 then
    raise exception '252: tf_controls_evaluate lost a pre-existing landmark'; end if;
end
$patch$;

------------------------------------------------------------------
-- 5. Wire the auto-ticket into the safety scanner cron path
------------------------------------------------------------------
do $wire$
declare
  v_def text;
  v_new text;
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'tf_safety_autoticket';
  if v_def is null then raise exception '252: tf_safety_autoticket not found'; end if;
  v_new := v_def;

  v_new := replace(v_new,
    E'  v_gt jsonb; v_gt_n int;',
    E'  v_gt jsonb; v_gt_n int;\n  v_ndj jsonb; v_nd_n int;');

  v_new := replace(v_new,
    E'  return jsonb_build_object(''ok'', true, ''checked_at'', now(),\n    ''function_register'',',
    E'  -- 5. Automation registry notes. The register describing the system wrongly\n  --    is the failure mode that survives every other control, because every\n  --    other control checks the system and none of them read the prose.\n  begin\n    v_ndj  := public.tf_automation_note_autoticket();\n    v_nd_n := coalesce((v_ndj->>''drift_count'')::int, 0);\n    v_opened := v_opened + coalesce((v_ndj->>''opened'')::int, 0);\n    v_closed := v_closed + coalesce((v_ndj->>''resolved'')::int, 0);\n  exception when others then v_nd_n := null; end;\n\n  return jsonb_build_object(''ok'', true, ''checked_at'', now(),\n    ''note_drift'', jsonb_build_object(''drift_count'', v_nd_n),\n    ''function_register'',');

  if v_new = v_def then raise exception '252: tf_safety_autoticket, no anchor matched'; end if;
  execute v_new;

  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'tf_safety_autoticket';
  if position('tf_automation_note_autoticket()' in v_def) = 0 then
    raise exception '252: the note autoticket call did not land'; end if;
  if position('tf_grant_tier_autoticket()' in v_def) = 0
     or position('safety:function_drift' in v_def) = 0
     or position('safety:automation_cutover' in v_def) = 0
     or position('safety:boolean_defaults' in v_def) = 0 then
    raise exception '252: tf_safety_autoticket lost a pre-existing landmark'; end if;
end
$wire$;

------------------------------------------------------------------
-- 6. The register must now reconcile, and the control must be observed
--    failing under induced drift and passing after cleanup.
------------------------------------------------------------------
do $prove$
declare
  v_aud    jsonb;
  v_sum    jsonb;
  v_status text;
  v_evid   text;
  v_left   int;
begin
  -- 6a. zero undeclared, zero drift, zero stale, zero diagnostic violations
  v_aud := public.tf_function_safety_audit();
  if coalesce((v_aud->>'undeclared_total')::int, -1) <> 0 then
    raise exception '252: the function register still reports % undeclared: %',
      v_aud->>'undeclared_total', v_aud->'undeclared';
  end if;
  if coalesce((v_aud->>'drift_total')::int, -1) <> 0
     or coalesce((v_aud->>'stale_total')::int, -1) <> 0
     or coalesce((v_aud->>'diagnostic_violation_total')::int, -1) <> 0 then
    raise exception '252: function register does not reconcile: drift=%, stale=%, diagnostic=%',
      v_aud->>'drift_total', v_aud->>'stale_total', v_aud->>'diagnostic_violation_total';
  end if;

  -- 6b. grant tiers still conform after two tier declarations
  v_aud := public.tf_grant_tier_audit();
  if coalesce((v_aud->>'violation_total')::int, -1) <> 0 then
    raise exception '252: grant tier violations after declaring two tiers: %', v_aud->'violations';
  end if;

  -- 6c. the control evaluates, and passes on a clean registry
  v_sum := public.tf_controls_evaluate();
  if coalesce((v_sum->>'total')::int, 0) <> 22 then
    raise exception '252: expected 22 controls after adding CM-NOTEDRIFT-022, found %', v_sum->>'total';
  end if;
  select status, evidence into v_status, v_evid
    from public.it_controls
   where company_id = 'ff000000-0000-4000-b000-000000000001'
     and control_key = 'CM-NOTEDRIFT-022';
  if v_status <> 'passing' then
    raise exception '252: CM-NOTEDRIFT-022 is % on a clean registry, evidence: %', v_status, v_evid;
  end if;
  if v_evid not like '0 automation registry note%' then
    raise exception '252: CM-NOTEDRIFT-022 evidence did not render: %', v_evid;
  end if;

  -- 6d. induce drift and observe the control fail. A control never observed
  --     failing is a green light nobody has tested.
  insert into public.tf_automation_registry
    (automation_key, sweep_function, cutover_path, blast_radius_sql, customer_reaching, bounded_by, notes)
  values
    ('_proof_control_drift', null, array['some_since_key'],
     'select 0::int where ($1::timestamptz is not null or $1::timestamptz is null) and $2::uuid is not null',
     false, 'cutover',
     'Synthetic row for migration 252. Predicate not yet transcribed and no cutover key in config. Deleted before this migration commits.');

  perform public.tf_controls_evaluate();
  select status, evidence into v_status, v_evid
    from public.it_controls
   where company_id = 'ff000000-0000-4000-b000-000000000001'
     and control_key = 'CM-NOTEDRIFT-022';

  delete from public.tf_automation_registry where automation_key = '_proof_control_drift';

  if v_status <> 'failing' then
    raise exception '252: CM-NOTEDRIFT-022 read % under induced drift, expected failing. Evidence: %',
      v_status, v_evid;
  end if;

  -- 6e. and back to passing once the fixture is gone
  v_sum := public.tf_controls_evaluate();
  select status into v_status
    from public.it_controls
   where company_id = 'ff000000-0000-4000-b000-000000000001'
     and control_key = 'CM-NOTEDRIFT-022';
  if v_status <> 'passing' then
    raise exception '252: CM-NOTEDRIFT-022 did not recover after cleanup, reads %', v_status;
  end if;
  if coalesce((v_sum->>'failing')::int, -1) <> 0 then
    raise exception '252: % control(s) failing at the end of the migration', v_sum->>'failing';
  end if;

  select count(*) into v_left from public.tf_automation_registry;
  if v_left <> 13 then
    raise exception '252: registry should hold 13 rows, holds %', v_left;
  end if;

  raise notice '252: note drift control wired, observed failing under induced drift and recovering';
end
$prove$;

------------------------------------------------------------------
-- 7. All thirteen automation flags remain false.
------------------------------------------------------------------
do $flags$
declare
  v_on int;
begin
  select count(*) into v_on
    from public.tf_automation_registry r
    join public.integration_settings s
      on s.company_id = 'ff000000-0000-4000-b000-000000000001' and s.provider = 'openphone'
   where coalesce((s.config->'automations'->>r.automation_key)::boolean, false) is true;
  if v_on <> 0 then
    raise exception '252: % automation flag(s) are enabled, expected 0', v_on;
  end if;
end
$flags$;
