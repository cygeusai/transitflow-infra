-- m336_intake_render_stops_leaking_the_provider_preamble
--
-- m335 got the answering-service emergency onto the #field-ops lane. Reading
-- the result out loud exposed two presentation defects that m335 introduced or
-- inherited, both found by rendering the eight real intakes rather than by
-- reasoning about them.
--
-- 1. THE PROVIDER PREAMBLE TRAILED INTO THE MESSAGE. These payloads are ONE
--    line of comma separated 'Label: value' pairs. The inbound_sms branch
--    captured the message with a regex that ran to end of line, so the single
--    non-emergency intake rendered as the customer's actual words followed by
--    'Greeting: Plumbing Service, Emergency Y or N: No - Not Emergency,
--    First Name: ..., Last Name: ...' until a character cap cut it off. That is
--    exactly the machine detail the routing work exists to keep out of a
--    business channel, and it repeats the customer's name for no reason.
--
-- 2. THE ISSUE LINE CLIPPED MID WORD. A hard left(x, 160) ended one emergency
--    at 'have been provided to yo'. A dispatcher should not have to wonder
--    whether the sentence mattered.
--
-- Both are fixed by giving the renderer two small pure helpers instead of ad
-- hoc splitting, and by teaching it that the provider uses a different label
-- depending on how the call was dispositioned: 'Nature of Emergency' on an
-- emergency, 'Service Description' on a booked job, 'Agent Notes' on a message.
-- Verified against all eight live intakes: 8 of 8 yield name, callback number,
-- street and city; 7 of 7 emergencies yield the stated nature; the one
-- non-emergency yields both its service description and its agent notes.
--
-- Also decided here rather than defaulted: inbound_sms_not_logged had no
-- routing row. It has never fired, and tf_notification_drain fails an unrouted
-- key loud to #information-technology, so nothing was at risk. But 'nothing was
-- at risk because the fallback happened to be right' is not a routing decision,
-- and A19 in the next migration asserts that every key that fires has one.

-- ---------------------------------------------------------------------------
-- 1. tf_intake_field. Pull one labelled value out of a single-line answering
--    service payload, stopping at the next capitalised label rather than at
--    end of line. The lowercase guard is deliberate: 'I spoke with a relative,
--    however her daughter...' must NOT be treated as a field boundary, and it
--    is not, because 'however' does not start with a capital.
-- ---------------------------------------------------------------------------
create or replace function public.tf_intake_field(p_body text, p_label text)
returns text
language sql
immutable
set search_path to 'public', 'pg_temp'
as $fn$
  select btrim(regexp_replace(
           split_part(coalesce(p_body, ''), coalesce(p_label, '') || ':', 2),
           ',[[:space:]]*[A-Z][A-Za-z ]{1,28}:.*$', ''));
$fn$;

-- ---------------------------------------------------------------------------
-- 2. tf_text_clip. Truncate on a word boundary when one is close enough to the
--    cap, and fall back to a hard cut when a single token is longer than the
--    search window, so a pasted URL or a long identifier cannot swallow the
--    whole line.
-- ---------------------------------------------------------------------------
create or replace function public.tf_text_clip(p_text text, p_max int)
returns text
language sql
immutable
set search_path to 'public', 'pg_temp'
as $fn$
  select case
           when p_text is null                                        then null
           when coalesce(p_max, 0) < 1                                then ''
           when length(p_text) <= p_max                               then p_text
           when position(' ' in reverse(left(p_text, p_max))) between 1 and 30
             then btrim(left(p_text, p_max - position(' ' in reverse(left(p_text, p_max))))) || '...'
           else btrim(left(p_text, p_max)) || '...'
         end;
$fn$;

