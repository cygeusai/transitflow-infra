-- ============================================================================
-- Data dictionary at the source: table and column comments so the schema is
-- self-documenting (Supabase Studio, generated types, and the exported data
-- dictionary all read these). Documentation only; no structural change.
-- ============================================================================

comment on table public.talentflow_pipelines is 'A named hiring pipeline (an ordered set of stages) owned by a company. is_default marks the pipeline new jobs use.';
comment on table public.talentflow_stages is 'An ordered stage within a pipeline. stage_type drives status behavior; is_terminal marks the hired and rejected endpoints.';
comment on table public.talentflow_jobs is 'A hiring requisition / job posting. status flows draft -> open -> filled/closed. Links to a pipeline and, optionally, a business unit and location.';
comment on table public.talentflow_candidates is 'A person in the ATS. A NEW employee-recruiting domain, deliberately distinct from the supply-side applicants cluster (which converts to vendor/technician/supplier).';
comment on table public.talentflow_applications is 'A candidate''s application to a job: the pipeline instance. Unique per (company_id, candidate_id, job_id). Advanced only through the enforced write RPCs.';
comment on table public.talentflow_application_activity is 'Append-only stage/status history and notes for an application. Written by the RPCs; the audit trail of the pipeline.';
comment on table public.talentflow_interviews is 'A scheduled interview tied to an application (phone_screen/technical/panel/onsite/final).';
comment on table public.talentflow_scorecards is 'A structured interview evaluation. recommendation is ADVISORY input to a human decision, never the decision itself.';
comment on table public.talentflow_offers is 'An offer extended for an application. status flows draft -> pending_approval -> approved -> sent -> accepted/declined.';
comment on table public.talentflow_employees is 'The employee HR record (TalentFlow People). source_application_id links a hire back to the exact Recruit application it came from.';
comment on table public.talentflow_onboarding_tasks is 'An onboarding checklist item for an employee (pending/in_progress/complete/blocked).';

comment on column public.talentflow_applications.ai_screen_score is 'AI Recruiting Copilot match score (0-100). Advisory only; never a decision.';
comment on column public.talentflow_applications.ai_screen_summary is 'AI Copilot explanation of the match. Surfaced to humans; not an action.';
comment on column public.talentflow_applications.decided_by is 'The human (profiles.id) who recorded the hire/reject decision via the decide_hire permission. AI never populates this.';
comment on column public.talentflow_applications.converted_employee_id is 'Set when a hired candidate is converted into a talentflow_employees row.';
comment on column public.talentflow_applications.form_data is 'Submitted application-form answers; the schema is defined by the job''s application_form.';
comment on column public.talentflow_candidates.tags is 'Free-form labels. The tag ''seed'' marks demonstration data that can be safely purged.';
comment on column public.talentflow_candidates.source is 'Where the candidate originated: careers_site, indeed, linkedin, referral, agency, direct, other.';
comment on column public.talentflow_jobs.application_form is 'JSON schema for this job''s application form (mirrors the supply-side form_schema pattern).';
comment on column public.talentflow_scorecards.recommendation is 'strong_yes/yes/no/strong_no. Advisory; the hire decision is recorded by a human holding decide_hire.';
comment on column public.talentflow_stages.stage_type is 'applied/screen/interview/assessment/offer/hired/rejected. Drives application status transitions in the write RPCs.';
comment on column public.talentflow_employees.source_application_id is 'The Recruit application this employee was hired from. The recruiting-to-HR seam that makes the two one continuous record.';
comment on column public.talentflow_employees.profile_id is 'Links to the platform user profile, enabling employee self-service via the profile_id = auth.uid() self-read policy.';