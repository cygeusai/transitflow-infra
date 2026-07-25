# Transit & Flow — Platform Knowledge Base

The single troubleshooting reference for the Transit & Flow backend. Written to
be read at 2am by someone who did not build it.

State captured 2026-07-25 against Supabase project `kjooyhvynkzuvsixsutt` at
migration 248. Every number in this document was read out of the live database,
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
select public.tf_data_quality_audit();  -- referential and convention integrity

-- connector credentials and freshness
select provider, is_enabled, last_sync_status,
       round(extract(epoch from (now() - last_synced_at))/3600, 1) as hours_since_sync
from public.integration_settings
where company_id = 'ff000000-0000-4000-b000-000000000001' and deleted_at is null
order by last_synced_at desc nulls last;
```

**Read the side-effect column before you paste anything.** Not every `tf_*`
function is a read, and two of them are named as though they were.

| Call | Side effects | Auth needed |
| --- | --- | --- |
| `tf_system_health(false)` | none with `false` | any |
| `tf_security_scan()` | none | staff, or no JWT |
| `tf_queue_health()` | none | staff, or no JWT |
| `tf_scheduler_health()` | **writes** `cron_job_registry` | staff, or no JWT |
| `tf_data_quality_audit()` | none | **staff JWT required** |
| `tf_revenue_linkage_audit(90)` | none | **staff JWT required** |
| `tf_marketing_roi(90)` | none | **staff JWT required** |
| `tf_integration_health_report(...)` | **records an outage, opens a ticket** | not a diagnostic |
| `tf_integration_watchdog(p_post)` | **writes regardless of `p_post`** | not a diagnostic |

Three of those rows exist because someone tried to run this section as written
and it did not survive contact. Each is worth knowing before 2am.

**`tf_integration_health_report` is not a report.** Despite the name it is the
*writer* the edge functions call to record a connector failure, and since
migration 190 it opens a ClickUp ticket immediately. Its real signature is
`(p_provider text, p_ok boolean, p_error_code text default 'reauth_required',
p_http_status integer default 401, p_message text default null)`. A bare
`select public.tf_integration_health_report();` raises `42883`, which is the
lucky outcome. The unlucky outcome is an operator supplying plausible arguments
to make the error go away and thereby injecting a fake outage into the health
board and a real ticket into ClickUp. Use the `integration_settings` query above
instead. It is a plain select and cannot do anything.

**`tf_integration_watchdog(false)` is not a dry run.** `p_post` gates the Slack
post and the alert-cadence stamp only. The self-heal pass, which resolves
`integration_errors` rows and closes their tickets, and the escalation pass,
which opens tickets for anything unresolved past 72h, both run either way. The
parameter is honestly named; the danger is reading `false` as `dry_run` by
analogy with `tf_link_revenue`. It is not that. Leave it to
`tf-integration-watchdog-daily` unless you intend the writes.

**`tf_scheduler_health()` writes, benignly.** It upserts every live `cron.job`
into `cron_job_registry` to maintain the first-seen clock and deletes registry
rows whose jobid is gone, so a recycled jobid cannot inherit a stale
`first_seen_at`. Idempotent, safe to run repeatedly, but it is not a pure read
and should not be described as one.

`tf_system_health` and the operator functions above run as `postgres` or
`service_role`. Several read models are staff-guarded. Most answer
`{"ok": false, "error": "forbidden"}` when called with no JWT, but
`tf_data_quality_audit` **raises** `P0001: not authorized` rather than returning
a refusal, which aborts a multi-call statement. Run it on its own, from a staff
session. That is correct behaviour, not a fault. See *The guard model*.

**Run these as separate statements, one per call.** Postgres aborts an entire
statement on the first error, so bundling five diagnostics into one
`jsonb_build_object` means a single bad call costs you the other four results.
That is exactly how the two defects above went unnoticed.

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
| A customer got a text they should not have | Autosend cutover timestamp stale, not refreshed before enabling | `tf_automation_readiness()` → the automation's `verdict` and `cutover_age_hours` |
| An automation flag is on and nobody armed it | Flag flipped by direct `update`, bypassing `tf_automation_arm` | `tf_automation_out_of_band()`; control `CM-AUTOARM-020` |
| `42501: permission denied for function` | The function is `admin` tier; you are calling it as `authenticated` | `select tier from tf_function_grant_tiers where proname='<name>'` |
| A new function is reachable by `anon` and nobody granted it | Supabase `ALTER DEFAULT PRIVILEGES`; `revoke from public` does not undo it | `tf_grant_tier_audit()`; fix with `tf_apply_grant_tier` |
| Two customer records for one person | Dedup sweep has not run, or phones differ in format | `tf_merge_duplicate_customers(true)` (dry run) |
| Scheduled report did not arrive in Slack | Cron fired but Slack connector degraded | `tf_scheduler_health()` then the `integration_settings` query above |
| A `tf_*` call raises `42883` or does something unexpected | The name implies a read; the function is a writer | *The first ten minutes*, side-effect table |
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

Since migration 248 (`grant_tier_drift_control`) the tiers are **data, not
prose**. They live in
`public.tf_function_grant_tiers`, they are applied by
`public.tf_apply_grant_tier`, they are checked by `public.tf_grant_tier_audit`,
and control `CM-GRANT-021` fails the board if the live ACL stops matching. The
full treatment is in `FUNCTION_GRANT_TIERS.md`. The short version:

| Tier | Roles granted | Requires an in-body guard | Typical members |
| --- | --- | --- | --- |
| `admin` | `postgres`, `service_role` | no, the grant *is* the control | `tf_automation_arm`, `tf_apply_grant_tier`, `tf_safety_autoticket`, `tf_grant_tier_autoticket`, the queue operators, every `*_sweep` |
| `staff` | adds `authenticated` | **yes, always** | `tf_grant_tier_audit`, `tf_automation_readiness`, `tf_control_attest`, `tf_owner_dashboard`, `tf_customer_360`, `tf_marketing_roi` |
| `anon` | adds `anon` | yes | exactly one: `studio_is_staff`, documented below |

**Why this drifts on its own.** Supabase installs `ALTER DEFAULT PRIVILEGES IN
SCHEMA public GRANT EXECUTE ON FUNCTIONS TO anon, authenticated`. Those are
*named-role* grants. The idiom used across this repo for years,
`revoke all on function ... from public`, revokes only the PUBLIC pseudo-role
and leaves `anon` and `authenticated` still holding EXECUTE. Every new function
in `public` is therefore reachable by an anonymous caller from the moment it is
created until something names `anon` explicitly. This is not a Supabase defect,
it is the platform default, and it is the reason the tier has to be asserted
rather than assumed.

The correct form is `revoke all on function ... from public, anon,
authenticated;` followed by the intended grant. In practice, never write that by
hand. Call `tf_apply_grant_tier(proname, ident_args, tier, rationale)`, which
records the intent as well as applying it.

**`studio_is_staff` is the one anon exception, and it is deliberate.** It is
referenced by RLS policies whose role is PUBLIC, covering the public reads on
`studio_plans`, `studio_products`, `studio_product_categories` and
`studio_conversion_credit_rules`. Revoking `anon` EXECUTE would break the public
storefront. It is in the tier table so that the checker treats it as declared
rather than reporting it as an undeclared hole every fifteen minutes.

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

**Both lines are required, and the second one is the one people forget.**
`auth.uid()` reads `request.jwt.claims`. It does *not* read the current role.
`set local role authenticated` on its own leaves `auth.uid()` null, which means
every cron-tolerant guard passes and every test of a guard silently succeeds
without having tested anything. A guard test that omits the claims line is not a
test, it is a false negative wearing a green tick.

Inside a `do` block the equivalent is:

```sql
perform set_config('request.jwt.claims',
  '{"sub":"dddddddd-0000-4000-a000-0000000000d1","role":"authenticated"}', true);
