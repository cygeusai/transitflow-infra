-- 251: automation_registry_note_drift_checker
--
-- tf_automation_registry.notes is not decoration. tf_automation_readiness()
-- projects it into the operator-facing readiness payload, so it is the text an
-- operator reads at the moment they decide whether to arm a customer-reaching
-- automation. After migrations 249 and 250 five of the thirteen notes were
-- false:
--
--   review_requests      claimed "that sweep has no company predicate"   (249 added one)
--   marketplace_dispatch claimed "predicate not yet transcribed"          (250 transcribed it)
--   cx_first_response    claimed "No cutover key in config"               (250 set cutover_path)
--   cx_sequences         claimed "predicate not yet transcribed"          (250 transcribed it)
--   appt_reminders       claimed "No cutover key and no _since bound"     (250 classified it natural_window)
--
-- A guard that is documented as absent when it is present is a smaller problem
-- than the reverse, but both are the same defect: the system of record drifted
-- away from the system. House rule 7 says conventions live in tables and
-- checkers read the tables. This migration rewrites all thirteen notes to the
-- post-250 truth and then installs a checker that fails the next time a note
-- claims something the catalog contradicts, so the drift cannot recur silently.
--
-- The checker is observed catching a synthetic drifted row before the migration
-- is allowed to commit. House rule 6: a checker never observed catching
-- anything is not a checker.

------------------------------------------------------------------
-- 1. The drift checker
------------------------------------------------------------------
create or replace function public.tf_automation_note_drift()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $fn$
declare
  v_company uuid := 'ff000000-0000-4000-b000-000000000001';
  v_rows    jsonb := '[]'::jsonb;
  r         record;
  v_body    text;
begin
  -- Read path. Refuse by return value, never by raise, so a dashboard that
  -- calls this without a session degrades to a visible error object.
  if auth.uid() is not null and not public.user_is_internal_staff(v_company) then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;

  for r in
    select automation_key, notes, blast_radius_sql, cutover_path, sweep_function, bounded_by
      from public.tf_automation_registry
     where notes is not null
     order by automation_key
  loop
    -- Rule 1: a note may not claim a predicate is missing when one is registered.
    if r.blast_radius_sql is not null
       and (r.notes ilike '%not yet transcribed%' or r.notes ilike '%no blast-radius predicate%') then
      v_rows := v_rows || jsonb_build_object(
        'automation_key', r.automation_key,
        'rule', 'predicate_claimed_missing_but_registered',
        'note', r.notes);
    end if;

    -- Rule 2: a note may not claim a cutover key is absent when cutover_path is set.
    if r.cutover_path is not null and r.notes ilike '%no cutover key%' then
      v_rows := v_rows || jsonb_build_object(
        'automation_key', r.automation_key,
        'rule', 'cutover_claimed_absent_but_registered',
        'note', r.notes);
    end if;

    -- Rule 3: a note may not claim its sweep lacks a company predicate when the
    -- live function body carries one. This is the migration-249 drift class.
    if r.sweep_function is not null and r.notes ilike '%no company predicate%' then
      select pg_get_functiondef(p.oid) into v_body
        from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = r.sweep_function
       limit 1;
      if v_body is not null and position('company_id = v_company' in v_body) <> 0 then
        v_rows := v_rows || jsonb_build_object(
          'automation_key', r.automation_key,
          'rule', 'company_predicate_claimed_missing_but_present',
          'note', r.notes);
      end if;
    end if;

    -- Rule 4: an edge_function automation may not carry a sweep_function, and a
    -- SQL-bounded automation must carry one. Structural, not textual, but it is
    -- the same class of disagreement and belongs in the same checker.
    if r.bounded_by = 'edge_function' and r.sweep_function is not null then
      v_rows := v_rows || jsonb_build_object(
        'automation_key', r.automation_key,
        'rule', 'edge_function_should_have_no_sweep',
        'note', coalesce(r.sweep_function, ''));
    end if;
    if r.bounded_by is not null and r.bounded_by <> 'edge_function' and r.sweep_function is null then
      v_rows := v_rows || jsonb_build_object(
        'automation_key', r.automation_key,
        'rule', 'sql_bounded_automation_has_no_sweep',
        'note', coalesce(r.bounded_by, ''));
    end if;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'drift_count', jsonb_array_length(v_rows),
    'drifted', v_rows,
    'checked_at', now());
end
$fn$;

revoke all on function public.tf_automation_note_drift() from public, anon, authenticated;
grant execute on function public.tf_automation_note_drift() to postgres, service_role, authenticated;

