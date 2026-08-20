-- ============================================================================
-- TalentFlow Recruit write path: server-side RPCs that enforce BOTH entitlement
-- (tf_company_has_entitlement) AND permission (user_has_permission) before any
-- mutation, then record activity. SECURITY INVOKER so RLS still gates the write.
-- The guard bypasses when auth.uid() is null (service_role / backend context),
-- matching the platform guard idiom. talentflow_ namespace: module logic, not
-- platform-control functions, so outside the tf_ registry regime by design.
-- ============================================================================

-- ---------- Advance an application to a new stage ----------
create or replace function public.talentflow_advance_application(
  p_application_id uuid, p_to_stage_id uuid, p_note text default null
) returns jsonb
language plpgsql
security invoker
set search_path to 'public', 'pg_catalog'
as $fn$
declare
  v_company uuid; v_from uuid; v_stage_type tf_stage_type;
begin
  select company_id, stage_id into v_company, v_from
    from public.talentflow_applications where id = p_application_id;
  if v_company is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;

  select stage_type into v_stage_type
    from public.talentflow_stages where id = p_to_stage_id and company_id = v_company;
  if v_stage_type is null then return jsonb_build_object('ok', false, 'error', 'invalid_stage'); end if;

  if auth.uid() is not null then
    if not public.tf_company_has_entitlement(v_company, 'tf.recruit') then
      return jsonb_build_object('ok', false, 'error', 'not_entitled', 'module', 'tf.recruit');
    end if;
    if v_stage_type = 'hired' then
      if not public.user_has_permission('decide_hire', v_company) then
        return jsonb_build_object('ok', false, 'error', 'forbidden', 'need', 'decide_hire');
      end if;
    elsif not public.user_has_permission('manage_candidates', v_company) then
      return jsonb_build_object('ok', false, 'error', 'forbidden', 'need', 'manage_candidates');
    end if;
  end if;

  update public.talentflow_applications
     set stage_id  = p_to_stage_id,
         status    = case when v_stage_type = 'hired'    then 'hired'::tf_application_status
                          when v_stage_type = 'rejected' then 'rejected'::tf_application_status
                          else status end,
         decided_at = case when v_stage_type in ('hired','rejected') then now() else decided_at end,
         decided_by = case when v_stage_type in ('hired','rejected') then auth.uid() else decided_by end,
         updated_at = now(), updated_by = auth.uid()
   where id = p_application_id;

  insert into public.talentflow_application_activity
    (company_id, application_id, from_stage_id, to_stage_id, note, actor_id)
  values (v_company, p_application_id, v_from, p_to_stage_id, coalesce(p_note, 'Advanced'), auth.uid());

  return jsonb_build_object('ok', true, 'application_id', p_application_id, 'stage_type', v_stage_type);
end $fn$;

-- ---------- Submit an interview scorecard ----------
create or replace function public.talentflow_submit_scorecard(
  p_application_id uuid, p_overall numeric, p_recommendation tf_scorecard_reco,
  p_competencies jsonb default '{}'::jsonb, p_notes text default null
) returns jsonb
language plpgsql
security invoker
set search_path to 'public', 'pg_catalog'
as $fn$
declare v_company uuid; v_id uuid;
begin
  select company_id into v_company from public.talentflow_applications where id = p_application_id;
  if v_company is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;

  if auth.uid() is not null then
    if not public.tf_company_has_entitlement(v_company, 'tf.recruit') then
      return jsonb_build_object('ok', false, 'error', 'not_entitled', 'module', 'tf.recruit');
    end if;
    if not public.user_has_permission('score_candidates', v_company) then
      return jsonb_build_object('ok', false, 'error', 'forbidden', 'need', 'score_candidates');
    end if;
  end if;

  insert into public.talentflow_scorecards
    (company_id, application_id, interviewer_id, overall, recommendation, competencies, notes, submitted_at)
  values (v_company, p_application_id, auth.uid(), p_overall, p_recommendation,
          coalesce(p_competencies, '{}'::jsonb), p_notes, now())
  returning id into v_id;

  insert into public.talentflow_application_activity (company_id, application_id, note, actor_id)
  values (v_company, p_application_id,
          'Scorecard submitted: ' || p_recommendation || ' (' || p_overall || ')', auth.uid());

  return jsonb_build_object('ok', true, 'scorecard_id', v_id);
end $fn$;

-- ---------- Extend an offer ----------
create or replace function public.talentflow_extend_offer(
  p_application_id uuid, p_amount numeric, p_unit text default 'hourly', p_start_date date default null
) returns jsonb
language plpgsql
security invoker
set search_path to 'public', 'pg_catalog'
as $fn$
declare v_company uuid; v_offer uuid; v_offer_stage uuid;
begin
  select company_id into v_company from public.talentflow_applications where id = p_application_id;
  if v_company is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;

  if auth.uid() is not null then
    if not public.tf_company_has_entitlement(v_company, 'tf.recruit') then
      return jsonb_build_object('ok', false, 'error', 'not_entitled', 'module', 'tf.recruit');
    end if;
    if not public.user_has_permission('manage_candidates', v_company) then
      return jsonb_build_object('ok', false, 'error', 'forbidden', 'need', 'manage_candidates');
    end if;
  end if;

  insert into public.talentflow_offers
    (company_id, application_id, status, compensation_amount, compensation_unit, start_date, expires_at, sent_at, created_by)
  values (v_company, p_application_id, 'sent', p_amount, coalesce(p_unit, 'hourly'), p_start_date,
          now() + interval '7 days', now(), auth.uid())
  returning id into v_offer;

  select s.id into v_offer_stage
    from public.talentflow_stages s
   where s.company_id = v_company and s.stage_type = 'offer'
     and s.pipeline_id = (select j.pipeline_id from public.talentflow_jobs j
                            join public.talentflow_applications a on a.job_id = j.id
                           where a.id = p_application_id)
   limit 1;
  if v_offer_stage is not null then
    update public.talentflow_applications
       set stage_id = v_offer_stage, updated_at = now(), updated_by = auth.uid()
     where id = p_application_id;
  end if;

  insert into public.talentflow_application_activity (company_id, application_id, to_stage_id, note, actor_id)
  values (v_company, p_application_id, v_offer_stage,
          'Offer extended: ' || p_amount || ' / ' || coalesce(p_unit, 'hourly'), auth.uid());

  return jsonb_build_object('ok', true, 'offer_id', v_offer);
end $fn$;

-- ---------- Least-privilege execute grants ----------
revoke all on function public.talentflow_advance_application(uuid, uuid, text) from public, anon;
revoke all on function public.talentflow_submit_scorecard(uuid, numeric, tf_scorecard_reco, jsonb, text) from public, anon;
revoke all on function public.talentflow_extend_offer(uuid, numeric, text, date) from public, anon;
grant execute on function public.talentflow_advance_application(uuid, uuid, text) to authenticated, service_role;
grant execute on function public.talentflow_submit_scorecard(uuid, numeric, tf_scorecard_reco, jsonb, text) to authenticated, service_role;
grant execute on function public.talentflow_extend_offer(uuid, numeric, text, date) to authenticated, service_role;