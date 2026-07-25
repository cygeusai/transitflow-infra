# Transit & Flow — Platform Knowledge Base

The single troubleshooting reference for the Transit & Flow backend. Written to
be read at 2am by someone who did not build it.

State captured 2026-07-25 against Supabase project `kjooyhvynkzuvsixsutt` at
migration 231. Every number in this document was read out of the live database,
not remembered.

---

## How to use this document

Start at **The first ten minutes**. It tells you which single command to run and
how to read the answer. From there, **Symptoms** routes you by what you are
actually seeing, not by which subsystem you suspect. The reference sections at
the back exist so that when the runbook says "check the lane registry" you can
find out what a lane registry is without leaving the page.

Three rules govern everything below.

**The database is the source of truth.** Access control lives in RLS policies
and function guards, not in the frontend. If the Hub shows something a user
should not see, the defect is in a policy, and fixing the frontend hides it
rather than fixing it.

**A number that looks wrong is almost always a freshness problem, not a math
problem.** Check `last_synced_at` before you check the arithmetic. This has been
true every time so far.

**Verification means driving the thing, not reading it.** A migration that
applies cleanly has proved nothing. See *The house rules* for why this sentence
exists.

---

## The first ten minutes

Run this. It is the whole board in one call.

```sql
select public.tf_system_health(false);
```

It returns `overall` plus eleven components, each with `status` and a
human-readable `detail`. `overall` is `degraded` if any component is degraded.

The health check is deliberately fault-tolerant: each component is evaluated
inside its own exception guard, so a sub-check that raises turns *that one
component* red with a message like `"queue health unavailable"` rather than
erroring the whole board. If you see a component whose detail says something is
unavailable, that is a broken diagnostic, not necessarily a broken subsystem,
and it is a P1 either way because you are now flying without that instrument.

Then, depending on what is red:

```sql
select public.tf_security_scan();     -- five axes, gap_total should be 0
select public.tf_queue_health();      -- lanes, orphans, stuck events
select public.tf_scheduler_health();  -- pg_cron, per-job first-seen and lateness
select public.tf_integration_health_report();  -- connector credentials and freshness
select public.tf_data_quality_audit();         -- referential and convention integrity
```

`tf_system_health` and the operator functions above run as `postgres` or
`service_role`. Several read models are staff-guarded and will answer
`{"ok": false, "error": "forbidden"}` when called with no JWT. That is correct
behaviour, not a fault. See *The guard model*.

### Live board as of this writing

| Component | Status | Detail |
| --- | --- | --- |
| QuickBooks Finance Sync | **degraded** | reconnect required, last ok 19.7h ago |
| Housecall Pro Sync | operational | synced 0.7h ago |
| ClickUp Operations Worker | **degraded** | worker running, ClickUp API auth issue, rotate token |
| Automated Reports (Slack) | operational | scheduled & connected |
| Customer Messaging (SMS) | operational | live |
| Property Management Domain | operational | 0 units · 0 leases · 0 open req |
| Data Quality & Integrity | operational | no integrity issues |
| Security Posture | operational | hardened, 0 gaps, auto-patch active |
| Scheduler (pg_cron) | operational | 36 jobs scheduled, all firing |
| Integration Queue | operational | queue clear, 0 pending |
| Data Pipeline & Automations | operational | 0 failed run(s) / 1h |

`overall: degraded`, for exactly two reasons, and both are owner actions that no
engineer can perform. See *The open register*.

---

## Symptoms

Routed by what you observe. Each row names the check to run first.