comment on function public.tf_automation_note_drift() is
  'Compares tf_automation_registry.notes against the live catalog and registry columns. Fails when a note claims a predicate, cutover key or company predicate is missing that is actually present, or when the bounded_by classification disagrees with the presence of a sweep function. Read path: refuses by return value.';

------------------------------------------------------------------
-- 2. Rewrite all thirteen notes to the post-250 truth
------------------------------------------------------------------
do $notes$
declare
  v_pairs jsonb := $j$[
  {"k":"ai_booking","n":"Guarded by user_is_internal_staff(company) since migration 249; before that the sweep POSTed to the ai-booking edge function with no authorization of its own. Bounded by config.ai_agent.booking_since. Caps at 5 leads per tick, so blast radius is the exposure accumulated over successive ticks, not a single send."},
  {"k":"appt_reminders","n":"Bounded by a moving window, not a cutover key: tf_engagement_sweep only considers jobs whose scheduled_start falls between now + 1 hour and now + 25 hours, so arming cannot flush a historical backlog. Company predicate added in migration 249. Limit 25 per tick. Shares its sweep with estimate_followups."},
  {"k":"cx_first_response","n":"Bounded by config.cx_first_response_since, read with coalesce(..., now()) so a missing key is fail-safe rather than fail-open. Cutover path registered and predicate transcribed in migration 250. The integration_settings read was unscoped until migration 250 section 5c."},
  {"k":"cx_sequences","n":"Bounded by config.cx_sequences_since with the same coalesce(..., now()) fail-safe. Blast radius counts one row per (sequence, lead) pair because that is what the sweep enrols, so it exceeds the lead count when several active sequences match. Settings read company-scoped in migration 250."},
  {"k":"estimate_followups","n":"Shares tf_engagement_sweep with appt_reminders. Bounded by a moving window: estimates sent between 7 days and 24 hours ago, status sent or viewed, deduplicated on communications.meta->>estimate_id. Company predicate added in migration 249."},
  {"k":"eta_reminders","n":"Bounded by a moving window around scheduled_start, now - 1 hour to now + 3 hours. Messages the on-call roster in config.oncall_numbers rather than customers, but is registered customer_reaching = true because the stricter classification is the safer default. Max 4 reminders per job, 25 minutes apart, limit 15 per tick."},
  {"k":"job_prep","n":"Bounded by config.intake_autosend_since. tf_intake_sweep sends at most 25 intakes per tick. Predicate transcribed in migration 250. tf_send_intake reaches real customers over the Quo API, so test fixtures must use reserved fictional numbers."},
  {"k":"late_penalty_enforcement","n":"The platform's only unbounded automation: no cutover key, no moving window, so the first tick after arming would process the entire historical backlog. tf_automation_arm refuses to arm it while blast radius is non-zero (migration 250). Its enable flag defaulted to true until migration 249, meaning deleting the config key would have armed it. Does not reach customers."},
  {"k":"live_connect","n":"Implemented in an edge function, not in SQL. Blast radius cannot be computed from the database, so this automation is permanently blocked_no_predicate by design. Arming it is outside tf_automation_arm's bounding guard and requires a manual pre-flight."},
  {"k":"marketplace_dispatch","n":"Bounded by config.marketplace_dispatch_since. Predicate transcribed in migration 250; tf_offer_sweep gained its company predicate and a company-scoped settings read in migration 249. Offers work to marketplace pros, so it does not reach customers."},
  {"k":"missed_call_textback","n":"Implemented in an edge function, not in SQL. Blast radius cannot be computed from the database. Customer-reaching, so treat any change here as a customer-facing change even though the registry cannot measure it."},
  {"k":"push_estimates_to_hcp","n":"Implemented in an edge function. Writes estimates into Housecall Pro rather than messaging customers, which is why its no-predicate verdict is classified low risk."},
  {"k":"review_requests","n":"Bounded by config.review_requests_since. Migration 249 added the company predicate that closed a live cross-tenant exposure: 3 jobs outside the production tenant matched the candidate predicate, so arming would have texted those customers from the production Quo number under the Transit & Flow brand. Honours do_not_service."}
]$j$::jsonb;
  v_item  jsonb;
  v_hits  int;
  v_drift jsonb;
  v_null  int;
begin
  for v_item in select * from jsonb_array_elements(v_pairs) loop
    update public.tf_automation_registry
       set notes = v_item->>'n', updated_at = now()
     where automation_key = v_item->>'k';
    get diagnostics v_hits = row_count;
    if v_hits <> 1 then
      raise exception '251: expected exactly 1 registry row for %, updated %', v_item->>'k', v_hits;
    end if;
  end loop;

  select count(*) into v_null from public.tf_automation_registry where notes is null or length(notes) < 40;
  if v_null <> 0 then
    raise exception '251: % registry rows have a missing or trivially short note', v_null;
  end if;

  ------------------------------------------------------------------
  -- 3. The rewritten notes must satisfy the checker
  ------------------------------------------------------------------
  v_drift := public.tf_automation_note_drift();
  if v_drift->>'ok' is distinct from 'true' then
    raise exception '251: note drift checker refused: %', v_drift;
  end if;
  if (v_drift->>'drift_count')::int <> 0 then
    raise exception '251: notes still drifted after rewrite: %', v_drift->'drifted';
  end if;
