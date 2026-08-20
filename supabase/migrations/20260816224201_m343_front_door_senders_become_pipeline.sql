-- m343_front_door_senders_become_pipeline
--
-- EXECUTIVE DECISION, CXO / customer success, 16 August 2026. The measured
-- fact behind it: 39 of the 87 stranded texted-in files came from 13 senders
-- who exist in neither customers nor leads. Reading their messages, they are
-- prospects asking for quotes, relatives arranging work for family members,
-- and warranty intakes. Staff answer them from the desk, and nothing records
-- that the conversation exists. That is interest arriving at the front door
-- and evaporating from every report, pipeline count and follow-up queue.
--
-- Decision: an unknown sender who texts the business becomes a lead,
-- automatically, at the moment their message is paged. Recording a lead
-- contacts nobody. It sends nothing. It is the CRM writing down what already
-- happened, which is the automation-first posture this platform is built on,
-- with humans doing what humans should: answering the person.
--
-- Mechanics:
--   tf_lead_from_inbound_sms creates the lead, deduped hard: no lead is
--   created if the phone matches a customer, a technician, or a lead that is
--   not terminally closed. The answering-service intake shape is recognised
--   and the LEAD carries the CALLER's details parsed from the payload, not
--   the answering service's relay number.
--   tf_page_inbound_sms calls it for unknown senders, so the text path needs
--   no edge deploy. quo-webhook v24 adds the one call for the media path.

create or replace function public.tf_lead_from_inbound_sms(
  p_company_id uuid,
  p_from       text,
  p_body       text default null)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $fn$
declare
  v_phone   text;
  v_name    text;
  v_addr    text;
  v_desc    text;
  v_id      uuid;
  v_src     uuid;
  v_intake  boolean;
begin
  if auth.uid() is not null and not public.user_is_internal_staff(p_company_id) then
    raise exception 'not_authorized';
  end if;

  -- The answering service relays intakes from its own number; the lead must
  -- carry the caller, not the relay.
  v_intake := coalesce(p_body,'') ~* 'Emergency[[:space:]]*Y[[:space:]]*or[[:space:]]*N[[:space:]]*:';
  if v_intake then
    v_phone := public.tf_contact_normalize(public.tf_intake_field(p_body, 'Main Phone'), 'phone');
    v_name  := btrim(public.tf_intake_field(p_body, 'First Name') || ' ' || public.tf_intake_field(p_body, 'Last Name'));
    v_addr  := btrim(concat_ws(', ',
                 nullif(public.tf_intake_field(p_body, 'Street Address'), ''),
                 nullif(public.tf_intake_field(p_body, 'City'), ''),
                 nullif(public.tf_intake_field(p_body, 'State'), '')));
    v_desc  := coalesce(
                 nullif(public.tf_intake_field(p_body, 'Nature of Emergency'), ''),
                 nullif(public.tf_intake_field(p_body, 'Service Description'), ''),
                 nullif(public.tf_intake_field(p_body, 'Agent Notes'), ''),
                 'Answering service intake');
  else
    v_phone := public.tf_contact_normalize(p_from, 'phone');
    v_name  := null;
    v_addr  := null;
    v_desc  := coalesce(nullif(left(btrim(coalesce(p_body,'')), 500), ''), 'Texted the business line');
  end if;

  if v_phone is null then
    return jsonb_build_object('created', false, 'reason', 'no_usable_phone');
  end if;

  -- Dedupe, hardest gate first. A customer is not a lead.
  if exists (select 1 from public.customers cu
              where cu.company_id = p_company_id and cu.deleted_at is null
                and regexp_replace(coalesce(cu.phone,''), '\D', '', 'g')
                    like '%' || right(regexp_replace(v_phone, '\D', '', 'g'), 10)) then
    return jsonb_build_object('created', false, 'reason', 'customer');
  end if;
  if exists (select 1 from public.technicians t
              where regexp_replace(coalesce(t.phone,''), '\D', '', 'g')
                    like '%' || right(regexp_replace(v_phone, '\D', '', 'g'), 10)) then
    return jsonb_build_object('created', false, 'reason', 'technician');
  end if;
  select l.id into v_id from public.leads l
   where l.company_id = p_company_id and l.deleted_at is null
     and l.status not in ('won','lost','invalid','spam','duplicate','refunded','closed')
     and regexp_replace(coalesce(l.phone,''), '\D', '', 'g')
         like '%' || right(regexp_replace(v_phone, '\D', '', 'g'), 10)
   limit 1;
  if v_id is not null then
    return jsonb_build_object('created', false, 'reason', 'open_lead_exists', 'lead_id', v_id);
  end if;

  select s.id into v_src from public.lead_sources s
   where s.name = 'SMS Text' order by s.created_at limit 1;

  insert into public.leads
    (company_id, source_id, channel, status, phone, contact_name, address,
     service_description, meta)
  values
    (p_company_id, v_src, 'sms', 'new', v_phone,
     nullif(v_name,''), nullif(v_addr,''),
     v_desc,
     jsonb_build_object('origin', case when v_intake then 'answering_service_intake' else 'sms_front_door' end,
                        'created_by_fn', 'tf_lead_from_inbound_sms', 'reviewed_in', 'm343'))
  returning id into v_id;

  return jsonb_build_object('created', true, 'lead_id', v_id,
                            'kind', case when v_intake then 'answering_service_intake' else 'sms_front_door' end);
