-- 250: automation_blast_radius_transcription_and_bounding_model
--
-- Blast radius answers "how many rows would the first tick touch". It does not
-- answer "what stops the first tick touching all of history". Those are two
-- different questions and only the first was ever written down.
--
-- There are exactly four answers to the second question in this platform:
--   cutover        a _since key that tf_automation_arm stamps at arm time
--   natural_window the sweep predicate is itself a moving time window
--   unbounded      nothing does, the entire backlog is fair game on tick one
--   edge_function  the automation is not implemented in SQL at all
--
-- This migration:
--   1. adds tf_automation_registry.bounded_by with a closed check constraint
--   2. corrects two cutover_path rows that understated the safety that exists
--   3. transcribes seven sweep predicates into blast_radius_sql
--   4. classifies all thirteen automations under the bounding model
--   5. teaches tf_automation_arm to refuse an unbounded automation with a
--      non-empty backlog, and tf_automation_readiness to surface the reason
--   6. closes the last two unscoped integration_settings reads (cx sweeps),
--      the same defect class migration 249 closed for the other three
--
-- Predicate contract, which is not obvious and has already cost one migration:
-- tf_automation_blast_radius runs
--     execute v_reg.blast_radius_sql into v_count using coalesce(v_since, now()), v_company
-- so $1 is the cutover timestamptz and $2 is the company uuid, and BOTH must be
-- referenced by every predicate or PL/pgSQL raises "too many parameters
-- specified for EXECUTE". Where a sweep has no cutover bound, $1 is referenced
-- through the visible tautology:
--     and ($1::timestamptz is not null or $1::timestamptz is null)

------------------------------------------------------------------
-- 1. The bounding column
------------------------------------------------------------------
alter table public.tf_automation_registry add column if not exists bounded_by text;

alter table public.tf_automation_registry
  drop constraint if exists tf_automation_registry_bounded_by_chk;

alter table public.tf_automation_registry
  add constraint tf_automation_registry_bounded_by_chk
  check (bounded_by is null or bounded_by in ('cutover','natural_window','unbounded','edge_function'));

comment on column public.tf_automation_registry.bounded_by is
  'What prevents the first tick after arming from processing the entire history. cutover = a _since key stamped by tf_automation_arm; natural_window = the sweep predicate is a moving time window; unbounded = nothing does, the backlog is fair game; edge_function = not implemented in SQL.';

------------------------------------------------------------------
-- 2. Two registry rows understated the safety that already exists.
--    Both cx sweeps read a _since key with coalesce(..., now()), so the
--    bound is real and fail-safe. The registry simply did not know, which
--    meant tf_automation_arm would never have stamped the key at arm time.
------------------------------------------------------------------
update public.tf_automation_registry
   set cutover_path = array['cx_first_response_since'], updated_at = now()
 where automation_key = 'cx_first_response';

update public.tf_automation_registry
   set cutover_path = array['cx_sequences_since'], updated_at = now()
 where automation_key = 'cx_sequences';

------------------------------------------------------------------
-- 3. Predicate transcription. Each one is a literal restatement of the
--    candidate loop inside the sweep it belongs to, at the same limits and
--    the same exclusions, minus the per-row skips the sweep applies after
--    selection (phone-length checks, pacing) which can only lower the count.
------------------------------------------------------------------

-- appt_reminders : tf_engagement_sweep section 1
update public.tf_automation_registry set blast_radius_sql = $br$
select count(*)::int
  from public.jobs j
  join public.customers c on c.id = j.customer_id
 where j.company_id = $2
   and j.deleted_at is null
   and j.status::text in ('scheduled','dispatched')
   and j.scheduled_start between now() + interval '1 hour' and now() + interval '25 hours'
   and not exists (select 1 from public.communications m
                    where m.job_id = j.id and m.meta->>'kind' = 'appt_reminder')
   and ($1::timestamptz is not null or $1::timestamptz is null)
$br$, updated_at = now() where automation_key = 'appt_reminders';

