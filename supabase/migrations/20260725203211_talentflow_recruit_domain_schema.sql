-- ============================================================================
-- TalentFlow OS - Deliverable 10 (schema), slice 2: the Recruit (ATS) domain.
-- New employee-recruiting domain. Distinct from the supply-side applicants
-- cluster (which converts to vendor/technician/supplier); mirrors its proven
-- patterns (configurable forms, stage history, reviewer assignment, scoring,
-- conversion). All tenant-isolated on company_id. No tf_* functions here.
-- ============================================================================

-- ---------- Enums ----------
do $$ begin create type tf_employment_type as enum ('full_time','part_time','contract','temporary','seasonal'); exception when duplicate_object then null; end $$;
do $$ begin create type tf_work_mode as enum ('onsite','hybrid','remote'); exception when duplicate_object then null; end $$;
do $$ begin create type tf_job_status as enum ('draft','open','on_hold','filled','closed','cancelled'); exception when duplicate_object then null; end $$;
do $$ begin create type tf_stage_type as enum ('applied','screen','interview','assessment','offer','hired','rejected'); exception when duplicate_object then null; end $$;
do $$ begin create type tf_candidate_source as enum ('careers_site','indeed','linkedin','referral','agency','direct','other'); exception when duplicate_object then null; end $$;
do $$ begin create type tf_application_status as enum ('active','hired','rejected','withdrawn','on_hold'); exception when duplicate_object then null; end $$;
do $$ begin create type tf_scorecard_reco as enum ('strong_yes','yes','no','strong_no'); exception when duplicate_object then null; end $$;
do $$ begin create type tf_interview_kind as enum ('phone_screen','technical','panel','onsite','final'); exception when duplicate_object then null; end $$;
do $$ begin create type tf_interview_status as enum ('scheduled','completed','canceled','no_show'); exception when duplicate_object then null; end $$;
do $$ begin create type tf_offer_status as enum ('draft','pending_approval','approved','sent','accepted','declined','rescinded','expired'); exception when duplicate_object then null; end $$;

-- ---------- Pipelines & stages ----------
create table if not exists public.talentflow_pipelines (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  name text not null,
  is_default boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid, updated_by uuid, deleted_at timestamptz
);
create table if not exists public.talentflow_stages (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  pipeline_id uuid not null references public.talentflow_pipelines(id),
  key text not null,
  name text not null,
  stage_type tf_stage_type not null,
  sort_order integer not null default 0,
  is_terminal boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (pipeline_id, key)
);
create index if not exists tf_stages_pipeline_idx on public.talentflow_stages (pipeline_id, sort_order);

-- ---------- Jobs (requisitions / postings) ----------
create table if not exists public.talentflow_jobs (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  business_unit_id uuid references public.business_units(id),
  location_id uuid references public.locations(id),
  pipeline_id uuid references public.talentflow_pipelines(id),
  title text not null,
  slug text,
  department text,
  employment_type tf_employment_type not null default 'full_time',
  work_mode tf_work_mode not null default 'onsite',
  city text, state text,
  description text,
  requirements text,
  compensation_min numeric(12,2),
  compensation_max numeric(12,2),
  compensation_unit text default 'hourly',
  openings integer not null default 1,
  status tf_job_status not null default 'draft',
  hiring_manager_id uuid references public.profiles(id),
  recruiter_id uuid references public.profiles(id),
  application_form jsonb not null default '{}'::jsonb,
  published_at timestamptz,
  closes_at timestamptz,
  external_apply_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid, updated_by uuid, deleted_at timestamptz
);
create index if not exists tf_jobs_company_status_idx on public.talentflow_jobs (company_id, status);

-- ---------- Candidates (people in the ATS) ----------
create table if not exists public.talentflow_candidates (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  first_name text not null,
  last_name text not null,
  email text,
  phone text,
  headline text,
  city text, state text,
  source tf_candidate_source not null default 'other',
  source_detail text,
  linkedin_url text,
  resume_path text,
  rating numeric(2,1),
  tags text[] not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid, updated_by uuid, deleted_at timestamptz
);
create index if not exists tf_candidates_company_idx on public.talentflow_candidates (company_id);

