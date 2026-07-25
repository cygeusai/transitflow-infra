# Automation Arming

**Transit & Flow — how a customer-reaching automation gets turned on, and what stops it from being turned on carelessly.**

Status at time of writing: 13 automations registered, **0 armed**, verified after migration 252.
Source of truth: `public.tf_automation_registry`, `public.integration_settings` (provider `openphone`, `config->'automations'`), and `public.automation_arm_log`.

---

## 1. Why this document exists

An automation flag on this platform is a single boolean in a JSONB column. Flipping it costs one keystroke. What it buys is a cron job that starts contacting real customers by SMS from the Transit & Flow number, under the Transit & Flow brand, at the cadence the sweep defines, against whatever rows happen to match its predicate.

The distance between those two facts is the entire subject of this document.

The specific failure this system is built to prevent is not "someone armed the wrong automation." It is "someone armed the right automation and it reached back further than anyone expected." A sweep whose predicate has no start bound does not send a few messages. It sends one to every historical row that has ever matched, in the first tick, before anybody can read the log. Migration 250 measured the live backlogs: `marketplace_dispatch` at 19 rows, `job_prep` at 17, `review_requests` at 7. Those are not hypothetical numbers, they are what would have gone out.

Migration 249 measured something worse. Three jobs existed outside the production tenant, and all three matched `tf_review_request_sweep`'s candidate predicate, because that sweep scanned `public.jobs` with no `company_id` filter. Arming `review_requests` would have texted three customers belonging to a different tenant from the production Quo number under the Transit & Flow brand. That is a brand incident and an access-control incident in the same message.

---

## 2. The registry

`public.tf_automation_registry` holds one row per automation. It is the table the checkers read, per the standing convention that conventions live in tables rather than compiled into function bodies.

| Column | Meaning |
| --- | --- |
| `automation_key` | The key inside `integration_settings.config->'automations'`. Primary identity. |
| `sweep_function` | The `public.*` function the cron calls. Null when the work happens in an edge function. |
| `cutover_path` | JSONB path to the timestamp that pins the sweep's start. Null when there is no cutover key. |
| `blast_radius_sql` | A single-value SQL predicate that counts what the next tick would touch. |
| `customer_reaching` | Whether a tick can produce an outbound message to a customer. |
| `bounded_by` | How the sweep is bounded. One of four values, CHECK-constrained. See section 3. |
| `notes` | The operator-facing explanation, projected into `tf_automation_readiness()`. See section 7. |

### The thirteen

| Key | Sweep | Bounded by | Customer reaching | Cutover key |
| --- | --- | --- | --- | --- |
| `ai_booking` | `tf_ai_booking_kickoff_sweep` | cutover | yes | `ai_agent -> booking_since` |
| `appt_reminders` | `tf_engagement_sweep` | natural_window | yes | none |
| `cx_first_response` | `tf_cx_first_response_sweep` | cutover | yes | `cx_first_response_since` |
| `cx_sequences` | `tf_cx_sequence_sweep` | cutover | yes | `cx_sequences_since` |
| `estimate_followups` | `tf_engagement_sweep` | natural_window | yes | none |
| `eta_reminders` | `tf_eta_reminder_sweep` | natural_window | yes | none |
| `job_prep` | `tf_intake_sweep` | cutover | yes | `intake_autosend_since` |
| `late_penalty_enforcement` | `tf_late_penalty_sweep` | **unbounded** | no | none |
| `live_connect` | edge function | edge_function | yes | none |
| `marketplace_dispatch` | `tf_offer_sweep` | cutover | no | `marketplace_dispatch_since` |
| `missed_call_textback` | edge function | edge_function | yes | none |
| `push_estimates_to_hcp` | edge function | edge_function | no | none |
| `review_requests` | `tf_review_request_sweep` | cutover | yes | `review_requests_since` |

Nine of the thirteen can reach a customer. That is the number that matters when reading anything else on this page.

---

## 3. The bounding model

`bounded_by` is a real column with a closed CHECK constraint, added in migration 250. It answers one question: **if this flag flips right now, how far back does the first tick reach?**

**`cutover`** — a config key pins the start. The sweep only considers rows newer than that timestamp, and `tf_automation_arm` moves the timestamp to `now()` in the same statement that sets the flag. This is the safest shape: arming is self-limiting, because the cutover cannot lag behind the flag.

**`natural_window`** — the predicate carries a moving time bound of its own. An appointment reminder only fires for appointments in the near future, so history is structurally excluded whether or not anyone thought about it. No cutover key is needed and none exists.

**`unbounded`** — neither a cutover key nor a moving window. The first tick processes the entire historical backlog. Exactly one automation is in this class, `late_penalty_enforcement`, and its measured backlog is currently 0. The guard exists for the day it is not.

**`edge_function`** — the work happens outside Postgres, in a Deno edge function reacting to a webhook. SQL cannot size the blast radius, so `blast_radius_sql` is null by design and readiness reports `blocked_no_predicate`. This is an honest null, not a gap: there is nothing in the database to count. Three automations are in this class.