-- estimate_followups : tf_engagement_sweep section 2
update public.tf_automation_registry set blast_radius_sql = $br$
select count(*)::int
  from public.estimates e
  join public.customers c on c.id = e.customer_id
 where e.company_id = $2
   and e.deleted_at is null
   and e.status::text in ('sent','viewed')
   and e.sent_at between now() - interval '7 days' and now() - interval '24 hours'
   and not exists (select 1 from public.communications m
                    where m.meta->>'kind' = 'estimate_followup'
                      and m.meta->>'estimate_id' = e.id::text)
   and ($1::timestamptz is not null or $1::timestamptz is null)
$br$, updated_at = now() where automation_key = 'estimate_followups';

-- eta_reminders : tf_eta_reminder_sweep. Messages the on-call roster, not the
-- customer, but it is registered customer_reaching = true deliberately: the
-- stricter classification is the safer default and nothing depends on it being
-- loosened.
update public.tf_automation_registry set blast_radius_sql = $br$
select count(*)::int
  from public.jobs j
  join public.customers c on c.id = j.customer_id
 where j.company_id = $2
   and j.deleted_at is null
   and j.status::text in ('scheduled','dispatched','en_route','intake')
   and j.tech_eta is null
   and j.needs_reschedule = false
   and j.scheduled_start is not null
   and j.scheduled_start between now() - interval '1 hour' and now() + interval '3 hours'
   and ($1::timestamptz is not null or $1::timestamptz is null)
$br$, updated_at = now() where automation_key = 'eta_reminders';

-- cx_first_response : tf_cx_first_response_sweep, bounded by the cutover
update public.tf_automation_registry set blast_radius_sql = $br$
select count(*)::int
  from public.leads l
 where l.company_id = $2
   and l.deleted_at is null
   and l.status::text = 'new'
   and l.received_at >= $1
   and l.phone is not null
   and not exists (select 1 from public.automation_runs ar
                    where ar.lead_id = l.id and ar.kind = 'first_response')
$br$, updated_at = now() where automation_key = 'cx_first_response';

-- cx_sequences : tf_cx_sequence_sweep enrolment loop, one row per
-- (sequence, lead) pair because that is what the sweep actually enrols
update public.tf_automation_registry set blast_radius_sql = $br$
select count(*)::int
  from public.followup_sequences s
  join public.leads l
    on l.company_id = s.company_id
   and l.deleted_at is null
   and l.phone is not null
   and l.received_at >= $1
   and (s.trigger_status is null or l.status::text = s.trigger_status::text)
   and (s.lead_source_id is null or l.source_id = s.lead_source_id)
 where s.company_id = $2
   and s.is_active
   and s.deleted_at is null
   and not exists (select 1 from public.automation_runs ar
                    where ar.sequence_id = s.id and ar.lead_id = l.id)
$br$, updated_at = now() where automation_key = 'cx_sequences';

-- marketplace_dispatch : tf_offer_sweep
update public.tf_automation_registry set blast_radius_sql = $br$
select count(*)::int
  from public.jobs j
  join public.customers c on c.id = j.customer_id and c.deleted_at is null
 where j.company_id = $2
   and j.deleted_at is null
   and j.auto_offered_at is null
   and j.created_at >= $1
   and j.status::text in ('scheduled','intake')
   and j.trade_id is not null
   and coalesce(j.needs_reschedule, false) = false
   and not exists (select 1 from public.job_offers o where o.job_id = j.id)
   and not exists (select 1 from public.dispatch_assignments da
                    where da.job_id = j.id and da.deleted_at is null
                      and da.technician_id is not null
                      and coalesce(da.status::text,'') not in ('declined','cancelled'))
$br$, updated_at = now() where automation_key = 'marketplace_dispatch';

-- late_penalty_enforcement : tf_late_penalty_sweep. This is the unbounded one.
-- There is no _since key and no moving window: every historically late job is
-- a candidate forever until a late_penalties row exists for it.
update public.tf_automation_registry set blast_radius_sql = $br$
select count(*)::int
  from public.jobs j
 where j.company_id = $2
   and j.deleted_at is null
   and j.arrived_at is not null
   and j.arrival_by is not null
   and j.arrived_at > j.arrival_by + interval '5 minutes'
   and coalesce(j.needs_reschedule, false) = false
   and j.status::text in ('on_site','in_progress','work_complete','pending_signoff','signed_off','invoiced','closed')
   and not exists (select 1 from public.late_penalties lp where lp.job_id = j.id)
   and exists (select 1 from public.job_offers o
                where o.job_id = j.id and o.status::text = 'accepted')
   and ($1::timestamptz is not null or $1::timestamptz is null)
