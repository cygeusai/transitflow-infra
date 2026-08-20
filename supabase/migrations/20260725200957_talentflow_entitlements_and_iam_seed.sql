-- ============================================================================
-- TalentFlow OS - Phase 1 foundation migration
-- Transit Entitlements service (company-keyed generalization of the Studio
-- entitlement pattern) + TalentFlow IAM seeds (roles, permissions, grants).
-- No new tf_* functions are created here, so the declaration/signal-wiring
-- enforcement triggers have nothing to enforce. Smallest stable increment.
-- Deliverable 10 (schema). Grounded in deliverables 6-9.
-- ============================================================================

-- ---------- Transit Entitlements: plan catalog (global, no company_id) ----------
create table if not exists public.tf_plans (
  id                    uuid primary key default gen_random_uuid(),
  code                  text not null unique,
  name                  text not null,
  tagline               text,
  audience              text,
  price_one_time_cents  integer,
  price_monthly_cents   integer,
  price_annual_cents    integer,
  features              jsonb not null default '[]'::jsonb,
  entitlements          jsonb not null default '{}'::jsonb,
  is_active             boolean not null default true,
  is_public             boolean not null default false,
  sort_order            integer not null default 0,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);
comment on table public.tf_plans is
  'Transit Entitlements plan catalog. entitlements jsonb maps module keys (tf.recruit, tf.people, ...) to grants. Generalized from studio_plans.';

-- ---------- Company subscriptions (company-keyed) ----------
create table if not exists public.tf_subscriptions (
  id                        uuid primary key default gen_random_uuid(),
  company_id                uuid not null references public.companies(id),
  plan_id                   uuid not null references public.tf_plans(id),
  status                    text not null default 'active',
  billing_interval          text,
  started_at                timestamptz not null default now(),
  current_period_end        timestamptz,
  canceled_at               timestamptz,
  seats                     integer,
  payment_provider          text,
  provider_customer_ref     text,
  provider_subscription_ref text,
  granted_by                uuid,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),
  unique (company_id, plan_id)
);
comment on table public.tf_subscriptions is
  'A company holds a plan. Keyed to company_id (Studio keyed to user_id; TalentFlow is B2B). Enforced server-side, never in the frontend alone.';
create index if not exists tf_subscriptions_company_idx on public.tf_subscriptions (company_id);

-- ---------- Per-company entitlement overrides (company-keyed) ----------
create table if not exists public.tf_entitlement_overrides (
  id              uuid primary key default gen_random_uuid(),
  company_id      uuid not null references public.companies(id),
  entitlement_key text not null,
  value           jsonb not null default 'true'::jsonb,
  reason          text,
  expires_at      timestamptz,
  granted_by      uuid,
  created_at      timestamptz not null default now()
);
comment on table public.tf_entitlement_overrides is
  'Time-boxed, audited per-company entitlement grants. Mirrors studio_entitlement_overrides, re-keyed to company_id.';
create index if not exists tf_ent_overrides_company_idx on public.tf_entitlement_overrides (company_id);