-- ... assert the function refuses ...
perform set_config('request.jwt.claims', '', true);
```

Clear the claims afterwards. They persist for the rest of the transaction, and
any later call in the same block will be evaluated as that non-staff user.

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

Fourteen times, the highest-yield defect on this platform has been two writers
each holding a different convention, both correct in isolation, silently
disagreeing at the seam. Every one of these is now enforced somewhere the
disagreement becomes an error at write time rather than a discrepancy at read
time.

| # | Convention | The canonical form | Enforced by |
| --- | --- | --- | --- |
| 1 | Phone identity | trailing ten digits: `right(regexp_replace(phone,'\D','','g'), 10)` | matching logic in intake and dedup |
| 2 | Revenue recognition | collected revenue = `total_amount - balance` | shared expression across `tf_marketing_roi` and `tf_revenue_linkage_audit` |
| 3 | QuickBooks external id | `<realm>:<qbId>`, never bare | unique index on the normalised expression |
| 4 | Invoice-to-job linkage | a recurring sweep, never a one-shot backfill | `tf-revenue-linkage-hourly` |
| 5 | Security axis list | one list, referenced not retyped | axis array built inside `tf_security_scan` |
| 6 | GRC control coverage | every security axis has a control | AC-DEFN-017 |
| 7 | Queue lane provider type | `public.integration_provider`, never `text` | column type plus a registry-completeness post-check against `pg_enum` |
| 8 | Function side-effect class | every `tf_*` function declares `read` or `write` | `tf_function_registry` + `tf_function_safety_audit`, ticket key `safety:function_drift` |
| 9 | Boolean parameter meaning | `p_dry_run` defaults `true`; any other boolean defaults to the inert value | `tf_boolean_param_conventions` + `tf_boolean_default_hazards`, ticket key `safety:boolean_defaults` |
| 10 | Automation arming | flags flip only through `tf_automation_arm`, which logs to `automation_arm_log` | `tf_automation_out_of_band`, control `CM-AUTOARM-020`, ticket key `safety:automation_cutover` |
| 11 | Function EXECUTE grants | every function carries exactly the grants its declared tier implies | `tf_function_grant_tiers` + `tf_grant_tier_audit`, control `CM-GRANT-021`, ticket key `safety:grant_tier` |
| 12 | Control evidence integrity | an automated control must be named in both the status CASE and the evidence CASE | `tf_controls_evaluate` wiring assertion in every control migration |
| 13 | Manual control attestation | manual controls are attested by a human through `tf_control_attest`, never auto-passed | `it_controls.last_attested_at` split from `last_evaluated_at` |
| 14 | Detection rules as data | patterns live in tables, not in checker bodies | `tf_function_safety_patterns`, `tf_boolean_param_conventions`, `tf_automation_registry`, `tf_function_grant_tiers` |

The countermeasure that keeps working is the same every time: express the
convention in the database, on the *normalised* form of the value, so violation
is impossible rather than merely discouraged.

Convention documented in prose is a convention that will drift. Convention
expressed as a unique index is a convention that cannot.

**Conventions 8 through 14 share a shape worth naming.** Each one is a table of
rules, a function that applies them, a checker that compares live state to the
table, a GRC control that fails when they disagree, and an auto-ticket key that
puts the disagreement in front of a human. Five parts. When a new convention is
introduced on this platform, build all five or it will drift like the first
seven did. The reason the rules live in tables rather than inside the checkers is
that a rule embedded in a function body can only be changed by a migration
written by someone who understands the function; a rule in a table can be
inspected, queried, and extended by an operator at 2am.

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

**A name that implies a read on a function that writes.** This was documented as
"two functions, assume there is a third." That was wrong, and the way it was
wrong is the lesson. Once the classification was made data rather than judgement,
`tf_function_registry` proved **seven**:

| Function | What the name suggests | What it does |
| --- | --- | --- |
| `tf_access_review` | a review | writes access-certification rows |
| `tf_controls_evaluate` | an evaluation | updates `it_controls` status and evidence |
| `tf_integration_health_report` | a report | five-argument writer that opens a ticket |
| `tf_it_governance_report` | a report | writes |
| `tf_ops_report` | a report | writes, and reaches Slack over HTTP |
| `tf_scheduler_health` | a health read | upserts `cron_job_registry` and deletes stale rows |
| `tf_system_health` | a health read | writes a snapshot **when `p_post` is true**; `tf_system_health(false)` is inert |

Two of the seven, `tf_scheduler_health` and `tf_system_health`, are *acknowledged*
diagnostics-that-mutate: `documented_as_diagnostic` and `write_acknowledged` are
both true in the registry, and the mutation is intentional and documented. The
other five are simply badly named and are flagged as such.

Three more write and reach third parties over HTTP without their names saying so:
`tf_draft_review_reply`, `tf_report_with_sync`, and again `tf_ops_report`.

Fix: before putting any call in a runbook, `select * from tf_function_registry
where proname = '<name>'`. If it is not there, `tf_function_safety_audit()` will
report it as undeclared within fifteen minutes. Do not reason from the name. The
estimate "assume there is a third" was off by a factor of three and a half, which
is what estimating instead of measuring costs.

**Grant tier drift with no author.** A function is created, the migration
revokes from `public`, the author believes it is locked down, and `anon` can call
it. Nobody did anything wrong and the hole is real. Cause: Supabase's
`ALTER DEFAULT PRIVILEGES` grants EXECUTE to `anon` and `authenticated` by name,
and revoking the PUBLIC pseudo-role does not touch named-role grants. Fix:
`tf_apply_grant_tier`. Detection: `tf_grant_tier_audit()`, every fifteen minutes,
control `CM-GRANT-021`.

**`has_function_privilege` rejects an identity-argument string.**
`pg_get_function_identity_arguments(oid)` returns parameter *names* as well as
types, for example `p_key text, p_enable boolean`. GRANT and REVOKE accept that.
`has_function_privilege(role, text, 'execute')` parses its second argument as a
type list and raises `invalid type name`. Fix: resolve the `pg_proc.oid` and call
`has_function_privilege(role, oid, 'execute')`.

**Prose spliced into generated SQL.** A migration that patches function B by
string-generating a large text literal into function A's body has to double every
`'` twice and escape every `E'\n'` twice. It raises `42601: syntax error at or
near "\"` and no amount of careful counting fixes it reliably. This cost a full
migration attempt. Fix, and it is structural rather than cosmetic: **put the
prose in its own function** where quoting is ordinary, and splice only a few
short call lines into the caller. Migration 248 failed one way and succeeded the
other way with no change to the prose itself.