end;
$fn$;

-- The text path: paging an unknown sender now also records them.
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
  v_lead jsonb := null;
  v_et   text := p_entity_type;
  v_ei   uuid := p_entity_id;
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

  -- m343. A sender who is nobody's customer becomes a lead before the page
  -- goes out, so the page can deep-link to the lead it is about. Creation is
  -- deduped inside tf_lead_from_inbound_sms; a repeat texter reuses their
  -- open lead. Failure to create a lead must never cost the page itself.
  begin
    if not exists (select 1 from public.customers cu
                    where cu.company_id = p_company_id and cu.deleted_at is null
                      and regexp_replace(coalesce(cu.phone,''), '\D', '', 'g')
                          like '%' || right(regexp_replace(coalesce(p_from,''), '\D', '', 'g'), 10)) then
      v_lead := public.tf_lead_from_inbound_sms(p_company_id, p_from, p_body);
      if coalesce((v_lead->>'created')::boolean, false)
         or v_lead->>'reason' = 'open_lead_exists' then
        v_et := coalesce(v_et, 'leads');
        v_ei := coalesce(v_ei, (v_lead->>'lead_id')::uuid);
      end if;
    end if;
  exception when others then
    v_lead := jsonb_build_object('created', false, 'reason', 'error: ' || left(sqlerrm, 200));
  end;

  -- 1500, not 280. The old truncation cut the answering-service payload off
  -- mid address, which is exactly the part a dispatcher needs. The renderer,
  -- not the transport, decides what a person finally sees.
  v_page := public.tf_page_staff(
              p_company_id, 'dispatch', v_key, v_sub,
              left(coalesce(nullif(btrim(coalesce(p_body, '')), ''), '(no text)'), 1500),
              v_et, v_ei);

  return jsonb_build_object('ok', true, 'event_key', v_key, 'subject', v_sub,
                            'lead', v_lead, 'page', v_page);
end;
$fn$;

-- Convention 33.
insert into public.tf_function_registry (proname, declared_kind, write_acknowledged, rationale)
values
  ('tf_lead_from_inbound_sms', 'write', true,
   'Inserts a leads row for an inbound SMS sender who matches no customer, no technician and no open lead. Recognises the answering-service intake shape and records the caller parsed from the payload rather than the relay number. Contacts nobody: the only write is the lead row. Executive decision m343.')
on conflict (proname) do update
  set declared_kind      = excluded.declared_kind,
      write_acknowledged = excluded.write_acknowledged,
      rationale          = excluded.rationale,
      updated_at         = now();

select public.tf_apply_grant_tier('tf_lead_from_inbound_sms', 'p_company_id uuid, p_from text, p_body text', 'admin',
  'Lead recorder for the inbound SMS front door. Operator and webhook surface only.');
select public.tf_apply_grant_tier('tf_page_inbound_sms', 'p_company_id uuid, p_from text, p_body text, p_entity_type text, p_entity_id uuid', 'admin',
  'Re-pinned after CREATE OR REPLACE in m343. Same tier as m335.');

comment on function public.tf_lead_from_inbound_sms(uuid, text, text) is
  'Creates a lead for an unknown inbound SMS sender, deduped against customers, technicians and open leads. Parses answering-service intakes so the lead carries the caller, not the relay number. Sends nothing.';