| What you see | Most likely cause | First check |
| --- | --- | --- |
| Revenue number on the dashboard looks too low | QuickBooks sync stale, not a math error | `tf_system_health(false)` → `quickbooks.detail` |
| Revenue looks *too high* / a job appears twice | Duplicate invoice on a non-conforming external id | `tf_revenue_linkage_audit(90)` → `duplicate_key_risk` |
| Marketing ROI shows unattributed revenue | Invoices unlinked from jobs | `tf_revenue_linkage_audit(90)` → `unlinked_reasons` |
| A ticket never appeared in ClickUp | ClickUp token expired; ticket row exists with `status='failed'` | `select * from auto_tickets where clickup_task_id is null` |
| Nothing has synced from the field in hours | Housecall Pro webhook or hourly reconcile stalled | `tf_system_health(false)` → `housecall_pro.detail` |
| A customer says they never got the prep text | Job-prep automation flag is off by design | `integration_settings.config->'automations'->>'job_prep'` |
| A customer got a text they should not have | Autosend cutover timestamp not set before enabling | `config ->> 'intake_autosend_since'` |
| Two customer records for one person | Dedup sweep has not run, or phones differ in format | `tf_merge_duplicate_customers(true)` (dry run) |
| Scheduled report did not arrive in Slack | Cron fired but Slack connector degraded | `tf_scheduler_health()` then `tf_integration_health_report()` |
| Events piling up, nothing draining | Producer writing to a lane with no consumer | `tf_queue_health()` → `orphan_lanes[].reason` |
| A staff user gets `forbidden` from an RPC | Function is `service_role`-only, not staff-callable | *The grant tiers* below |
| A function raises `42501 permission denied` | Same as above: wrong grant tier for the caller | `information_schema.routine_privileges` |
| A function raises `42883 operator does not exist` | Type drift between a new column and an existing enum | *Convention drift* |
| Owner portal shows another owner's property | RLS policy defect. Stop and treat as P0 | `pg_policies` for the table in question |
| Health board shows "X unavailable" | The diagnostic itself is broken | Read the component's underlying function |

---

## The health board, component by component

Eleven components. What each one actually measures, what turns it red, and what
to do about it.

**QuickBooks Finance Sync.** Reads `integration_settings` for provider
`quickbooks`: `last_sync_status` and `last_synced_at`. Degrades on
`reauth_required` or on staleness beyond the freshness threshold. QuickBooks is
the money truth for the whole platform, so this being red means every revenue
figure downstream is as old as `last_synced_at`. Only the owner can fix it, by
reconnecting OAuth through `qbo-connect`. The `qbo-sync-2h` cron keeps firing
and keeps failing, which is correct: it will resume the moment the token is
valid.

**Housecall Pro Sync.** Freshness of the field-operations feed. Two writers
serve it and they are not the same mechanism: `hcp-webhook` writes jobs and
customers directly as events arrive, and `hcp_sync_incremental()` reconciles
hourly on `hcp-hourly-sync`. If the webhook is silently failing, the hourly
reconcile masks it for up to an hour. A detail line above roughly one hour is
the signal that the webhook path is down and only the reconcile is working.

**ClickUp Operations Worker.** Distinguishes two failures that look identical
from a distance: the worker not running, and the worker running but rejected by
the ClickUp API. Today it is the second. The `tf-clickup-worker-hourly` cron
fires at `25 * * * *`, the worker drains the `clickup` lane, and ClickUp
answers with an auth error. Fix is a token rotation into Vault key
`clickup_token`.

**Automated Reports (Slack).** Verifies the six report crons exist and the Slack
connector is credentialed. Reports go to `#accounting_billing` for finance,
`#business_systems` for platform, `#field-ops` for dispatch.

**Customer Messaging (SMS).** The Quo/OpenPhone path. `live` means the connector
is credentialed and the send function is reachable. It does **not** mean any
automation is enabled; see the safety note under *Job-prep intake*.

**Property Management Domain.** Unit, lease and open-request counts. Zeroes here
are expected until the PM division onboards its first property; they are not an
error, and the component reads `operational` at zero deliberately.

**Data Quality & Integrity.** `tf_data_quality_audit()`. Referential integrity
plus the convention checks that have been added each time a drift was found.
This is the component that would catch the eighth convention drift, so treat any
non-zero finding here as high priority even when it looks cosmetic.

**Security Posture.** `tf_security_scan()`. Five axes plus `gap_total`. Reads
`hardened, 0 gaps, auto-patch active` when `gap_total = 0` and
`tf-security-autoharden` is scheduled. Full detail in *The security scan*.

**Scheduler (pg_cron).** `tf_scheduler_health()`. 36 jobs, all `active`.
Carries a first-seen grace period so a newly created job is not reported late
before it has had a chance to run once.

**Integration Queue.** `tf_queue_health()`. The most heavily revised diagnostic
on the platform, currently v7. Full detail in *The queue*.

**Data Pipeline & Automations.** Failed automation runs in the last hour. A
non-zero count here with everything else green usually means one automation
definition is broken rather than an infrastructure problem.

---

## The guard model

Every `security definer` function on this platform sits in one of a small number
of guard modes. Knowing which one applies is usually the difference between "the
platform is broken" and "you called it as the wrong principal".

### The three in-body forms