**A boolean parameter assumed to be `dry_run`.** The platform has both
conventions in play. `tf_link_revenue(p_dry_run boolean default true)` really is
a dry run. `tf_integration_watchdog(p_post boolean default true)` gates only the
outbound post, and `tf_system_health(p_post boolean default false)` gates only
snapshot persistence. Same type, same position, three different meanings. Read
the parameter *name*, not its type, and if the name is not `p_dry_run` do not
assume the call is inert.

**Refusal by `raise` rather than by return value.** Most staff-guarded read
models return `{"ok": false, "error": "forbidden"}`. `tf_data_quality_audit`
raises `P0001: not authorized` instead. The difference is invisible in a
single-call test and fatal in a bundled statement, because a raise aborts every
other call alongside it. Fix: run diagnostics one statement per call.

**Misleading evidence.** A diagnostic that collapses two distinct causes into one
label is worse than one that reports nothing, because it sends the operator
somewhere specific and wrong. The orphan-lane reporter did exactly this before
v7: it labelled a registered-but-undrained lane as `"registered": false`. If a
diagnostic can be wrong in two different ways, it must say which one.

---

## The house rules

Seven rules, each of which exists because breaking it cost real time.

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

**A runbook is code, and untested code is wrong.** This document shipped with a
first-ten-minutes block whose fourth line did not resolve, a function count off
by one, and a safety instruction that told the operator to set a field that was
already set. All three were caught by executing the document rather than
proofreading it, on the first pass after publication. Every command a runbook
gives an operator must be run, in the state and with the credentials the
operator will have, before it is published. The `do $drive$` rule applies to
prose exactly as it applies to migrations.

