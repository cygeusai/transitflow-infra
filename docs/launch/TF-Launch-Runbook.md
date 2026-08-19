# Transit & Flow, launch-day runbook

## T minus 1 day
1. Confirm board green: suite 21/21, advisors 0 errors, cron 0 failures. (Standing hourly check does this; eyeball #information-technology for silence.)
2. Ops loads the pricebook (Gate 3). Verify: pricebook_items rows > 0 for the company.
3. Record lawful basis (Gate 1) with counsel sign-off, stored where compliance can point to it.

## Launch morning
1. From an authenticated staff session: arm Wave 1a, watch 30 minutes, arm Wave 1b.
   select public.tf_automation_arm('missed_call_textback', true);
   select public.tf_automation_arm('ai_booking', true);
2. Place one live test call to the main line from (614) 555-0142, hang up, confirm the text-back arrives and a lead is created.
3. Post the launch announcement email to the consented segment only.
4. Watch #field-ops and #information-technology for two hours. The system pages you; silence is health.

## Rollback, any step
- Disarm instantly: select public.tf_automation_arm('<key>', false);  (guarded, logged)
- Notification kill switch: update tf_drain_control set is_armed=false;  (in-app delivery continues)
- Edge function rollback: redeploy prior version from the repo mirror; every deployed version is byte-pinned in git.

## Escalation
- Emergency intake misroute: check A18 in the hourly suite output first; it walks the whole path.
- Anything red on the board pages #information-technology automatically with a plain-language message and a Hub link.

## Week 2, deliberately deferred
- Wave 2 arming (appt_reminders, review_requests) after 48 clean hours.
- ai-booking to Housecall Pro push wiring, after your one controlled HCP write authorization.
- A2P registration against transitflowgroup.com, unblocking the Twilio lane.