**Strict staff.** `if not public.user_is_internal_staff(v_company) then return
forbidden`. Used for every operator read model. Eleven functions carry it today,
including `tf_security_scan`, `tf_owner_dashboard`, `tf_marketing_roi`,
`tf_revenue_linkage_audit`, `tf_executive_snapshot`, `tf_cx_metrics`,
`tf_nav_counts`, `tf_log_lead_cost`, `tf_log_lead_spend`, `tf_run_metrics_export`.

**Cron-tolerant.** `if auth.uid() is not null and not
public.user_is_internal_staff(v_company) then return forbidden`. Three functions
carry it: `tf_link_revenue`, `tf_ops_report`, `tf_send_intake`. All three are
invoked by pg_cron, which runs as `postgres` with no JWT and therefore no
`auth.uid()`. A strict guard on any of them would have turned the scheduled run
into a silent permanent no-op that reported success forever, which is the worst
possible failure mode because it is invisible.

**Party-scoped.** `user_is_internal_writer`, `current_owner_*`,
`current_tenant_*`, `user_is_assigned_to_*`. Used where the caller is a
portal user rather than staff: an owner approving maintenance on their own unit,
a tenant reading their own lease. These are the functions that make the
owner/tenant portals safe.

The guard is on the argument-taking form. `public.user_is_internal_staff(cid
uuid)` takes a company id and has **no zero-argument overload**. Calling it bare
raises `42883`. This has bitten twice.

It returns `false` rather than raising when `auth.uid()` is null, which is what
makes the cron-tolerant form work at all.

### The grant tiers

Guards in the function body are only half the story. The `EXECUTE` grant decides
who can reach the body at all, and the two mechanisms are frequently confused.

| Tier | Who can call | Typical members |
| --- | --- | --- |
| `postgres`, `service_role` only | cron and edge functions | `tf_queue_health`, `tf_queue_discard`, `tf_queue_requeue`, `tf_system_health`, `tf_security_autoharden`, all `*_sweep` functions |
| `authenticated`, `postgres`, `service_role` | staff and portal users, subject to the in-body guard | `tf_owner_dashboard`, `tf_customer_360`, `tf_marketing_roi`, `tf_render_document` |
| `anon` | nothing non-public | intentionally empty |

**This is a real trap.** Impersonating a staff user with `set local role
authenticated` and calling `tf_queue_discard` raises `42501: permission denied
for function tf_queue_discard`. That is not a bug and not a missing guard. The
queue operator functions are deliberately service-tier only, which is also why
they are structurally exempt from the fifth security axis: `authenticated` can
never reach them.

To exercise a staff-callable function as a staff user:

```sql
set local role authenticated;
set local request.jwt.claims = '{"sub":"<staff-user-uuid>","role":"authenticated"}';
select public.tf_owner_dashboard();
```

To exercise a service-tier function, call it as `postgres` with no impersonation
at all.

---

## The security scan

`tf_security_scan()` returns five axes and a `gap_total`. All five read 0 today.

| Axis | What it counts |
| --- | --- |
| `rls_disabled_tables` | public base tables with row-level security off |
| `anon_secdef_nonpublic` | definer functions `anon` can execute that are not meant to be public |
| `secdef_no_searchpath` | definer functions without a pinned `search_path` |
| `rls_enabled_no_policy` | tables with RLS on and no policy, so nobody can read them |
| `secdef_authenticated_no_guard` | definer functions `authenticated` can execute whose body contains no recognised authorization predicate |

`gap_total` is the sum. `tf-security-autoharden` runs every six hours at
`0 */6 * * *` and closes what it can close mechanically, chiefly missing
`search_path` pins.

**Read this before you trust the zero.** The fifth axis is a *textual* test. It
scans `pg_get_functiondef` for any of a fixed list of authorization identifiers,
`user_is_internal_staff`, `user_is_internal_writer`, `studio_is_staff`,
`has_permission`, `user_has_role`, `is_company_member`, `user_company_id`,
`current_company`, `current_owner_`, `current_tenant_`, `current_user_role`,
`is_privileged_role`, `user_is_assigned_to_`, `current_supabase_user_id`, and
bare `auth.uid`. A function that merely *mentions* one of those tokens passes,
even if it never acts on the result.

That is a deliberate trade and the reason it is acceptable is worth stating: a
semantic check is not expressible in SQL, and a textual check that runs every
six hours and catches the common case beats a perfect check that does not exist.
But it means **a green fifth axis is evidence, not proof**. When a new definer
function is granted to `authenticated`, read its guard yourself. Do not let the
scan read it for you.