**A guard never observed refusing is not a guard.** Writing the guard is not
evidence the guard works. A migration that adds one must, in the same
transaction, impersonate a principal who should be refused and assert on the
refusal, distinguishing the two refusal styles: read paths return
`{"ok": false, "error": "forbidden"}`, mutating admin paths `raise`. Asserting
only that the call did not succeed is too weak, because a guard test that never
set `request.jwt.claims` also does not succeed at proving anything.

**A checker never observed catching anything is not a checker.** A checker that
returns zero violations on a clean database is indistinguishable from a checker
that returns zero violations always. Migration 248 therefore does this inside
its own transaction: assert the baseline is clean, deliberately open the hole
(`grant execute on function tf_automation_arm to authenticated`), assert the
checker now reports exactly one drift, assert the GRC control has flipped to
`failing`, revert the grant, assert the checker is clean again and the control
is `passing`. Every new checker owes the same proof. If the failure mode cannot
be induced in a transaction, that is a signal the checker is testing the wrong
thing.

**Conventions live in tables, checkers read the tables.** A detection rule
compiled into a checker body can only be revised by someone willing to rewrite
that function. The same rule in a table can be read, queried, added to and
audited by an operator with no context. This is why
`tf_function_safety_patterns`, `tf_boolean_param_conventions`,
`tf_automation_registry` and `tf_function_grant_tiers` exist as data.

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

