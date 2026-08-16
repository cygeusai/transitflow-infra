-- m339_regression_a20_no_customer_files_their_own_photo
--
-- m338 gave the unfiled-photo page a destination and words. quo-webhook v23
-- removed the ask and fixed the guard that stopped the page firing at all.
-- This is what keeps both from coming back.
--
-- PROVEN RED BEFORE SHIPPING GREEN, on both halves:
--   Destination. Before m338 there was no tf_notification_routing row for
--   job_photo_not_filed, so the same predicate returns 0 and A20 is false. The
--   drain would have fallen back to #information-technology with a null
--   template, rendering the generic 'Something in the platform needs a look',
--   which is neither true nor actionable for a misfiled customer photo.
--   Copy. Against a 30 day window instead of the cutover, the same count
--   returns 43, spanning 2026-07-18 to 2026-08-16 13:32 UTC, and A20 is false.
--
-- The cutover boundary is deliberate and is the honest form of this check. The
-- 43 messages already sent are history. What must never happen again is a 44th.
--
-- Suite goes from 19 assertions to 20.

CREATE OR REPLACE FUNCTION public.tf_platform_regression_suite(p_company_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  r        jsonb := '[]'::jsonb;
  v_n      int;
  v_n2     int;
  v_txt    text;
  v_ok     boolean;
  v_passed int := 0;
  v_failed int := 0;
  v_gate   boolean;
  v_ie     boolean;
  v_cfg    boolean;
  v_probe  text;
  v_render text;
  v_key    text;
begin
  if p_company_id is null then
    raise exception 'p_company_id is required and has no default by design';
  end if;
  if auth.uid() is not null and not public.user_is_internal_staff(p_company_id) then
    raise exception 'not_authorized';
  end if;

  -- A1. THE ANON SURFACE IS A CLOSED, REVIEWED ALLOWLIST.
  select count(*), coalesce(string_agg(n.nspname||'.'||p.proname, ', ' order by p.proname),'')
    into v_n, v_txt
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname in ('public','cygeus') and p.prosecdef
    and has_function_privilege('anon', p.oid, 'EXECUTE')
    and p.proname not in ('auth_org','has_permission','create_organization_and_owner',
                          'studio_is_staff','tf_founding_stats');
  v_ok := (v_n = 0);
  r := r || jsonb_build_object('id','A1','name','anon surface is the reviewed allowlist',
        'ok',v_ok,'severity','critical','observed',v_n,'detail',nullif(v_txt,''),
        'prevents','pre-authentication cross-tenant privilege escalation via an unguarded SECURITY DEFINER function');
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;

  -- A2. FUNCTION SAFETY CONTROL BOARD IS CLEAN.
  select (x->>'gap_total')::int + (x->>'drift_total')::int
       + (x->>'undeclared_total')::int + (x->>'stale_total')::int
    into v_n
  from (select public.tf_function_safety_audit() as x) s;
  v_ok := (v_n = 0);
  r := r || jsonb_build_object('id','A2','name','function safety board clean',
        'ok',v_ok,'severity','high','observed',v_n,
        'prevents','an undeclared or mis-declared function reaching production unnoticed');
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;

  -- A3. SMS DELIVERY IS NEVER CLAIMED WITHOUT CARRIER CONFIRMATION.
  select count(*) into v_n
  from public.notifications nt
  where nt.company_id = p_company_id
    and nt.delivered_channel = 'sms'
    and nt.delivered_at is not null
    and not exists (
      select 1 from public.tf_notification_attempts a
      where a.notification_id = nt.id and a.channel = 'sms'
        and a.delivery_confirmed_at is not null
        and a.provider_status = 'delivered');
  v_ok := (v_n = 0);
  r := r || jsonb_build_object('id','A3','name','no SMS marked delivered without carrier confirmation',
        'ok',v_ok,'severity','critical','observed',v_n,
        'prevents','reporting an undelivered emergency page as delivered');
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;

  -- A4. AN ARMED DRAIN HAS SOMEWHERE TO SEND.
  select count(*) into v_n from public.tf_drain_control c
  where c.company_id = p_company_id and c.is_armed
    and cardinality(c.armed_tiers) > 0
    and public.tf_resolve_page_target(p_company_id,'sms','critical',null) is null;
  v_ok := (v_n = 0);
  r := r || jsonb_build_object('id','A4','name','armed drain has a resolvable destination',
        'ok',v_ok,'severity','critical','observed',v_n,
        'prevents','an escalation path that reports success and reaches no human');
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;

  -- A5. THE DEDUPE CONTRACT tf-omni-send v6 DEPENDS ON.
  v_txt := pg_get_functiondef('public.tf_page_staff_sev(text,uuid,text,text,text,text,text,uuid)'::regprocedure);
  v_ok := position('''notified'', v_recent' in v_txt) > 0;
  r := r || jsonb_build_object('id','A5','name','deduped page still reports notified > 0',
        'ok',v_ok,'severity','high','observed',v_ok,'method','structural (source inspection)',
        'prevents','a successful deduplication being misread as a paging failure by tf-omni-send');
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;

  -- A6. THE INTERNAL_OPS CONSENT LANE IS PREDICATE-BOUND, NOT A BYPASS FLAG.
  v_txt := pg_get_functiondef('public.tf_consent_gate(text,text,text,text,text,uuid)'::regprocedure);
  v_ok := position('tf_page_targets' in v_txt) > 0 and position('internal_ops' in v_txt) > 0;
  r := r || jsonb_build_object('id','A6','name','internal_ops lane is bound to a registered page target',
        'ok',v_ok,'severity','critical','observed',v_ok,'method','structural (source inspection)',
        'prevents','escaping consent by inventing a purpose string');
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;

  -- A7. THE CUSTOMER-FACING SMS SENDER IS CONFIGURED AND WELL-FORMED.
  select count(*) into v_n from public.integration_settings s
  where s.company_id = p_company_id and s.provider = 'openphone'::integration_provider
    and public.tf_contact_normalize(s.config->'twilio'->>'from_number','phone') is not null;
  v_ok := (v_n = 1);
  r := r || jsonb_build_object('id','A7','name','outbound SMS sender is set and E.164-normalisable',
        'ok',v_ok,'severity','high','observed',v_n,
        'prevents','sending from an unconfigured or malformed number');
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;

  -- A8. PROMOTION IS ONE-WAY AND ONE-TIME.
  select count(*) into v_n from (
    select lead_id from public.detected_opportunities
    where company_id = p_company_id and lead_id is not null
    group by lead_id having count(*) > 1) d;
  v_ok := (v_n = 0);
  r := r || jsonb_build_object('id','A8','name','no lead is claimed by two opportunities',
        'ok',v_ok,'severity','high','observed',v_n,
        'prevents','double-contacting one person from a duplicated promotion');
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;

  -- A9. ENGINE AND GOVERNANCE TABLES HAVE RLS AND A POLICY.
  select count(*) into v_n
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname='public'
    and c.relname in ('social_communities','social_content','social_identities',
                      'detected_opportunities','opportunity_signals',
                      'tf_page_targets','tf_page_routes','tf_drain_control',
                      'tf_notification_attempts','tf_notification_severity',
                      'tf_authenticated_definer_allowlist')
    and (not c.relrowsecurity or not exists (select 1 from pg_policy p where p.polrelid=c.oid));
  v_ok := (v_n = 0);
  r := r || jsonb_build_object('id','A9','name','engine and governance tables have RLS and a policy',
        'ok',v_ok,'severity','high','observed',v_n,
        'prevents','a table that is either wide open or silently unreadable');
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;

  -- A10. THE NIGHTLY CUSTOMER MERGE STILL REPOINTS SOCIAL IDENTITIES.
  v_txt := pg_get_functiondef('public.tf_merge_duplicate_customers(boolean)'::regprocedure);
  v_ok := position('social_identities' in v_txt) > 0;
  r := r || jsonb_build_object('id','A10','name','social_identities is in the nightly merge array',
        'ok',v_ok,'severity','high','observed',v_ok,'method','structural (source inspection)',
        'prevents','the nightly merge orphaning every social identity of a merged customer');
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;

  -- A11. NOTHING ARMED IS UNMEASURABLE, AND EVERY GAP IS DECLARED.
  select count(*) into v_n
  from public.integration_settings s
  cross join lateral jsonb_each(coalesce(s.config->'automations','{}'::jsonb)) e
  join public.tf_automation_registry a on a.automation_key = e.key
  where s.company_id = p_company_id
    and s.provider = 'openphone'::integration_provider
    and e.value = 'true'::jsonb
    and a.blast_radius_sql is null;

  select count(*) into v_n2
  from public.tf_automation_registry a
  where a.customer_reaching
    and a.blast_radius_sql is null
    and (a.bounded_by is distinct from 'edge_function' or coalesce(a.notes,'') = '');

  v_ok := (v_n = 0 and v_n2 = 0);
  r := r || jsonb_build_object('id','A11','name','nothing armed is unmeasurable, and every gap is declared',
        'ok',v_ok,'severity','critical','observed',v_n,'undeclared_gaps',v_n2,
        'prevents','arming an outreach path whose reach cannot be measured, and letting an unmeasurable automation exist by omission rather than by decision');
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;

  -- A12. THE SEVERITY REGISTRY COVERS THE EVENT KEYS THAT MATTER.
  select count(*) into v_n from (values
    ('fnol_emergency'),('life_safety'),('outbound_sent_not_logged'),('outbound_delivery_unknown')
  ) k(key)
  where not exists (select 1 from public.tf_notification_severity s
                    where s.event_key = k.key and s.severity = 'critical');
  v_ok := (v_n = 0);
  r := r || jsonb_build_object('id','A12','name','life-safety event keys are mapped critical',
        'ok',v_ok,'severity','critical','observed',v_n,
        'prevents','an emergency page being routed at the wrong tier');
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;

  -- A13. ARMING IS PREVENTED AT THE TABLE, NOT ONLY DETECTED AFTERWARDS.
  select count(*) into v_n
  from pg_trigger t
  join pg_class c on c.oid = t.tgrelid
  join pg_namespace n on n.oid = c.relnamespace
  join pg_proc p on p.oid = t.tgfoid
  where n.nspname = 'public' and c.relname = 'integration_settings'
    and p.proname = 'tf_automation_arm_guard'
    and not t.tgisinternal
    and t.tgenabled = 'O';
  v_ok := (v_n = 1);
  r := r || jsonb_build_object('id','A13','name','arm guard trigger is attached and enabled',
        'ok',v_ok,'severity','critical','observed',v_n,
        'prevents','arming a customer-reaching sweep by direct table write, with no measured blast radius, no cutover stamp and no arm-log entry');
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;

  -- A14. EVERY ARMED AUTOMATION CARRIES ITS PAPERWORK.
  select count(*) into v_n
  from public.integration_settings s
  cross join lateral jsonb_each(coalesce(s.config->'automations','{}'::jsonb)) e
  join public.tf_automation_registry a on a.automation_key = e.key
  where s.company_id = p_company_id
    and s.provider = 'openphone'::integration_provider
    and e.value = 'true'::jsonb
    and (
      (a.cutover_path is not null and nullif(s.config #>> a.cutover_path, '') is null)
      or not exists (select 1 from public.automation_arm_log l
                     where l.company_id = s.company_id
                       and l.automation_key = e.key
                       and l.action = 'arm')
    );
  v_ok := (v_n = 0);
  r := r || jsonb_build_object('id','A14','name','armed automations have a cutover and an arm-log row',
        'ok',v_ok,'severity','critical','observed',v_n,
        'prevents','a first tick that flushes the entire historical backlog at real customers because the flag was switched on without its cutover');
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;

  -- A15. THE authenticated SECURITY DEFINER SURFACE MAY ONLY SHRINK.
  select count(*) into v_n from (
    select p.proname
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f' and p.prosecdef
       and has_function_privilege('authenticated', p.oid, 'EXECUTE')
    except
    select a.proname from public.tf_authenticated_definer_allowlist a
  ) x;

  select count(*) into v_n2 from (
    select a.proname from public.tf_authenticated_definer_allowlist a
    except
    select p.proname
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f' and p.prosecdef
       and has_function_privilege('authenticated', p.oid, 'EXECUTE')
  ) x;

  select coalesce(string_agg(y.proname, ', ' order by y.proname), '') into v_txt from (
    select p.proname
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.prokind = 'f' and p.prosecdef
       and has_function_privilege('authenticated', p.oid, 'EXECUTE')
    except
    select a.proname from public.tf_authenticated_definer_allowlist a
  ) y;

  v_ok := (v_n = 0 and v_n2 = 0);
  r := r || jsonb_build_object('id','A15','name','authenticated definer surface matches the reviewed allowlist',
        'ok',v_ok,'severity','critical','observed',v_n,'stale_allowlist_rows',v_n2,
        'unreviewed',nullif(v_txt,''),
        'prevents','a new SECURITY DEFINER function becoming reachable from a browser session because Supabase grants EXECUTE to authenticated by default and nobody reviewed it');
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;

  -- A16. THE BILLING GATE FAILS CLOSED, AND CUSTOMER DOCUMENTS CARRY OUR HOST.
  -- Added in m327. Two facts that were both wrong until m326 and that revert
  -- silently. The gate had two writers and read the permissive one, so it
  -- answered yes to taking rent payments on an integration recorded disabled.
  -- The document renderer hardcoded a goqtf.lovable.app portal address into
  -- every owner statement and lease agreement, which a property owner reading
  -- about their own money is entitled to treat as fraud.
  select s.is_enabled, coalesce((s.config->>'rent_payments_enabled')::boolean,false)
    into v_ie, v_cfg
    from public.integration_settings s
   where s.company_id = p_company_id and s.provider = 'stripe'::integration_provider
   limit 1;
  v_gate := public.tf_rent_payments_enabled();

  select coalesce(string_agg(p.proname, ', ' order by p.proname), '') into v_txt
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f'
     and public.tf_sql_code_only(pg_get_functiondef(p.oid)) ilike '%lovable.app%';

  v_ok := (v_gate is not null
           and v_gate = (coalesce(v_ie,false) and coalesce(v_cfg,false))
           and v_txt = '');
  r := r || jsonb_build_object('id','A16','name','billing gate fails closed and documents carry the canonical host',
        'ok',v_ok,'severity','critical',
        'observed', jsonb_build_object('gate',v_gate,'is_enabled',v_ie,'feature_flag',v_cfg,
                                       'foreign_host_functions',nullif(v_txt,'')),
        'method','gate evaluated live; host check lexed so a comment cannot trip it',
        'prevents','taking rent payments on an integration recorded as disabled, and printing a foreign portal address into an owner statement');
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;

  -- A17. A FABRICATED SCHEDULE IS ABSENT, AND STRUCTURALLY IMPOSSIBLE.
  -- Added in m330. public.hcp_sync_incremental substituted now() for a missing
  -- Housecall Pro schedule and wrote that clock reading into scheduled_start,
  -- so 32 jobs carried an appointment no customer had ever agreed to. Two of
  -- them asserted a time Housecall Pro does not hold at all. Four were
  -- completed days BEFORE the slot they claimed. The newest was minted by a
  -- cron tick at 17:00:00.170999, which is not a time a dispatcher books. A
  -- board built on those rows sends a technician to a house at a time nobody
  -- chose. m328 fixed the writer, m329 nulled the rows and added the
  -- constraints. This assertion is what stops it coming back: it fails if a
  -- fabricated row reappears, and it fails if the constraints that forbid one
  -- are dropped or quietly re-added NOT VALID.
  select count(*) into v_n
    from public.jobs j
   where j.company_id = p_company_id
     and j.deleted_at is null
     and j.scheduled_start = j.created_at
     and j.scheduled_end is null;

  select count(*), coalesce(string_agg(c.conname, ', ' order by c.conname), '')
    into v_n2, v_txt
    from pg_constraint c
   where c.conrelid = 'public.jobs'::regclass
     and c.contype = 'c'
     and c.convalidated
     and c.conname in ('jobs_scheduled_start_minute_boundary',
                       'jobs_scheduled_end_minute_boundary',
                       'jobs_schedule_is_a_window',
                       'jobs_scheduled_status_requires_start');

  v_ok := (v_n = 0 and v_n2 = 4);
  r := r || jsonb_build_object('id','A17',
        'name','no fabricated schedule, and the constraints forbidding one are validated',
        'ok',v_ok,'severity','critical',
        'observed', jsonb_build_object(
            'fabricated_rows', v_n,
            'validated_constraints', v_n2,
            'expected_constraints', 4,
            'validated', nullif(v_txt,''),
            'clock_trigger_enabled', exists (select 1 from pg_trigger t
                                              where t.tgrelid = 'public.jobs'::regclass
                                                and t.tgname = 'jobs_reject_clock_schedule'
                                                and not t.tgisinternal
                                                and t.tgenabled = 'O')),
        'prevents','a now() default standing in for a missing upstream schedule, putting a fabricated appointment on the dispatch board and sending a technician to the wrong address at a time the customer never agreed to');
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;

  -- A18. AN EMERGENCY-FLAGGED ANSWERING SERVICE INTAKE REACHES A HUMAN.
  -- Added in m337. Between 2026-07-18 and 2026-08-16 the answering service
  -- relayed eight call intakes over the SMS line. Seven carried
  -- 'Emergency Y or N: Yes'. quo-webhook paged all of them as 'tech_update',
  -- which m331 routes to audience 'suppressed' and which resolves to severity
  -- 'low', whose only channel is in_app. Two independent gates agreed a flooded
  -- basement was nobody's problem, and none of the seven reached Slack.
  --
  -- This assertion walks the whole path with a synthetic payload, in the same
  -- order production does: classify, look up the audience, look up the severity
  -- tier's channels, then render. It writes nothing. It fails if ANY link is
  -- broken, including the render silently falling back to the ban-list generic,
  -- which would technically deliver while telling nobody anything useful.
  v_probe := 'Caller ID: 5555550142, DNIS: 5555550142, Company Name: Transit and Flow, '
          || 'Greeting: Plumbing Service, Emergency Y or N: Yes - Emergency, '
          || 'First Name: Regression, Last Name: Probe, Main Phone: 6145550142, '
          || 'Street Address: 1 Assertion Way, City: Columbus, State: OH, Zip Code: 43215, '
          || 'Nature of Emergency: Water is coming through the ceiling., Call Outcome: Emergency Inquiry';
  v_key := public.tf_inbound_sms_classify(v_probe);

  select count(*) into v_n
    from public.tf_notification_routing rt
   where rt.event_key = v_key
     and rt.audience <> 'suppressed'
     and rt.slack_channel_id is not null
     and rt.action_required = 'act';

  select count(*) into v_n2
    from public.tf_page_routes pr
   where pr.company_id = p_company_id
     and pr.is_active
     and pr.severity = public.tf_notification_severity_for(v_key)
     and 'slack' = any(pr.channel_priority);

  v_render := public.tf_notification_render(v_key, 'Answering service intake', v_probe,
                public.tf_notification_severity_for(v_key), null, null, null);

  v_ok := (v_n = 1 and v_n2 = 1
           and position('Dispatch now'   in v_render) > 0
           and position('6145550142'     in v_render) > 0
           and position('Assertion Way'  in v_render) > 0
           and position('needs a look'   in v_render) = 0
           and position('Caller ID'      in v_render) = 0
           and position('Greeting'       in v_render) = 0);

  r := r || jsonb_build_object('id','A18',
        'name','an emergency-flagged answering service intake reaches a human',
        'ok',v_ok,'severity','critical',
        'observed', jsonb_build_object(
            'classified_as', v_key,
            'routed_and_actionable', v_n,
            'severity_tier', public.tf_notification_severity_for(v_key),
            'tier_carries_slack', v_n2,
            'render_is_actionable', position('Dispatch now' in v_render) > 0,
            'render_carries_callback_number', position('6145550142' in v_render) > 0,
            'render_leaks_provider_preamble',
              position('Caller ID' in v_render) > 0 or position('Greeting' in v_render) > 0),
        'method','end to end over the real routing, severity and render path with a synthetic payload; writes nothing',
        'prevents','a flooded basement being filed under a technician status update, suppressed at two independent gates, and reaching nobody');
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;

  -- A19. EVERY EVENT KEY THAT HAS ACTUALLY FIRED HAS A ROUTING DECISION.
  -- Added in m337. tf_notification_drain deliberately fails an unrouted key
  -- LOUD, to #information-technology, so an omission is not silent. That is a
  -- safety net, not a decision. This assertion is the difference between a key
  -- whose destination somebody chose and a key whose destination the fallback
  -- happened to get right.
  select count(*), coalesce(string_agg(x.event_key, ', ' order by x.event_key), '')
    into v_n, v_txt
    from (select distinct nt.event_key
            from public.notifications nt
           where nt.company_id = p_company_id
          except
          select rt.event_key from public.tf_notification_routing rt) x;
  v_ok := (v_n = 0);
  r := r || jsonb_build_object('id','A19',
        'name','every event key that has fired has a routing decision',
        'ok',v_ok,'severity','high','observed',v_n,'detail',nullif(v_txt,''),
        'prevents','a new event key shipping with no routing decision and landing wherever the fallback puts it');
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;

  -- A20. WE NEVER ASK A CUSTOMER TO DO OUR FILING, AND AN UNFILED PHOTO PAGES US.
  -- Added in m339. A customer who texts photos of their problem used to get:
  --   "got your file but couldn't file it to a job yet. Reply with the job
  --    number and we'll take care of it."
  -- Three faults, and the third is the one that cost something. It asked a
  -- person holding a phone over a leak for an internal identifier they were
  -- never given. It fired even when the job WAS known and only our own insert
  -- had failed, so replying could not have helped. And quo-webhook only paged
  -- staff when (unfiled > 0 && jobId), while the common unfiled case is exactly
  -- the one where jobId is NULL, so nobody was ever told.
  --
  -- Measured before the fix: 43 such messages to 31 distinct customers between
  -- 2026-07-18 and 2026-08-16, and 87 of 137 stored files sitting in the
  -- unfiled prefix with no job_attachments row pointing at them. Ten of those
  -- customers never replied at all.
  --
  -- Two halves, both required. The destination has to exist and be actionable,
  -- and the words must not come back.
  select count(*) into v_n
    from public.tf_notification_routing rt
   where rt.event_key = 'job_photo_not_filed'
     and rt.audience <> 'suppressed'
     and rt.slack_channel_id is not null
     and rt.action_required = 'act';

  v_render := public.tf_notification_render('job_photo_not_filed',
                '2 texted photos from a customer are not on a job',
                'They uploaded to storage but no job could be matched to the sender.',
                public.tf_notification_severity_for('job_photo_not_filed'), null, null, null);

  -- The copy check is anchored to the quo-webhook v23 cutover rather than to a
  -- rolling window, because the 43 historical messages are recorded history and
  -- cannot be unsent. Anything AFTER the boundary means the wording returned.
  select count(*) into v_n2
    from public.communications c
   where c.company_id = p_company_id
     and c.direction = 'outbound'
     and c.created_at > '2026-08-16 15:00:00+00'::timestamptz
     and c.body ~* 'reply with the job number';

  v_ok := (v_n = 1 and v_n2 = 0
           and position('needs a look' in v_render) = 0
           and position('needs a person today' in v_render) > 0);

  r := r || jsonb_build_object('id','A20',
        'name','no customer is asked to file their own photo, and an unfiled photo pages a person',
        'ok',v_ok,'severity','high',
        'observed', jsonb_build_object(
            'routed_and_actionable', v_n,
            'asked_for_a_job_number_since_cutover', v_n2,
            'render_is_actionable', position('needs a person today' in v_render) > 0),
        'method','routing and render evaluated live; the copy check reads real outbound message bodies after the v23 cutover',
        'prevents','handing our own record keeping to a customer standing over a leak, and letting their photos sit in storage with nobody told');
  if v_ok then v_passed:=v_passed+1; else v_failed:=v_failed+1; end if;

  return jsonb_build_object(
    'ok', (v_failed = 0),
    'company_id', p_company_id,
    'generated_at', now(),
    'passed', v_passed,
    'failed', v_failed,
    'total', v_passed + v_failed,
    'critical_failures', (select count(*) from jsonb_array_elements(r) e
                          where (e->>'ok')::boolean is false and e->>'severity' = 'critical'),
    'assertions', r,
    'note', 'Read-only. Assertions marked method=structural inspect function source rather than '
            || 'executing the behaviour, because executing it would write rows. That is a weaker '
            || 'test and is labelled as one.');
end;
$function$;