There are 48 definer functions reachable by `authenticated`. Their guards break
down as: 11 strict staff, 3 cron-tolerant, 1 RBAC via `has_permission`, and the
remainder party-scoped through `user_is_internal_writer` or the `current_owner_*`
and `current_tenant_*` helpers.

Two functions sit on the exemption list in `public.security_scan_exemptions`:
`tf_security_scan` itself, and `tf_rent_payments_enabled`, which is a boolean
feature-flag read with no data exposure. Exemptions are rows in a table, not
hardcoded, so adding one is auditable.

Control **AC-DEFN-017** in the GRC register asserts that every definer function
reachable by `authenticated` carries an authorization predicate. It reads
`passing`.

---

## The queue

One table, `integration_events`, and one registry, `integration_queue_lanes`.

Columns on `integration_events`: `id, company_id, provider, direction,
event_type, entity_type, entity_id, status, payload, attempts, max_attempts,
next_retry_at, started_at, processed_at, last_error, created_at, updated_at,
created_by, updated_by`. The retry column is `next_retry_at`. There is no
`retry_at`.

### The lane registry

`integration_queue_lanes` carries one row per value of the
`public.integration_provider` enum, which has exactly ten values in sort order:
`housecall_pro, clickup, wordpress, notion, stripe, quickbooks, twilio, other,
openphone, slack`.

Only one lane is actually drained.

| Provider | Consumer | Cadence | Drained |
| --- | --- | --- | --- |
| `clickup` | `tf-clickup-worker` edge function | `25 * * * *` | **yes** |
| `housecall_pro` | none by design | `hcp-hourly-sync` reconciles | no |
| `quickbooks` | none by design | `qbo-sync-2h` pulls directly | no |
| `stripe` | none by design | inline on webhook receipt | no |
| `slack` | none by design | `tf-slack-sweep` every 2 min | no |
| `openphone` | none by design | inline send and webhook receipt | no |
| `wordpress` | none by design | `tf-site-ingest-weekly` reads the site | no |
| `twilio` | none by design | n/a | no |
| `notion` | none by design | n/a | no |
| `other` | none by design | n/a | no |

`is_drained = false` is a design statement, not a defect. It says *nothing should
ever enqueue under this provider*. So an event sitting in a non-drained lane is
a **producer bug**: something wrote where the design says nobody writes.

### Reading orphan lanes

`tf_queue_health()` reports orphans with a `reason` code, and the two codes mean
genuinely different things:

- `unregistered_provider` — an enum value with no lane row at all. Somebody added
  a provider and did not register it. Documentation defect.
- `no_consumer_by_design` — the lane is registered as not drained, and events are
  accumulating in it anyway. Producer defect. This is the one that matters.

The function also returns `unregistered_providers`, computed directly against
`pg_enum` rather than against traffic, so a provider added without a lane row is
visible immediately instead of waiting for something to enqueue under it.

Verdict logic: production orphans degrade the component. Registry gaps are
surfaced in `detail` but are **not** verdict-bearing, because a missing lane row
is a documentation defect, not an outage. Non-production tenant traffic is
surfaced but never verdict-bearing either, which is why the legacy demo tenant
`dd000000-0000-4000-a000-000000000001` cannot redden the board.

### Operating the queue

```sql
select public.tf_queue_health();   -- always start here

select public.tf_queue_requeue(p_event_id := '<uuid>');  -- retry a transient failure

select public.tf_queue_discard(
  p_event_id := '<uuid>',
  p_reason   := 'why this will never be retried');       -- close out permanently
```

All three are `postgres`/`service_role` only. Discard requires a reason and
writes it to the row; a discard without an explanation is worse than a stuck
event, because the next operator has no way to know whether it was safe.

---

## Conventions register

Seven times, the highest-yield defect on this platform has been two writers each
holding a different convention, both correct in isolation, silently disagreeing
at the seam. Every one of these is now enforced somewhere the disagreement
becomes an error at write time rather than a discrepancy at read time.