-- ---------- Applications (candidate -> job pipeline instance) ----------
create table if not exists public.talentflow_applications (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  candidate_id uuid not null references public.talentflow_candidates(id),
  job_id uuid not null references public.talentflow_jobs(id),
  stage_id uuid references public.talentflow_stages(id),
  status tf_application_status not null default 'active',
  source tf_candidate_source not null default 'other',
  applied_at timestamptz not null default now(),
  form_data jsonb not null default '{}'::jsonb,
  assigned_recruiter_id uuid references public.profiles(id),
  ai_screen_score numeric(4,2),
  ai_screen_summary text,
  rejection_reason text,
  decided_at timestamptz,
  decided_by uuid references public.profiles(id),
  converted_employee_id uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid, updated_by uuid, deleted_at timestamptz,
  unique (company_id, candidate_id, job_id)
);
create index if not exists tf_applications_job_stage_idx on public.talentflow_applications (job_id, stage_id);
create index if not exists tf_applications_company_status_idx on public.talentflow_applications (company_id, status);

-- ---------- Application activity (stage / status history) ----------
create table if not exists public.talentflow_application_activity (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  application_id uuid not null references public.talentflow_applications(id),
  from_stage_id uuid references public.talentflow_stages(id),
  to_stage_id uuid references public.talentflow_stages(id),
  from_status tf_application_status,
  to_status tf_application_status,
  note text,
  actor_id uuid references public.profiles(id),
  created_at timestamptz not null default now()
);
create index if not exists tf_app_activity_app_idx on public.talentflow_application_activity (application_id, created_at);

-- ---------- Interviews ----------
create table if not exists public.talentflow_interviews (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  application_id uuid not null references public.talentflow_applications(id),
  kind tf_interview_kind not null default 'phone_screen',
  scheduled_at timestamptz,
  duration_minutes integer default 45,
  location text,
  meeting_url text,
  status tf_interview_status not null default 'scheduled',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid, updated_by uuid
);
create index if not exists tf_interviews_app_idx on public.talentflow_interviews (application_id);

-- ---------- Scorecards ----------
create table if not exists public.talentflow_scorecards (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  application_id uuid not null references public.talentflow_applications(id),
  interviewer_id uuid references public.profiles(id),
  overall numeric(2,1),
  recommendation tf_scorecard_reco,
  competencies jsonb not null default '{}'::jsonb,
  notes text,
  submitted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists tf_scorecards_app_idx on public.talentflow_scorecards (application_id);

-- ---------- Offers ----------
create table if not exists public.talentflow_offers (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  application_id uuid not null references public.talentflow_applications(id),
  status tf_offer_status not null default 'draft',
  compensation_amount numeric(12,2),
  compensation_unit text default 'hourly',
  start_date date,
  expires_at timestamptz,
  template_id uuid references public.document_templates(id),
  approved_by uuid references public.profiles(id),
  sent_at timestamptz,
  responded_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid, updated_by uuid, deleted_at timestamptz
);
create index if not exists tf_offers_app_idx on public.talentflow_offers (application_id);

-- ============================================================================
-- RLS: every table isolated on company_id. Read = company member; write =
-- internal staff of the company. Built on the existing authorization functions.
-- ============================================================================
do $$
declare t text;
begin
  foreach t in array array[
    'talentflow_pipelines','talentflow_stages','talentflow_jobs','talentflow_candidates',
    'talentflow_applications','talentflow_application_activity','talentflow_interviews',
    'talentflow_scorecards','talentflow_offers'
  ] loop
    execute format('alter table public.%I enable row level security', t);
    execute format($p$create policy %I on public.%I for select to authenticated using (public.is_company_member(company_id))$p$, t||'_read', t);
    execute format($p$create policy %I on public.%I for all to authenticated using (public.user_is_internal_staff(company_id)) with check (public.user_is_internal_staff(company_id))$p$, t||'_write', t);
    execute format('revoke all on public.%I from anon', t);
    execute format('grant select, insert, update, delete on public.%I to authenticated', t);
    execute format('grant all on public.%I to service_role', t);
  end loop;
end $$;