$br$, updated_at = now() where automation_key = 'late_penalty_enforcement';

------------------------------------------------------------------
-- 4. Classify every automation under the bounding model
------------------------------------------------------------------
update public.tf_automation_registry set bounded_by = 'cutover', updated_at = now()
 where automation_key in ('ai_booking','job_prep','review_requests',
                          'cx_first_response','cx_sequences','marketplace_dispatch');

update public.tf_automation_registry set bounded_by = 'natural_window', updated_at = now()
 where automation_key in ('appt_reminders','estimate_followups','eta_reminders');

update public.tf_automation_registry set bounded_by = 'unbounded', updated_at = now()
 where automation_key = 'late_penalty_enforcement';

update public.tf_automation_registry set bounded_by = 'edge_function', updated_at = now()
 where automation_key in ('live_connect','missed_call_textback','push_estimates_to_hcp');

------------------------------------------------------------------
-- 5. Patch the arming path and the readiness report, then prove all of it.
------------------------------------------------------------------
do $drive$
declare
  v_def    text;
  v_new    text;
  v_msg    text;
  v_out    jsonb;
  v_br     jsonb;
  v_cfg    jsonb;
  v_n      int;
  v_flag   text;
  r        record;
  v_company uuid := 'ff000000-0000-4000-b000-000000000001';
