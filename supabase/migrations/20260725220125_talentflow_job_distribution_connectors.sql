-- ============================================================================
-- TalentFlow Job Distribution (tf.jobdist): the connector framework.
-- Represents each job board HONESTLY. A board is never shown active until valid
-- credentials / partner approval exist. Indeed is partner_approval_required and
-- is NOT connected. Careers site + Google for Jobs are genuinely available
-- because we already emit the careers page and Schema.org JobPosting.
-- ============================================================================

do $$ begin
  create type tf_connector_status as enum
    ('available','configuration_required','credentials_required',
     'partner_approval_required','in_development','restricted','unsupported');
exception when duplicate_object then null; end $$;

-- Global catalog of job-board connectors (no company_id; the boards are the same
-- for every tenant, per-tenant credentials live in integration settings later).
create table if not exists public.talentflow_job_board_connectors (
  id                        uuid primary key default gen_random_uuid(),
  key                       text not null unique,
  name                      text not null,
  category                  text,
  status                    tf_connector_status not null default 'credentials_required',
  auth_type                 text,
  requires_partner_approval boolean not null default false,
  notes                     text,
  docs_url                  text,
  sort_order                integer not null default 0,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now()
);
comment on table public.talentflow_job_board_connectors is
  'Catalog of job-board connectors with honest integration status. A board is never represented as active without valid credentials or partner approval.';

-- Per-company record of where a job has been distributed.
create table if not exists public.talentflow_job_distributions (
  id            uuid primary key default gen_random_uuid(),
  company_id    uuid not null references public.companies(id),
  job_id        uuid not null references public.talentflow_jobs(id),
  connector_key text not null,
  status        text not null default 'draft',
  external_ref  text,
  posted_at     timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  created_by    uuid,
  unique (company_id, job_id, connector_key)
);
comment on table public.talentflow_job_distributions is
  'Where a company has distributed a job. Empty until a connector is genuinely connected.';
create index if not exists tf_job_dist_company_idx on public.talentflow_job_distributions (company_id, job_id);

-- RLS
alter table public.talentflow_job_board_connectors enable row level security;
alter table public.talentflow_job_distributions enable row level security;

create policy tf_connectors_read on public.talentflow_job_board_connectors
  for select to authenticated using (true);
create policy tf_job_dist_read on public.talentflow_job_distributions
  for select to authenticated using (public.is_company_member(company_id));
create policy tf_job_dist_write on public.talentflow_job_distributions
  for all to authenticated using (public.user_is_internal_staff(company_id)) with check (public.user_is_internal_staff(company_id));

revoke all on public.talentflow_job_board_connectors, public.talentflow_job_distributions from anon;
grant select on public.talentflow_job_board_connectors to authenticated;
grant select, insert, update, delete on public.talentflow_job_distributions to authenticated;
grant all on public.talentflow_job_board_connectors, public.talentflow_job_distributions to service_role;

-- Seed the connector catalog with HONEST statuses.
insert into public.talentflow_job_board_connectors (key, name, category, status, auth_type, requires_partner_approval, notes, sort_order) values
  ('careers_site','Transit & Flow Careers','Owned','available','none', false,
    'Live. Jobs with status open and a published date appear automatically on the careers site.', 10),
  ('google_jobs','Google for Jobs','Search engine','available','feed', false,
    'Enabled via Schema.org JobPosting markup emitted on the careers site. No account required.', 20),
  ('indeed','Indeed','Aggregator','partner_approval_required','partner_api', true,
    'NOT CONNECTED. Indeed job sync / sponsored jobs require an Indeed employer account, API credentials, and Indeed partner approval before any posting can occur.', 30),
  ('linkedin','LinkedIn Jobs','Professional network','credentials_required','oauth', false,
    'NOT CONNECTED. Requires LinkedIn Talent Solutions job-posting API credentials.', 40),
  ('ziprecruiter','ZipRecruiter','Aggregator','credentials_required','api_key', false,
    'NOT CONNECTED. Requires a ZipRecruiter partner API key.', 50),
  ('glassdoor','Glassdoor','Aggregator','credentials_required','partner_api', true,
    'NOT CONNECTED. Distributed through the Indeed network; depends on an Indeed connection.', 60),
  ('monster','Monster','Aggregator','credentials_required','api_key', false,
    'NOT CONNECTED. Requires a Monster employer API key.', 70),
  ('facebook_jobs','Facebook Jobs','Social','unsupported','none', false,
    'Unsupported. Meta discontinued the Jobs product.', 80)
on conflict (key) do nothing;