-- ============================================================================
-- TalentFlow OS - QA automation suite (re-runnable against production).
-- Executes read-only assertions plus rolled-back negative-enforcement probes.
-- Every row returns result = PASS/FAIL. Run in the Supabase SQL editor or via
-- psql against the project. No writes are committed (the negative probes run
-- inside a guarded block and never pass their permission checks).
--
-- Sections:
--   1. Positive battery: security/RLS, tenant isolation, governance, data
--      integrity, analytics consistency (14 checks).
--   2. Negative enforcement: an authenticated user lacking the recruiting
--      permissions is refused by every write RPC (4 checks).
--
-- Companion repository checks (run separately, in CI):
--   python3 scripts/verify_migration_manifest.py        (fidelity gate, A-F)
--   python3 scripts/test_verify_migration_manifest.py   (refusal proof, 10)
-- ============================================================================

-- ---------- Section 1: positive battery ----------
with tf_tables as (
  select c.oid, c.relname, c.relrowsecurity as rls,
         (select count(*) from pg_policy p where p.polrelid=c.oid) as pols
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relkind='r'
    and (c.relname like 'talentflow\_%' or c.relname in ('tf_plans','tf_subscriptions','tf_entitlement_overrides','tf_usage_counters'))
),
ff as (select 'ff000000-0000-4000-b000-000000000001'::uuid c),
dd as (select 'dd000000-0000-4000-a000-000000000001'::uuid c),
an as (select public.talentflow_recruiting_analytics((select c from ff)) a)
select * from (
  select 1 seq, 'Security/RLS' cat, 'All TalentFlow tables have RLS enabled' t,
    case when (select count(*) from tf_tables where not rls)=0 then 'PASS' else 'FAIL' end r
  union all select 2,'Security/RLS','Every TalentFlow table has >=1 RLS policy',
    case when (select count(*) from tf_tables where pols=0)=0 then 'PASS' else 'FAIL' end
  union all select 3,'Security/RLS','anon has NO select on candidate PII',
    case when has_table_privilege('anon','public.talentflow_candidates','SELECT')=false then 'PASS' else 'FAIL' end
  union all select 4,'Isolation','Entitlement TRUE for subscribed tenant',
    case when public.tf_company_has_entitlement((select c from ff),'tf.recruit') then 'PASS' else 'FAIL' end
  union all select 5,'Isolation','Entitlement FALSE for unsubscribed tenant',
    case when public.tf_company_has_entitlement((select c from dd),'tf.recruit')=false then 'PASS' else 'FAIL' end
  union all select 6,'Isolation','No cross-company rows (app/candidate/job share company_id)',
    case when (select count(*) from public.talentflow_applications a
                join public.talentflow_candidates c on c.id=a.candidate_id
                join public.talentflow_jobs j on j.id=a.job_id
               where a.company_id<>c.company_id or a.company_id<>j.company_id)=0 then 'PASS' else 'FAIL' end
  union all select 7,'Governance','Entitlement resolver registered read + grant tier staff',
    case when (select declared_kind from public.tf_function_registry where proname='tf_company_has_entitlement')='read'
          and (select tier from public.tf_function_grant_tiers where proname='tf_company_has_entitlement')='staff'
         then 'PASS' else 'FAIL' end
  union all select 8,'Governance','No pending declaration or signal-wiring residue',
    case when (select count(*) from public.tf_declaration_pending)=0
          and (select count(*) from public.tf_signal_wiring_pending)=0 then 'PASS' else 'FAIL' end
  union all select 9,'Integrity','Application uniqueness (company,candidate,job) holds',
    case when (select count(*) from public.talentflow_applications)
             =(select count(distinct (company_id,candidate_id,job_id)) from public.talentflow_applications)
         then 'PASS' else 'FAIL' end
  union all select 10,'Integrity','Converted hires link back to their application',
    case when (select count(*) from public.talentflow_employees where source_application_id is not null
                and source_application_id not in (select id from public.talentflow_applications))=0 then 'PASS' else 'FAIL' end
  union all select 11,'Integrity','Active employees have zero incomplete onboarding tasks',
    case when (select count(*) from public.talentflow_employees e where e.status='active'
                and exists (select 1 from public.talentflow_onboarding_tasks tk
                             where tk.employee_id=e.id and tk.status<>'complete'))=0 then 'PASS' else 'FAIL' end
  union all select 12,'Analytics','Analytics KPI candidates matches table count',
    case when ((select a from an)->'kpis'->>'candidates')::int
             =(select count(*) from public.talentflow_candidates where company_id=(select c from ff))
         then 'PASS' else 'FAIL' end
  union all select 13,'Analytics','Analytics KPI hires matches hired count',
    case when ((select a from an)->'kpis'->>'hires')::int
             =(select count(*) from public.talentflow_applications where company_id=(select c from ff) and status='hired')
         then 'PASS' else 'FAIL' end
  union all select 14,'Integrity','No soft-deleted candidate rows leaking',
    case when (select count(*) from public.talentflow_candidates where deleted_at is not null)=0 then 'PASS' else 'FAIL' end
) q order by seq;

-- ---------- Section 2: negative enforcement (rolled back, no writes) ----------
-- Simulates the owner (who lacks the recruiting permissions) and asserts every
-- write RPC refuses with the required-permission name.
do $g$
declare
  v_co uuid := 'ff000000-0000-4000-b000-000000000001';
  v_uid uuid; v_hire uuid; v_screen uuid; v_app_int uuid; v_app_applied uuid; r jsonb; fails int := 0;
begin
  select id into v_uid from public.profiles where email='micheal.parker@goqtf.com';
  select id into v_hire   from public.talentflow_stages where company_id=v_co and key='hired' limit 1;
  select id into v_screen from public.talentflow_stages where company_id=v_co and key='screen' limit 1;
  select a.id into v_app_int from public.talentflow_applications a join public.talentflow_stages s on s.id=a.stage_id where a.company_id=v_co and s.key='interview' limit 1;
  select a.id into v_app_applied from public.talentflow_applications a join public.talentflow_stages s on s.id=a.stage_id where a.company_id=v_co and s.key='applied' limit 1;

  perform set_config('request.jwt.claims', json_build_object('sub',v_uid,'role','authenticated')::text, true);
  set local role authenticated;
    r := public.talentflow_advance_application(v_app_int, v_hire, 'qa');
    if not (r->>'error'='forbidden' and r->>'need'='decide_hire') then fails := fails+1; end if;
    r := public.talentflow_advance_application(v_app_applied, v_screen, 'qa');
    if not (r->>'error'='forbidden' and r->>'need'='manage_candidates') then fails := fails+1; end if;
    r := public.talentflow_submit_scorecard(v_app_int, 4.0, 'yes', '{}'::jsonb, 'qa');
    if not (r->>'error'='forbidden' and r->>'need'='score_candidates') then fails := fails+1; end if;
    r := public.talentflow_extend_offer(v_app_int, 25.0, 'hourly', current_date+14);
    if not (r->>'error'='forbidden') then fails := fails+1; end if;
  reset role;

  if fails = 0 then
    raise notice 'NEGATIVE ENFORCEMENT: 4/4 PASS - every write RPC refused the unpermitted user';
  else
    raise exception 'NEGATIVE ENFORCEMENT: % of 4 checks FAILED', fails;
  end if;
end $g$;