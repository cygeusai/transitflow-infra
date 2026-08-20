-- m344_backfill_front_door_leads
--
-- One-time execution of the m343 decision against the thirteen senders whose
-- 39 photos are stranded in the unfiled prefix. Derivation is DATA, not a
-- typed list: the senders are recomputed here with the same nearest-message
-- logic the matcher uses, so a sender who has since become a customer or
-- acquired a lead is skipped by the function's own dedupe rather than by this
-- migration's memory of last hour.
--
-- Each lead's service_description is the sender's own most recent substantive
-- words on the thread, so a dispatcher opening the lead sees what the person
-- actually asked for. Nothing is sent to anyone.

do $$
declare
  v_company constant uuid := 'ff000000-0000-4000-b000-000000000001';
  r         record;
  v_res     jsonb;
  v_created int := 0;
  v_skipped int := 0;
begin
  for r in
    with f as (
      select o.id, o.name, o.created_at
        from storage.objects o
       where o.bucket_id = 'job-photos'
         and o.name like v_company::text || '/unfiled/%'
         and not exists (select 1 from public.job_attachments a
                          where a.company_id = v_company and a.storage_path = o.name
                            and a.deleted_at is null)
    ),
    nearest as (
      select f.id as file_id, c.from_number, c.customer_id
        from f
        join lateral (
          select c.* from public.communications c
           where c.company_id = v_company
             and c.direction = 'inbound' and c.channel = 'sms'
             and coalesce((c.meta->>'media_count')::int, 0) > 0
             and c.created_at between f.created_at - interval '2 minutes'
                                  and f.created_at + interval '2 minutes'
           order by abs(extract(epoch from (f.created_at - c.created_at)))
           limit 1
        ) c on true
    ),
    unknowns as (
      select distinct n.from_number
        from nearest n
       where n.customer_id is null
         and n.from_number is not null
         and not exists (select 1 from public.customers cu
                          where cu.company_id = v_company and cu.deleted_at is null
                            and regexp_replace(coalesce(cu.phone,''), '\D', '', 'g')
                                like '%' || right(regexp_replace(n.from_number, '\D', '', 'g'), 10))
    )
    select u.from_number,
           (select i.body from public.communications i
             where i.company_id = v_company and i.direction = 'inbound'
               and i.from_number = u.from_number
               and length(btrim(coalesce(i.body,''))) > 0
             order by i.created_at desc limit 1) as last_words
      from unknowns u
  loop
    v_res := public.tf_lead_from_inbound_sms(v_company, r.from_number,
               coalesce(r.last_words, 'Texted photos of their problem to the business line.'));
    if coalesce((v_res->>'created')::boolean, false) then
      v_created := v_created + 1;
    else
      v_skipped := v_skipped + 1;
      raise notice 'm344 skipped %: %', r.from_number, v_res->>'reason';
    end if;
  end loop;

  raise notice 'm344 backfill complete: % leads created, % senders skipped by dedupe', v_created, v_skipped;

  -- The decision said thirteen. If the world changed between measurement and
  -- execution, that is fine, but silence is not: anything other than 13
  -- creations must be visible in the migration output above.
end $$;
