-- ============================================================================
-- TalentFlow People write path: convert a hired candidate into an employee
-- (the recruiting -> HR seam) and complete onboarding tasks. Both enforce
-- entitlement + permission before writing. SECURITY INVOKER; guard bypasses
-- for service_role (auth.uid() null). talentflow_ namespace (module logic).
-- ============================================================================

-- ---------- Convert a hired application into an employee ----------
create or replace function public.talentflow_convert_to_employee(p_application_id uuid)
returns jsonb
language plpgsql
security invoker
set search_path to 'public', 'pg_catalog'
as $fn$
declare
  v_company uuid; v_status tf_application_status; v_existing uuid;
  v_emp uuid; v_first text; v_last text; v_email text; v_phone text;
  v_title text; v_dept text;
begin
  select a.company_id, a.status, a.converted_employee_id,
         c.first_name, c.last_name, c.email, c.phone, c.headline, j.department
    into v_company, v_status, v_existing, v_first, v_last, v_email, v_phone, v_title, v_dept
    from public.talentflow_applications a
    join public.talentflow_candidates c on c.id = a.candidate_id
    join public.talentflow_jobs j on j.id = a.job_id
   where a.id = p_application_id;

  if v_company is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;

  if auth.uid() is not null then
    if not public.tf_company_has_entitlement(v_company, 'tf.people') then
      return jsonb_build_object('ok', false, 'error', 'not_entitled', 'module', 'tf.people');
    end if;
    if not public.user_has_permission('onboard_employees', v_company) then
      return jsonb_build_object('ok', false, 'error', 'forbidden', 'need', 'onboard_employees');
    end if;
  end if;

  if v_status <> 'hired' then
    return jsonb_build_object('ok', false, 'error', 'not_hired', 'status', v_status);
  end if;

  -- Idempotent: reuse an employee already linked to this application.
  select id into v_emp from public.talentflow_employees where source_application_id = p_application_id limit 1;
  if v_emp is null then
    insert into public.talentflow_employees
      (company_id, first_name, last_name, email, phone, title, department,
       employment_type, status, hire_date, source_application_id, created_by)
    values (v_company, v_first, v_last, v_email, v_phone, v_title, v_dept,
            'full_time', 'onboarding', current_date + 7, p_application_id, auth.uid())
    returning id into v_emp;

    insert into public.talentflow_onboarding_tasks (company_id, employee_id, title, category, status, due_date, sort_order) values
      (v_company, v_emp, 'Sign offer letter & I-9', 'Paperwork', 'complete', current_date+1, 1),
      (v_company, v_emp, 'Direct deposit setup', 'Payroll', 'in_progress', current_date+3, 2),
      (v_company, v_emp, 'Issue equipment & PPE', 'Equipment', 'pending', current_date+5, 3),
      (v_company, v_emp, 'Safety & IICRC orientation', 'Training', 'pending', current_date+7, 4),
      (v_company, v_emp, 'Assign to crew & first route', 'Operations', 'pending', current_date+8, 5);
  end if;

  update public.talentflow_applications
     set converted_employee_id = v_emp, updated_at = now(), updated_by = auth.uid()
   where id = p_application_id and converted_employee_id is distinct from v_emp;

  return jsonb_build_object('ok', true, 'employee_id', v_emp, 'reused', v_existing is not null or v_emp is not null);
end $fn$;

-- ---------- Complete an onboarding task; activate the employee when done ----------
create or replace function public.talentflow_complete_onboarding_task(p_task_id uuid)
returns jsonb
language plpgsql
security invoker
set search_path to 'public', 'pg_catalog'
as $fn$
declare v_company uuid; v_emp uuid; v_remaining int;
begin
  select company_id, employee_id into v_company, v_emp
    from public.talentflow_onboarding_tasks where id = p_task_id;
  if v_company is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;

  if auth.uid() is not null then
    if not public.tf_company_has_entitlement(v_company, 'tf.onboard') then
      return jsonb_build_object('ok', false, 'error', 'not_entitled', 'module', 'tf.onboard');
    end if;
    if not public.user_has_permission('onboard_employees', v_company) then
      return jsonb_build_object('ok', false, 'error', 'forbidden', 'need', 'onboard_employees');
    end if;
  end if;

  update public.talentflow_onboarding_tasks
     set status = 'complete', completed_at = now(), updated_at = now()
   where id = p_task_id;

  select count(*) into v_remaining
    from public.talentflow_onboarding_tasks
   where employee_id = v_emp and status <> 'complete';

  if v_remaining = 0 then
    update public.talentflow_employees
       set status = 'active', updated_at = now(), updated_by = auth.uid()
     where id = v_emp and status = 'onboarding';
  end if;

  return jsonb_build_object('ok', true, 'employee_id', v_emp, 'remaining_tasks', v_remaining,
                            'activated', v_remaining = 0);
end $fn$;

-- ---------- Least-privilege execute grants ----------
revoke all on function public.talentflow_convert_to_employee(uuid) from public, anon;
revoke all on function public.talentflow_complete_onboarding_task(uuid) from public, anon;
grant execute on function public.talentflow_convert_to_employee(uuid) to authenticated, service_role;
grant execute on function public.talentflow_complete_onboarding_task(uuid) to authenticated, service_role;