---

## 4. The blast-radius predicate contract

`tf_automation_blast_radius(key)` executes the registered predicate as:

```sql
execute v_reg.blast_radius_sql into v_count using coalesce(v_since, now()), v_company;
```

So `$1` is the cutover timestamptz and `$2` is the company uuid.

**Every predicate must reference both parameters.** PL/pgSQL counts the placeholders it finds in the statement text and raises `too many parameters specified for EXECUTE` if the count is short. This bites specifically on `natural_window` and `unbounded` sweeps, where there is no cutover to compare against and the natural instinct is to leave `$1` out.

The fix is a visible tautology rather than a silent omission:

```sql
and ($1::timestamptz is not null or $1::timestamptz is null)
```

It reads as deliberate, it costs nothing, and it documents at the point of use that this predicate is not cutover-bounded. A reviewer who sees it knows to check `bounded_by`.

Every predicate must also filter on `$2`. A blast-radius count that ignores the tenant is not a count of what the production tenant would send.

---

## 5. The arming sequence

`public.tf_automation_arm(p_key text, p_enable boolean)` is the only sanctioned way to change an automation flag. A direct `update` on `integration_settings` is detected as out-of-band arming and treated as an incident.

The order of operations when arming:

1. **Authorization.** `user_is_internal_staff(v_company)` or `raise exception 'not authorized to arm automations'`. Arming is a privileged mutation, so it refuses loudly rather than by return value.
2. **Explicit intent.** `p_enable` null is refused. There is no "toggle."
3. **Known key.** Unregistered keys are refused by name.
4. **Settings exist.** No `openphone` row for the production company is a hard stop.
5. **Predicate registered.** Arming with `blast_radius_sql` null is refused, because the number of customers the first tick would contact is unknown.
6. **Backlog check for unbounded automations.** An `unbounded` automation with a non-zero radius is refused, with the count in the message.
7. **Flag and cutover move together.** One `update` statement sets the flag and, where `cutover_path` is non-null, sets the cutover to `now()`. It is not possible to arm and leave the cutover stale, because there is no code path that does one without the other.
8. **Audit.** A row lands in `automation_arm_log` with previous and new flag, previous and new cutover, blast radius at the moment of arming, and `auth.uid()` as actor.

Disarming skips steps 5 and 6. Turning something off is never blocked.

### The refusal classes

| Refusal | Trigger | What to do |
| --- | --- | --- |
| `not authorized to arm automations` | Caller is not internal staff | Arm from a staff session, not a service call |
| `p_enable must be explicitly true or false` | Null passed | Say what you mean |
| `unknown automation key: <k>` | Key not in the registry | Register it first, with a predicate and a bounding classification |
| `no blast-radius predicate is registered` | `blast_radius_sql` is null | Transcribe the sweep's candidate predicate into the registry. Expected and permanent for the three `edge_function` automations |
| `it is unbounded ... and N historical rows are waiting` | `bounded_by = 'unbounded'` and radius > 0 | Clear the backlog, or give the sweep a cutover key. Do not work around it |

Every refusal message ends with the registry note, so the operator gets the explanation at the moment of refusal rather than having to go look one up.

---

## 6. Reading readiness before you arm

```sql
select public.tf_automation_readiness();
```

Returns one entry per automation with `enabled`, `verdict`, `blast_radius`, `bounded_by`, `cutover_value`, `cutover_age_hours`, `sweep_function`, `customer_reaching`, and `note`.

Verdicts:

- **`ready`** — predicate registered, radius sized, cutover current or not needed. Safe to arm subject to business judgement.
- **`stale_cutover`** — the cutover timestamp is old, so the backlog between then and now is what the first tick would process. `tf_automation_arm` moves the cutover for you when it arms, so this is informational rather than blocking, but the radius shown is the pre-arm number and is worth reading.
- **`blocked_unbounded_backlog`** — `tf_automation_arm` will refuse. Fix the backlog or the bounding.
- **`blocked_no_predicate`** — no predicate to size with. For the three edge-function automations this is permanent and expected.
- **`blocked_no_predicate_low_risk`** — same, but the automation is not customer-reaching.

Current live picture, all thirteen disarmed:

| Key | Verdict | Blast radius |
| --- | --- | --- |
| `ai_booking` | stale_cutover | 0 |
| `appt_reminders` | ready | 1 |
| `cx_first_response` | ready | 0 |
| `cx_sequences` | ready | 0 |
| `estimate_followups` | ready | 0 |
| `eta_reminders` | ready | 0 |
| `job_prep` | stale_cutover | 17 |
| `late_penalty_enforcement` | ready | 0 |
| `live_connect` | blocked_no_predicate | null |
| `marketplace_dispatch` | stale_cutover | 19 |
| `missed_call_textback` | blocked_no_predicate | null |
| `push_estimates_to_hcp` | blocked_no_predicate_low_risk | null |
| `review_requests` | stale_cutover | 7 |

---

## 7. The note is part of the change

