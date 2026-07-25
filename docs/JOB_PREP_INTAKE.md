# Job Prep Intake — Guards, Reminder Ladder, and Expiry

Before a technician rolls, Transit & Flow texts the customer a link to confirm
their details and add photos of the work area. It is the highest-leverage
sixty seconds in the whole job lifecycle: it turns a dispatch into a prepared
dispatch, and it is the difference between one truck roll and two.

It is also the single most dangerous automation on the platform, because it is
the only one that reaches a real human being's phone without a person in the
loop. Everything below exists because of that asymmetry. A read model that
returns a wrong number embarrasses an operator. A send path that fires twice
texts a paying customer twice at 11pm.

## What was actually happening

Task #73 shipped branded job numbers in the prep message, and that half worked:
later messages read `Job TF-100053` where earlier ones read
`Job HCP-joba9d3296e1`. Grouping the live `communications` rows by job to
confirm it surfaced something else entirely.

**TF-100054 was texted twice, eighty-eight minutes apart.**

The per-job cooldown was thirty minutes. Eighty-eight is more than thirty, so
the second message was not a race, it was the guard failing to guard. Reading
`tf_send_intake` against the live `job_intake` rows turned one symptom into
seven defects.

## The seven defects

**D1 — the per-job cooldown was a permanent no-op.** The guard read
`sent_at > now() - interval '30 minutes'`, and the update wrote
`sent_at = coalesce(sent_at, now())`. That `coalesce` freezes `sent_at` at the
*first* send forever. Thirty-one minutes after the first message the guard was
false, and it stayed false for the rest of time. Every resend after the first
half hour was completely unguarded, permanently, for every job on the platform.

The repair is a second column. `sent_at` now means the first contact and never
moves; `last_sent_at` is the cooldown and ladder key and moves on every attempt.
One column cannot be both the funnel origin and the rate limiter.

**D2 — a resend regressed the funnel.** The update set `status = 'sent'`
unconditionally, so a customer who had *opened* the intake link was silently
rolled back to *sent*. That is not a cosmetic bug: `opened` is the signal that
the outreach worked, and overwriting it destroys the only evidence that it did.
Proven from live data rather than inferred: TF-100054 sat at status `sent` with
`reminder_count` 0 after two confirmed sends, an end state reachable only if the
row was `opened` at the moment of the second send.

**D3 — `reminder_count` counted nothing.** Its case expression branched on
`status`, which D2 had already made unreliable, and it read the OLD row value
anyway. In PL/pgSQL an unqualified column reference on the right-hand side of a
`SET` clause reads the pre-update row, which is the mechanism behind D1, D2 and
D3 alike. The counter is now driven by `sent_at is not null`, a fact no other
clause in the statement mutates.

**D4 — the per-customer throttle compared raw strings.** It tested
`to_number = customers.phone`. `tf-omni-send` writes E.164; customers are
stored nationally. A prep message sent through any other worker was invisible to
the throttle.

**D5 — nothing capped lifetime contact.** No counter bounded how many times one
customer could be texted about one job. The only thing standing between a
customer and unlimited messages was a cooldown that D1 had already disabled.

**D6 — the function lied about sending.** Credentials were fetched *after* the
intake row was created, and the HTTP call sat behind
`if v_key is not null and v_from is not null`. With SMS unconfigured the
function created state, marked the intake `sent`, returned `sent: true`, and
transmitted nothing. The operator sees a contacted customer who was never
contacted, which is worse than an error, because an error gets fixed.

**D7 — the D4 fix did not actually fix D4.** Found by driving migration 216
against live data, which is the entire argument for the discipline. Migration
216 normalized both sides to digits and compared them whole. But E.164
`+16145550142` normalizes to eleven digits and `(614) 555-0142` to ten, so the
same human being still never matched. The guard was rewritten specifically to
see cross-worker messages and still could not see a single one.

Phone identity on this platform is the **trailing ten digits**. Everything
ahead of that, country code, punctuation, spacing, is formatting.
`tf_create_lead` already used `right(..., 10)`; `tf_send_intake` had quietly
invented a second convention. Migration 218 restores one.

## The guard ladder

Nine gates, evaluated in this order. The order is load-bearing: cheap and
absolute checks come before expensive and conditional ones, and nothing that
mutates state runs before everything that can refuse.

| # | Guard | Returns | Why here |
|---|-------|---------|----------|
| 1 | `job_not_found` | `ok:false` | Soft-deleted or unknown job |
| 2 | `no_customer` | `ok:false` | Customer missing or soft-deleted |
| 3 | `no_customer_phone` | `ok:false` | Fewer than ten digits is not a phone number |
| 4 | `do_not_service` | `ok:false` | An absolute instruction, checked before any throttle can be argued with |
| 5 | `max_sends_reached` | `ok:true, throttled` | Lifetime cap: one initial plus two reminders |
| 6 | `recently_sent` | `ok:true, throttled` | 30 minute cooldown keyed on `last_sent_at` |
| 7 | `recent_customer_prep` | `ok:true, throttled` | Cross-worker throttle on trailing-ten digits |
| 8 | `sms_not_configured` | `ok:false` | Refuse to claim a send we cannot make |
| 9 | send | `ok:true, sent` | Only reachable past all eight |