**Before that flag is ever set to `true`,** refresh
`config ->> 'intake_autosend_since'` to the actual cutover moment. The field is
*not* empty, and that is the trap. It currently reads
`2026-07-18T02:51:54.728504+00:00`, set during build-out and now **176 hours**
stale. An operator who checks that the timestamp is present, sees a value, and
enables the flag will back-text every job created since 2026-07-18. A stale
cutover timestamp is more dangerous than a missing one, because a missing one
looks wrong and a stale one looks done.

**And `job_prep` is not the only one.** Three automations carry a populated,
stale cutover timestamp right now, each of which would back-contact on arming:

| Automation | Cutover key | Stale by | Rows it would touch on the first tick |
| --- | --- | --- | --- |
| `job_prep` | `intake_autosend_since` | 176 h | **17** |
| `review_requests` | `review_requests_since` | 172 h | **7** |
| `ai_booking` | `ai_agent.booking_since` | 165 h | 0 today, but the sweep POSTs to an edge function with no auth guard of its own and caps at five leads per tick, so the real exposure is the backlog across successive ticks |
| `marketplace_dispatch` | `marketplace_dispatch_since` | 172 h | not customer-reaching, but the predicate is still untranscribed |

Do not read those numbers from this table when it matters. Read them live:

```sql
select public.tf_automation_readiness();
```

That returns, per automation, the enabled state, the cutover path and value, the
cutover age in hours, the computed blast radius, and a verdict. Today: **13
automations, 0 armed, 0 ready, 10 blocked, 3 stale_cutover.**

### The arming procedure

**`tf_automation_arm(p_key text, p_enable boolean)` is the only sanctioned way
to flip an automation flag.** It is `admin` tier, so no authenticated session can
reach it. It validates the key, refuses to arm anything whose readiness verdict
is not clean, and writes to `automation_arm_log`. A flag changed by a direct
`update` on `integration_settings` bypasses all of that, and
`tf_automation_out_of_band()` will detect the discrepancy and open a ticket under
`safety:automation_cutover`, with control `CM-AUTOARM-020` failing until it is
reconciled. That is the intended outcome. Out-of-band arming is treated as an
incident, not as a shortcut.

The sequence, in order, and never any other order:

1. `select public.tf_automation_readiness();` and find the automation.
2. `select public.tf_automation_blast_radius('<key>');` and read the number of
   rows the first tick will touch. If that number surprises you, stop.
3. Refresh the cutover timestamp to `now()`.
4. Re-run `tf_automation_readiness()` and confirm the verdict is no longer
   `stale_cutover`.