| # | Convention | The canonical form | Enforced by |
| --- | --- | --- | --- |
| 1 | Phone identity | trailing ten digits: `right(regexp_replace(phone,'\D','','g'), 10)` | matching logic in intake and dedup |
| 2 | Revenue recognition | collected revenue = `total_amount - balance` | shared expression across `tf_marketing_roi` and `tf_revenue_linkage_audit` |
| 3 | QuickBooks external id | `<realm>:<qbId>`, never bare | unique index on the normalised expression |
| 4 | Invoice-to-job linkage | a recurring sweep, never a one-shot backfill | `tf-revenue-linkage-hourly` |
| 5 | Security axis list | one list, referenced not retyped | axis array built inside `tf_security_scan` |
| 6 | GRC control coverage | every security axis has a control | AC-DEFN-017 |
| 7 | Queue lane provider type | `public.integration_provider`, never `text` | column type plus a registry-completeness post-check against `pg_enum` |

The countermeasure that keeps working is the same every time: express the
convention in the database, on the *normalised* form of the value, so violation
is impossible rather than merely discouraged.

Convention documented in prose is a convention that will drift. Convention
expressed as a unique index is a convention that cannot.

---

## Defect-pattern library

The recurring shapes. Recognising one of these saves an hour.

**Guard arity.** A function calls `user_is_internal_staff()` with no argument.
Raises `42883`. Nothing catches it until the function is actually invoked, and
if the caller is a nightly cron, that means it fails every night against a log
nobody reads. Fix: always pass the company id.

**Type drift between a new column and an existing enum.** A new table declares
`provider text` while the table it joins to holds `public.integration_provider`.
Raises `42883: operator does not exist: text = integration_provider` at the join.
The migration applies cleanly because nothing exercises the join. Fix: retype
with `alter column ... type ... using ...::...`.

**Missing aggregate.** Postgres has no `min(uuid)`. Use `(array_agg(col))[1]`,
which is exact when the group is known to hold one row.

**Non-re-entrant scratch tables.** `create temp table ... on commit drop` only
drops at COMMIT, so a second call inside the same transaction raises `42P07`.
Any wrapping transaction or retry breaks it. Fix: drop defensively before
creating.

**Dollar-quote escaping.** Inside a `do $tag$ ... $tag$` block, a single-quoted
literal needs `''` per quote, not `''''`. Writing four quotes raises `42601`.
Prefer `replace()` over `regexp_replace()` for catalog patches, and when the full
live definition is already in hand, prefer a straight `create or replace` over a
multi-anchor patch.

**Column-name assumption.** `auto_tickets` has `priority integer`, not
`severity`. `integration_settings` has `is_enabled`, not `is_active`, and
`last_sync_status`, not `connection_status`. `it_controls` keys on
`control_key`, not `control_id`. Read `information_schema.columns` before
writing the query; it costs one round trip and saves three.

**Misleading evidence.** A diagnostic that collapses two distinct causes into one
label is worse than one that reports nothing, because it sends the operator
somewhere specific and wrong. The orphan-lane reporter did exactly this before
v7: it labelled a registered-but-undrained lane as `"registered": false`. If a
diagnostic can be wrong in two different ways, it must say which one.

---

## The house rules

Three rules, each of which exists because breaking it cost real time.

**A migration that creates or replaces a function must drive that function in a
post-check, not inspect it.** Migration 229 in this repo's ordinal series applied
cleanly, reported success, and shipped a function that raised on every single
call. Nothing had exercised the join. Every function migration since carries a
`do $drive$` block that calls the function and asserts on its actual output.

**Repair by catalog patch, not by retyping.** Read `pg_get_functiondef(oid)`,
patch the one expression, re-execute. `create or replace` preserves grants;
retyping a body from memory does not, and silently widening a grant is a security
defect that no scan will attribute to you.

**Prefer loud failure to quiet corruption.** A unique index that stalls a sync
batch is visible within the hour, because the watchdog and autoticket
infrastructure raise it. Corrupted revenue is not visible at all, and by the time
anyone notices, the P&L has been wrong for months and nobody can say since when.
This will not always be convenient. That is the point.

---

## Scheduled work

36 pg_cron jobs, all active. Grouped by what they are for.

**Reliability and self-healing**

| Job | Schedule | Command |
| --- | --- | --- |
| `tf-system-health-check` | `*/15 * * * *` | `tf_system_health(false)` |
| `tf-system-health-daily` | `45 13 * * *` | `tf_system_health(true)` |
| `tf-security-autoharden` | `0 */6 * * *` | `tf_security_autoharden()` |
| `tf-reliability-autoticket-hourly` | `50 * * * *` | `tf_reliability_autoticket()` |
| `tf-integration-watchdog-daily` | `15 13 * * *` | `tf_integration_watchdog(true)` |
| `tf-governance-autoticket-daily` | `5 14 * * *` | `tf_governance_autoticket()` |

