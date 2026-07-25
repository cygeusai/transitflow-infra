-- ============================================================================
-- Migration 320: signal_wiring_checker_and_control
--
-- Closes the measurement half of obligation three of convention 33. Migration
-- 318 installed the commit-time refusal; 319 proved it actually refuses. This
-- migration gives the enforcement a checker and a control, so that the
-- enforcement itself is watched by the same register it protects.
--
-- WHY THIS IS ONE MIGRATION AND NOT TWO.
-- The original plan was 320 for the checker and 321 for the control. That plan
-- is now impossible, and the reason is the enforcement installed in 318.
-- tf_signal_wiring_enforcement_audit publishes an axis key, which by the
-- definition stated in 317 makes it a checker, so 318 refuses to let it commit
-- unwired. Splitting it in two would have been refused at the COMMIT of 320.
-- That is the enforcement working on its own author at the first opportunity,
-- which is the only kind of enforcement worth having.
--
-- THE PENDING-QUEUE COLLISION, DESIGNED FOR IN ADVANCE.
-- Creating the checker enqueues it into tf_signal_wiring_pending before the
-- wiring lands, and the queue row is only swept at COMMIT. So during the
-- assertion block below, the queue holds one row whose obligation is already
-- met. Migration 316 learned this the hard way on the declaration queue: if
-- residue counts queue rows, house rule twenty-two guarantees a red. Residue
-- here counts only the UNMET subset, and the raw queue count is published
-- beside it as non-gating population.
--
-- A WRONGLY TIMED CHECK COUNTS AS A MISSING ONE.
-- wiring_deferred_check_missing_total counts a constraint trigger that exists
-- and is enabled but is not DEFERRABLE INITIALLY DEFERRED. Such a trigger fires
-- at statement time, refuses every conforming migration, and is switched off
-- within the week. It is not enforcement, it is a fault.
--
-- KNOWN TRAP RECORDED HERE FOR THE RUNBOOK.
-- public.tf_controls_board() has NO 'summary' key. The register summary is the
-- return value of public.tf_controls_evaluate() itself. Migration 318 lost an
-- attempt to this. It surfaced as a loud red rather than a silent green only
-- because the assertion used coalesce(..., -1). RULE: in an assertion, the safe
-- default for a coalesce is the FAILING value, never the passing one.
--
-- AND ONE MORE, PAID FOR BY ATTEMPT ONE OF THIS MIGRATION.
-- it_controls_status_check allows exactly passing, attention, failing, manual.
-- 'pending' is not a status. A new automated control is seeded 'attention',
-- because a control that has never been evaluated is unmeasured, not clean.
-- tf_controls_evaluate() promotes it inside this same transaction, and the
-- final assertion verifies that it did.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- PART 1. The checker.
--
-- This function publishes an axis key, which by the definition in 317 makes it
-- a checker, which means 318 will enqueue it the moment it is created and
-- refuse at COMMIT unless parts 2, 3 and 4 land in this same transaction.
-- ---------------------------------------------------------------------------
create or replace function public.tf_signal_wiring_enforcement_audit()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $fn$
declare
  v_company    uuid := 'ff000000-0000-4000-b000-000000000001';
  v_out        jsonb;
  v_key        text;
  v_enabled    "char";
  v_et_state   text;
  v_missing    int := 0;
  v_disabled   int := 0;
  v_dc_missing int := 0;
  v_dc_state   text;
  v_residue    int := 0;
  v_queue      int := 0;
  v_unwired    int := 0;
  v_pop        int := 0;
  v_gap        int;
  v_deferrable   boolean;
  v_initdeferred boolean;
  v_tgenabled    "char";
  v_eval       text;
  v_roster     jsonb;
  v_wired      boolean;
  r            record;
  v_queued_names  text[] := '{}'::text[];
  v_residue_names text[] := '{}'::text[];
  v_unwired_names text[] := '{}'::text[];

  v_self_axes constant text[] := array['wiring_gap_total'];

  -- wiring_gap_total is a roll-up. The roll-up axis rule permits declaring it
  -- instead of its primitives only if this body asserts the identity, which it
  -- does immediately before publishing.
  v_component_axes constant text[] := array[
    'wiring_enforcement_missing_total',
    'wiring_enforcement_disabled_total',
    'wiring_deferred_check_missing_total',
    'wiring_residue_total',
    'unwired_checker_total'];

  v_non_gating constant jsonb := jsonb_build_object(
    'checker_population_total',
    'Population, not findings. Every public.tf_* function of prokind f whose '
    || 'own text publishes an axis key, which is what makes it a checker under '
    || 'convention 37 as read in migration 317. It is the denominator '
    || 'unwired_checker_total is drawn from, and publishing it is what lets a '
    || 'reader tell a clean result from a blind one. It is measured from the '
    || 'catalog, not from the roster, so a checker nobody registered still '
    || 'appears in it.',
    'wiring_queue_total',
    'Population, not findings. Every row currently in '
    || 'tf_signal_wiring_pending, met or unmet. wiring_residue_total is the '
    || 'unmet subset. The two differ only inside a transaction that has created '
    || 'a checker and has not finished wiring it, which is exactly the window '
    || 'house rule twenty-two inspects. Migration 316 established that counting '
    || 'the raw queue as residue makes a conforming migration fail its own '
    || 'control, so the two are published separately and only the unmet subset '
    || 'gates.');
