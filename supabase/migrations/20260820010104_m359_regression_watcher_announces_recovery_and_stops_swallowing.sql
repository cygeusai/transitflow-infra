-- m359_regression_watcher_announces_recovery_and_stops_swallowing
--
-- Found while closing the A1/A15 red board. The hourly regression watcher pages
-- Slack every time the board is red and says nothing at all when it goes green.
-- The team that got seven "2 critical assertion(s) failing" pages between 19:09
-- and 00:09 would have received exactly zero messages telling them it cleared.
-- Silence is not a recovery signal. Someone would have had to go and look.
--
-- Two further defects in the same function, both the same class:
--   exception when others then null;   -- around tf_request_ticket
--   exception when others then null;   -- around tf_resolve_ticket
-- A ticket that failed to open, or a ticket that failed to close, produced no
-- error, no warning and no field in the return payload. The watcher would have
-- reported ok:true with tickets_opened 0 and looked healthy while doing nothing.
-- Standing rule on this platform: never silently swallow an error.

-- ---------------------------------------------------------------------------
-- 1. Route and grade the recovery event
-- ---------------------------------------------------------------------------
insert into public.tf_notification_severity (event_key, severity, note)
values ('platform_regression_recovered','normal',
  'The platform regression suite returned to fully green after a period of failure. Graded normal, not low: the people who were paged about the failure are entitled to be told it ended, and low would route to in_app where nobody paged at 3am is looking.')
on conflict (event_key) do update
  set severity = excluded.severity, note = excluded.note, updated_at = now();

insert into public.tf_notification_routing
  (event_key, audience, slack_channel_id, channel_name, action_required,
   escalate_after, cooldown_seconds, template_key, rationale, reviewed_in)
values
  ('platform_regression_recovered','tech','C0BFQE3LD61','#information-technology','none',
   1, 0, 'regression_recovered',
   'Closes the loop on platform_regression_critical, which pages this same channel. An alarm that fires but never stands down trains people to ignore it, and leaves the runbook and everyone''s memory saying the board is still red. Fires only on the transition to green, so there is no steady-state noise. action_required none: the work is already done by the time this arrives.',
   'm359')
on conflict (event_key) do update
  set audience = excluded.audience,
      slack_channel_id = excluded.slack_channel_id,
      channel_name = excluded.channel_name,
      action_required = excluded.action_required,
      escalate_after = excluded.escalate_after,
      cooldown_seconds = excluded.cooldown_seconds,
      template_key = excluded.template_key,
      rationale = excluded.rationale,
      reviewed_in = excluded.reviewed_in,
      updated_at = now();

-- ---------------------------------------------------------------------------
-- 2. Give the recovery event a rendered form
-- ---------------------------------------------------------------------------
-- tf_notification_render dispatches on template_key through an if/elsif chain.
-- Patch a branch in ahead of data_mismatch rather than retransmitting sixteen
-- kilobytes of unrelated template text and risking a transcription error in it.
do $do$
declare
  v_def text;
  v_new text;
  v_hits int;
  v_anchor constant text := E'  elsif v_tpl = ''data_mismatch'' then';
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'tf_notification_render';

  if v_def is null then
    raise exception 'm359: public.tf_notification_render not found';
  end if;

  v_hits := (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor);
  if v_hits <> 1 then
    raise exception 'm359: expected exactly 1 data_mismatch branch anchor, found %', v_hits;
  end if;

  if position('regression_recovered' in v_def) > 0 then
    raise exception 'm359: tf_notification_render already has a regression_recovered branch';
  end if;

  v_new := replace(v_def, v_anchor,
    E'  elsif v_tpl = ''regression_recovered'' then\n'
 || E'    v_out := ''✅ Platform safety checks are green again''\n'
 || E'          || nl || ''Every assertion in the suite passes. The ticket closed itself.''\n'
 || E'          || nl || ''Nothing further is needed.'';\n'
 || E'\n'
 || v_anchor);

  execute v_new;
