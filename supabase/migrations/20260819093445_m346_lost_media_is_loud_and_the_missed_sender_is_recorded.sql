-- m346_lost_media_is_loud_and_the_missed_sender_is_recorded
--
-- Launch-readiness sweep, 19 August. Assertion A21 was red: on 17 August at
-- 22:17 UTC one sender texted two photos, the provider's media links could
-- not be fetched, and every early exit in quo-webhook's media loop was a
-- silent loss: nothing landed in storage, no counter moved, no page fired,
-- no lead was created, and the customer was still told their photo was being
-- matched. The assertion caught it two days later, which is exactly why the
-- assertion exists. quo-webhook v25 fixes the class: failed receives count as
-- LOST, page dispatch, and the customer is asked to resend instead of being
-- promised follow-through on a photo that does not exist.
--
-- This migration does the database half:
--   1. Routing and severity for media_receive_failed, so the page has a
--      reviewed destination before it can first fire (A19).
--   2. The missed sender becomes a lead through the validated function, which
--      is what returns A21 to green: honestly, by recording the person we
--      missed, not by widening the assertion.

insert into public.tf_notification_severity (event_key, severity)
values ('media_receive_failed', 'normal')
on conflict (event_key) do update set severity = excluded.severity;

insert into public.tf_notification_routing
  (event_key, audience, slack_channel_id, channel_name, action_required,
   escalate_after, cooldown_seconds, template_key, rationale, reviewed_in)
values
  ('media_receive_failed', 'field', 'C0AEUTNAU4V', '#field-ops', 'act',
   1, 0, 'media_unfiled',
   'A customer attachment could not be downloaded from the provider or written to storage, so it exists nowhere in the Hub. The customer has been asked to resend; dispatch needs to know a resend is pending so silence from the customer gets a follow-up call. First occurrence pages, no cooldown, each one is a different person.',
   'm346')
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

-- The person the 17 August loss dropped. Created through the validated
-- function so every dedupe gate applies; if they have since become a customer
-- or a lead, this is a recorded no-op, and the raise makes either outcome
-- visible in the migration output rather than silent.
do $$
declare v jsonb;
begin
  v := public.tf_lead_from_inbound_sms(
         'ff000000-0000-4000-b000-000000000001', '+16149051003',
         'Texted two photos on 17 August that failed to download from the provider. Nothing was stored; the sender was never recorded until this backfill. Ask them to resend.');
  raise notice 'm346 backfill for the 17 August sender: %', v::text;
end $$;