**Integration sync**

| Job | Schedule | Command |
| --- | --- | --- |
| `hcp-hourly-sync` | `0 * * * *` | `hcp_sync_incremental()` |
| `qbo-sync-2h` | `0 */2 * * *` | POST to `qbo-sync` |
| `tf-clickup-worker-hourly` | `25 * * * *` | POST to `tf-clickup-worker` |
| `tf-slack-sweep` | `*/2 * * * *` | POST to `tf-slack` |
| `tf-hcp-tech-sync` | `30 11 * * *` | POST to `tf-hcp-sync-techs` |
| `tf-site-ingest-weekly` | `0 7 * * 1` | POST to `tf-site-ingest` |
| `tf-metrics-export-weekly` | `0 12 * * 1` | POST to `tf-metrics-export` |

**Field operations**

| Job | Schedule | Command |
| --- | --- | --- |
| `tf-offer-sweep` | `*/2 * * * *` | `tf_offer_sweep()` |
| `tf-ai-booking-kickoff` | `*/2 * * * *` | `tf_ai_booking_kickoff_sweep()` |
| `tf-cx-first-response` | `*/2 * * * *` | `tf_cx_first_response_sweep()` |
| `tf-intake-sweep` | `*/3 * * * *` | `tf_intake_sweep()` |
| `tf-cx-sequences` | `*/5 * * * *` | `tf_cx_sequence_sweep()` |
| `tf-late-penalty-sweep` | `*/10 * * * *` | `tf_late_penalty_sweep()` |
| `tf-eta-reminders` | `5,35 * * * *` | `tf_eta_reminder_sweep()` |
| `tf-review-request-sweep` | `15,45 * * * *` | `tf_review_request_sweep()` |
| `tf-engagement-sweep` | `40 * * * *` | `tf_engagement_sweep()` |
| `tf-close-paid-jobs` | `10 7 * * *` | `tf_close_paid_jobs()` |

**Data integrity and finance**

| Job | Schedule | Command |
| --- | --- | --- |
| `tf-revenue-linkage-hourly` | `55 * * * *` | `tf_link_revenue(false, 180)` |
| `tf-customer-dedup` | `20 6 * * *` | `tf_merge_duplicate_customers(false)` |

**Reporting**

`tf-report-daily` `0 12 * * *`, `tf-report-weekly` `10 12 * * 1`,
`tf-report-monthly` `20 12 1 * *`, `tf-report-quarterly` `30 12 1 1,4,7,10 *`,
`tf-report-semiannual` `40 12 1 1,7 *`, `tf-report-annual` `50 12 1 1 *`. Each
calls `tf_report_with_sync(<cadence>)`. Also `tf-sop-reminder-daily`
`30 13 * * *` and `tf-sop-reminder-weekly` `35 13 * * 1`.

**Governance**

`tf-controls-evaluate-monthly` `0 14 1 * *`,
`tf-governance-report-monthly` `30 14 1 * *`,
`tf-access-review-quarterly` `0 14 1 1,4,7,10 *`.

The minute offsets are not arbitrary. Revenue linkage sits at minute 55 to stay
clear of the 2-hourly QuickBooks pull on the hour; the ClickUp worker sits at 25
to stay clear of the Housecall Pro reconcile at 0. When adding a job, pick a
minute nothing else occupies.

---

## Integration topology

37 edge functions. The ones that matter operationally:

**Inbound webhooks** (`verify_jwt: false`, authenticated by provider signature):
`hcp-webhook` writes jobs and customers from Housecall Pro; `quo-webhook`
receives SMS; `tf-stripe-webhook` receives payment events; `slack-webhook` and
`tf-meta-webhook` receive their respective platforms; `intake-submit` and
`intake-context` serve the customer-facing prep form; `public-apply` serves the
public application form.

**Outbound workers**: `tf-clickup-worker` drains the ClickUp lane;
`tf-omni-send` and `quo-messenger` send messages; `tf-slack` posts to Slack;
`hcp-estimate-push` pushes estimates to Housecall Pro.

**Sync and reporting**: `qbo-sync` and `qbo-connect` for QuickBooks;
`tf-hcp-sync-techs`; `tf-site-ingest`; `tf-metrics-export`; `tf-status` serves
the public status page.

**Platform**: `cygeus-api`, `ai-gateway`, `ai-assist`, `ai-booking`,
`cygeus-selftest`, `tf-admin-provision-user`.

