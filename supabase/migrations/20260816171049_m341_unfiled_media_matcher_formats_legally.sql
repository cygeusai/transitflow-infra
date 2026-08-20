-- m341_unfiled_media_matcher_formats_legally
--
-- m340 shipped this function with C-style %.1f specifiers in format(), which
-- PostgreSQL's format() does not implement: it knows %s, %I and %L only, so
-- every invocation that reached a job-candidate branch raised 22023 and the
-- matcher could not complete a dry run. The operator agent caught it at the
-- review gate, before the writing path was ever reached, which is the gate
-- doing exactly its job. Same function, same rules; distances are now
-- rendered with round(x::numeric, 1)::text through plain %s.
--
-- The backlog behind the message the owner flagged: 87 texted-in files sit in
-- the unfiled storage prefix with no job_attachments row pointing at them.
-- quo-webhook v23 stopped the backlog growing silently; this is the tool that
-- works it down.
--
-- MEASURED FIRST, BUILT SECOND. Before this function was written, the match
-- ceiling was measured read-only against all 87 files:
--   87 of 87 pair to exactly one inbound media message within 4 seconds.
--   48 resolve to a customer; 31 of those customers have at least one job.
--   12 files have ONE job within 7 days of the send with no rival inside a
--      7 day margin. Those attach.
--   19 are close calls, two candidate jobs inside the margin. A human picks.
--   17 belong to a customer who has no job at all. A human decides whether
--      to create one.
--   39 come from 13 senders who are in neither customers nor leads. Reading
--      their conversations shows prospects, customer relatives and one job
--      applicant, mid-conversation with staff. That is intake work, not
--      filing work.
-- So the honest yield is 12 automatic attachments and a complete, reasoned
-- worklist for the other 75. The function returns that worklist either way.
--
-- SAFETY MODEL
--   Dry run by default. p_dry_run => false is the only writing path.
--   Attach in place: job_attachments.storage_path points at the existing
--     unfiled object. storage.objects is never updated, renamed or moved,
--     because the storage API owns those keys.
--   Additive and reversible: the only write is an insert with
--     is_customer_visible = false and a caption stating exactly how the match
--     was made. Undo is deleting the row.
--   Idempotent: a file already referenced by any job_attachments row is
--     skipped, so a second run cannot double-attach.
--   Sends nothing: no SMS, no Slack, no notifications rows.

create or replace function public.tf_unfiled_media_match(p_dry_run boolean default true)
returns jsonb
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $fn$
declare
  v_company  constant uuid := 'ff000000-0000-4000-b000-000000000001';
  f          record;
  v_rows     jsonb := '[]'::jsonb;
  v_attached int := 0; v_close int := 0; v_no_job int := 0; v_unknown int := 0; v_skipped int := 0;
  v_msg      record;
  v_customer uuid;
  v_best     record;
  v_second   record;
  v_tier     text;
  v_detail   text;
  v_kind     public.attachment_kind;