`tf_automation_registry.notes` is projected straight into the readiness payload and into every `tf_automation_arm` refusal message. It is not documentation of the system, it is the operator's decision input at the moment of decision.

Which means it can be wrong in a way that no other control catches. Every other control on this platform checks the system. None of them read the prose. Migration 249 added company predicates to three sweeps and did not update the notes describing those sweeps, so for two migrations the registry told operators a guard was missing that was in fact present. A note that says a guard is absent when it works teaches an operator to distrust a control that functions. A note that says a bound exists when it does not authorises a send nobody sized. Same defect, opposite direction, and the second one reaches customers.

`public.tf_automation_note_drift()` compares every note against the live catalog on four rules:

1. A note may not claim a blast-radius predicate is missing when one is registered.
2. A note may not claim a cutover key is absent when `cutover_path` is set.
3. A note may not claim its sweep lacks a company predicate when `pg_get_functiondef` shows one present.
4. `bounded_by` must agree structurally with `sweep_function`: `edge_function` implies no sweep, everything else implies a sweep.

Control **`CM-NOTEDRIFT-022`** fails when `drift_count > 0`. Auto-ticket key **`safety:note_drift`** files at priority 2 and closes itself when the drift clears. The control was observed going to `failing` under induced drift and back to `passing` after cleanup, inside migration 252's transaction, per the house rule that a checker never observed catching anything is not a checker.

**The rule this produces:** a migration that changes a sweep, a predicate, or a bounding classification rewrites the matching note in the same transaction. Not in a follow-up. Not in a docs commit.

---

## 8. Runbook

### Before arming anything

```sql
select public.tf_automation_readiness();
select public.tf_automation_note_drift();
select public.tf_automation_blast_radius('<key>');
```

Read the note. Read the radius. If the radius is larger than the number of customers you are willing to contact in the next ten minutes, do not arm.

### Arm

```sql
select public.tf_automation_arm('<key>', true);
```

From a staff session. The return value carries `blast_radius_at_arm`, which is the number to quote if anyone asks afterwards how many were contacted.

### Disarm

```sql
select public.tf_automation_arm('<key>', false);
```

Never blocked, never delayed.

### Audit what happened

```sql
select automation_key, action, previous_enabled, new_enabled,
       previous_cutover, new_cutover, blast_radius, actor, created_at
  from public.automation_arm_log
 order by created_at desc limit 50;
```

### Confirm nothing is armed

```sql
select r.automation_key,
       coalesce((s.config->'automations'->>r.automation_key)::boolean, false) as enabled
  from public.tf_automation_registry r
  join public.integration_settings s
    on s.company_id = 'ff000000-0000-4000-b000-000000000001'
   and s.provider = 'openphone'
 order by 1;
```

Every migration from 249 onward ends by asserting this returns thirteen `false` values.

---

## 9. Adding a fourteenth automation

The five-part convention shape applies. A convention that is not all five parts is a convention someone will violate without noticing.

1. **A row in the table.** `tf_automation_registry` with `automation_key`, `sweep_function`, `cutover_path`, `blast_radius_sql` referencing both `$1` and `$2`, `customer_reaching`, `bounded_by`, and a `notes` string that describes the actual behaviour.
2. **A function that applies the rule.** The sweep itself, carrying `company_id = v_company` on every table it scans and on the `integration_settings` read that supplies its enable flag, and reading its flag with `coalesce(..., false)` so that deleting the config key disarms rather than arms.
3. **A checker.** `tf_automation_note_drift` and `tf_automation_readiness` pick up new rows automatically. If the automation introduces a new failure mode, it needs its own checker.
4. **A control.** Only if the new failure mode is not already covered by `CM-NOTEDRIFT-022` or the existing arming controls.
5. **An auto-ticket key.** Same condition.

Then declare the sweep in `tf_function_registry` and `tf_function_grant_tiers` **in the same migration**, and prove the guard refusing before the migration commits.

---

## 10. Related

- [`README.md`](./README.md) — the conventions list, including the sweep tenant-scoping rule and the `$1`/`$2` predicate contract
- [`PLATFORM_KNOWLEDGE_BASE.md`](./PLATFORM_KNOWLEDGE_BASE.md) — full platform inventory and verification log
- [`FUNCTION_GRANT_TIERS.md`](./FUNCTION_GRANT_TIERS.md) — the three-tier EXECUTE model these functions are granted under
- [`IT_GOVERNANCE_GRC.md`](./IT_GOVERNANCE_GRC.md) — the control register `CM-NOTEDRIFT-022` lives in
- [`CLOSED_LOOP_AUTOTICKETING.md`](./CLOSED_LOOP_AUTOTICKETING.md) — how `safety:note_drift` files and closes
- `supabase/migrations/20260725113932_sweep_tenant_scoping_and_ai_booking_guard.sql`
- `supabase/migrations/20260725115002_automation_blast_radius_transcription_and_bounding_model.sql`
- `supabase/migrations/20260725115531_automation_registry_note_drift_checker.sql`
- `supabase/migrations/20260725120338_note_drift_control_and_register_reconciliation.sql`
