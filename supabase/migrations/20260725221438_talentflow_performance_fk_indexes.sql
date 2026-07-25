-- ============================================================================
-- Performance audit remediation (Supabase performance advisor):
--   1. Covering indexes for all TalentFlow foreign keys flagged
--      unindexed_foreign_keys - prevents slow joins and constraint checks.
--   2. RLS initplan fix: evaluate auth.uid() once per query, not per row,
--      on the employee self-read policy (auth_rls_initplan).
-- Additive and idempotent. No behavioural change; performance only.
-- ============================================================================

-- 1. Covering indexes for foreign keys
create index if not exists tf_app_activity_actor_idx      on public.talentflow_application_activity (actor_id);
create index if not exists tf_app_activity_company_idx    on public.talentflow_application_activity (company_id);
create index if not exists tf_app_activity_from_stage_idx on public.talentflow_application_activity (from_stage_id);
create index if not exists tf_app_activity_to_stage_idx   on public.talentflow_application_activity (to_stage_id);
create index if not exists tf_applications_candidate_idx  on public.talentflow_applications (candidate_id);
create index if not exists tf_applications_stage_idx      on public.talentflow_applications (stage_id);
create index if not exists tf_applications_recruiter_idx  on public.talentflow_applications (assigned_recruiter_id);
create index if not exists tf_applications_decided_by_idx on public.talentflow_applications (decided_by);
create index if not exists tf_employees_bu_idx            on public.talentflow_employees (business_unit_id);
create index if not exists tf_employees_loc_idx           on public.talentflow_employees (location_id);
create index if not exists tf_employees_manager_idx       on public.talentflow_employees (manager_id);
create index if not exists tf_employees_profile_idx       on public.talentflow_employees (profile_id);
create index if not exists tf_employees_source_app_idx    on public.talentflow_employees (source_application_id);
create index if not exists tf_interviews_company_idx      on public.talentflow_interviews (company_id);
create index if not exists tf_job_dist_job_idx            on public.talentflow_job_distributions (job_id);
create index if not exists tf_jobs_bu_idx                 on public.talentflow_jobs (business_unit_id);
create index if not exists tf_jobs_hm_idx                 on public.talentflow_jobs (hiring_manager_id);
create index if not exists tf_jobs_loc_idx                on public.talentflow_jobs (location_id);
create index if not exists tf_jobs_pipeline_idx           on public.talentflow_jobs (pipeline_id);
create index if not exists tf_jobs_recruiter_idx          on public.talentflow_jobs (recruiter_id);
create index if not exists tf_offers_approved_by_idx      on public.talentflow_offers (approved_by);
create index if not exists tf_offers_company_idx          on public.talentflow_offers (company_id);
create index if not exists tf_offers_template_idx         on public.talentflow_offers (template_id);
create index if not exists tf_onboarding_assignee_idx     on public.talentflow_onboarding_tasks (assignee_id);
create index if not exists tf_onboarding_company_idx      on public.talentflow_onboarding_tasks (company_id);
create index if not exists tf_pipelines_company_idx       on public.talentflow_pipelines (company_id);
create index if not exists tf_scorecards_company_idx      on public.talentflow_scorecards (company_id);
create index if not exists tf_scorecards_interviewer_idx  on public.talentflow_scorecards (interviewer_id);
create index if not exists tf_stages_company_idx          on public.talentflow_stages (company_id);
create index if not exists tf_subscriptions_plan_idx      on public.tf_subscriptions (plan_id);

-- 2. RLS initplan optimization on the employee self-read policy
drop policy if exists talentflow_employees_self on public.talentflow_employees;
create policy talentflow_employees_self on public.talentflow_employees
  for select to authenticated using (profile_id = (select auth.uid()));