Where connector credentials live: Supabase Vault, referenced from
`integration_settings.secret_ref` and `webhook_secret_ref`. Never in table
columns, never in edge function source. Control DP-VAULT-006 asserts this and
reads `passing`.

Current connector state for the production tenant
`ff000000-0000-4000-b000-000000000001`:

| Provider | Enabled | Last status | Last synced |
| --- | --- | --- | --- |
| `housecall_pro` | yes | connected | 2026-07-25 09:00 |
| `slack` | yes | connected | 2026-07-25 07:12 |
| `openphone` | yes | connected | 2026-07-18 01:27 |
| `stripe` | no | connected | 2026-07-23 23:32 |
| `quickbooks` | yes | **reauth_required** | 2026-07-24 14:00 |
| `clickup` | yes | **reauth_required** | 2026-07-17 18:32 |

---

## Job-prep intake, and the one thing that must not go wrong

`tf_send_intake` sends **real SMS to real customers**. It is cron-tolerant
guarded and reachable from `tf-intake-sweep` every three minutes.

The automation flag
`integration_settings.config->'automations'->>'job_prep'` on provider `openphone`
is currently **`false`**. That is the only thing standing between a test sweep
and a text message to a live customer. Any testing of the intake path must use
reserved fictional numbers, `(614) 555-0142` and `(614) 555-0143`.

**Before that flag is ever set to `true`,** set
`config ->> 'intake_autosend_since'` to the cutover timestamp. Without it,
enabling autosend will back-text the entire existing book of jobs. This is an
operator decision, correctly sequenced as: set the cutover timestamp, verify it
reads back, then enable the flag. Never the other way round.

The intake path itself carries a send-guard ladder, a reminder ladder, and an
expiry, documented in `JOB_PREP_INTAKE.md`. Phone matching uses the trailing-ten
convention, which is convention #1 in the register above.

---

## The open register

Everything currently unresolved, with who can resolve it. Each has a tracked
ClickUp ticket produced by the auto-ticket engine.

### Owner actions, not performable by engineering

| # | Action | Ticket | Closes |
| --- | --- | --- | --- |
| 1 | Reconnect QuickBooks OAuth | `86bb3a6mh` | `quickbooks` component |
| 2 | Rotate ClickUp API token into Vault `clickup_token` | `86bb3az53` | `clickup` component |
| 3 | Enable MFA on the owner account | `86bb3ae6c` | control AC-MFA-003 |
| 4 | Enable Point-in-Time Recovery | `86bb3ayzr` | control DP-PITR-007 |
| 5 | Enable Google and Microsoft SSO providers | `86bb3az04` | provisioning coverage |
| 6 | Normalise the 2 bare QuickBooks invoice external ids (80, 82) | `86bb3byg5` | `duplicate_key_risk` |

Items 1 and 2 are the *entire* reason `overall` reads `degraded`. Close both and
the board goes green.

Also outstanding and security-relevant: rotate the Stripe secret key that was
exposed in conversation (`86bb2uatj`, `86bb2t2c2`), and revoke the GitHub
personal access token once repository pushes are complete. Neither is tracked as
a platform component because neither is observable from inside the database.

### Two tickets that failed to reach ClickUp

`reliability:queue` and `integration:slack:reauth_required` both sit at
`status = 'failed'` with `clickup_task_id = null`. They failed for one reason:
the ClickUp token was already expired when the auto-ticket engine tried to
create them. Both underlying conditions have since cleared, and both rows carry a
`resolved_at`. They are evidence of the ClickUp blocker, not open issues. They
will not be retried, and they should not be, because the conditions they describe
no longer exist.

This is worth naming as a systemic point: **the auto-ticket engine depends on the
connector it is most likely to be reporting on.** When ClickUp is down, the
platform loses its ability to tell you ClickUp is down through ClickUp. The
`auto_tickets` table is therefore the authoritative record, and ClickUp is a
mirror of it. Query the table, not the board:

```sql
select dedup_key, title, status, priority, clickup_task_id, resolved_at
from public.auto_tickets order by created_at;
```

### GRC controls

17 controls, 15 `passing`, 2 `attention`: AC-MFA-003 and DP-PITR-007, which are
owner actions 3 and 4 above. Evaluated monthly by `tf-controls-evaluate-monthly`.

---

## Revenue and attribution

The state of the money data, and how to check it.

```sql
-- staff-guarded; impersonate a staff user to call these
select public.tf_revenue_linkage_audit(90);
select public.tf_marketing_roi(90);
```