-- ---------- Metered usage counters (company-keyed, optional user) ----------
create table if not exists public.tf_usage_counters (
  id           uuid primary key default gen_random_uuid(),
  company_id   uuid not null references public.companies(id),
  user_id      uuid,
  metric       text not null,
  period_start date not null,
  count        bigint not null default 0,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
comment on table public.tf_usage_counters is
  'Metered usage for usage-billed modules. Mirrors studio_usage_counters, re-keyed to company_id with optional per-seat user_id.';
create unique index if not exists tf_usage_company_metric_uidx
  on public.tf_usage_counters (company_id, metric, period_start) where user_id is null;
create unique index if not exists tf_usage_company_user_metric_uidx
  on public.tf_usage_counters (company_id, user_id, metric, period_start) where user_id is not null;

-- ---------- RLS (ensure_rls also enables it; explicit for clarity) ----------
alter table public.tf_plans                enable row level security;
alter table public.tf_subscriptions        enable row level security;
alter table public.tf_entitlement_overrides enable row level security;
alter table public.tf_usage_counters       enable row level security;

-- Catalog is readable to any authenticated user (active plans only).
create policy tf_plans_read on public.tf_plans
  for select to authenticated using (is_active);

-- Subscriptions and usage are visible to members of the owning company.
create policy tf_subscriptions_read on public.tf_subscriptions
  for select to authenticated using (public.is_company_member(company_id));
create policy tf_usage_read on public.tf_usage_counters
  for select to authenticated using (public.is_company_member(company_id));

-- Overrides are sensitive: internal staff of the company only.
create policy tf_ent_overrides_read on public.tf_entitlement_overrides
  for select to authenticated using (public.user_is_internal_staff(company_id));

-- Least privilege: no anon access; writes only via service_role (RLS-bypass billing service).
revoke all on public.tf_plans, public.tf_subscriptions, public.tf_entitlement_overrides, public.tf_usage_counters from anon;
grant select on public.tf_plans, public.tf_subscriptions, public.tf_entitlement_overrides, public.tf_usage_counters to authenticated;
grant all on public.tf_plans, public.tf_subscriptions, public.tf_entitlement_overrides, public.tf_usage_counters to service_role;

-- ============================================================================
-- TalentFlow IAM seeds
-- ============================================================================

-- ---------- Roles (7 new, following is_internal/is_system convention) ----------
insert into public.roles (key, name, description, is_internal, is_system, sort_order) values
  ('tf_recruiter',       'Recruiter',        'Full TalentFlow ATS pipeline management', true,  true, 260),
  ('tf_recruiting_admin','Recruiting Admin', 'Configures jobs, forms, pipelines, and job distribution', true, true, 261),
  ('tf_hiring_manager',  'Hiring Manager',   'Reviews candidates, submits scorecards, records hiring decisions', true, true, 262),
  ('tf_interviewer',     'Interviewer',      'Time-boxed access to assigned candidates and scorecards', true, true, 263),
  ('tf_hr_manager',      'HR Manager',       'Employee records, onboarding, performance, and offers', true, true, 264),
  ('tf_employee',        'Employee',         'Self-service directory, onboarding tasks, and surveys', true, true, 265),
  ('tf_candidate',       'Candidate',        'External. Own application, status, and documents only', false, true, 266)
on conflict (key) do nothing;

-- ---------- Permissions (recruiting extends existing category; people is new) ----------
insert into public.permissions (key, name, description, category) values
  ('view_candidates',    'View Candidates',       'View candidate records in the ATS', 'recruiting'),
  ('manage_candidates',  'Manage Candidates',     'Advance, edit, and manage candidates through the pipeline', 'recruiting'),
  ('configure_recruiting','Configure Recruiting', 'Configure jobs, application forms, pipelines, and stages', 'recruiting'),
  ('score_candidates',   'Score Candidates',      'Submit interview scorecards and evaluations', 'recruiting'),
  ('decide_hire',        'Make Hiring Decision',  'Record the final human hiring decision. AI never holds this permission.', 'recruiting'),
  ('distribute_jobs',    'Distribute Jobs',       'Publish jobs to boards and the careers site', 'recruiting'),
  ('manage_job_postings','Manage Job Postings',   'Create and manage hiring requisitions and job postings', 'recruiting'),
  ('view_people',        'View People',           'View the employee directory and HR records', 'people'),
  ('manage_people',      'Manage People Records', 'Create and edit employee records', 'people'),
  ('onboard_employees',  'Onboard Employees',     'Run employee onboarding workflows', 'people'),
  ('view_own_profile',   'View Own Profile',      'Employee self-service access to their own record', 'people'),
  ('manage_performance', 'Manage Performance',    'Manage performance reviews and cycles', 'people')
on conflict (key) do nothing;

-- ---------- Role -> permission grants ----------
insert into public.role_permissions (role_id, permission_id)
select r.id, p.id
from (values
  ('tf_recruiter','view_candidates'),('tf_recruiter','manage_candidates'),('tf_recruiter','score_candidates'),
  ('tf_recruiter','distribute_jobs'),('tf_recruiter','manage_job_postings'),('tf_recruiter','view_people'),
  ('tf_recruiting_admin','view_candidates'),('tf_recruiting_admin','manage_candidates'),('tf_recruiting_admin','configure_recruiting'),
  ('tf_recruiting_admin','score_candidates'),('tf_recruiting_admin','distribute_jobs'),('tf_recruiting_admin','manage_job_postings'),
  ('tf_recruiting_admin','decide_hire'),('tf_recruiting_admin','view_people'),
  ('tf_hiring_manager','view_candidates'),('tf_hiring_manager','score_candidates'),('tf_hiring_manager','decide_hire'),
  ('tf_hiring_manager','manage_job_postings'),('tf_hiring_manager','view_people'),
  ('tf_interviewer','view_candidates'),('tf_interviewer','score_candidates'),
  ('tf_hr_manager','view_people'),('tf_hr_manager','manage_people'),('tf_hr_manager','onboard_employees'),
  ('tf_hr_manager','manage_performance'),('tf_hr_manager','view_candidates'),
  ('tf_employee','view_own_profile')
) as m(rk, pk)
join public.roles r on r.key = m.rk
join public.permissions p on p.key = m.pk
on conflict do nothing;

-- ============================================================================
-- Seed the sellable plan catalog
-- ============================================================================
insert into public.tf_plans (code, name, tagline, audience, price_monthly_cents, price_annual_cents, entitlements, is_public, sort_order) values
  ('tf_recruit_starter','Recruit Starter','Applicant tracking for one hiring team','smb', 9900, 99000,
    '{"tf.recruit": true}'::jsonb, true, 10),
  ('tf_recruit_pro','Recruit Pro','Full ATS with candidate CRM, job distribution, careers site, and AI copilot','mid', 24900, 249000,
    '{"tf.recruit": true, "tf.connect": true, "tf.jobdist": true, "tf.careers": true, "tf.copilot": true}'::jsonb, true, 20),
  ('tf_workforce','Workforce','People directory, onboarding, scheduling, performance, and surveys','mid', 19900, 199000,
    '{"tf.people": true, "tf.onboard": true, "tf.schedule": true, "tf.perform": true, "tf.surveys": true, "tf.files": true}'::jsonb, true, 30),
  ('tf_suite','TalentFlow Suite','The complete recruiting and workforce operations platform','enterprise', 39900, 399000,
    '{"tf.recruit": true, "tf.connect": true, "tf.jobdist": true, "tf.careers": true, "tf.people": true, "tf.onboard": true, "tf.perform": true, "tf.schedule": true, "tf.automate": true, "tf.insights": true, "tf.copilot": true, "tf.surveys": true, "tf.files": true, "tf.franchise": true}'::jsonb, true, 40)
on conflict (code) do nothing;

-- ============================================================================
-- Transit & Flow (the first tenant) is subscribed to the full Suite so internal
-- recruiting can begin immediately. company_id = production company.
-- ============================================================================
insert into public.tf_subscriptions (company_id, plan_id, status, billing_interval, current_period_end)
select 'ff000000-0000-4000-b000-000000000001'::uuid, p.id, 'active', 'annual', now() + interval '1 year'
from public.tf_plans p
where p.code = 'tf_suite'
on conflict (company_id, plan_id) do nothing;