end
$notes$;

------------------------------------------------------------------
-- 4. Observe the checker catching drift, then roll the fixture back.
--    House rule 6. The synthetic row is deleted before commit; if it is ever
--    found in a live database, migration 251 did not finish.
------------------------------------------------------------------
do $catch$
declare
  v_drift jsonb;
  v_hit   jsonb;
  v_found int := 0;
  v_left  int;
begin
  insert into public.tf_automation_registry
    (automation_key, sweep_function, cutover_path, blast_radius_sql, customer_reaching, bounded_by, notes)
  values
    ('_proof_note_drift', null, array['some_since_key'],
     'select 0::int where ($1::timestamptz is not null or $1::timestamptz is null) and $2::uuid is not null',
     false, 'cutover',
     'Synthetic row for migration 251. Predicate not yet transcribed and no cutover key in config. Migration 251 observes the drift checker catching both false claims, then deletes this row.');

  v_drift := public.tf_automation_note_drift();
  if (v_drift->>'drift_count')::int = 0 then
    delete from public.tf_automation_registry where automation_key = '_proof_note_drift';
    raise exception '251: the drift checker did not catch a row that claims a missing predicate and a missing cutover key';
  end if;

  for v_hit in select * from jsonb_array_elements(v_drift->'drifted') loop
    if v_hit->>'automation_key' = '_proof_note_drift' then
      v_found := v_found + 1;
    end if;
  end loop;

  delete from public.tf_automation_registry where automation_key = '_proof_note_drift';

  -- Both rule 1 and rule 2 should have fired on the fixture.
  if v_found < 2 then
    raise exception '251: expected the fixture to trip both the predicate rule and the cutover rule, tripped % rule(s): %', v_found, v_drift->'drifted';
  end if;

  select count(*) into v_left from public.tf_automation_registry where automation_key = '_proof_note_drift';
  if v_left <> 0 then
    raise exception '251: the synthetic fixture survived the migration';
  end if;

  select count(*) into v_left from public.tf_automation_registry;
  if v_left <> 13 then
    raise exception '251: registry should hold 13 rows, holds %', v_left;
  end if;

  -- And the live registry is clean again.
  v_drift := public.tf_automation_note_drift();
  if (v_drift->>'drift_count')::int <> 0 then
    raise exception '251: registry drifted after fixture cleanup: %', v_drift->'drifted';
  end if;

  raise notice '251: notes rewritten, drift checker installed and observed catching a synthetic drifted row';
end
$catch$;

------------------------------------------------------------------
-- 5. Observe the checker refusing a non-staff caller, by return value.
------------------------------------------------------------------
do $guard$
declare
  v_out jsonb;
begin
  perform set_config('request.jwt.claims',
    '{"sub":"dddddddd-0000-4000-a000-0000000000d1","role":"authenticated"}', true);
  v_out := public.tf_automation_note_drift();
  perform set_config('request.jwt.claims', '', true);

  if auth.uid() is not null then
    raise exception '251: request.jwt.claims was not cleared';
  end if;
  if v_out->>'ok' is distinct from 'false' or v_out->>'error' is distinct from 'forbidden' then
    raise exception '251: tf_automation_note_drift did not refuse a non-staff caller, returned %', v_out;
  end if;

  -- and it must still answer for the cron path, where auth.uid() is null
  v_out := public.tf_automation_note_drift();
  if v_out->>'ok' is distinct from 'true' then
    raise exception '251: tf_automation_note_drift refused the unauthenticated cron path: %', v_out;
  end if;
end
$guard$;

------------------------------------------------------------------
-- 6. All thirteen automation flags remain false.
------------------------------------------------------------------
do $flags$
declare
  v_company uuid := 'ff000000-0000-4000-b000-000000000001';
  v_on      int;
begin
  select count(*) into v_on
    from public.tf_automation_registry r
    join public.integration_settings s
      on s.company_id = v_company and s.provider = 'openphone'
   where coalesce((s.config->'automations'->>r.automation_key)::boolean, false) is true;

  if v_on <> 0 then
    raise exception '251: % automation flag(s) are enabled, expected 0', v_on;
  end if;
end
$flags$;