begin
  ------------------------------------------------------------------
  -- 5a. tf_automation_arm : refuse an unbounded automation with a backlog
  ------------------------------------------------------------------
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'tf_automation_arm';
  if v_def is null then raise exception '250: tf_automation_arm not found'; end if;

  v_new := replace(v_def,
    E'    v_br := public.tf_automation_blast_radius(p_key);\n    v_radius := (v_br ->> ''blast_radius'')::int;\n    v_new_ts := now();',
    E'    v_br := public.tf_automation_blast_radius(p_key);\n    v_radius := (v_br ->> ''blast_radius'')::int;\n\n    -- An unbounded automation has no cutover key and no moving window, so the\n    -- first tick after arming processes the entire backlog. Refuse until it is\n    -- empty, or until the sweep is given a bound.\n    if v_reg.bounded_by = ''unbounded'' and coalesce(v_radius, 0) > 0 then\n      raise exception\n        ''refusing to arm %: it is unbounded (no cutover key, no moving window) and % historical rows are waiting. The first tick would process all of them. Clear the backlog, or give the sweep a cutover key, then arm. Registry note: %'',\n        p_key, v_radius, coalesce(v_reg.notes, ''(none)'');\n    end if;\n\n    v_new_ts := now();');

  if v_new = v_def then raise exception '250: tf_automation_arm, no anchor matched'; end if;
  execute v_new;

  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'tf_automation_arm';
  if position('bounded_by = ''unbounded''' in v_def) = 0 then
    raise exception '250: tf_automation_arm unbounded refusal did not land'; end if;
  if position('not authorized to arm automations' in v_def) = 0
     or position('no blast-radius predicate is registered' in v_def) = 0
     or position('automation_arm_log' in v_def) = 0 then
    raise exception '250: tf_automation_arm lost a pre-existing landmark'; end if;

  ------------------------------------------------------------------
  -- 5b. tf_automation_readiness : new verdict and a visible bounding column
  ------------------------------------------------------------------
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'tf_automation_readiness';
  if v_def is null then raise exception '250: tf_automation_readiness not found'; end if;
  v_new := v_def;

  v_new := replace(v_new,
    E'      when r.blast_radius_sql is null then ''blocked_no_predicate_low_risk''\n      when (v_br ->> ''cutover_age_hours'')::numeric > 24 then ''stale_cutover''',
    E'      when r.blast_radius_sql is null then ''blocked_no_predicate_low_risk''\n      when r.bounded_by = ''unbounded'' and coalesce((v_br ->> ''blast_radius'')::int, 0) > 0\n        then ''blocked_unbounded_backlog''\n      when (v_br ->> ''cutover_age_hours'')::numeric > 24 then ''stale_cutover''');

  v_new := replace(v_new,
    E'      ''customer_reaching'', r.customer_reaching,',
    E'      ''customer_reaching'', r.customer_reaching,\n      ''bounded_by'', r.bounded_by,');

  if v_new = v_def then raise exception '250: tf_automation_readiness, no anchor matched'; end if;
  execute v_new;

  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'tf_automation_readiness';
  if position('blocked_unbounded_backlog' in v_def) = 0 then
    raise exception '250: readiness verdict did not land'; end if;
  if position('''bounded_by'', r.bounded_by' in v_def) = 0 then
    raise exception '250: readiness bounded_by projection did not land'; end if;
  if position('blocked_no_predicate_low_risk' in v_def) = 0
     or position('stale_cutover' in v_def) = 0 then
    raise exception '250: tf_automation_readiness lost a pre-existing landmark'; end if;

  ------------------------------------------------------------------
  -- 5c. The last two unscoped integration_settings reads. Same defect class
  --     as migration 249: the enable flag was read from whichever openphone
  --     row came back first rather than this company's row.
  ------------------------------------------------------------------
  for v_flag in select unnest(array['tf_cx_first_response_sweep','tf_cx_sequence_sweep']) loop
    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_flag;
    if v_def is null then raise exception '250: % not found', v_flag; end if;

    v_new := replace(v_def,
      E'from public.integration_settings where provider=''openphone'' limit 1;',
      E'from public.integration_settings where company_id = v_company and provider=''openphone'' limit 1;');

    if v_new = v_def then raise exception '250: %, no settings anchor matched', v_flag; end if;
    execute v_new;

    select pg_get_functiondef(p.oid) into v_def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = v_flag;
    if position('where provider=''openphone'' limit 1;' in v_def) <> 0 then
      raise exception '250: % still has an unscoped settings read', v_flag; end if;
    if position('company_id = v_company and provider=''openphone''' in v_def) = 0 then
      raise exception '250: % settings scoping did not land', v_flag; end if;
  end loop;

  ------------------------------------------------------------------
  -- 5d. Every registered predicate must actually execute.
  --     House rule 6: a checker never observed catching anything is not a
  --     checker. A predicate that has never been run is not a predicate.
  ------------------------------------------------------------------
  for r in select automation_key from public.tf_automation_registry
            where blast_radius_sql is not null order by automation_key loop
    v_br := public.tf_automation_blast_radius(r.automation_key);
    if coalesce((v_br ->> 'ok')::boolean, false) is not true then
      raise exception '250: blast radius for % returned not-ok: %', r.automation_key, v_br; end if;
    if coalesce((v_br ->> 'registered')::boolean, false) is not true then
      raise exception '250: blast radius for % reports unregistered', r.automation_key; end if;
    if v_br ->> 'blast_radius' is null then
      raise exception '250: blast radius for % returned null', r.automation_key; end if;
    raise notice '250: blast_radius % = % (bounded_by %)',
      r.automation_key, v_br ->> 'blast_radius',
      (select bounded_by from public.tf_automation_registry where automation_key = r.automation_key);
  end loop;

  ------------------------------------------------------------------
  -- 5e. Coverage assertions
  ------------------------------------------------------------------
  select count(*) into v_n from public.tf_automation_registry where bounded_by is null;
  if v_n <> 0 then raise exception '250: % automations still unclassified', v_n; end if;

  select count(*) into v_n from public.tf_automation_registry where blast_radius_sql is null;
  if v_n <> 3 then
    raise exception '250: expected exactly 3 automations without a predicate, found %', v_n; end if;

  select count(*) into v_n from public.tf_automation_registry
   where blast_radius_sql is null and bounded_by is distinct from 'edge_function';
  if v_n <> 0 then
    raise exception '250: % automations have no predicate and are not edge_function', v_n; end if;

  select count(*) into v_n from public.tf_automation_registry
   where bounded_by = 'cutover' and cutover_path is null;
  if v_n <> 0 then
    raise exception '250: % automations claim cutover bounding with no cutover_path', v_n; end if;

  ------------------------------------------------------------------
  -- 5f. Readiness must surface the new field
  ------------------------------------------------------------------
  v_out := public.tf_automation_readiness();
  if coalesce((v_out ->> 'ok')::boolean, false) is not true then
    raise exception '250: readiness returned not-ok: %', v_out; end if;
  if not exists (
    select 1 from jsonb_array_elements(v_out -> 'automations') a
     where a ->> 'bounded_by' is not null) then
    raise exception '250: readiness did not surface bounded_by'; end if;
  if exists (
    select 1 from jsonb_array_elements(v_out -> 'automations') a
     where a ->> 'bounded_by' is null) then
    raise exception '250: readiness surfaced a null bounded_by'; end if;

  ------------------------------------------------------------------
  -- 5g. Observe the unbounded refusal. House rule 5: a guard never observed
  --     refusing is not a guard.
  --
  --     The only real unbounded automation is late_penalty_enforcement and its
  --     backlog is currently 0, so arming it would SUCCEED rather than refuse.
  --     Attempting the proof against it would arm a live automation. So the
  --     failure is induced instead: a synthetic registry row is created whose
  --     predicate returns a constant positive count, the refusal is observed
  --     against that row, and the row is removed before the migration commits.
  --
  --     The inner block is a subtransaction. If tf_automation_arm refuses, the
  --     exception rolls it back. If it does NOT refuse, the synthetic key would
  --     have been written into config->'automations', so the block raises its
  --     own exception to force that same rollback and then fails the migration.
  --     Under no code path does an arm survive this proof.
  ------------------------------------------------------------------
  insert into public.tf_automation_registry
    (automation_key, sweep_function, cutover_path, blast_radius_sql, customer_reaching, bounded_by, notes)
  values
    ('_proof_unbounded', null, null,
     'select 42::int where ($1::timestamptz is not null or $1::timestamptz is null) and $2::uuid is not null',
     false, 'unbounded',
     'Synthetic row. Migration 250 uses it to observe the unbounded arming refusal, then deletes it. If this row is ever found in a live database, migration 250 did not finish.');

  v_br := public.tf_automation_blast_radius('_proof_unbounded');
  if (v_br ->> 'blast_radius')::int <> 42 then
    raise exception '250: synthetic predicate returned %, expected 42', v_br ->> 'blast_radius'; end if;

  perform set_config('request.jwt.claims',
    '{"sub":"f6f3566e-4baa-4963-8da7-134b8ed541ce","role":"authenticated"}', true);
  begin
    perform public.tf_automation_arm('_proof_unbounded', true);
    raise exception 'TF250_ARM_WAS_NOT_REFUSED';
  exception when others then
    v_msg := sqlerrm;
  end;
  perform set_config('request.jwt.claims', '', true);

  delete from public.tf_automation_registry where automation_key = '_proof_unbounded';

  if auth.uid() is not null then
    raise exception '250: request.jwt.claims was not cleared'; end if;

  if v_msg = 'TF250_ARM_WAS_NOT_REFUSED' then
    raise exception '250: tf_automation_arm did not refuse an unbounded automation with a backlog of 42'; end if;
  if position('it is unbounded' in v_msg) = 0 then
    raise exception '250: arm refused for the wrong reason: %', v_msg; end if;
  if position('42 historical rows' in v_msg) = 0 then
    raise exception '250: refusal did not report the measured backlog: %', v_msg; end if;
  raise notice '250: unbounded refusal observed -> %', v_msg;

  select count(*) into v_n from public.tf_automation_registry;
  if v_n <> 13 then
    raise exception '250: registry has % rows after the proof, expected 13', v_n; end if;
  if exists (select 1 from public.tf_automation_registry where automation_key = '_proof_unbounded') then
    raise exception '250: synthetic proof row survived'; end if;

  ------------------------------------------------------------------
  -- 5h. Nothing armed itself along the way. All thirteen flags stay false.
  ------------------------------------------------------------------
  select config into v_cfg from public.integration_settings
   where provider = 'openphone' and company_id = v_company limit 1;
  for v_flag in select automation_key from public.tf_automation_registry order by automation_key loop
    if coalesce((v_cfg -> 'automations' ->> v_flag)::boolean, false) then
      raise exception '250: automation % is ARMED and must not be', v_flag; end if;
  end loop;

  raise notice '250: bounding model applied, 10 predicates registered, 3 edge_function, all 13 flags false';
end
$drive$;