end
$do$;

-- ---------------------------------------------------------------------------
-- 3. The watcher itself
-- ---------------------------------------------------------------------------
create or replace function public.tf_regression_autoticket()
returns jsonb
language plpgsql
security definer
set search_path to 'public','pg_catalog'
as $function$
declare
  v_company constant uuid := 'ff000000-0000-4000-b000-000000000001';
  v_res     jsonb;
  v_failed  int;
  v_crit    int;
  v_total   int;
  v_names   text;
  v_body    text;
  v_t       uuid;
  v_paged   jsonb := null;
  v_recov   jsonb := null;
  v_errs    jsonb := '[]'::jsonb;
  v_opened  int := 0;
  v_closed  int := 0;
begin
  -- pg_cron calls this as postgres with a null auth.uid(), so the guard is
  -- scoped to real sessions. An authenticated non-staff caller is refused
  -- outright: this function opens tickets and can page a human at 3am.
  if auth.uid() is not null and not public.user_is_internal_staff(v_company) then
    raise exception 'tf_regression_autoticket: not authorized';
  end if;

  v_res := public.tf_platform_regression_suite(v_company);

  v_total  := coalesce((v_res->>'total')::int, 0);
  v_failed := coalesce((v_res->>'failed')::int, 0);
  v_crit   := coalesce((v_res->>'critical_failures')::int, 0);

  -- An empty population is not a pass. If the suite ever returns zero
  -- assertions, every counter reads zero and a broken platform is
  -- indistinguishable from a healthy one on the board.
  if v_total = 0 then
    raise exception 'tf_regression_autoticket refuses to certify an empty suite: 0 assertions ran.';
  end if;

  if v_failed > 0 then
    -- Migration 321. The separator below was a double hyphen. Inside a string
    -- literal that is invisible to a human reader and indistinguishable from a
    -- line comment to tf_function_safety_audit, which strips comments before it
    -- strips literals. It deleted the rest of this line, unbalanced the quotes,
    -- and caused every call below to be swallowed as literal text, classifying
    -- this writer as a read. Keep punctuation that opens a comment out of the
    -- literals in this file until the classifier lexes properly.
    select string_agg(
             (a->>'id') || ' [' || (a->>'severity') || '] ' || (a->>'name')
             || ', observed ' || coalesce(a->>'observed','?')
             || E'\n      prevents: ' || coalesce(a->>'prevents','(unstated)'),
             E'\n  - ' order by a->>'id')
      into v_names
    from jsonb_array_elements(v_res->'assertions') a
    where (a->>'ok')::boolean is false;

    v_body := 'The platform regression suite is failing.'
      ||E'\n\nAssertions: '||v_total||'   Failed: '||v_failed||'   Critical: '||v_crit
      ||E'\n\nFailing:\n  - '||coalesce(v_names,'(see the suite output)')
      ||E'\n\nEvery assertion in this suite was written the day an incident was closed, '
      ||'and each one names the incident it prevents. A failure here is not a new '
      ||'defect discovered by a scanner. It is a control that was verified closed and '
      ||'has since reopened, which is the more dangerous of the two because the '
      ||'runbook, the architecture notes and everyone''s memory all still say it is fixed.'
      ||E'\n\nDiagnose: select public.tf_platform_regression_suite('''||v_company||'''::uuid);'
      ||E'\nAssertions marked method=structural inspect function source rather than '
      ||'executing the behaviour, and are the weaker test. Treat a structural failure '
      ||'as a definite regression: the source no longer contains the thing it must contain.'
      ||E'\n\nThis ticket closes automatically once every assertion passes.';

    begin
      v_t := public.tf_request_ticket(
        'safety:platform_regression', 'safety',
        'Platform regression suite: '||v_failed||' of '||v_total||' assertion(s) failing'
          ||case when v_crit > 0 then ' ('||v_crit||' critical)' else '' end,
        v_body,
        case when v_crit > 0 then 1 else 2 end,
        null);
      if v_t is not null then v_opened := v_opened + 1; end if;
    exception when others then
      -- Was: exception when others then null. A ticket that failed to open is
      -- the whole point of this function failing, and it used to be invisible.
      raise warning 'tf_regression_autoticket: could not open the regression ticket (% %)', sqlstate, sqlerrm;
      v_errs := v_errs || jsonb_build_object('stage','open_ticket','sqlstate',sqlstate,'message',sqlerrm);
    end;

    -- Critical failures also page. tf_page_staff_sev deduplicates, so a defect
    -- left standing for a day yields one page, not one per tick.
    if v_crit > 0 then
      begin
        v_paged := public.tf_page_staff_sev(
          'critical', v_company, 'internal_ops', 'platform_regression_critical',
          'Platform regression: '||v_crit||' critical assertion(s) failing',
          coalesce(v_names, 'See select public.tf_platform_regression_suite().'),
          'regression_suite', null);
      exception when others then
        raise warning 'tf_regression_autoticket: could not page on critical failure (% %)', sqlstate, sqlerrm;
        v_paged := jsonb_build_object('ok', false, 'error', sqlerrm);
        v_errs := v_errs || jsonb_build_object('stage','page_critical','sqlstate',sqlstate,'message',sqlerrm);
      end;
    end if;
  else
    begin
      v_closed := coalesce(public.tf_resolve_ticket(
        'safety:platform_regression',
        'Platform regression suite green: '||v_total||' of '||v_total||' assertions pass. '
        ||'Closed automatically.'), 0);
    exception when others then
      raise warning 'tf_regression_autoticket: could not close the regression ticket (% %)', sqlstate, sqlerrm;
      v_errs := v_errs || jsonb_build_object('stage','close_ticket','sqlstate',sqlstate,'message',sqlerrm);
    end;

    -- Stand the alarm down. A ticket was open, so the board was red, so people
    -- were paged. v_closed > 0 is the transition edge: it is true exactly once
    -- per red-to-green crossing and false on every steady-state green tick, so
    -- this announces recovery without becoming an hourly heartbeat.
    if v_closed > 0 then
      begin
        v_recov := public.tf_page_staff_sev(
          'normal', v_company, 'internal_ops', 'platform_regression_recovered',
          'Platform regression suite green: '||v_total||' of '||v_total||' assertions pass',
          'The suite is fully green. The safety:platform_regression ticket closed '
          ||'automatically. No action is needed. This message exists because an alarm '
          ||'that never stands down teaches people to ignore it.',
          'regression_suite', null);
      exception when others then
        raise warning 'tf_regression_autoticket: could not page recovery (% %)', sqlstate, sqlerrm;
        v_recov := jsonb_build_object('ok', false, 'error', sqlerrm);
        v_errs := v_errs || jsonb_build_object('stage','page_recovery','sqlstate',sqlstate,'message',sqlerrm);
      end;
    end if;
  end if;

  return jsonb_build_object(
    'ok', jsonb_array_length(v_errs) = 0,
    'checked_at', now(),
    'assertions_total', v_total,
    'failed_total', v_failed,
    'critical_failures', v_crit,
    'tickets_opened', v_opened,
    'tickets_resolved', v_closed,
    'paged', v_paged,
    'recovery_paged', v_recov,
    'errors', v_errs,
    'suite', v_res);
end;
$function$;

update public.tf_function_registry
   set rationale = 'Hourly regression watcher. Runs the platform suite, opens or closes the safety:platform_regression ticket, pages on critical failure and, since m359, pages once on the red-to-green transition so the alarm stands down. m359 also replaced two exception-when-others-then-null blocks with warnings and an errors array, so a ticket that fails to open or close can no longer return ok:true.',
       updated_at = now()
 where proname = 'tf_regression_autoticket';