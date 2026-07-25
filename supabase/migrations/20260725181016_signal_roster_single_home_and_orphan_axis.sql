-- Migration 317: the roster gets one home, and the coverage checker gains the
-- axis that can see a checker nobody wired.
--
-- Obligation three of convention 33 has been the oldest open structural gap:
-- nothing prevented a migration from creating a checker and never wiring its
-- signal into a control. The reason it stayed open was stated as "no single
-- catalog fact testable at commit time". That was wrong, and this migration
-- states the fact.
--
-- A checker is a function that publishes an 'axes' key. That is convention 37
-- read literally: the axis is the consumption surface, so publishing one is
-- what makes a function a checker. It is not self-declared intent, it is a
-- property of the function's own text, which is why it cannot be an exemption
-- lever of the kind migration 265 closed.
--
-- Measured before writing this: twelve public tf_* functions publish an 'axes'
-- key, and the roster holds exactly those twelve. The textual definition and
-- the hand-maintained roster agree with zero disagreement in either direction,
-- which is what makes the test safe to install.

-- The roster lived inside tf_controls_signal_coverage's body. A second reader
-- arrives in migration 318, and two copies of a roster is the duplication this
-- platform keeps paying for. It gets one home.
create or replace function public.tf_controls_signal_roster()
returns jsonb
language sql
stable
set search_path = public, pg_catalog
as $fn$
  select jsonb_build_object(
    'tf_security_scan',                  jsonb_build_array('v_scan', 'v_scan_raw'),
    'tf_grant_tier_audit',               jsonb_build_array('v_gtj'),
    'tf_function_safety_audit',          jsonb_build_array('v_fnaud'),
    'tf_guard_detection_audit',          jsonb_build_array('v_gdj'),
    'tf_automation_note_drift',          jsonb_build_array('v_ndj'),
    'tf_boolean_default_hazards',        jsonb_build_array('v_boolh'),
    'tf_automation_out_of_band',         jsonb_build_array('v_oobj'),
    'tf_data_quality_audit',             jsonb_build_array('v_dqj'),
    'tf_controls_board',                 jsonb_build_array('v_board'),
    'tf_controls_signal_coverage',       jsonb_build_array('v_sigcov'),
    'tf_declaration_enforcement_audit',  jsonb_build_array('v_decl'),
    'tf_deploy_coordination_audit',      jsonb_build_array('v_coordj'));
$fn$;

comment on function public.tf_controls_signal_roster() is
  'The single home of the checker roster. Maps checker name to the variable '
  'name or names tf_controls_evaluate binds its payload to. Read by '
  'tf_controls_signal_coverage and by the commit-time signal wiring check. '
  'A roster with two copies is a roster that drifts, so it has one.';

select public.tf_apply_grant_tier(
  'tf_controls_signal_roster', '', 'admin',
  'Returns a static mapping with no company data and no rows. Its only callers '
  'are security definer bodies that already run as postgres, so admin tier is '
  'the narrowest grant that keeps every real caller working.');

insert into public.tf_function_registry
  (proname, declared_kind, documented_as_diagnostic, write_acknowledged, rationale)
values
  ('tf_controls_signal_roster', 'read', false, false,
   'Returns a constant jsonb object. It reads no table, writes no row and takes '
   'no argument. Declared read because on the axis declared_kind classifies it '
   'genuinely reads nothing and writes nothing, and the computed kind agrees.')
on conflict (proname) do update
  set declared_kind = excluded.declared_kind,
      rationale     = excluded.rationale;

