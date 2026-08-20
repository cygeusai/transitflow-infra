-- m335_answering_service_emergency_reaches_field_ops
--
-- WHAT WAS WRONG
-- quo-webhook's inbound catch-all paged every inbound SMS that was not a
-- technician command as event_key 'tech_update'. m331 routes tech_update to
-- audience 'suppressed', and tf_notification_severity_for('tech_update') is
-- 'low', whose only channel is in_app. Two independent gates therefore agreed
-- that the message was nobody's problem.
--
-- The answering service relays its call intakes over that same SMS line. Eight
-- of them arrived between 2026-07-18 and 2026-08-16. Seven carried
-- 'Emergency Y or N: Yes - Emergency'. All eight were recorded in the Hub and
-- none of them reached Slack. A leaking water heater and a dead sump pump sat
-- in a table.
--
-- The catch-all was also mislabelled at the source: across 385 inbound SMS
-- rows, ZERO have meta->>'sender_kind' = 'technician'. 'tech_update' was
-- carrying customer traffic under a technician's name.
--
-- WHAT THIS CHANGES
-- 1. tf_inbound_sms_classify: one pure, immutable answer to 'what kind of
--    inbound message is this', so the decision is server side, inspectable
--    and assertable rather than buried in an edge function expression.
-- 2. tf_page_inbound_sms: the single entry point quo-webhook calls instead of
--    hardcoding an event key. Classification cannot be bypassed by a caller
--    that forgets it.
-- 3. tf_notification_render: emergency_lead learns the answering-service
--    payload shape, so a critical intake renders as name, callback number,
--    address and the stated emergency. inbound_sms gains the callback number.
--    The ban-list fallback stops describing an emergency as a platform issue.
--
-- WHAT THIS DOES NOT CHANGE
-- tech_update remains the key for technician command acknowledgements
-- (accepted, ETA set, on site) and remains suppressed. Nothing is deleted,
-- no error logging is removed, and every raw body still lands in
-- public.communications and in notifications.body exactly as before.

-- ---------------------------------------------------------------------------
-- 1. The classifier. Pure, immutable, no table access, no catalog access.
-- ---------------------------------------------------------------------------
create or replace function public.tf_inbound_sms_classify(p_body text)
returns text
language sql
immutable
set search_path to 'public', 'pg_temp'
as $fn$
  -- The answering service stamps every relayed intake with an
  -- 'Emergency Y or N:' field. That field, and only that field, decides
  -- whether a truck has to move tonight. Anything without it is ordinary
  -- inbound traffic and belongs on the omni_inbound lane, which m331 already
  -- routes to #field-ops at normal severity with a 300 second cooldown.
  select case
           when coalesce(p_body, '') !~* 'Emergency[[:space:]]*Y[[:space:]]*or[[:space:]]*N[[:space:]]*:'
             then 'omni_inbound'
           when p_body ~* 'Emergency[[:space:]]*Y[[:space:]]*or[[:space:]]*N[[:space:]]*:[[:space:]]*(yes|y)\M'
             then 'fnol_emergency'
           else 'omni_inbound'
         end;
$fn$;