-- ---------------------------------------------------------------------------
-- 3. The renderer, now built on the two helpers.
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
      v_name  := btrim(public.tf_intake_field(p_body, 'First Name')
                 || ' ' || public.tf_intake_field(p_body, 'Last Name'));
      v_phone := public.tf_intake_field(p_body, 'Main Phone');
      v_addr  := btrim(concat_ws(', ',
                   nullif(public.tf_intake_field(p_body, 'Street Address'), ''),
                   nullif(public.tf_intake_field(p_body, 'City'), '')));
      -- m336. The provider uses a different label depending on how the call was
      -- dispositioned. Take them in the order a dispatcher would want to read.
      v_issue := coalesce(
                   nullif(public.tf_intake_field(p_body, 'Nature of Emergency'), ''),
                   nullif(public.tf_intake_field(p_body, 'Service Description'), ''),
                   nullif(public.tf_intake_field(p_body, 'Agent Notes'), ''),
                   '');
      v_out := v_out || nl || btrim(coalesce(nullif(v_name, ''), 'Caller')
                       || case when v_phone <> '' then ', ' || v_phone else '' end);
      if v_addr  <> '' then v_out := v_out || nl || v_addr; end if;
      if v_issue <> '' then v_out := v_out || nl || public.tf_text_clip(v_issue, 180); end if;
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
      -- m336. These payloads are ONE line of comma separated Label: value pairs,
      -- so a capture that runs to end of line drags the whole provider preamble
      -- along with it. tf_intake_field stops at the next capitalised label,
      -- which is what keeps greeting, company name and the emergency Y/N field
      -- out of a business channel.
      v_name := btrim(public.tf_intake_field(p_body, 'First Name')
                || ' ' || public.tf_intake_field(p_body, 'Last Name'));
      v_phone := public.tf_intake_field(p_body, 'Main Phone');
      v_msg  := coalesce(
                  nullif(public.tf_intake_field(p_body, 'Nature of Emergency'), ''),
                  nullif(public.tf_intake_field(p_body, 'Service Description'), ''),
                  nullif(public.tf_intake_field(p_body, 'Agent Notes'), ''),
                  nullif(public.tf_intake_field(p_body, 'Notes'), ''),
                  nullif(public.tf_intake_field(p_body, 'Comments'), ''),
                  nullif(public.tf_intake_field(p_body, 'Message'), ''),
                  nullif(public.tf_intake_field(p_body, 'Details'), ''),
                  nullif(public.tf_intake_field(p_body, 'Issue'), ''),
                  '');
      if v_msg = '' then v_msg := 'Left a message on the answering line.'; end if;
      -- The callback number goes FIRST so the length cap can never eat it.
      if v_phone <> '' then v_msg := 'Call back ' || v_phone || '. ' || v_msg; end if;
    elsif v_first ~ '^[^:]{1,40}:' then
      v_name := btrim(split_part(v_first, ':', 1));
      v_msg  := btrim(substr(v_first, position(':' in v_first) + 1));
    else
      v_name := ''; v_msg := v_first;
    end if;
    if lower(coalesce(v_name,'')) in ('lead','customer','sms','web','from','') then v_name := ''; end if;
    v_out := '💬 ' || coalesce(nullif(v_name,''), 'A customer') || ' sent a message'
          || nl || public.tf_text_clip(coalesce(nullif(v_msg,''), 'No text came through.'), 240);

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
-- 4. The routing decision that was previously a fallback.
-- ---------------------------------------------------------------------------
insert into public.tf_notification_routing
  (event_key, audience, slack_channel_id, channel_name, action_required,
   escalate_after, cooldown_seconds, template_key, rationale, reviewed_in)
values
  ('inbound_sms_not_logged', 'tech', 'C0BFQE3LD61', '#information-technology', 'act',
   1, 1800, 'ingest_failed',
   'quo-webhook raises this when an inbound message cannot be written to communications. The text is invisible to every human in the company until someone recovers it, so it is an engineering incident, not field traffic. First occurrence pages, because the second one is another customer nobody answered.',
   'm336')
on conflict (event_key) do update
  set audience         = excluded.audience,
      slack_channel_id = excluded.slack_channel_id,
      channel_name     = excluded.channel_name,
      action_required  = excluded.action_required,
      escalate_after   = excluded.escalate_after,
      cooldown_seconds = excluded.cooldown_seconds,
      template_key     = excluded.template_key,
      rationale        = excluded.rationale,
      reviewed_in      = excluded.reviewed_in,
      updated_at       = now();

-- ---------------------------------------------------------------------------
-- Convention 33.
-- ---------------------------------------------------------------------------
insert into public.tf_function_registry (proname, declared_kind, write_acknowledged, rationale)
values
  ('tf_intake_field', 'read', false,
   'Pure extractor over a single-line answering service payload. Immutable, no table access, no DML. Returns one labelled value, terminated at the next capitalised label so the provider preamble cannot trail into a rendered message.'),
  ('tf_text_clip', 'read', false,
   'Pure word-boundary truncation. Immutable, no table access, no DML. Exists because a hard character cut ended an emergency description mid word on a dispatcher''s phone.')
on conflict (proname) do update
  set declared_kind      = excluded.declared_kind,
      write_acknowledged = excluded.write_acknowledged,
      rationale          = excluded.rationale,
      updated_at         = now();

select public.tf_apply_grant_tier('tf_intake_field', 'p_body text, p_label text', 'admin',
  'Pure extractor used by tf_notification_render. No browser session needs it.');
select public.tf_apply_grant_tier('tf_text_clip', 'p_text text, p_max integer', 'admin',
  'Pure text helper used by tf_notification_render. No browser session needs it.');

comment on function public.tf_intake_field(text, text) is
  'Returns one labelled value from a single-line answering service intake payload, stopping at the next capitalised label rather than at end of line.';
comment on function public.tf_text_clip(text, integer) is
  'Truncates on a word boundary when one falls within 30 characters of the cap, otherwise cuts hard. Appends an ellipsis when anything was removed.';