-- The coverage checker now reads the roster from its one home, and gains a
-- sixth component axis: a function that publishes an axes key and is on no
-- roster is a checker nobody is consuming.
create or replace function public.tf_controls_signal_coverage()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, cron
as $fn$
declare
  v_company uuid := 'ff000000-0000-4000-b000-000000000001';
  v_def      text;
  v_out      jsonb;
  v_payload  jsonb;
  v_name     text;
  v_axis     text;
  v_var      text;
  v_key      text;
  v_needle   text;
  v_read     boolean;
  v_gated    boolean;
  v_callee   text;
  v_axes_of  text[];
  v_roster   jsonb;

  v_unread       jsonb   := '[]'::jsonb;
  v_undeclared   text[]  := '{}'::text[];
  v_unmeasured   text[]  := '{}'::text[];
  v_unrostered   text[]  := '{}'::text[];
  v_ungated      text[]  := '{}'::text[];
  v_orphans      text[]  := '{}'::text[];
  v_checkers     int := 0;
  v_declaring    int := 0;
  v_axes_total   int := 0;
  v_unread_n     int := 0;
  v_undecl_n     int := 0;
  v_unmeas_n     int := 0;
  v_unrost_n     int := 0;
  v_ungated_n    int := 0;
  v_orphan_n     int := 0;
  v_gap          int;

  -- Evaluator callees that are not checkers. Exactly one qualifies: the
  -- evaluator itself, which matches only inside its own CREATE header.
  v_non_checkers constant text[] := array['tf_controls_evaluate'];

  -- This checker's own declaration.
  v_self_axes constant text[] := array['gap_total'];

  -- gap_total is a roll-up. The roll-up axis rule permits declaring it instead
  -- of its primitives only if this body asserts the identity, which it does
  -- before publishing.
  v_component_axes constant text[] := array[
    'unread_total',
    'undeclared_checker_total',
    'unmeasured_checker_total',
    'unrostered_callee_total',
    'ungated_refusal_total',
    'orphan_checker_total'];

  v_non_gating constant jsonb := jsonb_build_object(
    'checkers_total',
    'Population, not findings. The size of the roster. Every gap counter here is '
    || 'drawn from it, and publishing it is what lets a reader tell a clean result '
    || 'from a narrow one.',
    'declaring_checker_total',
    'Complement, not findings. Rostered checkers that published a non-empty axes '
    || 'array. checkers_total minus this is the undeclared and unmeasured count.',
    'axes_total',
    'Population, not findings. The total number of declared axes across the whole '
    || 'roster, which is the denominator unread_total is drawn from.',
    'axes_publishing_function_total',
    'Population, not findings. Every public tf_* function whose text publishes an '
    || 'axes key, rostered or not. It is the denominator orphan_checker_total is '
    || 'drawn from, and the two together are what separates a clean roster from a '
    || 'short one.');