begin
  if auth.uid() is not null and not public.user_is_internal_staff(v_company) then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;

  -- ---- Is the enqueue half installed and firing on origin? -----------------
  select evtenabled into v_enabled
    from pg_event_trigger
   where evtname = 'tf_require_signal_wiring';

  if v_enabled is null then
    v_missing  := 1;
    v_et_state := 'absent';
  elsif v_enabled = 'D' then
    v_disabled := 1;
    v_et_state := 'disabled';
  elsif v_enabled = 'R' then
    -- Replica-only. It exists, it is not disabled, and it does not fire for
    -- ordinary origin DDL, which is the only session anyone deploys from. It
    -- counts as disabled and the raw catalog letter travels with the payload
    -- so a reader can tell the two apart.
    v_disabled := 1;
    v_et_state := 'replica';
  elsif v_enabled = 'A' then
    v_et_state := 'always';
  elsif v_enabled = 'O' then
    v_et_state := 'origin';
  else
    v_disabled := 1;
    v_et_state := 'unknown';
  end if;

  -- ---- Is the commit-time half installed, enabled, AND correctly timed? ----
  select t.tgdeferrable, t.tginitdeferred, t.tgenabled
    into v_deferrable, v_initdeferred, v_tgenabled
    from pg_trigger t
   where t.tgrelid = to_regclass('public.tf_signal_wiring_pending')
     and t.tgname  = 'tf_signal_wiring_pending_deferred_check';

  if v_tgenabled is null then
    v_dc_state   := 'absent';
    v_dc_missing := 1;
  elsif v_tgenabled = 'D' then
    v_dc_state   := 'disabled';
    v_dc_missing := 1;
  elsif not (coalesce(v_deferrable, false) and coalesce(v_initdeferred, false)) then
    v_dc_state   := 'immediate';
    v_dc_missing := 1;
  else
    v_dc_state := 'deferred';
  end if;

  -- ---- The three catalog facts that constitute WIRED ----------------------
  select public.tf_controls_signal_roster() into v_roster;

  select pg_get_functiondef(p.oid) into v_eval
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'tf_controls_evaluate' and p.prokind = 'f'
   limit 1;

  -- Queue population, and the unmet subset of it.
  for r in select q.proname from public.tf_signal_wiring_pending q order by q.proname loop
    v_queue := v_queue + 1;
    v_queued_names := v_queued_names || r.proname;

    v_wired :=
         jsonb_exists(v_roster, r.proname)
     and v_eval is not null
     and strpos(v_eval, 'public.' || r.proname || '()') > 0
     and exists (select 1 from public.it_controls c
                  where c.signal is not null and strpos(c.signal, r.proname) > 0);

    if not v_wired then
      v_residue := v_residue + 1;
      v_residue_names := v_residue_names || r.proname;
    end if;
  end loop;

  -- Live catalog sweep. This is the axis the queue cannot see: a checker that
  -- was created before the enforcement existed, or created while it was off.
  for r in
    select p.proname, pg_get_functiondef(p.oid) as src
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f' and p.proname like 'tf\_%'
     order by p.proname
  loop
    if strpos(r.src, '''axes'',') = 0 then
      continue;
    end if;

    v_pop := v_pop + 1;

    v_wired :=
         jsonb_exists(v_roster, r.proname)
     and v_eval is not null
     and strpos(v_eval, 'public.' || r.proname || '()') > 0
     and exists (select 1 from public.it_controls c
                  where c.signal is not null and strpos(c.signal, r.proname) > 0);

    if not v_wired then
      v_unwired := v_unwired + 1;
      v_unwired_names := v_unwired_names || r.proname;
    end if;
  end loop;

  v_gap := v_missing + v_disabled + v_dc_missing + v_residue + v_unwired;

  v_out := jsonb_build_object(
    'ok', true,
    'checked_at', now(),
    'event_trigger', 'tf_require_signal_wiring',
    'event_trigger_state', v_et_state,
    'event_trigger_flag', coalesce(v_enabled::text, 'none'),
    'deferred_check', 'tf_signal_wiring_pending_deferred_check',
    'deferred_check_state', v_dc_state,
    'queue_relation', 'public.tf_signal_wiring_pending',
    'consumer', 'public.tf_controls_evaluate',
    'roster_source', 'public.tf_controls_signal_roster',
    'wiring_enforcement_missing_total', v_missing,
    'wiring_enforcement_disabled_total', v_disabled,
    'wiring_deferred_check_missing_total', v_dc_missing,
    'wiring_residue_total', v_residue,
    'unwired_checker_total', v_unwired,
    'checker_population_total', v_pop,
    'wiring_queue_total', v_queue,
    'queued_checkers', to_jsonb(v_queued_names),
    'residue_checkers', to_jsonb(v_residue_names),
    'unwired_checkers', to_jsonb(v_unwired_names),
    'wiring_gap_total', v_gap,
    'deferred_check_note',
      'A constraint trigger that exists and is enabled but is not DEFERRABLE '
      || 'INITIALLY DEFERRED fires at statement time instead of at COMMIT. It '
      || 'would refuse every conforming migration, because a conforming '
      || 'migration necessarily creates the checker before it wires it. Such a '
      || 'trigger gets switched off within the week, so a wrongly timed check '
      || 'is counted here as a missing one rather than as a present one.',
    'residue_note',
      'wiring_residue_total counts queue rows whose obligation is still unmet, '
      || 'which is a checker created and not wired. It reads non-zero only '
      || 'inside a transaction that has created a checker and has not finished '
      || 'wiring it. Outside a transaction the queue is empty by construction, '
      || 'so a standing non-zero here means the commit-time check did not run. '
      || 'wiring_queue_total counts every queue row including met ones, and the '
      || 'gap between the two is the ordinary create-then-wire window that '
      || 'migration 316 stopped failing a control for.',
    'contradiction_note',
      'Four of the five components read the catalog and answer whether the '
      || 'enforcement is installed and correctly timed. The fifth, '
      || 'unwired_checker_total, sweeps live function text and answers whether '
      || 'the enforcement actually held. An enforcement reported present, '
      || 'enabled and deferred that nonetheless left an unwired checker in the '
      || 'schema reads zero on the four catalog axes and non-zero on the one '
      || 'measuring the claim. That is the only direction in which this checker '
      || 'can contradict itself, and it is deliberate.');

  -- Roll-up identity, asserted here, in this body, before the roll-up is published.
  if v_gap <> coalesce((v_out->>'wiring_enforcement_missing_total')::int, 0)
            + coalesce((v_out->>'wiring_enforcement_disabled_total')::int, 0)
            + coalesce((v_out->>'wiring_deferred_check_missing_total')::int, 0)
            + coalesce((v_out->>'wiring_residue_total')::int, 0)
            + coalesce((v_out->>'unwired_checker_total')::int, 0) then
    raise exception 'tf_signal_wiring_enforcement_audit roll-up identity broken: wiring_gap_total % does not equal the sum of its five components', v_gap;
  end if;

  -- Coupling one. Declared axis resolves to a computed key.
  foreach v_key in array v_self_axes loop
    if not jsonb_exists(v_out, v_key) then
      raise exception 'tf_signal_wiring_enforcement_audit declares axis % but publishes no such key.', v_key;
    end if;
  end loop;

  -- Coupling one, extended to the components the roll-up stands for.
  foreach v_key in array v_component_axes loop
    if not jsonb_exists(v_out, v_key) then
      raise exception 'tf_signal_wiring_enforcement_audit declares component axis % but publishes no such key.', v_key;
    end if;
  end loop;

  -- Coupling two. Declared non-gating counters resolve to computed keys.
  for v_key in select k from jsonb_object_keys(v_non_gating) as t(k) loop
    if not jsonb_exists(v_out, v_key) then
      raise exception 'tf_signal_wiring_enforcement_audit declares non-gating counter % but publishes no such key.', v_key;
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
      raise exception 'tf_signal_wiring_enforcement_audit publishes counter % that is neither a declared axis, a declared component of the roll-up, nor a declared non-gating counter. Classify it before this checker can certify.', v_key;
    end if;
  end loop;

  return v_out || jsonb_build_object(
    'axes', to_jsonb(v_self_axes),
    'component_axes', to_jsonb(v_component_axes),
    'non_gating', v_non_gating);
end;
$fn$;

comment on function public.tf_signal_wiring_enforcement_audit() is
'Measures the commit-time signal wiring enforcement installed in migration 318 and proved falsifiable in 319. Five gating components: the enqueue event trigger is absent, the enqueue event trigger is disabled or replica-only, the commit-time constraint trigger is absent, disabled or wrongly timed, the pending queue holds unmet rows, and the live catalog holds a checker that is wired nowhere. The fifth is the only one that can contradict the other four, because it is measured from function text rather than from the trigger catalog.';


-- ---------------------------------------------------------------------------
-- PART 2. Roster. Twelve becomes thirteen.
-- ---------------------------------------------------------------------------
create or replace function public.tf_controls_signal_roster()
returns jsonb
language sql
stable
set search_path = public, pg_catalog
as $roster$
  select jsonb_build_object(
    'tf_security_scan',                     jsonb_build_array('v_scan', 'v_scan_raw'),
    'tf_grant_tier_audit',                  jsonb_build_array('v_gtj'),
    'tf_function_safety_audit',             jsonb_build_array('v_fnaud'),
    'tf_guard_detection_audit',             jsonb_build_array('v_gdj'),
    'tf_automation_note_drift',             jsonb_build_array('v_ndj'),
    'tf_boolean_default_hazards',           jsonb_build_array('v_boolh'),
    'tf_automation_out_of_band',            jsonb_build_array('v_oobj'),
    'tf_data_quality_audit',                jsonb_build_array('v_dqj'),
    'tf_controls_board',                    jsonb_build_array('v_board'),
    'tf_controls_signal_coverage',          jsonb_build_array('v_sigcov'),
    'tf_declaration_enforcement_audit',     jsonb_build_array('v_decl'),
    'tf_deploy_coordination_audit',         jsonb_build_array('v_coordj'),
    'tf_signal_wiring_enforcement_audit',   jsonb_build_array('v_sigwj'));
$roster$;


-- ---------------------------------------------------------------------------
-- PART 3. The control.
-- Seeded 'attention', not 'passing'. An automated control that has never been
-- evaluated is unmeasured, not clean. Part 6 verifies the promotion.
-- ---------------------------------------------------------------------------
insert into public.it_controls
  (company_id, control_key, title, domain, description, frameworks,
   owner_role, automated, signal, status, evidence)
values (
  'ff000000-0000-4000-b000-000000000001',
  'CM-SIGWIRE-030',
  'Creating a checker without wiring its signal into a control is impossible, not merely detectable',
  'Change Management',
  'Obligation three of convention 33 says a new checker must have its signal wired into a control. Six prior verification passes recorded this obligation as unclosable, on the stated grounds that "wire its signal into a control" had no single catalog fact testable at commit time. That premise was wrong, and this control exists because it was refuted.'
  || E'\n\n'
  || 'Convention 37 already says the axis is the consumption surface. Read literally, that makes publishing an axis key the definition of being a checker, rather than a property an author declares about a function. It is therefore a fact about the function''s own text, readable from pg_get_functiondef, and not an intention that can be withheld. That closes the exemption route migration 265 had to close by hand: an author cannot opt out of being a checker except by not publishing an axis, which is the same as not being one.'
  || E'\n\n'
  || 'WIRED is then three catalog facts, all re-tested at COMMIT: the function name is a key in public.tf_controls_signal_roster(); the text of public.tf_controls_evaluate() calls it; and at least one public.it_controls row carries a signal naming it. Migration 318 installed an event trigger on ddl_command_end that enqueues any tf_* function publishing an axis key and not satisfying all three, plus a DEFERRABLE INITIALLY DEFERRED constraint trigger that enforces and sweeps at COMMIT. Deferral is what makes the rule usable: any ordering inside the transaction is accepted, only the end state is judged.'
  || E'\n\n'
  || 'Migration 319 proved the refusal is real rather than assumed. It created an unwired checker inside a subtransaction, forced the deferred check with SET CONSTRAINTS ALL IMMEDIATE, and caught SQLSTATE 23514 only, so a non-firing enforcement would have reached an uncaught exception and failed the migration loudly. The refusal enumerated all three unmet facts in one message and carried a remediation hint. A probe that passes when the thing it probes is broken is worse than no probe.'
  || E'\n\n'
  || 'This control gates on wiring_gap_total from tf_signal_wiring_enforcement_audit, a roll-up of five components. Four read the trigger catalog and answer whether the enforcement is installed, enabled and correctly timed; a constraint trigger that is not deferred is counted as missing, because it would refuse every conforming migration and be switched off within the week. The fifth sweeps live function text for a checker that is wired nowhere, and is the only component that can contradict the other four. The pending queue is published as population and only its unmet subset gates, because migration 316 established that counting the raw queue as residue makes a conforming migration fail its own control at the moment it does the right thing.',
  jsonb_build_object(
    'SOC2',     jsonb_build_array('CC4.1', 'CC7.1', 'CC8.1'),
    'CIS_v8',   jsonb_build_array('4.1', '16.11'),
    'NIST_CSF', jsonb_build_array('PR.IP-1', 'PR.IP-3', 'DE.CM-7')),
  'CISO',
  true,
  'tf_signal_wiring_enforcement_audit wiring_gap_total, a roll-up of enforcement present, enforcement enabled, commit-time check correctly deferred, no unmet queue residue, and no unwired checker in the live catalog',
  'attention',
  'seeded by migration 320 and not yet evaluated'
)
on conflict (control_key) do update set
  title       = excluded.title,
  domain      = excluded.domain,
  description = excluded.description,
  frameworks  = excluded.frameworks,
  owner_role  = excluded.owner_role,
  automated   = excluded.automated,
  signal      = excluded.signal,
  updated_at  = now();


-- ---------------------------------------------------------------------------
-- PART 4. Asserted textual splice into public.tf_controls_evaluate().
--
-- Every anchor must match exactly once. A zero-hit anchor means the evaluator
-- drifted and the splice would silently no-op; a multi-hit anchor means it
-- would corrupt an unrelated branch. Both are refusals, not warnings.
--
-- None of the inserted text contains the literal that defines a checker, so
-- splicing the evaluator does not make the evaluator a checker and does not
-- self-trigger the enforcement installed in 318.
-- ---------------------------------------------------------------------------
do $splice$
declare
  v_src  text;
  v_new  text;
  v_a    text;
  v_r    text;
  v_hits int;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'tf_controls_evaluate' and p.prokind = 'f'
   limit 1;

  if v_src is null then
    raise exception 'migration 320: public.tf_controls_evaluate() not found';
  end if;

  v_new := v_src;

  -- Anchor 1: declarations.
  v_a := $a1$v_coordj jsonb; v_coord int;$a1$;
  v_r := $b1$v_coordj jsonb; v_coord int;
  v_sigwj jsonb; v_sigw int;$b1$;
  v_hits := (length(v_new) - length(replace(v_new, v_a, ''))) / length(v_a);
  if v_hits <> 1 then
    raise exception 'migration 320: anchor A1 matched % time(s), expected exactly 1', v_hits;
  end if;
  v_new := replace(v_new, v_a, v_r);

  -- Anchor 2: the checker call and the strict counter read.
  v_a := $a2$else coalesce((v_coordj->>'coordination_gap_total')::int,0) end;$a2$;
  v_r := $b2$else coalesce((v_coordj->>'coordination_gap_total')::int,0) end;

  -- Signal wiring enforcement, installed in migration 318, proved falsifiable
  -- in 319, measured by the checker added in 320. Four of its five component
  -- axes read the trigger catalog, which answers whether the enforcement is
  -- installed and correctly timed. The fifth sweeps live function text and
  -- answers whether it held. An enforcement reported present and deferred that
  -- nonetheless left an unwired checker reads zero on the catalog axes and
  -- non-zero on the one measuring the claim.
  begin v_sigwj := public.tf_signal_wiring_enforcement_audit(); exception when others then v_sigwj := null; end;
  v_sigw := case when v_sigwj is null or coalesce(v_sigwj->>'ok','false') <> 'true' then null
                 else coalesce((v_sigwj->>'wiring_gap_total')::int,0) end;$b2$;
  v_hits := (length(v_new) - length(replace(v_new, v_a, ''))) / length(v_a);
  if v_hits <> 1 then
    raise exception 'migration 320: anchor A2 matched % time(s), expected exactly 1', v_hits;
  end if;
  v_new := replace(v_new, v_a, v_r);

  -- Anchor 3: status branch.
  v_a := $a3$else status end$a3$;
  v_r := $b3$when 'CM-SIGWIRE-030'    then case when v_sigw is null then 'attention'
                                         when v_sigw=0 then 'passing' else 'failing' end
      else status end$b3$;
  v_hits := (length(v_new) - length(replace(v_new, v_a, ''))) / length(v_a);
  if v_hits <> 1 then
    raise exception 'migration 320: anchor A3 matched % time(s), expected exactly 1', v_hits;
  end if;
  v_new := replace(v_new, v_a, v_r);

  -- Anchor 4: evidence branch.
  v_a := $a4$else evidence end$a4$;
  v_r := $b4$when 'CM-SIGWIRE-030'    then case when v_sigwj is null then 'tf_signal_wiring_enforcement_audit raised and returned no payload'
                                         when coalesce(v_sigwj->>'ok','false') <> 'true' then 'signal wiring checker refused: '||coalesce(v_sigwj->>'error','unknown')
                                         else 'enqueue trigger '||coalesce(v_sigwj->>'event_trigger','?')||' is '||coalesce(v_sigwj->>'event_trigger_state','?')
                                              ||' and the commit-time check is '||coalesce(v_sigwj->>'deferred_check_state','?')
                                              ||'; '||coalesce(v_sigwj->>'unwired_checker_total','?')||' unwired checker(s) '
                                              ||coalesce(v_sigwj->>'unwired_checkers','[]')||' across a population of '
                                              ||coalesce(v_sigwj->>'checker_population_total','?')||' function(s) that publish an axis key; '
                                              ||coalesce(v_sigwj->>'wiring_residue_total','?')||' unmet queue row(s) of '
                                              ||coalesce(v_sigwj->>'wiring_queue_total','?')||' queued '
                                              ||coalesce(v_sigwj->>'queued_checkers','[]')
                                              ||'. Publishing an axis key is the definition of being a checker, so this axis is measured from function text rather than from what an author declared'
                                    end
      else evidence end$b4$;
  v_hits := (length(v_new) - length(replace(v_new, v_a, ''))) / length(v_a);
  if v_hits <> 1 then
    raise exception 'migration 320: anchor A4 matched % time(s), expected exactly 1', v_hits;
  end if;
  v_new := replace(v_new, v_a, v_r);

  if v_new = v_src then
    raise exception 'migration 320: splice produced an identical body, refusing to pretend it changed something';
  end if;

  execute v_new;
end;
$splice$;


-- ---------------------------------------------------------------------------
-- PART 5. Declaration and grant tier for the new checker.
-- Both are obligations of convention 33 in their own right, and the
-- declaration enforcement from 307 is watching this transaction too.
-- ---------------------------------------------------------------------------
insert into public.tf_function_registry (proname, declared_kind, rationale)
values (
  'tf_signal_wiring_enforcement_audit',
  'read',
  'Read-only checker. Reads pg_event_trigger, pg_trigger, pg_proc, tf_signal_wiring_pending, it_controls and the roster, and writes nothing. Measures the commit-time signal wiring enforcement installed in migration 318.')
on conflict (proname) do update set
  declared_kind = excluded.declared_kind,
  rationale     = excluded.rationale,
  updated_at    = now();

do $gt$
begin
  perform public.tf_apply_grant_tier(
    'tf_signal_wiring_enforcement_audit',
    '',
    'staff',
    'Governance checker consumed by the control register. Same tier as every other roster checker.');
end;
$gt$;


-- ---------------------------------------------------------------------------
-- PART 6. Assertions. Nothing below is optional.
-- House rule twenty-two closes it: a migration that writes a row into
-- tf_function_registry must re-evaluate the control register before it
-- commits, because a stale green is worse than a red, since nobody
-- investigates a green.
-- ---------------------------------------------------------------------------
do $assert$
declare
  v_roster jsonb;
  v_eval   text;
  v_j      jsonb;
  v_cov    jsonb;
  v_sum    jsonb;
  v_status text;
  v_n      int;
begin
  -- Wiring fact one: roster.
  select public.tf_controls_signal_roster() into v_roster;
  select count(*) into v_n from jsonb_object_keys(v_roster);
  if v_n <> 13 then
    raise exception 'migration 320: roster holds % checker(s), expected 13', v_n;
  end if;
  if not jsonb_exists(v_roster, 'tf_signal_wiring_enforcement_audit') then
    raise exception 'migration 320: roster does not name tf_signal_wiring_enforcement_audit';
  end if;

  -- Wiring fact two: the evaluator calls it, reads its axis strictly, and gates on it.
  select pg_get_functiondef(p.oid) into v_eval
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'tf_controls_evaluate' and p.prokind = 'f'
   limit 1;
  if v_eval is null then
    raise exception 'migration 320: tf_controls_evaluate() vanished';
  end if;
  if strpos(v_eval, 'public.tf_signal_wiring_enforcement_audit()') = 0 then
    raise exception 'migration 320: tf_controls_evaluate() does not call the new checker';
  end if;
  if strpos(v_eval, 'coalesce((v_sigwj->>''wiring_gap_total'')::int') = 0 then
    raise exception 'migration 320: tf_controls_evaluate() does not read wiring_gap_total as a strict counter';
  end if;
  if strpos(v_eval, '''CM-SIGWIRE-030''') = 0 then
    raise exception 'migration 320: tf_controls_evaluate() has no CM-SIGWIRE-030 branch';
  end if;
  if strpos(v_eval, '''axes'',') <> 0 then
    raise exception 'migration 320: the splice made tf_controls_evaluate() look like a checker, which would make the consumer its own producer';
  end if;

  -- Wiring fact three: a control names it.
  if not exists (select 1 from public.it_controls c
                  where c.signal is not null
                    and strpos(c.signal, 'tf_signal_wiring_enforcement_audit') > 0) then
    raise exception 'migration 320: no it_controls row carries a signal naming the new checker';
  end if;

  -- The checker itself.
  select public.tf_signal_wiring_enforcement_audit() into v_j;
  if coalesce(v_j->>'ok','false') <> 'true' then
    raise exception 'migration 320: checker refused: %', coalesce(v_j->>'error','unknown');
  end if;
  if v_j->>'event_trigger_state' <> 'origin' then
    raise exception 'migration 320: enqueue event trigger state is %, expected origin', coalesce(v_j->>'event_trigger_state','<NULL>');
  end if;
  if v_j->>'deferred_check_state' <> 'deferred' then
    raise exception 'migration 320: commit-time check state is %, expected deferred', coalesce(v_j->>'deferred_check_state','<NULL>');
  end if;
  if coalesce((v_j->>'checker_population_total')::int, -1) <> 13 then
    raise exception 'migration 320: checker population is %, expected 13', coalesce(v_j->>'checker_population_total','<NULL>');
  end if;
  if coalesce((v_j->>'unwired_checker_total')::int, -1) <> 0 then
    raise exception 'migration 320: % unwired checker(s) remain: %',
      coalesce(v_j->>'unwired_checker_total','<NULL>'), coalesce(v_j->>'unwired_checkers','<NULL>');
  end if;
  if coalesce((v_j->>'wiring_residue_total')::int, -1) <> 0 then
    raise exception 'migration 320: % unmet queue row(s) remain: %',
      coalesce(v_j->>'wiring_residue_total','<NULL>'), coalesce(v_j->>'residue_checkers','<NULL>');
  end if;
  -- The enforcement must have observed its own author. If the queue is empty
  -- here, the event trigger did not fire when this migration created the
  -- checker, and the commit-time sweep will have nothing to enforce against.
  if coalesce((v_j->>'wiring_queue_total')::int, 0) < 1 then
    raise exception 'migration 320: the wiring queue is empty, which means the enqueue trigger did not observe this migration creating a checker';
  end if;
  if coalesce((v_j->>'wiring_gap_total')::int, -1) <> 0 then
    raise exception 'migration 320: wiring_gap_total is %, expected 0', coalesce(v_j->>'wiring_gap_total','<NULL>');
  end if;

  -- Coverage: no roster drift, no orphan, population agrees.
  select public.tf_controls_signal_coverage() into v_cov;
  if coalesce(v_cov->>'ok','false') <> 'true' then
    raise exception 'migration 320: coverage checker refused: %', coalesce(v_cov->>'error','unknown');
  end if;
  if coalesce((v_cov->>'gap_total')::int, -1) <> 0 then
    raise exception 'migration 320: coverage gap_total is %, expected 0. Payload: %',
      coalesce(v_cov->>'gap_total','<NULL>'), v_cov::text;
  end if;
  if coalesce((v_cov->>'orphan_checker_total')::int, -1) <> 0 then
    raise exception 'migration 320: orphan_checker_total is %, orphans: %',
      coalesce(v_cov->>'orphan_checker_total','<NULL>'), coalesce(v_cov->>'orphan_checkers','<NULL>');
  end if;
  if coalesce((v_cov->>'axes_publishing_function_total')::int, -1) <> 13 then
    raise exception 'migration 320: axes_publishing_function_total is %, expected 13', coalesce(v_cov->>'axes_publishing_function_total','<NULL>');
  end if;
  if coalesce((v_cov->>'checkers_total')::int, -1) <> 13 then
    raise exception 'migration 320: checkers_total is %, expected 13', coalesce(v_cov->>'checkers_total','<NULL>');
  end if;

  -- Declaration enforcement must still be clean after this transaction added a function.
  select public.tf_declaration_enforcement_audit() into v_j;
  if coalesce(v_j->>'ok','false') <> 'true' then
    raise exception 'migration 320: declaration enforcement checker refused: %', coalesce(v_j->>'error','unknown');
  end if;
  if coalesce((v_j->>'enforcement_gap_total')::int, -1) <> 0 then
    -- DIVERGENCE FROM PRODUCTION, RECORDED DELIBERATELY.
    -- The statement applied to production on 2026-07-25 carried a typo here:
    -- the first raise argument read coaleske_placeholder, an identifier that
    -- does not exist. It committed clean anyway, because enforcement_gap_total
    -- was 0 and this branch was never entered. plpgsql does not resolve
    -- identifiers inside a branch it does not execute, so an assertion whose
    -- FAILURE PATH is broken passes its success path silently. The live schema
    -- is unaffected: no database object contains this text, only the immutable
    -- migration history row does. This file carries the fix so that a replay
    -- onto a fresh database reports the intended message instead of
    -- 42703 column "coaleske_placeholder" does not exist.
    -- This defect is what opened the plpgsql static analysis workstream.
    -- See docs/SIGNAL_WIRING_ENFORCEMENT.md, "House rule twenty-three".
    raise exception 'migration 320: enforcement_gap_total is %, expected 0. Payload: %',
      coalesce(v_j->>'enforcement_gap_total','<NULL>'), v_j::text;
  end if;

  -- Grant tier coverage.
  select public.tf_grant_tier_audit() into v_j;
  if coalesce(v_j->>'ok','false') <> 'true' then
    raise exception 'migration 320: grant tier audit refused: %', coalesce(v_j->>'error','unknown');
  end if;

  -- House rule twenty-two.
  select public.tf_controls_evaluate() into v_sum;
  if coalesce((v_sum->>'total')::int, -1) <> 30 then
    raise exception 'migration 320: register holds % control(s), expected 30. Summary: %',
      coalesce(v_sum->>'total','<NULL>'), coalesce(v_sum::text,'<NULL>');
  end if;
  if coalesce((v_sum->>'failing')::int, -1) <> 0 then
    raise exception 'migration 320: register reports % failing control(s), expected 0. Summary: %',
      coalesce(v_sum->>'failing','<NULL>'), coalesce(v_sum::text,'<NULL>');
  end if;

  -- The seeded control was promoted by the evaluation above.
  select status into v_status from public.it_controls where control_key = 'CM-SIGWIRE-030';
  if v_status <> 'passing' then
    raise exception 'migration 320: CM-SIGWIRE-030 evaluated to %, expected passing', coalesce(v_status,'<NULL>');
  end if;

  raise notice 'migration 320: 13 checkers, all wired, register 30 controls 0 failing, CM-SIGWIRE-030 passing';
end;
$assert$;