Throttles return `ok:true` with `throttled:true`; refusals return `ok:false`.
A caller can therefore distinguish "correctly declined" from "broken" without
string-matching a reason code.

**Credentials resolve at gate 8, before any state exists.** No intake row, no
`communications` row, no status change. If the platform cannot text, the
platform says so and leaves the record exactly as it found it.

## The reminder ladder

Bounded, quiet, and self-terminating. `tf_intake_sweep` runs every three
minutes and does three things in a fixed order.

**Expiry runs first, and runs even when sending is disabled.** An intake is
expired when its job is soft-deleted, when the scheduled start is more than a
day in the past, or when an unscheduled intake is older than fourteen days.
Garbage collection is not a feature of sending; it is a property of the data,
so it must not be gated behind the send flag.

**Quiet hours, 9am to 7pm America/New_York.** Outside the window the sweep
returns `{"skipped":"quiet_hours"}` and sends nothing.

**Two passes.** First contact for jobs with no intake row. Then reminders for
intakes that are `sent` or `opened`, under two reminders, last touched more than
twenty hours ago, on a job that is still at least two hours out, for a customer
with a phone who is not marked do-not-service. Both passes are capped at 25 per
run and reminders are ordered oldest-first, so a backlog drains fairly instead
of starving the customers who have waited longest.

Three messages, then silence. A customer who ignores three texts has answered.

**Automation respects quiet hours. A human operator calling `tf_send_intake`
directly does not**, because that is a deliberate act by someone who knows the
job and the customer. Automation first, human override second.

## Verified live

Every guard was driven against a hermetic fixture on the reserved fictional
number `(614) 555-0142`, with the `job_prep` automation flag off, and the
fixture destroyed afterward.

| Guard | Result |
|-------|--------|
| `job_not_found` | zero UUID → `{"ok":false,"reason":"job_not_found"}` |
| `no_customer` | customer soft-deleted → `{"ok":false,"reason":"no_customer"}` |
| `no_customer_phone` | phone `555` → `{"ok":false,"reason":"no_customer_phone"}` |
| `do_not_service` | flag set → `{"ok":false,"reason":"do_not_service"}` |
| `max_sends_reached` | `reminder_count` 2 → `throttled`, `total_sends: 3` |
| `recently_sent` | `last_sent_at` 2 min old → `throttled`, returns `last_sent_at` |
| `recent_customer_prep` | E.164 message vs national customer → `throttled` |
| `sms_not_configured` | tenant with no credentials → `ok:false`, **0 intake rows created, 0 communications rows written** |

D7 was proven before it was fixed, by evaluating both predicates side by side
against the live rows: `cust_digits 6145550142`, `msg_digits 16145550142`,
shipped predicate **false**, trailing-ten predicate **true**. Fix applied, guard
re-driven, `recent_customer_prep` now fires.

D2 and D3 were verified by executing the shipped `UPDATE` statement verbatim
against the fixture row, which tests the real semantics with no HTTP and no SMS:

- An `opened` intake taking reminder 1 → status stays **`opened`**,
  `reminder_count` **0 → 1**, `sent_at` preserved.
- A never-sent intake taking its first message → status **`sent`**,
  `reminder_count` stays **0**, `sent_at` stamped.

**Across all eight refused and throttled calls, zero `communications` rows were
written and `reminder_count` never moved.** The prep-message count was 6 before
the drill and 6 after. No customer was contacted at any point.

Post-migration security scan: **0 gaps on all four axes**
(`rls_disabled_tables`, `secdef_no_searchpath`, `anon_secdef_nonpublic`,
`rls_enabled_no_policy`).

## Indexes

| Index | Serves |
|-------|--------|
| `idx_job_intake_reminder_scan (last_sent_at) where status in ('sent','opened')` | The reminder pass, which scans only live intakes |
| `idx_job_intake_job_id (job_id)` | Intake lookup on every send |
| `idx_communications_prep_dest_digits (company_id, right(digits,10), created_at desc) where kind = 'job_prep_request'` | The cross-worker throttle, indexed on the expression the guard actually filters on |

The last one matters: an index on the raw `to_number` column would never be used
by a predicate that normalizes it. Index the expression, not the column.

## Security

`tf_send_intake` and `tf_intake_sweep` are `SECURITY DEFINER` with
`search_path` pinned to `public, extensions`. `tf_send_intake` is revoked from
`public` and `anon`, executable by `authenticated` and `service_role`, because
an operator can legitimately trigger a prep text for a job in front of them.
`tf_intake_sweep` is `service_role` only. Nothing that reaches a customer's
phone is reachable by an anonymous caller.

## Operating it

The automation flag lives at
`integration_settings.config -> 'automations' ->> 'job_prep'` on provider
`openphone`, and is currently **false**. Turning it on starts first contact and
the reminder ladder on the next three-minute sweep. Expiry runs regardless.

Set `config ->> 'intake_autosend_since'` to bound first contact to jobs created
after a cutover timestamp, so enabling the automation never back-texts the
existing book.

Migrations 216, 217, 218.