5. `select public.tf_automation_arm('<key>', true);`
6. Watch the next tick. Every sweep is on pg_cron at a two-to-five minute cadence,
   so confirmation is minutes away, not hours.

Never arm on the strength of a field merely being populated. Never arm two
automations in the same window; if something goes out that should not have, you
want exactly one candidate.

**Ten automations are blocked and cannot be armed at all today**, because their
blast-radius predicate has not been transcribed into `tf_automation_registry`.
That is deliberate. Of those, three, `live_connect`, `missed_call_textback` and
`push_estimates_to_hcp`, are implemented entirely in edge functions and no
`tf_*` function references their key, so a SQL blast radius cannot be computed
for them in principle. They stay blocked with that explanation rather than being
waved through. The remaining seven, `cx_sequences`, `cx_first_response`,
`eta_reminders`, `appt_reminders`, `estimate_followups`,
`late_penalty_enforcement` and `marketplace_dispatch`, are blocked pending
transcription and are the next tranche of work.

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
| ~~6~~ | ~~Normalise the 2 bare QuickBooks invoice external ids (80, 82)~~ | `86bb3byg5` | **resolved by migration 237** |

Item 6 is closed. Migration 237, `normalize_bare_quickbooks_invoice_external_ids`,
normalised both rows and added the unique index
on the normalised expression, so the defect cannot recur rather than merely
having been cleaned up. Verified 2026-07-25: 31 of 31 invoices carry a
`<realm>:<qbId>` external id, zero bare.

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
| Migrations applied | 248 |
| Base tables in `public` | 170 |
| Tables with RLS enabled | 170 (100%) |
| RLS policies | 581 |
| Functions in `public` | 269 |
| `tf_*` operator functions | 78 |
| `tf_*` functions declared in `tf_function_registry` | 78 (100%) |
| Functions with a declared grant tier | 12 |
| Views | 7 |
| Enums | 80 |
| Indexes | 654 |
| Active pg_cron jobs | 37 |
| Edge functions | 37 |
| GRC controls | 21 |
| Controls passing / attention / failing | 19 / 2 / 0 |
| Automations armed | 0 of 13 |

170 of 170 tables carry RLS. That is the number to re-check after any migration
that creates a table, because a new table without RLS is the single fastest way
to open a cross-tenant leak, and `rls_disabled_tables` is the axis that catches
it.

78 of 78 `tf_*` functions are declared in `tf_function_registry`. That is the
second number to re-check, because an undeclared function is one whose
side-effect class nobody has stated, and `tf_function_safety_audit()` will open a
ticket under `safety:function_drift` within fifteen minutes if the two counts
diverge.

The two controls in `attention` are both owner actions rather than code defects:
`AC-MFA-003`, one privileged account without MFA, and `DP-PITR-007`,
point-in-time recovery not yet enabled. Zero controls are failing.

To reproduce this whole table in one statement:

```sql
select
  (select count(*) from supabase_migrations.schema_migrations)                         as migrations,
  (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
     where n.nspname='public' and c.relkind='r')                                       as base_tables,
  (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
     where n.nspname='public' and c.relkind='r' and c.relrowsecurity)                   as rls_tables,
  (select count(*) from pg_policies where schemaname='public')                          as policies,
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public')                                                          as functions,
  (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
     where n.nspname='public' and p.proname like 'tf/_%' escape '/')                    as tf_functions,
  (select count(*) from public.tf_function_registry)                                    as declared,
  (select count(*) from public.tf_function_grant_tiers)                                 as tiered,
  (select count(*) from cron.job where active)                                          as cron_jobs,
  (select count(*) from public.it_controls)                                             as controls;
```

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
- `FUNCTION_GRANT_TIERS.md` — the three-tier grant model, the Supabase default-privileges trap, `CM-GRANT-021`
- `MIGRATIONS_INDEX.md` — the ordered migration manifest

Notion carries the same material for non-engineers under **🧭 Operations Hub —
SOPs & FAQs**, with persona-routed SOPs and FAQs. ClickUp carries the
operational queues and the ticket surface.

