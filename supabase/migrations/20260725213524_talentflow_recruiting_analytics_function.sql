-- ============================================================================
-- TalentFlow Insights: one read-only RPC that returns the full recruiting +
-- workforce analytics payload for a company. SECURITY INVOKER so RLS scopes
-- every underlying read to the caller's company; the optional p_company_id
-- filters deterministically for the active-company context. Server-side
-- aggregation keeps the frontend thin (data-engineering discipline).
-- ============================================================================

create or replace function public.talentflow_recruiting_analytics(p_company_id uuid default null)
returns jsonb
language plpgsql
stable
security invoker
set search_path to 'public', 'pg_catalog'
as $fn$
declare
  v_pipe uuid;
  v_result jsonb;
begin
  select p.id into v_pipe
    from public.talentflow_pipelines p
   where (p_company_id is null or p.company_id = p_company_id)
     and p.is_default
   order by p.created_at
   limit 1;

  select jsonb_build_object(
    'kpis', jsonb_build_object(
      'open_jobs',       (select count(*) from public.talentflow_jobs j
                            where (p_company_id is null or j.company_id = p_company_id) and j.status = 'open'),
      'candidates',      (select count(*) from public.talentflow_candidates c
                            where (p_company_id is null or c.company_id = p_company_id)),
      'offers_out',      (select count(*) from public.talentflow_offers o
                            where (p_company_id is null or o.company_id = p_company_id) and o.status = 'sent'),
      'hires',           (select count(*) from public.talentflow_applications a
                            where (p_company_id is null or a.company_id = p_company_id) and a.status = 'hired'),
      'employees',       (select count(*) from public.talentflow_employees e
                            where (p_company_id is null or e.company_id = p_company_id)),
      'active_employees',(select count(*) from public.talentflow_employees e
                            where (p_company_id is null or e.company_id = p_company_id) and e.status = 'active'),
      'time_to_hire_days',(select round(avg(extract(epoch from (coalesce(a.decided_at, now()) - a.applied_at))/86400))
                            from public.talentflow_applications a
                           where (p_company_id is null or a.company_id = p_company_id) and a.status = 'hired'),
      'offers_accepted', (select count(*) from public.talentflow_offers o
                            where (p_company_id is null or o.company_id = p_company_id) and o.status = 'accepted')
    ),
    'funnel', coalesce((
      select jsonb_agg(jsonb_build_object('stage', s.name, 'n', (
                 select count(*) from public.talentflow_applications a where a.stage_id = s.id))
             order by s.sort_order)
        from public.talentflow_stages s
       where s.pipeline_id = v_pipe and s.stage_type <> 'rejected'), '[]'::jsonb),
    'by_source', coalesce((
      select jsonb_agg(x order by (x->>'candidates')::int desc) from (
        select jsonb_build_object('source', c.source::text, 'candidates', count(*),
                                  'avg_rating', round(avg(c.rating), 2)) as x
          from public.talentflow_candidates c
         where (p_company_id is null or c.company_id = p_company_id)
         group by c.source) t), '[]'::jsonb),
    'jobs', coalesce((
      select jsonb_agg(x order by (x->>'apps')::int desc) from (
        select jsonb_build_object('title', j.title, 'apps', count(a.id),
                                  'hired', count(a.id) filter (where a.status = 'hired')) as x
          from public.talentflow_jobs j
          left join public.talentflow_applications a on a.job_id = j.id
         where (p_company_id is null or j.company_id = p_company_id)
         group by j.title) t), '[]'::jsonb),
    'headcount_by_dept', coalesce((
      select jsonb_agg(x order by (x->>'n')::int desc) from (
        select jsonb_build_object('dept', coalesce(e.department, 'Unassigned'), 'n', count(*)) as x
          from public.talentflow_employees e
         where (p_company_id is null or e.company_id = p_company_id) and e.status in ('active','onboarding')
         group by e.department) t), '[]'::jsonb)
  ) into v_result;

  return v_result;
end $fn$;

comment on function public.talentflow_recruiting_analytics(uuid) is
  'TalentFlow Insights: full recruiting + workforce analytics payload (KPIs, funnel, source effectiveness, jobs, headcount) for a company. SECURITY INVOKER; RLS scopes reads to the caller.';

revoke all on function public.talentflow_recruiting_analytics(uuid) from public, anon;
grant execute on function public.talentflow_recruiting_analytics(uuid) to authenticated, service_role;