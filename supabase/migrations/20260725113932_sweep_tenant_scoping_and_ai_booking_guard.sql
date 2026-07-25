-- 249: sweep_tenant_scoping_and_ai_booking_guard
--
-- Three customer-reaching sweeps scan public.jobs with no company_id predicate
-- and read their enable flag from an unscoped integration_settings row. A fourth,
-- tf_ai_booking_kickoff_sweep, POSTs to an edge function for up to five live leads
-- with no authorization guard of its own.
--
-- Measured exposure at the time of writing: 3 jobs exist outside the production
-- tenant, and all 3 match tf_review_request_sweep's candidate predicate. Arming
-- review_requests would text those customers from the production tenant's Quo
-- number under the Transit & Flow brand.
--
-- Repair is by anchored catalog patch, per house rule 2. Every replace asserts it
-- landed, every pre-existing landmark is asserted to survive, and both new guards
-- are observed refusing before the migration is allowed to commit.

do $drive$
declare
  v_def    text;
  v_new    text;
  v_raised boolean := false;
  v_msg    text;
  v_out    jsonb;
begin
  ------------------------------------------------------------------
  -- 1. tf_review_request_sweep
  ------------------------------------------------------------------
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'tf_review_request_sweep';
  if v_def is null then raise exception '249: tf_review_request_sweep not found'; end if;
  v_new := v_def;

  v_new := replace(v_new,
    E'declare\n  v_enabled boolean; v_since timestamptz; v_key text; v_from text; r record;',
    E'declare\n  v_company uuid := ''ff000000-0000-4000-b000-000000000001'';\n  v_enabled boolean; v_since timestamptz; v_key text; v_from text; r record;');

  v_new := replace(v_new,
    E'    into v_enabled, v_since from public.integration_settings where provider=''openphone'' limit 1;',
    E'    into v_enabled, v_since from public.integration_settings\n   where company_id = v_company and provider=''openphone'' limit 1;');

  v_new := replace(v_new,
    E'  select config->>''from_number'' into v_from from public.integration_settings where provider=''openphone'' limit 1;',
    E'  select config->>''from_number'' into v_from from public.integration_settings\n   where company_id = v_company and provider=''openphone'' limit 1;');

  v_new := replace(v_new,
    E'    where j.deleted_at is null\n      and j.updated_at >= v_since',
    E'    where j.company_id = v_company\n      and j.deleted_at is null\n      and j.updated_at >= v_since');

  if v_new = v_def then raise exception '249: tf_review_request_sweep, no anchor matched'; end if;
  execute v_new;

  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'tf_review_request_sweep';
  if position('where j.company_id = v_company' in v_def) = 0 then
    raise exception '249: tf_review_request_sweep company predicate did not land'; end if;
  if position('where company_id = v_company and provider=''openphone''' in v_def) = 0 then
    raise exception '249: tf_review_request_sweep settings scoping did not land'; end if;
  if position('review_requests_since' in v_def) = 0
     or position('do_not_service' in v_def) = 0
     or position('public.review_requests rr' in v_def) = 0 then
    raise exception '249: tf_review_request_sweep lost a pre-existing landmark'; end if;

  ------------------------------------------------------------------
  -- 2. tf_offer_sweep
  ------------------------------------------------------------------
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'tf_offer_sweep';
  if v_def is null then raise exception '249: tf_offer_sweep not found'; end if;
  v_new := v_def;

  v_new := replace(v_new,
    E'declare\n  v_enabled boolean; v_since timestamptz; r record; v_count int := 0;',
    E'declare\n  v_company uuid := ''ff000000-0000-4000-b000-000000000001'';\n  v_enabled boolean; v_since timestamptz; r record; v_count int := 0;');

  v_new := replace(v_new,
    E'  from public.integration_settings where provider = ''openphone'' limit 1;',
    E'  from public.integration_settings\n   where company_id = v_company and provider = ''openphone'' limit 1;');

  v_new := replace(v_new,
    E'    where j.deleted_at is null\n      and j.auto_offered_at is null',
    E'    where j.company_id = v_company\n      and j.deleted_at is null\n      and j.auto_offered_at is null');

  if v_new = v_def then raise exception '249: tf_offer_sweep, no anchor matched'; end if;
  execute v_new;

  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'tf_offer_sweep';
  if position('where j.company_id = v_company' in v_def) = 0 then
    raise exception '249: tf_offer_sweep company predicate did not land'; end if;
  if position('where company_id = v_company and provider = ''openphone''' in v_def) = 0 then
    raise exception '249: tf_offer_sweep settings scoping did not land'; end if;
  if position('marketplace_dispatch_since' in v_def) = 0
     or position('public.tf_offer_job(r.id, false)' in v_def) = 0
     or position('dispatch_assignments da' in v_def) = 0 then
    raise exception '249: tf_offer_sweep lost a pre-existing landmark'; end if;

  ------------------------------------------------------------------
  -- 3. tf_late_penalty_sweep
  --    Also closes a boolean-default hazard: the enable flag defaulted to TRUE,
  --    so deleting the config key would have armed the automation rather than
  --    disarmed it. Convention 9: a boolean parameter or flag that gates a
  --    side effect defaults to the safe value, which is false.
  ------------------------------------------------------------------
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'tf_late_penalty_sweep';
  if v_def is null then raise exception '249: tf_late_penalty_sweep not found'; end if;
  v_new := v_def;

  v_new := replace(v_new,
    E'declare\n  v_enabled boolean; r record; v_count int := 0;',
    E'declare\n  v_company uuid := ''ff000000-0000-4000-b000-000000000001'';\n  v_enabled boolean; r record; v_count int := 0;');

  v_new := replace(v_new,
    E'  select coalesce((config->''automations''->>''late_penalty_enforcement'')::boolean, true)\n    into v_enabled from public.integration_settings where provider=''openphone'' limit 1;',
    E'  select coalesce((config->''automations''->>''late_penalty_enforcement'')::boolean, false)\n    into v_enabled from public.integration_settings\n   where company_id = v_company and provider=''openphone'' limit 1;');

  v_new := replace(v_new,
    E'    where j.deleted_at is null\n      and j.arrived_at is not null',
    E'    where j.company_id = v_company\n      and j.deleted_at is null\n      and j.arrived_at is not null');

  if v_new = v_def then raise exception '249: tf_late_penalty_sweep, no anchor matched'; end if;
  execute v_new;

  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'tf_late_penalty_sweep';
  if position('where j.company_id = v_company' in v_def) = 0 then
    raise exception '249: tf_late_penalty_sweep company predicate did not land'; end if;
  if position('''late_penalty_enforcement'')::boolean, false)' in v_def) = 0 then
    raise exception '249: tf_late_penalty_sweep boolean default is still true'; end if;
  if position('public.late_penalties lp' in v_def) = 0
     or position('late_penalty_review' in v_def) = 0
     or position('0.15' in v_def) = 0 then
    raise exception '249: tf_late_penalty_sweep lost a pre-existing landmark'; end if;

  ------------------------------------------------------------------
  -- 4. tf_ai_booking_kickoff_sweep : add the cron-tolerant staff guard
  ------------------------------------------------------------------
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'tf_ai_booking_kickoff_sweep';
  if v_def is null then raise exception '249: tf_ai_booking_kickoff_sweep not found'; end if;
  v_new := v_def;

  v_new := replace(v_new,
    E'begin\n  select config into v_cfg from integration_settings where company_id = v_company and provider = ''openphone'';',
    E'begin\n  if auth.uid() is not null and not public.user_is_internal_staff(v_company) then\n    raise exception ''not authorized'';\n  end if;\n\n  select config into v_cfg from integration_settings where company_id = v_company and provider = ''openphone'';');

  if v_new = v_def then raise exception '249: tf_ai_booking_kickoff_sweep, no anchor matched'; end if;
  execute v_new;

  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'tf_ai_booking_kickoff_sweep';
  if position('user_is_internal_staff(v_company)' in v_def) = 0 then
    raise exception '249: tf_ai_booking_kickoff_sweep guard did not land'; end if;
  if position('functions/v1/ai-booking' in v_def) = 0
     or position('booking_since' in v_def) = 0
     or position('limit 5' in v_def) = 0 then
    raise exception '249: tf_ai_booking_kickoff_sweep lost a pre-existing landmark'; end if;

  ------------------------------------------------------------------
  -- 5. Prove the sweeps still run and still refuse to act while disarmed.
  --    All four automation flags are false, so each must short-circuit before
  --    reaching a customer. auth.uid() is null here, so the new guard is inert,
  --    which is the cron path.
  ------------------------------------------------------------------
  v_out := public.tf_review_request_sweep();
  if v_out->>'skipped' is distinct from 'disabled' then
    raise exception '249: tf_review_request_sweep did not short-circuit, returned %', v_out; end if;

  v_out := public.tf_offer_sweep();
  if v_out->>'skipped' is distinct from 'disabled' then
    raise exception '249: tf_offer_sweep did not short-circuit, returned %', v_out; end if;

  v_out := public.tf_late_penalty_sweep();
  if v_out->>'skipped' is distinct from 'disabled' then
    raise exception '249: tf_late_penalty_sweep did not short-circuit, returned %', v_out; end if;

  v_out := public.tf_ai_booking_kickoff_sweep();
  if v_out->>'skipped' is distinct from 'disabled' then
    raise exception '249: tf_ai_booking_kickoff_sweep did not short-circuit, returned %', v_out; end if;

  ------------------------------------------------------------------
  -- 6. Observe the new guard refusing. House rule 5: a guard never observed
  --    refusing is not a guard. set local role alone leaves auth.uid() null,
  --    so the claims must be set, and cleared again afterwards.
  ------------------------------------------------------------------
  perform set_config('request.jwt.claims',
    '{"sub":"dddddddd-0000-4000-a000-0000000000d1","role":"authenticated"}', true);
  begin
    perform public.tf_ai_booking_kickoff_sweep();
  exception when others then
    v_raised := true; v_msg := sqlerrm;
  end;
  perform set_config('request.jwt.claims', '', true);

  if not v_raised then
    raise exception '249: tf_ai_booking_kickoff_sweep guard did not refuse a non-staff caller'; end if;
  if v_msg <> 'not authorized' then
    raise exception '249: tf_ai_booking_kickoff_sweep guard raised the wrong error: %', v_msg; end if;

  -- and confirm the claims really were cleared, or every later call is poisoned
  if auth.uid() is not null then
    raise exception '249: request.jwt.claims was not cleared'; end if;

  raise notice '249: four sweeps repaired, tenant scoping asserted, ai_booking guard observed refusing';
end
$drive$;