Current figures over a 90-day window: 31 invoices, 26 linked to a job, 5
unlinked. Collected revenue $12,834.05, of which $10,721.31 is traceable to a
job. `revenue_traceable_pct` 83.5%.

The five unlinked invoices are fully explained rather than merely counted: 2
zero-amount credit memos, 2 with no candidate job, 1 genuinely ambiguous. Read
`unlinked_reasons` before you read the percentage. The percentage tells you
whether to care; the reason codes tell you what to do.

`tf_marketing_roi(90)` independently reports 83.5% and $10,721.31 from the same
convention, computed separately. Two read models agreeing is worth more than
either one asserting. **If those two ever disagree, the convention has drifted
again.**

`duplicate_key_risk.nonconforming_rows` sits at 2, carrying $1,404.13 of
collected revenue that would double-count on a re-sync if the unique index were
not there. The index makes the collision impossible, so the risk is neutralised,
but neutralised is not resolved: those two QuickBooks entities will fail to sync
loudly rather than corrupt quietly until they are normalised. That is owner
action 6.

Watch `ambiguous_candidates`. If it climbs, the defect is upstream, jobs are
being created in near-duplicate pairs, and no amount of linker cleverness fixes
it. Watch `no_candidate_job` too: growth there means work is being invoiced that
was never opened as a job, which is an operations problem wearing a data costume.

---

## Platform inventory

Read live from the catalog, not counted by hand.

| | Count |
| --- | --- |
| Migrations applied | 231 |
| Base tables in `public` | 163 |
| Tables with RLS enabled | 163 (100%) |
| RLS policies | 574 |
| Functions in `public` | 254 |
| `tf_*` operator functions | 68 |
| Views | 7 |
| Enums | 80 |
| Indexes | 645 |
| pg_cron jobs | 36 |
| Edge functions | 37 |
| GRC controls | 17 |

163 of 163 tables carry RLS. That is the number to re-check after any migration
that creates a table, because a new table without RLS is the single fastest way
to open a cross-tenant leak, and `rls_disabled_tables` is the axis that catches
it.

---

## Tenancy

Two company ids appear throughout.

`ff000000-0000-4000-b000-000000000001` is **production**. Everything that matters
belongs to it, and it is the only tenant whose state is verdict-bearing in
health checks.

`dd000000-0000-4000-a000-000000000001` is the **legacy demo tenant**. Its rows
are surfaced in diagnostics under a `non_production` key so they remain visible,
but they cannot turn a component red. If a health check ever degrades on demo
data, the scoping is wrong and that is itself the defect.

---

## Where else things are written down

This document is the troubleshooting spine. The depth lives in the
subject-specific notes beside it in `docs/`:

- `CUSTOMER_360.md` — customer read model, index and 360 RPCs
- `JOB_PREP_INTAKE.md` — prep-text guard ladder, reminder ladder, expiry
- `SCHEDULER_AND_QUEUE_RELIABILITY.md` — pg_cron and queue health
- `CLOSED_LOOP_AUTOTICKETING.md` — self-ticketing and self-healing
- `RELIABILITY_INTEGRATION_WATCHDOG.md` — connector watchdog
- `IT_GOVERNANCE_GRC.md` — controls, access certification, SLOs
- `MARKETING_ROI_AND_REVENUE.md` — collected-revenue convention, channel P&L
- `REVENUE_LINKAGE.md` — invoice-to-job sweep, natural-key integrity
- `SECURITY_GUARDS_AND_QUEUE_LANES.md` — the guard sweep, AC-DEFN-017, lane registry
- `MIGRATIONS_INDEX.md` — the ordered migration manifest

Notion carries the same material for non-engineers under **🧭 Operations Hub —
SOPs & FAQs**, with persona-routed SOPs and FAQs. ClickUp carries the
operational queues and the ticket surface.

---

## The pattern, stated plainly

Everything in this document reduces to one observation. On this platform, the
defects that cost the most were never the ones that raised an error. They were
the ones where two components each did something reasonable and disagreed
silently: a linker that ran once and looked like a process, a health check that
reported a lane as unregistered when it was registered and idle by design, a
scan that returned zero because it was looking for a word rather than a
behaviour.

The countermeasure is always the same shape. Make the disagreement impossible at
write time, or make it loud at read time. Never let it be quiet.

A system that fails loudly can be operated by someone who has never seen it
before. That is the actual goal of this document.