begin
  if auth.uid() is not null and not public.user_is_internal_staff(v_company) then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;

  v_roster := public.tf_controls_signal_roster();

  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = 'tf_controls_evaluate'
     and p.prokind = 'f';

  if v_def is null then
    return jsonb_build_object('ok', false, 'error', 'consumer_not_found', 'gap_total', null);
  end if;

  -- Roster closure. Anything the consumer calls that is not on the roster and
  -- is not a declared non-checker.
  for v_callee in
    select distinct m[1]
      from regexp_matches(v_def, 'public\.(tf_[a-z0-9_]+)\(\)', 'g') as m
  loop
    if not jsonb_exists(v_roster, v_callee) and not (v_callee = any(v_non_checkers)) then
      v_unrostered := v_unrostered || v_callee;
    end if;
  end loop;

  -- Orphan closure, the other direction. A function that publishes an axes key
  -- is a checker by construction, whether or not anybody remembered to roster
  -- it. Roster closure above can only see functions the consumer already calls,
  -- so it is blind to a checker that was created and never wired at all. This
  -- is the axis that sees one.
  select coalesce(array_agg(p.proname order by p.proname), '{}'::text[])
    into v_orphans
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.prokind = 'f'
     and p.proname like 'tf\_%'
     and pg_get_functiondef(p.oid) like '%''axes'',%'
     and not jsonb_exists(v_roster, p.proname);
  v_orphan_n := coalesce(array_length(v_orphans, 1), 0);

  for v_name in select k from jsonb_object_keys(v_roster) as t(k) order by k loop
    v_checkers := v_checkers + 1;
    v_axes_of  := null;

    -- Refusal gating. Does the consumer condition this checker's counter reads
    -- on its ok flag, in either the negative or the affirmative spelling.
    v_gated := false;
    for v_var in select value #>> '{}' from jsonb_array_elements(v_roster->v_name) loop
      if strpos(v_def, 'coalesce(' || v_var || '->>''ok'',''false'') <> ''true''') > 0
         or strpos(v_def, 'coalesce(' || v_var || '->>''ok'',''false'') = ''true''') > 0 then
        v_gated := true;
      end if;
    end loop;
    if not v_gated then
      v_ungated := v_ungated || v_name;
    end if;

    if v_name = 'tf_controls_signal_coverage' then
      -- Self. Stated, not called. The exclusion is published in the payload.
      v_axes_of := v_self_axes;
    else
      begin
        execute format('select public.%I()', v_name) into v_payload;
      exception when others then
        -- Null, never zero. An unrunnable checker is unmeasured, not clean.
        v_payload := null;
      end;

      if v_payload is null then
        v_unmeasured := v_unmeasured || v_name;
        continue;
      end if;

      if not jsonb_exists(v_payload, 'axes') then
        -- Covers refusal too. A checker that refused published no axes, and a
        -- refusal is not a certification of declaration.
        v_undeclared := v_undeclared || v_name;
        continue;
      end if;

      select array_agg(a) into v_axes_of
        from jsonb_array_elements_text(v_payload->'axes') as t(a);
    end if;

    if coalesce(array_length(v_axes_of, 1), 0) = 0 then
      v_undeclared := v_undeclared || v_name;
      continue;
    end if;

    v_declaring := v_declaring + 1;

    foreach v_axis in array v_axes_of loop
      v_axes_total := v_axes_total + 1;
      v_read := false;
      for v_var in select value #>> '{}' from jsonb_array_elements(v_roster->v_name) loop
        v_needle := 'coalesce((' || v_var || '->>''' || v_axis || ''')::int';
        if strpos(v_def, v_needle) > 0 then
          v_read := true;
        end if;
      end loop;
      if not v_read then
        v_unread := v_unread || jsonb_build_array(
          jsonb_build_object('checker', v_name, 'axis', v_axis));
      end if;
    end loop;
  end loop;

  v_unread_n  := jsonb_array_length(v_unread);
  v_undecl_n  := coalesce(array_length(v_undeclared, 1), 0);
  v_unmeas_n  := coalesce(array_length(v_unmeasured, 1), 0);
  v_unrost_n  := coalesce(array_length(v_unrostered, 1), 0);
  v_ungated_n := coalesce(array_length(v_ungated, 1), 0);

  v_gap := v_unread_n + v_undecl_n + v_unmeas_n + v_unrost_n + v_ungated_n + v_orphan_n;

  v_out := jsonb_build_object(
    'ok', true,
    'checked_at', now(),
    'consumer', 'public.tf_controls_evaluate',
    'checkers_total', v_checkers,
    'declaring_checker_total', v_declaring,
    'axes_total', v_axes_total,
    'axes_publishing_function_total', v_checkers + v_orphan_n,
    'unread_total', v_unread_n,
    'unread_axes', v_unread,
    'undeclared_checker_total', v_undecl_n,
    'undeclared_checkers', to_jsonb(v_undeclared),
    'unmeasured_checker_total', v_unmeas_n,
    'unmeasured_checkers', to_jsonb(v_unmeasured),
    'unrostered_callee_total', v_unrost_n,
    'unrostered_callees', to_jsonb(v_unrostered),
    'ungated_refusal_total', v_ungated_n,
    'ungated_checkers', to_jsonb(v_ungated),
    'orphan_checker_total', v_orphan_n,
    'orphan_checkers', to_jsonb(v_orphans),
    'gap_total', v_gap,
    'roster', v_roster,
    'roster_source', 'public.tf_controls_signal_roster',
    'non_checkers', to_jsonb(v_non_checkers),
    'self_note', 'tf_controls_signal_coverage appears in its own roster. It cannot '
      || 'call itself, so its axis is read from a constant in its body and its '
      || 'consumer read is checked the same way as every other entry. The exclusion '
      || 'is stated here rather than left for a reader to infer from a count.',
    'orphan_note', 'orphan_checker_total is measured from function text, not from '
      || 'the roster and not from the consumer. A function that publishes an axes '
      || 'key is a checker by construction, so a function that publishes one and is '
      || 'on no roster is a checker nobody consumes. The other five components can '
      || 'only see checkers that are already wired somewhere; this one sees the '
      || 'ones that are wired nowhere, which is the direction obligation three of '
      || 'convention 33 was blind in. The test is textual and will count a function '
      || 'that merely contains the literal, which is a false positive the roster '
      || 'resolves in one line and is the cheaper error to make.');

  -- Roll-up identity. gap_total is the declared axis and stands in for six
  -- primitives, so the identity is asserted here, in this body, before the
  -- roll-up is published.
  if v_gap <> coalesce((v_out->>'unread_total')::int, 0)
              + coalesce((v_out->>'undeclared_checker_total')::int, 0)
              + coalesce((v_out->>'unmeasured_checker_total')::int, 0)
              + coalesce((v_out->>'unrostered_callee_total')::int, 0)
              + coalesce((v_out->>'ungated_refusal_total')::int, 0)
              + coalesce((v_out->>'orphan_checker_total')::int, 0) then
    raise exception 'tf_controls_signal_coverage roll-up identity broken: gap_total % does not equal the sum of its six components', v_gap;
  end if;

  -- Coupling one. Declared axis resolves to a computed key.
  foreach v_key in array v_self_axes loop
    if not jsonb_exists(v_out, v_key) then
      raise exception 'tf_controls_signal_coverage declares axis % but publishes no such key.', v_key;
    end if;
  end loop;

  -- Coupling one, extended to the components the roll-up stands for.
  foreach v_key in array v_component_axes loop
    if not jsonb_exists(v_out, v_key) then
      raise exception 'tf_controls_signal_coverage declares component axis % but publishes no such key.', v_key;
    end if;
  end loop;

  -- Coupling two. Declared non-gating counters resolve to computed keys.
  for v_key in select k from jsonb_object_keys(v_non_gating) as t(k) loop
    if not jsonb_exists(v_out, v_key) then
      raise exception 'tf_controls_signal_coverage declares non-gating counter % but publishes no such key.', v_key;
    end if;
  end loop;

  -- Coupling three. Every published counter is classified.
  for v_key in
    select k from jsonb_object_keys(v_out) as t(k)
     where k like '%\_total' or k like '%\_count'
  loop
    if not (v_key = any(v_self_axes))
       and not (v_key = any(v_component_axes))
       and not jsonb_exists(v_non_gating, v_key) then
      raise exception 'tf_controls_signal_coverage publishes counter % that is neither a declared axis, a declared component of the roll-up, nor a declared non-gating counter. Classify it before this checker can certify.', v_key;
    end if;
  end loop;

  return v_out || jsonb_build_object(
    'axes', to_jsonb(v_self_axes),
    'component_axes', to_jsonb(v_component_axes),
    'non_gating', v_non_gating);
end;
$fn$;

-- Self-proving assertions.
do $mig$
declare
  v_roster  jsonb;
  v_cov     jsonb;
  v_summary jsonb;
begin
  v_roster := public.tf_controls_signal_roster();
  if jsonb_typeof(v_roster) is distinct from 'object'
     or (select count(*) from jsonb_object_keys(v_roster)) <> 12 then
    raise exception 'migration 317: tf_controls_signal_roster did not return a twelve key object';
  end if;

  v_cov := public.tf_controls_signal_coverage();

  if coalesce(v_cov->>'ok', 'false') <> 'true' then
    raise exception 'migration 317: coverage checker did not certify: %', v_cov;
  end if;

  if v_cov->>'roster_source' is distinct from 'public.tf_controls_signal_roster' then
    raise exception 'migration 317: coverage checker is not reading the roster from its one home';
  end if;

  if v_cov->'roster' <> v_roster then
    raise exception 'migration 317: coverage roster and roster function disagree, which is the drift this migration exists to remove';
  end if;

  if not (v_cov ? 'orphan_checker_total') then
    raise exception 'migration 317: coverage checker publishes no orphan_checker_total';
  end if;

  if coalesce((v_cov->>'orphan_checker_total')::int, -1) <> 0 then
    raise exception 'migration 317: orphan checkers present at install: %', v_cov->'orphan_checkers';
  end if;

  if coalesce((v_cov->>'axes_publishing_function_total')::int, -1) <> 12 then
    raise exception 'migration 317: expected twelve axes publishing functions, got %',
      v_cov->>'axes_publishing_function_total';
  end if;

  if coalesce((v_cov->>'gap_total')::int, -1) <> 0 then
    raise exception 'migration 317: coverage gap_total is % after install, expected 0. Payload: %',
      v_cov->>'gap_total', v_cov;
  end if;

  if not exists (select 1 from public.tf_function_registry
                  where proname = 'tf_controls_signal_roster') then
    raise exception 'migration 317: registry row for tf_controls_signal_roster is missing';
  end if;

  -- House rule twenty-two. This migration wrote a registry row, so it
  -- re-evaluates the register before it commits. A stale green is worse than a
  -- red, because nobody investigates a green.
  perform public.tf_controls_evaluate();

  select jsonb_build_object(
           'total',     count(*),
           'failing',   count(*) filter (where status = 'failing'),
           'passing',   count(*) filter (where status = 'passing'),
           'attention', count(*) filter (where status = 'attention'))
    into v_summary
    from public.it_controls;

  if coalesce((v_summary->>'failing')::int, -1) <> 0 then
    raise exception 'migration 317: register reports % failing control(s) after wiring, expected 0. Summary: %',
      v_summary->>'failing', v_summary;
  end if;

  raise notice 'migration 317 ok: roster has one home, orphan axis live, register %', v_summary;
end
$mig$;
