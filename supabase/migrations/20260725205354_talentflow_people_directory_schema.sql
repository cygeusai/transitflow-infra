-- ============================================================================
-- TalentFlow People: the employee directory and HR records (workforce anchor).
-- The seam where a hired candidate becomes an employee (source_application_id).
-- Tenant-isolated on company_id; internal staff manage, employees self-read.
-- ============================================================================

do $$ begin create type tf_employee_status as enum ('onboarding','active','on_leave','terminated'); exception when duplicate_object then null; end $$;
do $$ begin create type tf_onboarding_status as enum ('pending','in_progress','complete','blocked'); exception when duplicate_object then null; end $$;

create table if not exists public.talentflow_employees (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  profile_id uuid references public.profiles(id),
  first_name text not null,
  last_name text not null,
  email text,
  phone text,
  title text,
  department text,
  business_unit_id uuid references public.business_units(id),
  location_id uuid references public.locations(id),
  employment_type tf_employment_type not null default 'full_time',
  status tf_employee_status not null default 'onboarding',
  hire_date date,
  manager_id uuid references public.talentflow_employees(id),
  comp_amount numeric(12,2),
  comp_unit text default 'hourly',
  source_application_id uuid references public.talentflow_applications(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid, updated_by uuid, deleted_at timestamptz
);
create index if not exists tf_employees_company_status_idx on public.talentflow_employees (company_id, status);

create table if not exists public.talentflow_onboarding_tasks (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  employee_id uuid not null references public.talentflow_employees(id),
  title text not null,
  category text,
  status tf_onboarding_status not null default 'pending',
  due_date date,
  assignee_id uuid references public.profiles(id),
  sort_order integer not null default 0,
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists tf_onboarding_employee_idx on public.talentflow_onboarding_tasks (employee_id, sort_order);

-- RLS
alter table public.talentflow_employees enable row level security;
alter table public.talentflow_onboarding_tasks enable row level security;

create policy talentflow_employees_read on public.talentflow_employees
  for select to authenticated using (public.is_company_member(company_id));
create policy talentflow_employees_self on public.talentflow_employees
  for select to authenticated using (profile_id = auth.uid());
create policy talentflow_employees_write on public.talentflow_employees
  for all to authenticated using (public.user_is_internal_staff(company_id)) with check (public.user_is_internal_staff(company_id));

create policy talentflow_onboarding_read on public.talentflow_onboarding_tasks
  for select to authenticated using (public.is_company_member(company_id));
create policy talentflow_onboarding_write on public.talentflow_onboarding_tasks
  for all to authenticated using (public.user_is_internal_staff(company_id)) with check (public.user_is_internal_staff(company_id));

revoke all on public.talentflow_employees, public.talentflow_onboarding_tasks from anon;
grant select, insert, update, delete on public.talentflow_employees, public.talentflow_onboarding_tasks to authenticated;
grant all on public.talentflow_employees, public.talentflow_onboarding_tasks to service_role;