-- ---------------------------------------------------------------------------
-- 2. The paging entry point. quo-webhook states the facts; the database
--    decides the event key. A caller cannot route around the classifier
--    because there is no event_key parameter to get wrong.
-- ---------------------------------------------------------------------------
create or replace function public.tf_page_inbound_sms(
  p_company_id  uuid,
  p_from        text,
  p_body        text,
  p_entity_type text default null,
  p_entity_id   uuid default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $fn$
declare
  v_key  text;
  v_who  text;
  v_sub  text;
  v_page jsonb;
begin
  if auth.uid() is not null and not public.user_is_internal_staff(p_company_id) then
    raise exception 'not_authorized';
  end if;

  v_key := public.tf_inbound_sms_classify(p_body);
  v_who := coalesce(nullif(btrim(coalesce(p_from, '')), ''), 'an unknown number');

  v_sub := case v_key
             when 'fnol_emergency' then 'Answering service intake'
             else 'SMS from ' || v_who
           end;

  -- 1500, not 280. The old truncation cut the answering-service payload off
  -- mid address, which is exactly the part a dispatcher needs. The renderer,
  -- not the transport, decides what a person finally sees.
  v_page := public.tf_page_staff(
              p_company_id, 'dispatch', v_key, v_sub,
              left(coalesce(nullif(btrim(coalesce(p_body, '')), ''), '(no text)'), 1500),
              p_entity_type, p_entity_id);

  return jsonb_build_object('ok', true, 'event_key', v_key, 'subject', v_sub, 'page', v_page);
end;
$fn$;

-- ---------------------------------------------------------------------------
-- 3. The renderer, so a critical intake is readable by the person on call.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.tf_notification_render(p_event_key text, p_subject text, p_body text, p_severity text DEFAULT NULL::text, p_entity_type text DEFAULT NULL::text, p_entity_id uuid DEFAULT NULL::uuid, p_template_key text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'extensions', 'pg_temp'
AS $function$
declare
  nl     constant text := chr(10);
  c_hub  constant text := 'https://hub.transitflowgroup.com';
  c_uuid constant text :=
    '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}';
  -- The ban list. If the finished message matches any of this, the message is
  -- thrown away and the safe generic render is returned instead. Cheaper than
  -- trusting every template to stay clean as they are edited by other people.
  c_ban  constant text :=
       '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
    || '|_uq|duplicate key|unique constr|violates|sqlstate|traceback|watermark'
    || '|\mseverity\M|\mevent\M|\mnotification\M|\mnotifications\M'
    || '|\minsert\M|\mupdate\M|\mdelete\M|\mselect\M|\mconstraint\M|\mrelation\M|\mcolumn\M'
    || '|\mattempt|\mretry|\mretries\M|\mjson\M|\mpayload\M|\mstack\M'
    || '|[{}]|null value|\mDNIS\M|Caller ID';
  v_tpl text; v_base text; v_link text; v_subj text; v_first text; v_prov text;
  v_name text; v_phone text; v_addr text; v_issue text; v_msg text; v_job text;
  v_ref text; v_cnt text; v_out text;
begin
  -- One home and one answer for the host, same lookup tf_send_intake and
  -- tf_render_document already use.
  select coalesce(s.config->>'app_base_url', c_hub) into v_base
    from public.integration_settings s
   where s.company_id = 'ff000000-0000-4000-b000-000000000001'::uuid
     and s.provider = 'openphone'::integration_provider
     and s.deleted_at is null
   order by s.updated_at desc limit 1;
  v_base := coalesce(v_base, c_hub);

  v_tpl := nullif(btrim(coalesce(p_template_key,'')),'');
  if v_tpl is null then
    select r.template_key into v_tpl
      from public.tf_notification_routing r where r.event_key = p_event_key;
  end if;
  v_tpl := coalesce(v_tpl, 'generic');

  -- Subject with its leading emoji stripped, so the template owns the emoji.
  v_subj  := btrim(regexp_replace(regexp_replace(coalesce(p_subject,''), '^[^[:alnum:](]+', ''), '[[:space:]]+', ' ', 'g'));
  -- First line of the body only. Everything after it is provider detail.
  v_first := btrim(regexp_replace(split_part(coalesce(p_body,''), nl, 1), '[[:space:]]+', ' ', 'g'));
  v_job   := (regexp_match(coalesce(p_subject,'') || ' ' || coalesce(p_body,''), 'TF-[0-9]{4,}'))[1];
  v_ref   := (regexp_match(coalesce(p_subject,'') || ' ' || coalesce(p_body,''), 'FNOL-[0-9A-Z-]{4,}'))[1];

  v_prov := case
    when p_event_key like 'qbo%'        then 'QuickBooks'
    when p_event_key like 'hcp%'        then 'Housecall Pro'
    when p_event_key like 'slack%'      then 'Slack'
    when p_event_key like 'ai_gateway%' then 'The AI gateway'
    when p_event_key in ('omni_inbound','outbound_delivery_unknown','outbound_sent_not_logged')
                                        then 'The messaging line'
    else nullif(initcap(btrim(split_part(v_subj, ':', 2))), '') end;
  v_prov := coalesce(v_prov, 'A connected system');

  -- The deep link is a SECTION of the Hub, never a row address, because a row
  -- address would carry the UUID this renderer exists to keep out.
  v_link := case p_entity_type
    when 'jobs'                 then v_base || '/jobs'
    when 'leads'                then v_base || '/leads'
    when 'integration_settings' then v_base || '/settings/integrations'
    else null end;

  if v_tpl = 'emergency_lead' then
    v_out := '🚨 Emergency: '
          || coalesce(nullif(btrim(split_part(v_subj, chr(8212), 1)),''), 'service request')
          || coalesce(' (' || v_ref || ')','');
    if coalesce(p_body,'') ~* '(caller id|dnis)' then
      -- The answering-service intake shape, m335. Same provider payload the
      -- inbound_sms branch already reads, presented for someone who has to get
      -- a truck moving: who, what number to call back, where, and what is wrong.
      -- The provider preamble (caller ID, DNIS, greeting, company name) is
      -- never carried through, which is also what keeps the ban list quiet.
      v_name  := btrim(btrim(split_part(split_part(p_body, 'First Name:', 2), ',', 1))
                 || ' ' || btrim(split_part(split_part(p_body, 'Last Name:', 2), ',', 1)));
      v_phone := btrim(split_part(split_part(p_body, 'Main Phone:', 2), ',', 1));
      v_addr  := btrim(concat_ws(', ',
                   nullif(btrim(split_part(split_part(p_body, 'Street Address:', 2), ',', 1)), ''),
                   nullif(btrim(split_part(split_part(p_body, 'City:', 2), ',', 1)), '')));
      v_issue := btrim(split_part(split_part(p_body, 'Nature of Emergency:', 2), ', Call Outcome:', 1));
      v_out := v_out || nl || btrim(coalesce(nullif(v_name, ''), 'Caller')
                       || case when v_phone <> '' then ', ' || v_phone else '' end);
      if v_addr  <> '' then v_out := v_out || nl || v_addr; end if;
      if v_issue <> '' then v_out := v_out || nl || left(v_issue, 160); end if;
    elsif position(chr(183) in coalesce(p_body,'')) > 0 then
      v_name  := btrim(split_part(p_body, chr(183), 1));
      v_phone := btrim(split_part(p_body, chr(183), 2));
      v_addr  := btrim(split_part(btrim(split_part(p_body, chr(183), 3)), '.', 1));
      v_out := v_out || nl || btrim(v_name || case when v_phone <> '' then ', ' || v_phone else '' end);
      if v_addr <> '' then v_out := v_out || nl || v_addr; end if;
    elsif v_first <> '' then
      v_out := v_out || nl || left(v_first, 140);
    end if;
    v_out := v_out || nl || 'Dispatch now, on site inside 60 minutes.'
                   || nl || coalesce(v_link, v_base || '/jobs');

  elsif v_tpl = 'live_transfer' then
    v_out := '📞 Caller waiting to be connected';
    if v_first <> '' then v_out := v_out || nl || left(v_first, 140); end if;
    v_out := v_out || nl || 'Pick this one up now, it does not keep.';

  elsif v_tpl = 'new_lead' then
    -- Named fields only. The AI qualification transcript is thousands of
    -- characters of dialogue and belongs in the Hub, not on a phone.
    v_name  := (regexp_match(coalesce(p_body,''), 'Name:[ ]*([^' || nl || ']+)'))[1];
    v_issue := (regexp_match(coalesce(p_body,''), 'Issue:[ ]*([^' || nl || ']+)'))[1];
    v_phone := (regexp_match(coalesce(p_body,''), 'Phone:[ ]*([^' || nl || ']+)'))[1];
    v_name  := coalesce(nullif(btrim(coalesce(v_name,'')),''), btrim(split_part(v_subj, chr(8212), 2)));
    v_out := '✅ New qualified lead'
          || nl || btrim(coalesce(nullif(v_name,''),'Caller')
                   || case when coalesce(v_phone,'') <> '' then ', ' || btrim(v_phone) else '' end);
    if coalesce(v_issue,'') <> '' then v_out := v_out || nl || left(btrim(v_issue), 120); end if;
    v_out := v_out || nl || 'Call back now, speed to lead decides this one.'
                   || nl || coalesce(v_link, v_base || '/leads');

  elsif v_tpl = 'inbound_sms' then
    -- The customer message render: who it is from, and what they said. Nothing
    -- else. The answering-service payload that arrives on this path carries
    -- caller ID, DNIS, company name, greeting, an emergency Y/N field, a main
    -- phone and an email address. None of that is the message.
    if coalesce(p_body,'') ~* '(caller id|dnis)' then
      v_name := btrim(btrim(coalesce((regexp_match(p_body, 'First Name:[ ]*([^,' || nl || ']+)'))[1], ''))
                || ' ' || btrim(coalesce((regexp_match(p_body, 'Last Name:[ ]*([^,' || nl || ']+)'))[1], '')));
      v_phone := btrim(split_part(split_part(p_body, 'Main Phone:', 2), ',', 1));
      v_msg  := btrim(split_part(split_part(p_body, 'Nature of Emergency:', 2), ', Call Outcome:', 1));
      if v_msg = '' then
        v_msg := btrim(coalesce((regexp_match(p_body, '(?:Notes|Comments|Message|Details|Issue):[ ]*([^' || nl || ']+)'))[1], ''));
      end if;
      if v_msg = '' then v_msg := 'Left a message on the answering line.'; end if;
      -- The callback number goes FIRST so the 220 character cap can never eat it.
      if v_phone <> '' then v_msg := 'Call back ' || v_phone || '. ' || v_msg; end if;
    elsif v_first ~ '^[^:]{1,40}:' then
      v_name := btrim(split_part(v_first, ':', 1));
      v_msg  := btrim(substr(v_first, position(':' in v_first) + 1));
    else
      v_name := ''; v_msg := v_first;
    end if;
    if lower(coalesce(v_name,'')) in ('lead','customer','sms','web','from','') then v_name := ''; end if;
    v_out := '💬 ' || coalesce(nullif(v_name,''), 'A customer') || ' sent a message'
          || nl || left(coalesce(nullif(v_msg,''), 'No text came through.'), 220);

  elsif v_tpl = 'job_scheduled' then
    v_name := btrim(split_part(btrim(split_part(v_first, chr(8212), 1)), '.', 1));
    v_out := '📅 New booking'
          || nl || btrim(coalesce(nullif(v_name,''),'Customer')
                   || case when v_first ilike '%scheduled%' then ', on the calendar.' else '.' end)
          || nl || coalesce(v_link, v_base || '/jobs');

  elsif v_tpl = 'job_prep' then
    v_name := btrim(split_part(v_first, ' submitted', 1));
    v_cnt  := (regexp_match(v_first, '([0-9]+) photo'))[1];
    v_out := '📸 Job prep received'
          || nl || btrim(coalesce(v_job || ', ','') || coalesce(nullif(v_name,''),'Customer')
                   || coalesce(', ' || v_cnt || ' photos','') || '.')
          || nl || coalesce(v_link, v_base || '/jobs');

  elsif v_tpl = 'job_paid_closed' then
    -- Two lines by design, per the m331 rationale for #accounting_billing.
    v_out := '✅ Paid and closed'
          || nl || coalesce(v_job || ', payment received.', 'Payment received, the job is closed.');

  elsif v_tpl = 'integration_disconnected' then
    v_out := '🔌 ' || v_prov || ' needs reconnecting'
          || nl || 'The stored sign-in has gone stale, so the next sync will not run.'
          || nl || 'Someone with admin access has to sign in again.'
          || nl || coalesce(v_link, v_base || '/settings/integrations');

  elsif v_tpl = 'integration_degraded' then
    v_out := '⚠️ ' || v_prov || ' is failing intermittently'
          || nl || 'Calls to it are not completing reliably.'
          || nl || 'Worth a look before it becomes an outage.'
          || nl || coalesce(v_link, v_base || '/settings/integrations');

  elsif v_tpl = 'queue_stalled' then
    v_out := '🐢 A processing queue has stopped moving'
          || nl || 'Work is piling up behind it. Nothing has been lost.'
          || nl || 'Restart the worker.';

  elsif v_tpl = 'delivery_unknown' then
    v_out := '📡 A message was accepted but never confirmed delivered'
          || nl || 'The carrier has not reported it as delivered.'
          || nl || 'Confirm with the customer before assuming they got it.';

  elsif v_tpl = 'ingest_failed' then
    v_out := '📥 ' || v_prov || ' messages are not being saved'
          || nl || 'Incoming messages may be missing from the Hub.'
          || nl || 'Check the inbound path.';

  elsif v_tpl = 'regression_failed' then
    v_cnt := (regexp_match(v_subj, '([0-9]+)'))[1];
    v_out := '🧪 Platform safety checks are failing'
          || nl || coalesce(v_cnt,'One') || ' critical check(s) that were closed have reopened.'
          || nl || 'Treat this as a returning incident, not a new one.';

  elsif v_tpl = 'data_mismatch' then
    v_out := '🔀 A job and a customer disagree about who they belong to'
          || nl || 'The link was left alone because the two records are not provably the same person.'
          || nl || 'Reconcile them before invoicing.';

  elsif v_tpl = 'mapping_failed' then
    v_out := '🔗 A ' || v_prov || ' link was not saved'
          || nl || 'The next sync may create a duplicate on their side.'
          || nl || 'Verify the link before the next sync run.';

  elsif v_tpl = 'ai_anomaly' then
    v_out := '🤖 The AI gateway logged an anomaly'
          || nl || case when p_event_key = 'ai_gateway_unrecorded'
                        then 'A call completed without a spend record. The money was still spent.'
                        else 'A request could not be resolved unambiguously.' end
          || nl || 'Interesting in aggregate, not one at a time.';

  elsif v_tpl = 'sync_delayed' then
    -- The headline fix. Plain language, no SQL, no constraint name, no counter,
    -- and no sync-watermark vocabulary: the reader needs to know the Hub may be
    -- behind and that the connection is worth checking.
    v_out := '🕒 ' || v_prov || ' records are not saving'
          || nl || 'Some invoices and payments in the Hub may be behind ' || v_prov || '.'
          || nl || 'Check the ' || v_prov || ' connection.'
          || nl || coalesce(v_link, v_base || '/settings/integrations');

  elsif v_tpl = 'in_app_only' then
    -- Never posted. Rendered anyway so a caller always gets safe text.
    v_out := '🔕 Kept in the Hub'
          || nl || 'Nothing was posted to Slack for this one.';

  else
    -- THE SAFE GENERIC RENDER. Subject only, capped, never the body.
    v_out := case lower(coalesce(p_severity,''))
               when 'critical' then '🚨 ' when 'high' then '🔴 '
               when 'normal' then '🟡 ' else '🔔 ' end
          || coalesce(nullif(left(v_subj, 120), ''), 'Something needs a look')
          || nl || 'Open the Hub for the details.'
          || nl || coalesce(v_link, v_base);
  end if;

  v_out := regexp_replace(coalesce(v_out,''), c_uuid, '', 'g');
  v_out := regexp_replace(v_out, '"[^"]*"', '', 'g');
  v_out := regexp_replace(v_out, '[[:blank:]]+', ' ', 'g');
  v_out := regexp_replace(v_out, ' *' || nl || ' *', nl, 'g');
  v_out := btrim(v_out);
  if length(v_out) > 560 then v_out := left(v_out, 557) || '...'; end if;
  if v_out = '' or v_out ~* c_ban then
    -- m335. The fallback used to describe every discarded message as a platform
    -- issue. At critical tier that is a lie with a truck attached, so the tier
    -- decides the words. The details still exist, in the Hub and in the row.
    v_out := case lower(coalesce(p_severity,''))
               when 'critical' then '🚨 An emergency came in and could not be summarised safely here.'
                                 || nl || 'Open the Hub now and work it from there.'
               else '🔔 Something in the platform needs a look.'
                                 || nl || 'Open the Hub for the details.' end
          || nl || v_base;
  end if;
  return v_out;
end
$function$;

-- ---------------------------------------------------------------------------
-- Convention 33. Declarations in the same transaction as the creations.
-- ---------------------------------------------------------------------------
insert into public.tf_function_registry (proname, declared_kind, write_acknowledged, rationale)
values
  ('tf_inbound_sms_classify', 'read', false,
   'Pure classifier over an inbound SMS body. Immutable, no table access, no DML. Answers whether the answering service flagged the intake as an emergency, which decides whether the message reaches #field-ops at critical tier or the ordinary omni_inbound lane.'),
  ('tf_page_inbound_sms', 'write', true,
   'Calls tf_page_staff, which inserts a notifications row. Sole paging entry point for inbound SMS: it classifies server side so no caller can hardcode the wrong event key, which is how eight answering-service intakes, seven of them flagged emergency, were suppressed as tech_update.')
on conflict (proname) do update
  set declared_kind      = excluded.declared_kind,
      write_acknowledged = excluded.write_acknowledged,
      rationale          = excluded.rationale,
      updated_at         = now();

-- ---------------------------------------------------------------------------
-- Grants. Both are service_role surface. Neither belongs in a browser session,
-- and A15 ratchets the authenticated SECURITY DEFINER surface, so 'admin' here
-- is load bearing rather than decorative.
-- ---------------------------------------------------------------------------
select public.tf_apply_grant_tier('tf_inbound_sms_classify', 'p_body text', 'admin',
  'Pure classifier. No reason for a browser session to hold it.');
select public.tf_apply_grant_tier('tf_page_inbound_sms', 'p_company_id uuid, p_from text, p_body text, p_entity_type text, p_entity_id uuid', 'admin',
  'Writes a notifications row on behalf of the inbound SMS webhook. service_role only.');

comment on function public.tf_inbound_sms_classify(text) is
  'Returns the notification event_key for an inbound SMS body. fnol_emergency when the answering service flagged Emergency Y or N as yes, otherwise omni_inbound. Pure and immutable so the regression suite can assert it without writing a row.';
comment on function public.tf_page_inbound_sms(uuid, text, text, text, uuid) is
  'Pages staff about an inbound SMS. Classifies the body server side and forwards to tf_page_staff. Callers state the facts; this function decides the event key.';