begin
  if auth.uid() is not null and not public.user_is_internal_staff(v_company) then
    raise exception 'not_authorized';
  end if;

  for f in
    select o.id, o.name, o.created_at,
           o.metadata->>'mimetype' as mime,
           coalesce((o.metadata->>'size')::bigint, 0) as size_bytes
      from storage.objects o
     where o.bucket_id = 'job-photos'
       and o.name like v_company::text || '/unfiled/%'
     order by o.created_at
  loop
    -- Idempotence. Any existing reference, from this run or a human, wins.
    if exists (select 1 from public.job_attachments a
                where a.company_id = v_company and a.storage_path = f.name
                  and a.deleted_at is null) then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    -- The inbound message that carried this file. Measured worst gap is 4
    -- seconds; the window is 2 minutes and the NEAREST message wins.
    select c.id, c.from_number, c.customer_id, c.created_at, left(coalesce(c.body,''), 200) as body_head
      into v_msg
      from public.communications c
     where c.company_id = v_company
       and c.direction = 'inbound' and c.channel = 'sms'
       and coalesce((c.meta->>'media_count')::int, 0) > 0
       and c.created_at between f.created_at - interval '2 minutes'
                            and f.created_at + interval '2 minutes'
     order by abs(extract(epoch from (f.created_at - c.created_at)))
     limit 1;

    if v_msg.id is null then
      v_tier := 'unknown_sender'; v_detail := 'no inbound media message within 2 minutes of the upload';
      v_unknown := v_unknown + 1;
      v_rows := v_rows || jsonb_build_object('file', f.name, 'tier', v_tier, 'detail', v_detail);
      continue;
    end if;

    -- Sender to customer: the message's own link first, then a phone match on
    -- the last ten digits.
    v_customer := v_msg.customer_id;
    if v_customer is null then
      select cu.id into v_customer
        from public.customers cu
       where cu.company_id = v_company and cu.deleted_at is null
         and regexp_replace(coalesce(cu.phone,''), '\D', '', 'g')
             like '%' || right(regexp_replace(coalesce(v_msg.from_number,''), '\D', '', 'g'), 10)
       limit 1;
    end if;

    if v_customer is null then
      v_tier := 'unknown_sender';
      v_detail := format('sender %s matches no customer; message begins: %s',
                         coalesce(v_msg.from_number,'(none)'), coalesce(nullif(v_msg.body_head,''),'(no text)'));
      v_unknown := v_unknown + 1;
      v_rows := v_rows || jsonb_build_object('file', f.name, 'tier', v_tier,
                  'sender', v_msg.from_number, 'detail', v_detail);
      continue;
    end if;

    -- Candidate jobs, ranked by distance in days from the send moment to the
    -- job's activity interval [created_at .. completed_at|scheduled_start].
    select j.id, j.job_number,
           greatest(extract(epoch from (j.created_at - v_msg.created_at)),
                    extract(epoch from (v_msg.created_at - coalesce(j.completed_at, j.scheduled_start, j.created_at))),
                    0) / 86400.0 as dist_days
      into v_best
      from public.jobs j
     where j.company_id = v_company and j.customer_id = v_customer and j.deleted_at is null
     order by 3 limit 1;

    if v_best.id is null then
      v_tier := 'customer_no_job';
      v_detail := format('sender %s is a known customer with no job on record', v_msg.from_number);
      v_no_job := v_no_job + 1;
      v_rows := v_rows || jsonb_build_object('file', f.name, 'tier', v_tier,
                  'sender', v_msg.from_number, 'customer_id', v_customer, 'detail', v_detail);
      continue;
    end if;

    select j.id, j.job_number,
           greatest(extract(epoch from (j.created_at - v_msg.created_at)),
                    extract(epoch from (v_msg.created_at - coalesce(j.completed_at, j.scheduled_start, j.created_at))),
                    0) / 86400.0 as dist_days
      into v_second
      from public.jobs j
     where j.company_id = v_company and j.customer_id = v_customer and j.deleted_at is null
       and j.id <> v_best.id
     order by 3 limit 1;

    -- The confidence rule, exactly as measured: the best job is within 7 days
    -- of the send AND any rival is at least 7 days further away.
    if v_best.dist_days <= 7
       and (v_second.id is null or v_second.dist_days - v_best.dist_days >= 7) then
      v_tier := 'attach';
      v_detail := format('%s at %s days%s', v_best.job_number, round(v_best.dist_days::numeric, 1)::text,
                         case when v_second.id is null then ', only job'
                              else format(', next candidate %s at %s days', v_second.job_number, round(v_second.dist_days::numeric, 1)::text) end);
      if not p_dry_run then
        v_kind := case
                    when coalesce(f.mime,'') like 'image/%' then 'photo'::public.attachment_kind
                    when coalesce(f.mime,'') like 'video/%' then 'video'::public.attachment_kind
                    when coalesce(f.mime,'') like '%pdf%'   then 'document'::public.attachment_kind
                    else 'other'::public.attachment_kind end;
        insert into public.job_attachments
          (company_id, job_id, kind, storage_path, file_name, mime_type,
           file_size_bytes, caption, taken_at, is_customer_visible)
        values
          (v_company, v_best.id, v_kind, f.name,
           regexp_replace(f.name, '^.*/', ''), f.mime, f.size_bytes,
           format('Texted in by %s on %s. Matched to %s by tf_unfiled_media_match (m340): nearest job at %s days, no rival within 7 days.',
                  coalesce(v_msg.from_number,'an unknown number'),
                  to_char(v_msg.created_at at time zone 'America/New_York', 'Mon DD, YYYY HH12:MI AM'),
                  v_best.job_number, round(v_best.dist_days::numeric, 1)::text),
           v_msg.created_at, false);
      end if;
      v_attached := v_attached + 1;
    else
      v_tier := 'close_call';
      v_detail := format('two candidates inside the margin: %s at %s days, %s at %s days',
                         v_best.job_number, round(v_best.dist_days::numeric, 1)::text,
                         coalesce(v_second.job_number,'(none)'), round(coalesce(v_second.dist_days, 0)::numeric, 1)::text);
      v_close := v_close + 1;
    end if;

    v_rows := v_rows || jsonb_build_object('file', f.name, 'tier', v_tier,
                'sender', v_msg.from_number, 'customer_id', v_customer,
                'job_id', case when v_tier = 'attach' then v_best.id end,
                'job_number', case when v_tier = 'attach' then v_best.job_number end,
                'detail', v_detail);
  end loop;

  return jsonb_build_object(
    'ok', true, 'dry_run', p_dry_run,
    'attached', v_attached, 'close_call', v_close, 'customer_no_job', v_no_job,
    'unknown_sender', v_unknown, 'already_filed_skipped', v_skipped,
    'note', case when p_dry_run
                 then 'Dry run. Nothing was written. The attach tier shows exactly what an execute run would insert.'
                 else 'Attachments inserted in place; storage objects untouched. Undo is deleting the job_attachments rows whose caption names this function.' end,
    'rows', v_rows);
end;
$fn$;

-- Convention 33.
insert into public.tf_function_registry (proname, declared_kind, write_acknowledged, rationale)
values
  ('tf_unfiled_media_match', 'write', true,
   'Inserts job_attachments rows for texted-in files stranded in the unfiled storage prefix, only when the sender resolves to a customer whose nearest job is within 7 days of the send and no rival job is within 7 days of that. Dry run by default, idempotent via a storage_path existence check, never touches storage.objects, never sends anything. Everything below the confidence bar is returned as a reasoned worklist for a human.')
on conflict (proname) do update
  set declared_kind      = excluded.declared_kind,
      write_acknowledged = excluded.write_acknowledged,
      rationale          = excluded.rationale,
      updated_at         = now();

select public.tf_apply_grant_tier('tf_unfiled_media_match', 'p_dry_run boolean', 'admin',
  'Backlog matcher over storage and job_attachments. Operator surface, not browser surface.');

comment on function public.tf_unfiled_media_match(boolean) is
  'Matches unfiled texted-in media to jobs. Dry run by default; p_dry_run => false inserts job_attachments rows in place for the confident tier only and returns the full worklist either way.';