---

## Verification log

This document is driven, not proofread. Each pass runs every command it gives an
operator, in the state and with the credentials that operator will have, and
records what broke.

**Pass 1, 2026-07-25, at migration 231.** Four defects found, all in the
document, none in the database.

| Claim as published | Live reality | Resolution |
| --- | --- | --- |
| `tf_integration_health_report()` is a first-ten-minutes read | raises `42883`; the function is a five-argument writer that opens a ticket | replaced with a plain `integration_settings` select; the trap documented |
| `tf_integration_watchdog` implied safe to inspect | writes on both paths, `p_post` gates only the Slack post | annotated as not a diagnostic |
| `tf_*` operator functions: 68 | 67 | corrected |
| `intake_autosend_since` implied unset | set, and a week stale at `2026-07-18T02:51:54` | instruction changed from *set* to *refresh* |

Everything else held exactly. `tf_system_health(false)` returned `degraded` on
QuickBooks and ClickUp only, with all nine other components operational and
their detail strings verbatim. `tf_security_scan()` returned five axes in the
documented order, all zero, `gap_total: 0`. `tf_queue_health()` returned
`operational`, ten registered lanes matching the published registry row for row,
zero orphans, zero stuck. `tf_scheduler_health()` returned 36 jobs, all firing,
zero stalled, zero failing. `tf_data_quality_audit()` returned zero on all six
checks. `tf_revenue_linkage_audit(90)` and `tf_marketing_roi(90)` independently
returned 83.5% and $10,721.31 from separately computed paths, which is the
agreement that makes the number worth quoting. Every inventory figure but the
one above matched. The `job_prep` flag reads `false`.

The finding worth carrying forward: the three failures clustered entirely in the
*first* section, the one an operator reaches first and trusts most. Sections
written by transcribing live output were correct. The section written by
reasoning about what an operator should run was not. Documentation drifts
fastest where it is least examined and most load-bearing.

**Pass 2, 2026-07-25, at migration 248.** Seventeen migrations landed between
pass 1 and pass 2. Six defects found, again all in the document, none in the
database.

| Claim as published | Live reality | Resolution |
| --- | --- | --- |
| Migrations applied: 231 | 248 | corrected, along with every other inventory row, all of which had moved |
| `tf_*` operator functions: 67 | 78 | corrected; registry coverage row added so the two can be compared |
| "Two functions were named badly enough to survive review; assume there is a third" | **seven**, proven from `tf_function_registry`, of which two are acknowledged diagnostics-that-mutate | replaced the estimate with the measured table |
| One stale cutover timestamp (`intake_autosend_since`) | **three** stale cutovers, with measured blast radii of 17 and 7 rows | generalised, and the operator pointed at `tf_automation_readiness()` rather than at a hard-coded field |
| Grant tiers described as prose, `anon` tier "intentionally empty" | tiers are now data in `tf_function_grant_tiers`; `anon` has exactly one deliberate member, `studio_is_staff` | rewritten against the live tier table, with the Supabase default-privileges trap documented |
| Arming procedure absent entirely | `tf_automation_arm` is the only sanctioned path and out-of-band arming is a detected incident | full arming procedure added |
| Owner action 6 still listed open | resolved by migration 232, 0 of 31 invoices bare | struck through and the ticket closed |

Everything re-measured this pass agreed with the database on the second reading:
`tf_grant_tier_audit()` returned `violation_total: 0` across 12 declared tiers,
`tf_controls_evaluate()` returned 21 controls with 19 passing, 2 in attention and
0 failing, `tf_security_scan()` returned all five axes at zero with `gap_total: 0`,
and all 13 automation flags read `false`.

The finding worth carrying forward from this pass is sharper than pass 1's. Every
single defect was a **number or a count that had been correct when written**. Not
one was a reasoning error. The document did not become wrong, it became stale,
and stale reads exactly like correct to the operator at 2am. The countermeasure
is the same one the database uses on itself: where this document states a count,
it now also states the query that produces it, so the next reader can refute it
in one round trip instead of trusting it.

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
