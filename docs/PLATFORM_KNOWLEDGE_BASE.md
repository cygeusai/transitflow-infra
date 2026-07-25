# Transit & Flow — Platform Knowledge Base

The single troubleshooting reference for the Transit & Flow backend. Written to
be read at 2am by someone who did not build it.

State captured 2026-07-25 against Supabase project `kjooyhvynkzuvsixsutt` at
migration 267. Every number in this document was read out of the live database,
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
select public.tf_guard_detection_audit();  -- is the guard check itself sound?

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
| `tf_guard_detection_audit()` | none | staff, or no JWT |
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
| A new function is reachable by `anon` and nobody granted it | Supabase `ALTER DEFAULT PRIVILEGES`; `revoke from public` does not undo it, and neither does `revoke from anon` alone, because Postgres grants EXECUTE to PUBLIC on every new function | `tf_grant_tier_audit()`; fix with `tf_apply_grant_tier` |
| `CM-GRANT-021` evidence says "across N of 84" with N below 84 | somebody created a `tf_*` function without a `tf_apply_grant_tier` call in the same migration | `tf_grant_tier_audit()` → `coverage_pct` and the `violations` array, which names it |
| `CM-GRANT-021` reads `failing` and the named function is reachable by nobody | since migration 262 an undeclared tier is a violation whether or not anything can reach it, because unreachable is not the same as *intended* to be unreachable | `tf_grant_tier_audit()` → `uncovered_total` and `uncovered_unreachable_total`; the violation row carries `reachable_by: 'none'` and a ready `tf_apply_grant_tier` remedy |
| `CM-GRANT-021` reads `attention` with no evidence string at all | `tf_grant_tier_audit()` itself raised, so `tf_controls_evaluate` caught it and propagated null; since migration 263 the most likely cause is the empty-population refusal | call `select public.tf_grant_tier_audit();` directly and read the raise: `refuses to certify` means the `tf_*` population came back zero |
| `AC-GUARDREG-023` evidence shows a scanned count below 55 | functions were excused into `security_scan_exemptions`, or dropped; since migration 267 the evidence says which, in the `[population R reachable, E exempted, S stale exemption(s)]` suffix | `tf_guard_detection_audit()` → `exempted_fns` names every excused function; compare `reachable_total` against the previous reading |
| `AC-GUARDREG-023` reads `failing` and names a stale exemption | a row in `security_scan_exemptions` names something that is not a definer function reachable by `authenticated`, usually a rename or drop that left the exemption behind | `tf_guard_detection_audit()` → `stale_exemption_fns`; confirm the function is gone, then delete the row. Never create a function under that name to satisfy it |
| `AC-GUARDREG-023` reads `attention` with no evidence string | the audit raised and `tf_controls_evaluate` propagated null; since migration 266 the likely cause is the empty-population refusal | `select public.tf_guard_detection_audit();` and read the raise: `refuses to certify an empty population` means every reachable definer function has been excused |
| Two customer records for one person | Dedup sweep has not run, or phones differ in format | `tf_merge_duplicate_customers(true)` (dry run) |
| Scheduled report did not arrive in Slack | Cron fired but Slack connector degraded | `tf_scheduler_health()` then the `integration_settings` query above |
| A `tf_*` call raises `42883` or does something unexpected | The name implies a read; the function is a writer | *The first ten minutes*, side-effect table |
| Events piling up, nothing draining | Producer writing to a lane with no consumer | `tf_queue_health()` → `orphan_lanes[].reason` |
| A staff user gets `forbidden` from an RPC | Function is `service_role`-only, not staff-callable | *The grant tiers* below |
| A function raises `42501 permission denied` | Same as above: wrong grant tier for the caller | `information_schema.routine_privileges` |
| A function raises `42883 operator does not exist` | Type drift between a new column and an existing enum | *Convention drift* |
| Owner portal shows another owner's property | RLS policy defect. Stop and treat as P0 | `pg_policies` for the table in question |
| Health board shows "X unavailable" | The diagnostic itself is broken | Read the component's underlying function |
| A customer in the demo tenant received a production-branded text | A sweep is missing its `company_id` predicate | read the sweep's `where` clause; migration 249 closed three, migration 250 closed two settings reads |
| `tf_automation_readiness()` reports a note that contradicts the sweep | The migration changed the code and not the registry note | `tf_automation_note_drift()`; control `CM-NOTEDRIFT-022` |
| `42601: too many parameters specified for EXECUTE` from a blast-radius call | The predicate ignores `$1` or `$2` | *Defect-pattern library*, "Blast-radius predicate arity" |
| `42P10: no unique or exclusion constraint matching ON CONFLICT` | The arbiter guessed does not exist on that table | `select conname, pg_get_constraintdef(oid) from pg_constraint where conrelid='<table>'::regclass` |
| `42601: too many parameters specified for RAISE` in a freshly patched function | A `%%` was written inside an anchored `replace()` payload | *Defect-pattern library*, "No doubling layer inside a catalog patch" |
| `AC-GUARDREG-023` is failing | A definer function reads as guarded only because of a comment, or the scanner stopped reading the registry | `tf_guard_detection_audit()` → `comment_only_fns` then `integrity_violations`; see `GUARD_DETECTION.md` |
| `AC-DEFN-017` and `AC-GUARDREG-023` fail together, naming the same function | A real unguarded definer function reachable by `authenticated` | read the body, add a guard or an approved `security_scan_exemptions` row |
| `tf_guard_pattern: tf_guard_predicate_registry is empty` | Somebody truncated the guard registry | reseed from migration 253; the raise is deliberate, a null pattern would pass everything |
| Three security controls read `attention` at once and evidence shows `?` | `tf_security_scan()` raised, so its signals propagate null | call `tf_security_scan()` directly and read the actual error |

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

**How the platform decides a function carries one of these forms.**
`tf_security_scan` matches a pattern assembled from
`tf_guard_predicate_registry` against
`tf_strip_sql_comments(pg_get_functiondef(oid))`. Comments are stripped before
the match, so a sentence describing a guard is not a guard. String literals are
deliberately left in, because a function that builds dynamic SQL carries its
`where` clause in a literal by construction; literal-only matches are reported as
advisory rather than gated. Both counts are zero today. The rules are rows, not
code: adding a sixteenth helper is an `insert`, and editing the scanner to add a
name is the defect that `AC-GUARDREG-023` exists to catch. Full treatment in
[`GUARD_DETECTION.md`](./GUARD_DETECTION.md).

### The grant tiers

Guards in the function body are only half the story. The `EXECUTE` grant decides
who can reach the body at all, and the two mechanisms are frequently confused.

Since migration 248 (`grant_tier_drift_control`) the tiers are **data, not
prose**. They live in
`public.tf_function_grant_tiers`, they are applied by
`public.tf_apply_grant_tier`, they are checked by `public.tf_grant_tier_audit`,
and control `CM-GRANT-021` fails the board if the live ACL stops matching. Since
migration 262 the checker also fails the board on **its own coverage**, and since
migration 263 it refuses to certify an empty population rather than reporting one
as complete. The full treatment is in `FUNCTION_GRANT_TIERS.md`. The short
version:

| Tier | Roles granted | Requires an in-body guard | Count | Typical members |
| --- | --- | --- | --- | --- |
| `admin` | `postgres`, `service_role` | no, the grant *is* the control | 48 | `tf_automation_arm`, `tf_apply_grant_tier`, `tf_safety_autoticket`, `tf_grant_tier_autoticket`, `tf_vault_set_secret`, the queue operators, every `*_sweep` |
| `staff` | adds `authenticated` | **yes, always** | 36 | `tf_grant_tier_audit`, `tf_automation_readiness`, `tf_control_attest`, `tf_owner_dashboard`, `tf_customer_360`, `tf_marketing_roi`, `tf_send_intake` |
| `anon` | adds `anon` | yes | 1 | exactly one: `studio_is_staff`, documented below |

Eighty-five declared rows, covering **84 of 84** `tf_*` functions, `coverage_pct`
100.0, `violation_total` 0. The eighty-fifth row is `studio_is_staff`, which is
not a `tf_*` function.

**Why this drifts on its own.** Supabase installs `ALTER DEFAULT PRIVILEGES IN
SCHEMA public GRANT EXECUTE ON FUNCTIONS TO anon, authenticated`. Those are
*named-role* grants. The idiom used across this repo for years,
`revoke all on function ... from public`, revokes only the PUBLIC pseudo-role
and leaves `anon` and `authenticated` still holding EXECUTE. Every new function
in `public` is therefore reachable by an anonymous caller from the moment it is
created until something names `anon` explicitly. This is not a Supabase defect,
it is the platform default, and it is the reason the tier has to be asserted
rather than assumed.

**And revoking `anon` alone does not close it either.** PostgreSQL grants EXECUTE
to the PUBLIC pseudo-role on every newly created function, on top of anything
Supabase installs. Because every role is a member of PUBLIC,
`has_function_privilege('anon', oid, 'execute')` stays true after
`revoke execute ... from anon`. Both revokes must appear in one statement. This
was found by migration 260's fixture-setup assertion, which caught it on the
person writing the proof harness.

**The coverage defect, closed by migrations 258 through 261.** Through migration
257 only 18 of the 84 `tf_*` functions carried a declared tier, and the audit's
undeclared class only looked at functions reachable by `anon`. Since `anon`
reaches almost nothing here, that class read zero permanently. Sixty-six
functions were untiered, twenty-seven of them reachable by `authenticated`, and
the control reported green. **Not declaring a tier was a way to never be checked
for tier drift**: the checker's coverage was decided by the population being
checked. 258 declared the full surface at current live reality with a proven
zero-reachability-change assertion, 259 widened the sweep to
`anon or authenticated` and added `tf_population_total`, `tf_covered_total` and
`coverage_pct`, 260 proved the widened sweep by inducing exactly the blind case,
and 261 widened the two consumers still reading the narrow number. Grants were
deliberately **not** demoted in bulk, because silently revoking `authenticated`
from functions the Lovable Hub calls is quiet corruption.

**And the coverage number was still inert, closed by migrations 262 through
264.** 258 through 261 made the checker's coverage complete and visible. They did
not make it *enforced*. Between 259 and 261 `coverage_pct` was computed, returned
and printed into the control's evidence string, and nothing failed on it. A
function created without a `tf_apply_grant_tier` call would have dropped
`coverage_pct` below 100 and `CM-GRANT-021` would still have read `passing`,
because `violation_total` did not include the shortfall. Publishing a denominator
is not the same as failing on it. Migration 262 folded the shortfall into
`violation_total` as a first-class class, `uncovered_total`, and proved it by
inducing the one shape migration 260's fixture structurally could not catch: an
untiered function reachable by **nobody**. That shape fell out of every existing
violation class while quietly dropping coverage. The reasoning for treating it as
a violation rather than a benign gap is that being unreachable is not the same as
being *intended* to be unreachable, and only the register records intent.

Migration 263 closed the complementary hole at the other end. If the population
read from `pg_proc` ever came back zero, the arithmetic would have produced
`coverage_pct` 100 on a denominator of nothing and certified a failed measurement
as full coverage. The audit now raises instead, with a message that says so in
words: *"An empty population is a failed measurement, not full coverage. Emptying
the input must never be a way to pass a control."* `tf_controls_evaluate` catches
that raise and propagates null, which surfaces as `CM-GRANT-021` reading
`attention` with no evidence, which is the symptom row above.

Migration 264 widened the two consumers, `tf_controls_evaluate` and
`tf_grant_tier_autoticket`, additively, per convention 21. Neither existing key
changed meaning; `uncovered_total` and `uncovered_unreachable_total` were added
beside `undeclared_anon_total` and `undeclared_reachable_total`, which remain
strict subsets. `violation_total` is deliberately
`drift_total + missing_total + uncovered_total` and **not** the sum of every key,
because `undeclared_reachable_total` is a strict subset of `uncovered_total` and
summing both would double-count every exposed function. An internal-consistency
raise enforces the partition: `uncovered_total` must equal
`undeclared_reachable_total` plus `uncovered_unreachable_total`, or the audit
raises rather than returning an arithmetic it cannot explain.

The live `CM-GRANT-021` evidence string today, verbatim, states its denominator
and its enforcement:

> 0 function grant-tier violation(s) across 84 of 84 tf_* fn(s) declared (100.0
> pct), of which 0 undeclared and 0 of those reachable: live EXECUTE grants
> versus tf_function_grant_tiers, plus every tf_* fn with no declared tier
> whether reachable or not. Coverage is enforced since 262, and an empty
> population is refused rather than certified since 263

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

**Read this before you trust the zero.** The fifth axis is a *textual* test, and
until migration 254 it was a worse one than anybody reading the green zero
realised. Two things changed.

**The rules moved out of the function and into a table.** The fifteen
authorization identifiers now live in `public.tf_guard_predicate_registry`, one
row each, carrying a regex fragment, a guard class and a written rationale.
`tf_guard_pattern()` assembles the alternation from that table and
`tf_security_scan` calls it. Adding a sixteenth helper is an `insert`, not a
rewrite of the scanner.

| Guard class | Helpers |
| --- | --- |
| `staff_role` | `user_is_internal_staff`, `user_is_internal_writer`, `studio_is_staff` |
| `permission` | `has_permission`, `user_has_role`, `current_user_role`, `is_privileged_role` |
| `tenant_scope` | `user_company_id`, `current_company`, `current_tenant_`, `is_company_member` |
| `owner_scope` | `current_owner_` |
| `assignment` | `user_is_assigned_to_` |
| `session_identity` | `auth.uid`, `current_supabase_user_id` |

Three fragments are prefixes on purpose. `current_owner_` covers
`current_owner_unit_ids` and `current_owner_work_order_ids`; `current_tenant_`
and `user_is_assigned_to_` cover their families the same way.

**The match now runs against code, not source text.** The scan compares the
pattern to `tf_strip_sql_comments(pg_get_functiondef(oid))`. Before migration
254 it matched raw source, which meant a function whose only guard was the
sentence `-- protected by auth.uid() and user_is_internal_staff` passed the
check, `AC-DEFN-017` read `passing`, and the dashboard was green. Zero functions
were actually exploiting that, measured, but nothing prevented it and nothing
would have reported it.

String literals are deliberately **not** stripped before the gating match. A
function that builds dynamic SQL puts its `where` clause in a literal by
construction, so gating on literal-stripped source would fail functions for
doing the right thing. Literal-only matches are reported by
`tf_guard_detection_audit()` as `literal_only_total` for a human to look at.
Both that and `comment_only_total` are zero today.

What is still true: a function that *calls* a guard helper and ignores the
result passes. A semantic check is not expressible in SQL. **A green fifth axis
is evidence, not proof.** When a new definer function is granted to
`authenticated`, read its guard yourself. Do not let the scan read it for you.

`tf_security_scan` gained two additive output keys, `guard_pattern_source` and
`guard_helpers`, so the payload describes its own rules to whoever reads it.
Control **AC-GUARDREG-023** watches the watcher: it fails if the registry is
emptied, if the scanner stops calling `tf_guard_pattern` or
`tf_strip_sql_comments`, if an inline alternation reappears in the scanner body,
or if any function reads as guarded only because of a comment. The full design,
the before-and-after code and the operator runbook are in
[`GUARD_DETECTION.md`](./GUARD_DETECTION.md).

There are 55 definer functions reachable by `authenticated` and not exempt. All
55 carry a recognised authorization predicate in executable code. The guards
break down as strict staff, cron-tolerant staff, RBAC via `has_permission`, and
party-scoped through `user_is_internal_writer` or the `current_owner_*` and
`current_tenant_*` helpers.

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

Twenty-five conventions. Repeatedly, the highest-yield defect on this platform has been two writers
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
| 14 | Detection rules as data | patterns live in tables, not in checker bodies | `tf_function_safety_patterns`, `tf_boolean_param_conventions`, `tf_automation_registry`, `tf_function_grant_tiers`, `tf_guard_predicate_registry` |
| 15 | Tenant scoping in sweeps | every sweep filters `company_id = v_company`, and the enable flag it reads is scoped the same way | migration 249 for the sweeps, migration 250 for the settings reads; the reviewer's check is `pg_get_functiondef` |
| 16 | Automation bounding | every automation declares `bounded_by` as one of `cutover`, `natural_window`, `unbounded`, `edge_function` | CHECK constraint on `tf_automation_registry.bounded_by`; `tf_automation_arm` refuses an `unbounded` automation with a non-zero blast radius |
| 17 | Blast-radius predicate arity | every predicate references both `$1` (cutover) and `$2` (company), using the visible tautology where there is no cutover | `tf_automation_blast_radius` executes `using coalesce(v_since, now()), v_company`; a predicate that ignores either one raises at call time |
| 18 | Registry note currency | the note is part of the change, not documentation of it, and is rewritten in the same transaction as the sweep | `tf_automation_note_drift`, control `CM-NOTEDRIFT-022`, ticket key `safety:note_drift` |
| 19 | Guard detection as data, matched on code | guard-helper names live in a table, and the match runs against comment-stripped source so a comment cannot stand in for a guard | `tf_guard_predicate_registry`, `tf_guard_pattern`, `tf_strip_sql_comments`, `tf_guard_detection_audit`, control `AC-GUARDREG-023`, ticket key `safety:guard_detection` |
| 20 | Checker coverage is published, not assumed | a register a checker reads is complete by construction, the audit returns its own `population` / `covered` / `coverage_pct`, and the control's evidence string states its denominator | `tf_grant_tier_audit` coverage keys, the widened `CM-GRANT-021` evidence string, migration 260's induced-failure proof; publication alone proved insufficient and is now backed by convention 22 |
| 21 | Widen a signal, never repurpose a key | a narrowed key keeps its original meaning and the wider key is added beside it, because a redefined key does not break consumers, it makes them quietly wrong | `undeclared_anon_total` retained as a strict subset of `undeclared_reachable_total` across migrations 259 and 261, and both retained beside `uncovered_total` across 262 and 264 |
| 22 | A checker's own coverage is a violation class, not a statistic | if the register a checker reads is incomplete, the checker **fails**; a shortfall is folded into `violation_total`, not merely printed next to it | `tf_grant_tier_audit` `uncovered_total`, gating since migration 262, proved by an untiered fixture reachable by nobody |
| 23 | A checker must refuse on an empty population, not certify one | zero inputs is a failed measurement, and the checker raises rather than dividing into a denominator of nothing and reporting 100 percent | `tf_grant_tier_audit` empty-population raise, migration 263; `tf_controls_evaluate` propagates null, so the control reads `attention` rather than `passing` |
| 24 | Prove by inducing the failure; where the live object cannot be broken, prove on a derived clone and say so | build the clone from the live catalog text by asserted mechanical substitutions, name it outside the population being measured so the proof does not perturb itself, assert every substitution landed and that the branch under test survived, drop it, then label the proof as weaker than an induced one **in writing** | migration 263's `zz__granttier_refusal_clone()`, labelled in `FUNCTION_GRANT_TIERS.md` as the weakest of the three proofs in that document |
| 25 | An exclusion lever must be visible in the number it shrinks, and a stale exclusion is a violation | a checker that supports exclusions publishes the full population, the excluded count and the excluded names, asserts the partition `population = measured + excluded` in its own body, and treats an exclusion naming nothing real as a violation rather than a curiosity | `tf_guard_detection_audit` `reachable_total` / `exempted_total` / `exempted_fns` / `stale_exemption_total`, gating since migration 265, surfaced on `AC-GUARDREG-023` since migration 267, proved by a planted stale exemption |

The countermeasure that keeps working is the same every time: express the
convention in the database, on the *normalised* form of the value, so violation
is impossible rather than merely discouraged.

Convention documented in prose is a convention that will drift. Convention
expressed as a unique index is a convention that cannot.

**Conventions 8 through 19 share a shape worth naming.** Each one is a table of
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

**The unscoped sweep.** A sweep selects its candidates from a shared table with
no `company_id` filter, or reads the enable flag from `integration_settings`
without scoping that read either. It is invisible while the flag is off, which
is exactly the window in which nobody looks at it, and it becomes a cross-tenant
send the instant the flag flips. Migration 249 found three of these and measured
the exposure before fixing them: three jobs existed outside the production
tenant, all three matched `tf_review_request_sweep`'s candidate predicate, so
arming `review_requests` would have texted those customers from the production
number under the Transit & Flow brand. Migration 250 then found two *settings*
reads the first pass had missed, in sweeps whose candidate query was already
correctly scoped. Fix: scope the candidate query and the flag read, in the same
migration, and re-read `pg_get_functiondef` afterwards rather than trusting the
patch. Reviewer's rule: a sweep is not scoped until both halves are.

**Blast-radius predicate arity.** `tf_automation_blast_radius` runs every
registered predicate as `execute ... using coalesce(v_since, now()), v_company`,
so `$1` is the cutover timestamp and `$2` is the company id. PL/pgSQL raises
`42601: too many parameters specified for EXECUTE` when a predicate references
fewer placeholders than the `using` clause supplies, which means a predicate that
legitimately has no cutover bound still has to mention `$1`. Fix, and it must be
visible rather than clever: append
`and ($1::timestamptz is not null or $1::timestamptz is null)`. It is a tautology
on purpose. Silently dropping the parameter is the failure this shape prevents.

**No doubling layer inside a catalog patch.** Ordinary generated SQL has two
levels of quoting, so authors learn to double things. An anchored catalog patch
has only one: the `replace()` payload is written into the function source
literally. A `%%` intended as an escaped percent therefore lands as a literal
`%%` in the body, PL/pgSQL reads it as an escaped percent consuming zero
arguments, and the function raises `42601: too many parameters specified for
RAISE` on its first call. Use a single `%` per argument inside a patch payload.

**The inverse quoting rule inside dollar quotes.** Inside `$j$ ... $j$` a single
quote is literal and must **not** be doubled. Doubling it stores two apostrophes
in the text. This is the exact inverse of the ordinary quoted-string rule, and
the two rules are usually a few lines apart in the same migration, which is why
this keeps happening. Caught pre-flight in migration 251 by reading the payload
back before applying it.

**The guessed ON CONFLICT arbiter.** `it_controls` carries `UNIQUE (control_key)`
and `PRIMARY KEY (id)`, not the composite `(company_id, control_key)` that the
multi-tenant shape of the table suggests. Writing the plausible composite raises
`42P10: there is no unique or exclusion constraint matching the ON CONFLICT
specification`, and it raises it at apply time, so it costs a migration attempt
rather than corrupting anything. Fix: `select conname, pg_get_constraintdef(oid)
from pg_constraint where conrelid = '<table>'::regclass` before writing an upsert
against a table the current session has not already written to. This is the same
discipline as reading `information_schema.columns` before writing a select, and
it is the same failure mode: reasoning about the schema instead of reading it.

**A register that drifts inside the migration that creates the drift.**
Migration 251 created `tf_automation_note_drift` and did not declare it in
`tf_function_registry`. `tf_function_safety_audit()` reported
`undeclared_total: 1` within minutes and `CM-FNDRIFT-018` was working exactly as
designed, which is the good news and the whole point of the register. The bad
news is that the migration should never have shipped a function without its
declaration. Fix, now a house rule: a migration that creates a function declares
it in `tf_function_registry` and `tf_function_grant_tiers` in the same
transaction. Closed by migration 252; `undeclared_total` is back to 0.

**Projecting keys from a payload nobody enumerated.** Four post-migration
measurement queries in a single sitting returned nulls because they selected
JSON keys that do not exist: `total`, `write_total`, `read_total` and
`misleading_name_total` on `tf_function_safety_audit()`, where the counts
actually live under a nested `totals` object and the key is `misleading_total`;
and `automation_key` and `armed` on the readiness payload, where the real keys
are `key` and `enabled`. A null is not an error, so this class of mistake reads
as "zero" rather than as "wrong question", which makes it more dangerous than a
syntax error. Fix: `select jsonb_object_keys(<payload>)` once, then project. Same
lesson as the column-name assumption, one layer up.

**The checker with its rules compiled in.** `tf_security_scan` decided whether a
`SECURITY DEFINER` function was guarded by matching a fifteen-name regex written
directly into its own body, against raw `pg_get_functiondef` output. Two
failures in one. The rules could not be extended without rewriting the scanner,
violating convention 14 in the one place it mattered most. And matching raw
source meant comments counted: a function whose entire guard was the sentence
`-- authorization: protected by auth.uid() and user_is_internal_staff` passed,
and `AC-DEFN-017` reported `passing` over it. Measured exposure at discovery was
54 of 54 functions passing on both raw and stripped source, so zero were
actually exploiting it, but nothing prevented the fifty-fifth. Fix, migrations
253 through 257: rules into `tf_guard_predicate_registry`, match against
`tf_strip_sql_comments(...)`, and a new control `AC-GUARDREG-023` that fails if
either property is ever reverted. The general shape: **when a checker's rules
live inside the checker, nothing checks the rules.**

**The null pattern that passes everything.** `x !~* null` evaluates to null, not
true. A checker that builds its match pattern by aggregating a table returns
null the moment that table is empty, and a `where ... !~* null` filter then
returns zero rows. The control reads `passing` while protecting nothing, and
truncating a table becomes a way to turn a dashboard green. This is why
`tf_guard_pattern()` is `plpgsql` rather than `sql`: its only reason to exist in
that language is to `raise` on an empty registry instead of returning null. Any
checker that derives its rules from a table must refuse to run on an empty
table. Loud failure over quiet corruption.

**A control that passes because its own evaluation crashed.**
`tf_controls_evaluate` called `tf_security_scan()` as its unguarded first
statement and used `coalesce(..., 0)` on the result. Introducing a function that
can `raise` anywhere in that call chain would have aborted the entire evaluation,
leaving all twenty-three controls holding whatever status they last had, with no
signal that the evaluation never ran. Worse, the `coalesce` to zero meant a
partially-failed measurement would have read as a clean result. Fix in migration
255: wrap every audit call in `begin ... exception when others then <var> := null;
end`, propagate `null` rather than `0`, and report `attention` on null. A zero
substituted for a failed measurement is a false green, and a false green is worse
than a red.

**The checker whose coverage was decided by the thing it checked.** This is the
sibling of the two defects above and the subtlest of the three. `tf_grant_tier_audit`
had correct rules, a table-driven register, an induced-failure proof from
migration 248, and a control wired into both CASEs. It reported
`violation_total: 0` truthfully. It was auditing eighteen of eighty-four
functions.

The three violation classes were drift on a declared tier, a declaration pointing
at a missing function, and an undeclared function reachable by `anon`. Read them
together: a function with no declaration was invisible unless `anon` specifically
could reach it, and `anon` reaches almost nothing here. **Not declaring a tier was
a way to opt out of enforcement entirely.** Sixty-six functions were untiered,
twenty-seven reachable by every signed-in identity in the system, and the
denominator, eighteen, appeared nowhere a human would read it. The knowledge base
itself had rationalized the gap in prose as deliberate.

Fix, migrations 258 through 261. Declare the whole surface at *current live
reality* rather than at an aspirational tier, asserting that not one function's
reachability changed, because bulk-revoking `authenticated` from functions the
Hub calls is quiet corruption. Widen the undeclared sweep to
`anon or authenticated`. Make the audit publish `tf_population_total`,
`tf_covered_total` and `coverage_pct`. Prove it by inducing a definer function
reachable by `authenticated` and not by `anon` with no declared tier, asserting
the old predicate reads zero on it first. Then update every consumer still
reading the narrow number, additively.

The general shape: **a checker must publish what it found, what it looked at, and
what it could not see.** A violation count without a denominator is an opinion.

**The coverage number that was visible and inert.** The direct sequel to the
defect above, and the reason that defect gets two entries instead of one.
Migrations 258 through 261 made `tf_grant_tier_audit`'s coverage complete and
visible: `tf_population_total`, `tf_covered_total` and `coverage_pct` were
computed, returned, and concatenated into the `CM-GRANT-021` evidence string
where a human would read them. Nothing failed on them. Had somebody created a
`tf_*` function without a `tf_apply_grant_tier` call, `coverage_pct` would have
dropped below 100, the evidence string would have said so in plain text, and the
control would still have read `passing`, because `violation_total` was
`drift_total + missing_total + undeclared_reachable_total` and the coverage
shortfall was in none of those. **Publishing a denominator is not the same as
failing on it.** Nobody was paged, no ticket opened, and the number sat in an
evidence string waiting for somebody to happen to read it.

The blind spot had a specific shape, and it was the complement of the one
migration 260 proved. 260's fixture was reachable by `authenticated`, so it
landed in `undeclared_reachable_total` and was caught. An untiered function
reachable by **nobody** fell out of every violation class while still dropping
`coverage_pct`. Migration 262 made any uncovered function a violation on the
reasoning that being unreachable is not the same as being *intended* to be
unreachable, and only the register records intent. It proved this with a fixture
built to be the caught-by-nothing shape, asserting that
`undeclared_reachable_total` stayed **unchanged** while `uncovered_total`,
`uncovered_unreachable_total` and `violation_total` all moved, then dropping it
and asserting every counter returned to baseline.

Migration 263 closed the mirror-image failure: a zero population would have
certified a failed measurement as 100 percent coverage. The audit now raises. The
general shape here is worth carrying to every other checker on the platform:
**a number a checker publishes but never fails on is documentation, not a
control.** Ask of any coverage figure, what happens when this drops? If the
answer is "the string changes", it is inert.

**The denominator with a lever attached.** Carrying the question above to a
second checker produced a sharper version of the same defect, and this one had a
control-tampering shape rather than an oversight shape.
`tf_guard_detection_audit` is the function that decides whether every
security-definer function on the platform carries an authorization predicate. It
published one population number, `scanned`, which read 55. It did not publish how
many definer functions were actually reachable by `authenticated`, which was 57.
It did not publish that two had been excused, and it did not name them. And
`security_scan_exemptions`, the table that does the excusing, has no cardinality
limit, no approval workflow beyond a free-text `approved_by` column, and no
counter anywhere in the payload.

The consequence is not that the number was incomplete. It is that the number had
a lever attached and the lever was invisible from the readout. An operator facing
an unguarded function had two ways to make the finding go away: add a guard, or
add a row. The second is faster, requires no review, and moves the reported
figure in a direction that reads like the population simply shrank. Nobody
comparing two readings a month apart could distinguish thirty functions deleted
from thirty functions excused.

Migration 265 published `reachable_total`, `exempted_total` and `exempted_fns`,
and asserted `reachable = scanned + exempted` inside the audit body, so a future
edit that drops functions from the scan for any other reason raises instead of
under-reporting. It also made a **stale** exemption a gating violation, a row
naming something that is not a definer function reachable by `authenticated`
being a pre-authorised hole waiting for something to be created under that name.
Migration 266 added the empty-population refusal, and here the failure was
inducible against the live object rather than needing a derived clone, because
the lever itself is the induction: exempt all 57 and `scanned` is zero while the
partition still holds. Migration 267 put the decomposition on the control board.

The general shape: **an exclusion mechanism that does not appear in the metric it
excludes from is not a governance feature, it is an undocumented override.** Ask
of any checker with an exemption list, a skip list, an allowlist or an ignore
file: if somebody adds everything to it, what does this report? If the answer is
"success", the list is the attack.

**The half-revoke that revokes nothing.** Found while building the fixture above.
PostgreSQL grants EXECUTE to the PUBLIC pseudo-role on every newly created
function, independently of Supabase's named-role default privileges. Because
every role is a member of PUBLIC, `revoke execute ... from anon` leaves
`has_function_privilege('anon', oid, 'execute')` true. The platform already
documented the Supabase half of this trap; the Postgres half defeats the obvious
fix for the Supabase half. Always
`revoke all on function ... from public, anon, authenticated` in one statement.
Migration 260's first attempt failed on this, caught by its own fixture-setup
assertion, which is the harness working exactly as intended.

---

## The house rules

Twelve rules, each of which exists because breaking it cost real time.

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
`tf_automation_registry`, `tf_function_grant_tiers` and
`tf_guard_predicate_registry` exist as data.

**Declare what you create, in the same transaction that creates it.** A
migration that adds a function must add its `tf_function_registry` row and call
`tf_apply_grant_tier` before it commits. Migration 251 did not, and the register
was in drift for the eleven minutes it took `tf_function_safety_audit` to notice.
The audit catching it is not a defence of the omission. It is the reason the
omission was survivable, which is a different thing, and relying on the second
one is how a platform accumulates the first.

**Induce the failure and force the rollback.** When the condition a guard
protects against does not exist in live data, the guard cannot be observed
refusing by simply calling it. Insert a synthetic row that forces the condition,
observe the refusal, delete the fixture, then assert two things: that the fixture
did not survive, and that the row counts are back where they started. Wrap the
attempt in a subtransaction that raises its own sentinel exception on success, so
the mutation rolls back on every code path including the one where the guard
fails to fire. Migration 252 proved `CM-NOTEDRIFT-022` this way: clean baseline,
induced drift, control observed at `failing`, fixture deleted, control observed
back at `passing`, registry back at 13 rows. Without the induced failure, all
that migration would have proved is that a control can return `passing`.

**Verify the verifier.** Twenty-two controls watched the platform and nothing
watched the thing that decides whether a control can see a defect. When
`tf_security_scan`'s guard detection turned out to accept a comment in place of a
guard, every control reading it had been reporting success from a broken
measurement, and success from a broken checker is indistinguishable from success
from a working one right up until an audit or an incident. Every checker on this
platform now has something above it: a checker of its own rules, an integrity
block that asserts it still calls what it is supposed to call, or a control that
fails when it stops. Migration 257 is the pattern in full, a
`SECURITY DEFINER` function created live whose only guard is a comment, five
assertions that the new logic catches what the old logic missed, the fixture
dropped after the exception handler so it comes out on every code path, and
recovery asserted afterwards. Ask of every new control: what happens if this
control's own evaluation is wrong? If the answer is "it reports passing", the
control is not finished.

**A number the checker never fails on is not a control, and an empty input is
not a pass.** The eleventh rule is the sequel to the tenth, and it exists because
following the tenth was not enough. `tf_grant_tier_audit` was given a full
coverage denominator in migration 259, published it in its payload and in
`CM-GRANT-021`'s evidence string, and gated nothing on it for three migrations.
A `tf_*` function created without a `tf_apply_grant_tier` call would have driven
`coverage_pct` below 100, changed the wording of an evidence string, and left the
control green. Migration 262 folded the shortfall into `violation_total` and
proved it on the one fixture shape the earlier proof structurally could not
catch, an untiered function reachable by nobody. Migration 263 closed the mirror
image: a population of zero would have divided into an empty denominator and
certified a failed measurement as full coverage, which makes deleting the
evidence the cheapest way to pass the control. It now raises. Two questions
belong on every metric a checker returns. **What fails when this number goes
bad?** If the answer is "the wording of a string", nothing fails. **What does
this report when its input is empty?** If the answer is "success", the checker
rewards its own blindness.

**Every lever that shrinks what a checker measures must appear in what the
checker reports.** The twelfth rule came from turning the eleventh on a second
checker and finding a worse version of the same defect. `tf_guard_detection_audit`
decides whether every security-definer function on the platform carries an
authorization predicate. It published a bare `scanned` count of 55, and
`security_scan_exemptions` sat beside it as a live table, no cardinality limit,
no approval workflow beyond a text column, whose entire purpose is to remove
functions from that 55. The count moved when somebody inserted a row and the
payload never said an exemption was the reason. That makes inserting a row the
cheapest available way to stop an unguarded function being reported, and it does
not look like tampering, it looks like the number going down. Migrations 265
through 267 published the whole decomposition, asserted the partition
`reachable = scanned + exempted` inside the function so the accounting cannot
drift silently, made an exemption naming nothing real a gating violation, made an
emptied population a refusal, and carried all of it onto the control board where
an auditor reads it. Ask of every checker that supports an exclusion list: **if
somebody excludes everything, what does this say?** and **can a reader tell an
excused function from a deleted one?** A denominator with an undisclosed lever
attached is not a measurement, it is a dial.

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

**And `job_prep` is not the only one.** Four automations carry a populated,
stale cutover timestamp right now, each of which would back-contact on arming:

| Automation | Cutover key | Stale by | Rows it would touch on the first tick |
| --- | --- | --- | --- |
| `job_prep` | `intake_autosend_since` | 177 h | **17** |
| `marketplace_dispatch` | `marketplace_dispatch_since` | 173 h | **19** |
| `review_requests` | `review_requests_since` | 172 h | **7** |
| `ai_booking` | `ai_agent.booking_since` | 166 h | 0 today, but the sweep POSTs to an edge function with no auth guard of its own and caps at five leads per tick, so the real exposure is the backlog across successive ticks |

Do not read those numbers from this table when it matters. Read them live:

```sql
select public.tf_automation_readiness();
```

That returns, per automation, the enabled state, the cutover path and value, the
cutover age in hours, the computed blast radius, and a verdict. Today: **13
automations, 0 armed, 6 ready, 4 stale_cutover, 3 blocked.**

That is a material change from the picture at migration 248, when the same call
returned 0 ready and 10 blocked. Migration 250 transcribed the seven missing
blast-radius predicates into `tf_automation_registry` and added the bounding
model, which moved six automations from `blocked_no_predicate` to a real verdict
and gave `marketplace_dispatch` a measured radius of 19 rows where it previously
had none. Blocked no longer means "we have not looked." It now means only one
thing: the work happens in an edge function and SQL cannot size it.

| Verdict | Count | Automations |
| --- | --- | --- |
| `ready` | 6 | `appt_reminders` (1 row), `cx_first_response`, `cx_sequences`, `estimate_followups`, `eta_reminders`, `late_penalty_enforcement` (all 0) |
| `stale_cutover` | 4 | `job_prep` (17), `marketplace_dispatch` (19), `review_requests` (7), `ai_booking` (0) |
| `blocked_no_predicate` | 2 | `live_connect`, `missed_call_textback` |
| `blocked_no_predicate_low_risk` | 1 | `push_estimates_to_hcp` |

`ready` means the readiness checks pass, not that arming is a good idea. It is
the floor, not the recommendation. `AUTOMATION_ARMING.md` carries the full
registry schema, the bounding model, the predicate contract and the refusal
classes; read it before arming anything that reaches a customer.

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

**Three automations are blocked and cannot be armed at all today**, and they are
the three that cannot in principle be sized from SQL. `live_connect`,
`missed_call_textback` and `push_estimates_to_hcp` are implemented entirely in
edge functions; no `tf_*` function references their key, so there is nothing for
a blast-radius predicate to select from. `tf_automation_registry.bounded_by`
records this as `edge_function` rather than leaving it blank, and
`push_estimates_to_hcp` carries the softer `blocked_no_predicate_low_risk`
verdict because it pushes to Housecall Pro rather than to a customer. All three
stay blocked with that explanation rather than being waved through. Arming any of
them requires instrumenting the edge function to report what it would send, which
is the next tranche of work on this axis.

The other seven were blocked for a different and less honourable reason until
migration 250: nobody had transcribed their predicate. That is now closed.

**Before arming, read the registry note, and treat a stale note as a blocker.**
`tf_automation_readiness()` projects `tf_automation_registry.notes` into its
output, which makes that note the last piece of prose an operator reads before
flipping a customer-reaching flag. A note that describes a sweep the migration
already changed is worse than no note, because it is read at the exact moment
trust is highest. `tf_automation_note_drift()` compares each note against the
live catalog on four rules, control `CM-NOTEDRIFT-022` fails when they disagree,
and `safety:note_drift` puts it in front of a human. `drift_count` reads **0**
today.

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

23 controls, 21 `passing`, 2 `attention`, 0 `failing`. The two in `attention` are
AC-MFA-003 and DP-PITR-007, which are owner actions 3 and 4 above. Evaluated
monthly by `tf-controls-evaluate-monthly`, and on demand by
`tf_controls_evaluate()`, which is a writer.

The six most recently added controls are the convention-enforcement tier:
`AC-DEFN-017` (definer authorization), `CM-FNDRIFT-018` (function register
drift), `CM-AUTOARM-020` (out-of-band arming), `CM-GRANT-021` (grant tier drift),
`CM-NOTEDRIFT-022` (registry notes agree with the catalog) and
`AC-GUARDREG-023` (guard detection rules are data and are evaluated against
executable code). Each was observed failing under an induced defect inside the
migration that created it, then observed recovering. A control that has only ever
been seen passing is not evidence of anything.

`AC-GUARDREG-023` is the one that watches another control. It fails when
`AC-DEFN-017`'s own detection is unsound, which is a different question from
whether any function is unguarded, and the reason it exists is that nothing else
on the platform was asking it. See [`GUARD_DETECTION.md`](./GUARD_DETECTION.md).

`tf_controls_evaluate` now wraps every audit call it makes and propagates `null`
rather than `0` when one raises. `AC-RLS-001`, `AC-PRIV-002`, `AC-DEFN-017` and
`AC-GUARDREG-023` therefore read `attention` with `?` in the evidence when their
underlying measurement could not run, rather than `passing` on a substituted
zero. If several security controls go to `attention` at once, call the audit
function directly and read the real error.

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
| Migrations applied | 267 |
| Base tables in `public` | 171 |
| Tables with RLS enabled | 171 (100%) |
| RLS policies | 582 |
| Functions in `public` (`prokind = 'f'`) | 271 |
| `tf_*` operator functions | 84 |
| `tf_*` functions declared in `tf_function_registry` | 84 (100%) |
| `tf_*` functions with a declared grant tier | 84 (100%) |
| Declared grant-tier rows | 85 (48 admin / 36 staff / 1 anon) |
| Views | 7 |
| Enums | 80 |
| Indexes | 655 |
| Active pg_cron jobs | 37 |
| Edge functions | 37 |
| GRC controls | 23 |
| Controls passing / attention / failing | 21 / 2 / 0 |
| Automations registered | 13 |
| Automations armed | 0 of 13 |
| Automation registry note drift | 0 |
| Registered guard helpers | 15 |
| Definer functions scanned for a guard | 55 |
| Unguarded / comment-only / literal-only | 0 / 0 / 0 |
| Guard-detection integrity violations | 0 |

171 of 171 tables carry RLS. That is the number to re-check after any migration
that creates a table, because a new table without RLS is the single fastest way
to open a cross-tenant leak, and `rls_disabled_tables` is the axis that catches
it.

84 of 84 `tf_*` functions are declared in `tf_function_registry`. That is the
second number to re-check, because an undeclared function is one whose
side-effect class nobody has stated, and `tf_function_safety_audit()` will open a
ticket under `safety:function_drift` within fifteen minutes if the two counts
diverge. It did exactly that between migrations 251 and 252; see the
defect-pattern library.

**All eighty-four now carry a declared grant tier, and this line used to say
something else.** Through migration 257 the count was eighteen, and this document
argued that the gap was deliberate: *"a tier is declared where the intended
reachability is not obvious from the function's role."* That reasoning was wrong,
and it is left on the record here because the way it was wrong is instructive.

The audit's undeclared class only looked at functions reachable by `anon`, and
`anon` reaches almost nothing on this platform, so **not declaring a tier was a
way to never be checked for tier drift at all**. Sixty-six functions were
untiered, twenty-seven of them reachable by every signed-in identity in the
system, and `violation_total` read 0 the whole time. The checker's coverage was
decided by the population it was checking. Migrations 258 through 261 closed it:
declare the full surface at current live reality, widen the sweep to
`anon or authenticated`, prove the widened sweep by inducing the exact blind
case, and update the consumers that were still reading the narrow number.
`coverage_pct` is now part of the audit payload and part of `CM-GRANT-021`'s
evidence string, so the denominator can never go unstated again.

**And then this line had to be corrected a second time.** Making the denominator
visible is not the same as making it binding. Between 259 and 261 `coverage_pct`
was published and nothing failed on it, so a function created without a
`tf_apply_grant_tier` call would have dropped coverage below 100 while
`CM-GRANT-021` stayed green. Migrations 262 through 264 closed that: the coverage
shortfall is now a violation class, `uncovered_total`, folded into
`violation_total`; an empty population is refused rather than certified; and both
consumers were widened additively. The proof for 262 was an untiered fixture
reachable by nobody, the one shape migration 260's fixture structurally could not
catch.

The lesson generalizes past grants, in two parts: **a register a checker reads
must be complete by construction, or the checker is measuring its own register
rather than the system**, and **a coverage number the checker never fails on is
documentation, not a control.** See `FUNCTION_GRANT_TIERS.md`.

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
  (select count(*) from public.it_controls)                                             as controls,
  (select count(*) from public.tf_guard_predicate_registry)                              as guard_helpers;
```

And for the guard-detection numbers specifically:

```sql
select public.tf_guard_detection_audit();
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
- `FUNCTION_GRANT_TIERS.md` — the three-tier grant model, the Supabase default-privileges trap, `CM-GRANT-021`, the coverage defect closed by migrations 258 through 261 and the coverage *enforcement* added by 262 through 264
- `AUTOMATION_ARMING.md` — the automation registry, the bounding model, the blast-radius predicate contract, the arming sequence and its refusal classes, `CM-NOTEDRIFT-022`
- `GUARD_DETECTION.md` — how a `SECURITY DEFINER` function is judged guarded, the guard predicate registry, the comment-stripped match, the comments-gated / literals-advisory line, `AC-GUARDREG-023`, and the induced comment-only guard that proves the chain
- `MIGRATIONS_INDEX.md` — the ordered migration manifest; migrations 249 through 252 are checked in verbatim beside it as worked examples of the anchored catalog-patch idiom, 253 through 257 are indexed with their reasoning carried in `GUARD_DETECTION.md`, 258 through 264 with theirs in `FUNCTION_GRANT_TIERS.md`, and 265 through 267 with theirs back in `GUARD_DETECTION.md`

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

**Pass 3, 2026-07-25, at migration 252.** Four migrations landed between pass 2
and pass 3, and unlike the previous two passes the defects this time were **not
all in the document**. Two were live defects in the database, found by reading
function bodies rather than by running the runbook, and both were
customer-reaching.

| Claim as published | Live reality | Resolution |
| --- | --- | --- |
| Sweeps implied tenant-safe because the platform is multi-tenant by construction | **three sweeps carried no `company_id` predicate**; 3 jobs exist outside the production tenant and all 3 matched `tf_review_request_sweep`'s candidates, so arming `review_requests` would have texted them under the Transit & Flow brand | migration 249 scoped all three, plus a guard on `tf_ai_booking_kickoff_sweep`; migration 250 scoped two further *settings* reads the first pass missed |
| `tf_late_penalty_sweep` enable flag read as `coalesce(..., true)` | defaulted to **enabled** when the key was absent, which is the wrong side of the boolean-default convention (#9) | flipped to `coalesce(..., false)` in migration 249 |
| 10 automations blocked, 3 stale, 0 ready | after transcription: **6 ready, 4 stale_cutover, 3 blocked**, and `marketplace_dispatch` has a measured radius of **19 rows** where it previously reported none | migration 250 transcribed seven predicates and added the four-value bounding model; arming section rewritten against the live verdicts |
| Registry notes treated as documentation | a note that contradicts the sweep is read at the moment trust is highest | `tf_automation_note_drift()` (251) and control `CM-NOTEDRIFT-022` (252); `drift_count` 0 |
| Migrations 248, functions 78, tiers 12, controls 21 | 252 / 80 / 14 / 22 | every inventory row re-read from the catalog |
| GRC controls section said 17 controls, 15 passing | 22 controls, 20 passing, 2 attention, 0 failing | corrected, and the convention-enforcement tier named explicitly |

Three defects were found in the *authoring* rather than in the document or the
database, and they are recorded in the defect-pattern library because they will
recur: a guessed `ON CONFLICT` arbiter that cost one migration attempt
(`it_controls` keys on `control_key` alone, not the composite), four measurement
queries that projected JSON keys nobody had enumerated and returned nulls that
read like zeros, and a function created in migration 251 without its
`tf_function_registry` row. The last one is the most instructive of the three:
`CM-FNDRIFT-018` caught it within minutes, which is the register working exactly
as designed, and it is still a defect that should not have shipped.

Everything re-measured this pass agreed on the second reading:
`tf_function_safety_audit()` returned 80 functions, 54 writers, 26 reads, 6
transitive writers, 17 documented diagnostics, `undeclared_total` 0, `drift` 0,
`stale` 0, diagnostic violations 0, misleading names 7. `tf_grant_tier_audit()`
returned `violation_total: 0` across 14 declared tiers.
`tf_automation_note_drift()` returned `drift_count: 0`. All thirteen automation
flags read `false`, re-asserted inside migrations 250, 251 and 252 rather than
merely observed afterwards.

The finding worth carrying forward is the one that changed this pass's character.
Passes 1 and 2 found stale numbers. Pass 3 found **unarmed hazards**: code paths
that were correct-looking, currently inert, and would have been wrong the instant
someone flipped a flag. Neither would have surfaced through any command in the
runbook, because the runbook exercises the system in its current state and these
defects only exist in a state nobody has entered yet. The countermeasure is not a
better runbook. It is the arming procedure itself, which forces a blast-radius
measurement and a note read before the state changes, and it is the reason
`AUTOMATION_ARMING.md` exists as a separate document rather than as a section
here. **A system verified only in the state it is in has been verified for the
one state that is not risky.**

**Pass 4, 2026-07-25, at migration 257.** Five migrations landed between pass 3
and pass 4, and all five exist because of a single finding this pass produced.
Unlike pass 3, the defect was not in a code path waiting for a flag. It was in
the **measurement instrument itself**, which means every prior pass's clean
security reading had been taken with an instrument nobody had calibrated.

| Claim as published | Live reality | Resolution |
| --- | --- | --- |
| "The fifth axis is a textual test, and a green fifth axis is evidence, not proof" | true, and understated. The test matched **raw** `pg_get_functiondef` output, so a guard-helper name appearing only in a comment satisfied it. A function whose entire guard was the sentence `-- protected by auth.uid()` passed | migration 254 matches against `tf_strip_sql_comments(...)`; migration 257 proves it by creating exactly that function and observing it caught |
| Fifteen guard identifiers listed in prose, sourced from the scanner body | the list was compiled **into** `tf_security_scan`, the one checker on the platform that had not been brought under convention 14 | migration 253 moved all fifteen into `tf_guard_predicate_registry` with a class and a rationale per row |
| `tf_controls_evaluate` treated as robust | it called `tf_security_scan()` as its unguarded first statement and `coalesce`d the result to `0`, so a raise anywhere in that chain would have frozen all controls on stale statuses, and a partial failure would have read as a clean zero | migration 255 wraps every audit call, propagates `null`, and reports `attention` on null across four controls |
| "48 definer functions reachable by `authenticated`" | 55, none unguarded, and the count had been stale since pass 1 | re-read from the catalog; the query now sits beside the number |
| Migrations 252, functions 80, tiers 14, controls 22, conventions 18, house rules 9 | 257 / 84 / 18 / 23 / 19 / 10 | every inventory row, the conventions register, the GRC section and the house rules re-read and re-counted |

**Measured exposure, because this deserves a number rather than an adjective.**
At the moment of discovery there were 54 definer functions granted to
`authenticated` and not exempt. All 54 passed the raw-source regex. All 54 also
passed once comments and literals were stripped. **Zero** passed only because of
a comment or a literal. So the defect was latent, not realized, exactly like the
migration-249 tenant-scoping finding, and exactly as unacceptable to leave in
place: nothing prevented the fifty-fifth function from being the one that
mattered, and nothing would have reported it.

Two new defect classes went into the library this pass and both are general:
**the checker with its rules compiled in**, where nothing checks the rules
because the rules are not data; and **the null pattern that passes everything**,
where `x !~* null` is null rather than true, so emptying a rules table turns a
control green. The second one is the sharper of the two. It means that for any
checker built the way this platform builds them, `truncate` is a privilege
escalation unless the pattern builder refuses to return null. `tf_guard_pattern()`
is written in `plpgsql` for that one reason.

Everything re-measured this pass agreed on the second reading:
`tf_function_safety_audit()` returned 84 functions, 55 writers, 29 reads, 7
transitive writers, 20 documented diagnostics, `undeclared_total` 0, `drift` 0,
`stale` 0, diagnostic violations 0, misleading names 7. `tf_grant_tier_audit()`
returned `violation_total: 0` across 18 declared tiers.
`tf_automation_note_drift()` returned `drift_count: 0`. `tf_security_scan()`
returned `gap_total: 0`. `tf_guard_detection_audit()` returned 15 registry
helpers, 55 scanned, 0 unguarded, 0 comment-only, 0 literal-only, 0 integrity
violations. All thirteen automation flags read `false`, re-asserted inside
migrations 250 through 252 and again inside 257 rather than merely observed
afterwards.

The finding worth carrying forward is the tenth house rule. Passes 1 and 2 found
stale numbers. Pass 3 found unarmed hazards. Pass 4 found a **blind instrument**,
and that is a different and worse category, because the first three classes
announce themselves eventually and this one does not. A checker whose detection
is wrong does not report a problem. It reports success. And success from a broken
checker is byte-identical to success from a working one, right up until the audit
or the incident that reveals which kind you had. Twenty-two controls were
watching the platform and nothing was watching the thing that decides whether a
control can see. **Verify the verifier**, then induce the failure and watch it
get caught.

**Pass 5, 2026-07-25, at migration 261.** Four migrations landed between pass 4
and pass 5, and like pass 4 they all exist because of one finding. Pass 4 found
an instrument whose **rules** were wrong. Pass 5 found an instrument whose rules
were right and whose **coverage** was wrong, and, worse, whose coverage was
determined by the population it was measuring.

| Claim as published | Live reality | Resolution |
| --- | --- | --- |
| "Eighteen of the eighty-four carry a declared grant tier. That number is deliberately smaller than eighty-four and is **not a coverage gap**" | it was exactly a coverage gap. The audit's undeclared class only looked at `anon`-reachable functions, and `anon` reaches almost nothing here, so an undeclared function was simply never checked. 66 untiered, **27 of them reachable by `authenticated`**, `violation_total` 0 throughout | migration 258 declares all 84 at current live reality with a proven zero-reachability-change assertion; 259 widens the sweep to `anon or authenticated` and publishes `coverage_pct` |
| `CM-GRANT-021` evidence: "N function grant-tier violation(s): live EXECUTE grants versus `tf_function_grant_tiers`" | a violation count with no denominator. A reader could not tell 0-of-84 from 0-of-18 | migration 261: the evidence now reads "0 function grant-tier violation(s) **across 84 of 84 tf_\* fn(s) declared (100.0 pct)**: ... plus any fn reachable by anon or authenticated with no declared tier" |
| `tf_grant_tier_autoticket` assumed correct because `CM-GRANT-021` was passing | its ticket body, its auto-close message and one return key all read `undeclared_anon_total`, a subset that is 0 on this platform always. A real undeclared function would have opened a ticket saying `Undeclared: 0` and auto-closed on a property nobody had measured | migration 261 widens all three to `undeclared_reachable_total`, adds the anon subset as a second line, adds a `Surface measured` line, and keeps `undeclared_anon_total` in the payload with its original meaning so no consumer breaks |
| "`revoke ... from anon` closes an anon hole" | Postgres grants EXECUTE to PUBLIC on every new function, so `anon` still executes through PUBLIC and `has_function_privilege` stays true | documented as a convention; `revoke all ... from public, anon, authenticated` in one statement, always |
| Migrations 257, tiers 18, conventions 19 | 261 / 85 rows over 84 functions / 21 | inventory, conventions register and the grant-tier document re-read and re-counted |

**Measured exposure, again with a number.** 84 `tf_*` functions, 18 declared, 66
undeclared, 27 of those reachable by `authenticated`, 0 by `anon`, and therefore
0 violations reported. As with passes 3 and 4 the hazard was latent rather than
realized: every one of the 27 carries an in-body guard, `AC-DEFN-017` was and is
`passing`, and no cross-tenant read was ever possible through them. What was
missing was any mechanism that would have **told** us if the twenty-eighth had
not.

The deliberate non-action is the part worth remembering. The obvious fix, revoke
`authenticated` from all 27, would have broken the Lovable Hub silently and
unattributably. Declaring at current reality first, then demoting individually
with evidence, is slower and is the only version that does not trade a latent
hazard for a live outage.

Two conventions went into the register this pass, numbers 20 and 21: **checker
coverage is published, not assumed**, and **widen a signal, never repurpose a
key**. Two defect classes went into the library: **the checker whose coverage was
decided by the thing it checked**, and **the half-revoke that revokes nothing**.

Everything re-measured this pass agreed on the second reading:
`tf_function_safety_audit()` returned 84 functions, 55 writers, 29 reads, 7
transitive writers, 20 documented diagnostics, `undeclared_total` 0, `drift` 0,
`stale` 0, diagnostic violations 0, misleading names 7.
`tf_grant_tier_audit()` returned `violation_total: 0` across **85 declared rows
covering 84 of 84 `tf_*` functions at `coverage_pct` 100.0**.
`tf_automation_note_drift()` returned `drift_count: 0`. `tf_security_scan()`
returned `gap_total: 0`. `tf_guard_detection_audit()` returned 15 registry
helpers, 0 unguarded, 0 comment-only, 0 literal-only, 0 integrity violations.
23 controls, 21 passing, 2 attention, 0 failing. All thirteen automation flags
read `false`.

The finding worth carrying forward: pass 4's lesson was *verify the verifier*.
Pass 5's is that verifying the verifier includes asking **what the verifier is
pointed at**. Correct rules over a partial surface produce a number that is true,
green, defensible in an audit, and load-bearing for a claim it does not support.
The countermeasure is structural rather than procedural: the register must be
complete by construction, the audit must return its own coverage, and the
control's evidence string must carry the denominator, so that partial coverage is
visible in the same glance as the result.

**Pass 6, 2026-07-25, at migration 264.** Three migrations landed between pass 5
and pass 6, and pass 6 is the audit of pass 5's own fix. Pass 5 made the
instrument's coverage complete and visible. Pass 6 found that visible was where
it stopped.

| Claim as published | Live reality | Resolution |
| --- | --- | --- |
| "`coverage_pct` is now part of the audit payload and part of `CM-GRANT-021`'s evidence string, so the denominator can never go unstated again" | true, and insufficient. The denominator was stated and never enforced. `violation_total` was `drift_total + missing_total + undeclared_reachable_total`, so a coverage shortfall changed the evidence text and failed nothing. A new `tf_*` function with no `tf_apply_grant_tier` call would have printed a number below 100 into a string nobody was paged on | migration 262 adds `uncovered_total` as a first-class violation class and folds it into `violation_total` |
| Migration 260's induced-failure proof read as proof of the coverage mechanism | 260's fixture was reachable by `authenticated`, so it landed in `undeclared_reachable_total`. The **complementary** shape, untiered and reachable by nobody, fell out of every violation class while still dropping `coverage_pct`. The proof and the gap were disjoint | migration 262's fixture is built to be exactly that shape, and asserts `undeclared_reachable_total` stays **unchanged** while `uncovered_total`, `uncovered_unreachable_total` and `violation_total` each move by one |
| The audit's coverage arithmetic was assumed safe at every input | at a population of zero it would have divided into nothing and returned `coverage_pct` 100, certifying a failed measurement as full coverage. Emptying the input was a way to pass the control | migration 263 raises instead: *"An empty population is a failed measurement, not full coverage."* `tf_controls_evaluate` catches it and propagates null, so the control reads `attention`, never `passing` |
| `violation_total` could simply sum the counters | `undeclared_reachable_total` is a strict subset of `uncovered_total`; summing both double-counts every exposed function | `violation_total` is `drift_total + missing_total + uncovered_total`, and an internal-consistency raise enforces that `uncovered_total` partitions exactly into `undeclared_reachable_total` plus `uncovered_unreachable_total` |
| Migrations 261, conventions 21, house rules 10 | 264 / 24 / 11 | inventory, conventions register, house rules, defect-pattern library and the grant-tier document re-read and re-counted |

Three conventions went into the register this pass, numbers 22, 23 and 24: **a
checker's own coverage is a violation class, not a statistic**, **a checker must
refuse on an empty population, not certify one**, and **prove by inducing the
failure; where the live object cannot be broken, prove on a derived clone and say
so**. One defect class went into the library, **the coverage number that was
visible and inert**, and one house rule went in as the eleventh: *a number the
checker never fails on is not a control, and an empty input is not a pass*.

**On the weakest proof in the set, stated deliberately.** The empty-population
refusal cannot be induced against the live function without dropping every `tf_*`
function in the schema. Rather than fall back to a catalog-text presence check,
which would have violated the house rule *a checker never observed catching
anything is not a checker*, migration 263 built
`zz__granttier_refusal_clone()` from the live catalog text by two asserted
mechanical substitutions, named it outside the `tf_*` namespace so the proof
would not perturb the population it was measuring, called it, captured the raise,
asserted the message content, and dropped it. That is a real observation of the
branch firing. It is still weaker than an induced failure on the live object,
because the clone is a copy, and that weakness is written down in
`FUNCTION_GRANT_TIERS.md` rather than left for a reader to notice. It is now
convention 24.

Everything re-measured this pass agreed on the second reading: 264 migrations,
271 functions in `public`, 84 `tf_*` functions, 85 declared grant-tier rows
covering 84 of 84 at `coverage_pct` 100.0, `violation_total` 0, `uncovered_total`
0, `uncovered_unreachable_total` 0, 23 controls at 21 passing / 2 attention / 0
failing. The two in `attention` remain `AC-MFA-003` and `DP-PITR-007`, both owner
actions rather than code defects. All thirteen automation flags read `false`.

The finding worth carrying forward: pass 4 asked *is the verifier correct*, pass
5 asked *what is the verifier pointed at*, and pass 6 asks **what happens when
the verifier's own number goes bad**. A metric that is computed, returned and
printed but never gates anything is not a control, it is a comment with better
production values. The test to apply to any coverage figure on this platform is
one question: what fails when this drops? If the answer is "the wording of a
string", nothing fails. And the mirror-image question is just as load-bearing:
what does this report when its input is empty? If the answer is "success", the
cheapest way to pass the control is to delete the evidence.

**Pass 7, 2026-07-25, at migration 267.** Pass 6 ended by writing house rule
eleven and immediately raised an obvious question about its own scope: it had
been applied to exactly one checker. Pass 7 opened by sweeping all eleven checker
functions on the platform for any coverage, population or empty-input concept.
`tf_grant_tier_audit` was the only one that had any. The other ten,
`tf_function_safety_audit`, `tf_security_scan`, `tf_guard_detection_audit`,
`tf_automation_note_drift`, `tf_boolean_default_hazards`,
`tf_automation_out_of_band`, `tf_revenue_linkage_audit`, `tf_queue_health`,
`tf_scheduler_health` and `tf_access_review`, contained no population word, no
coverage word and no empty-population refusal anywhere in their bodies.

`tf_guard_detection_audit` was taken first, because `AC-GUARDREG-023` depends on
it and because it is the function that decides whether every security-definer
function on the platform carries an authorization predicate. What it found there
was worse than the shape house rule eleven was written to catch.

| Claim carried into this pass | What the catalog said | Resolution |
| --- | --- | --- |
| Guard detection publishes its population | it published `scanned`, 55, and nothing else about the population. The reachable definer count, 57, was never computed | migration 265 publishes `reachable_total`, `exempted_total` and `exempted_fns` |
| An exemption is an accountable act | `security_scan_exemptions` shrank the scan population with no counter anywhere in the payload. A reader could not distinguish 0-unguarded-of-55 from 0-unguarded-of-55-with-thirty-excused | migration 265 names every excused function; migration 267 puts the count on the control board |
| The scan population accounting cannot drift | nothing tied `scanned` to the population it was drawn from | migration 265 asserts `reachable = scanned + exempted` inside the audit body and raises on divergence |
| An exemption row is harmless if the function is gone | a row naming a dropped or misspelled function is a pre-authorised hole waiting for something to be created under that name | migration 265 makes a stale exemption a gating integrity violation, proved by planting one and observing `AC-GUARDREG-023` go `failing` |
| The audit cannot be emptied | exempting all 57 reachable definer functions drives `scanned` to zero, the partition still holds at `57 = 0 + 57`, and the audit returned `ok: true, unguarded_total: 0` over nothing | migration 266 raises: *"A guard scan that scanned nothing is not a pass."* |
| Migrations 264, conventions 24, house rules 11 | 267 / 25 / 12 | inventory, conventions register, house rules, defect-pattern library, `GUARD_DETECTION.md` re-read and re-counted |

One convention went into the register this pass, number 25: **an exclusion lever
must be visible in the number it shrinks, and a stale exclusion is a violation**.
One defect class went into the library, **the denominator with a lever attached**,
and one house rule went in as the twelfth: *every lever that shrinks what a
checker measures must appear in what the checker reports*.

**On the strongest proof in the set, also stated deliberately.** Pass 6 had to
write down that its empty-population proof was the weak kind, a derived clone,
because the live object could not be broken. Pass 7 did not have that problem and
the reason is itself the finding. The empty-population failure on the guard scan
is inducible against the live function, because the lever that empties it is a
table anybody can insert into. Migration 266's proof inserts one exemption row
per reachable definer function, asserts the number inserted equals the previous
scan size so the fixture is exactly the emptying and nothing more, captures the
raise, asserts the message names the denominator it refused over, asserts
`AC-GUARDREG-023` stopped reading `passing`, then deletes every fixture row and
asserts the row count, all five payload counters, the control status and the
control's evidence string are back where they started. That a checker's blind
spot could be induced this easily from ordinary table access is the argument for
migration 265, not a footnote to it.

Everything re-measured this pass agreed on the second reading: 267 migrations,
271 functions in `public`, 84 `tf_*` functions, grant-tier coverage still 100.0
with `violation_total` 0, 57 definer functions reachable by `authenticated`, 2
exempted with written reasons, 0 stale, 55 scanned, 0 unguarded, 0 comment-only,
0 integrity violations, 15 registered guard helpers, 23 controls at 21 passing /
2 attention / 0 failing, and no proof-fixture residue in
`security_scan_exemptions`. The two in `attention` remain `AC-MFA-003` and
`DP-PITR-007`, both owner actions. All thirteen automation flags read `false`.

The finding worth carrying forward: pass 6 asked what happens when the verifier's
own number goes bad, and pass 7 asks **who is allowed to move it**. A metric with
an undisclosed exclusion lever is not a weaker metric, it is a different kind of
object: a dial that reads like a gauge. The remaining nine checkers have not yet
been put through this and that is the next pass, in the order
`tf_function_safety_audit`, `tf_security_scan`, `tf_access_review`, then the
rest.

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

Pass 3 added one clause to that observation. The most expensive disagreements are
not always the ones happening now. Some are dormant, sitting in a code path that
is correct in every state the system has ever been in and wrong in the first
state someone puts it in deliberately. A sweep with no tenant predicate is not a
bug until an operator arms it, and by then the text messages have already gone
out. Loud failure is necessary and not sufficient. The other half is measuring
the blast radius *before* the state changes, which is why arming is a procedure
with refusals rather than an `update` statement, and why every automation on this
platform must declare how it is bounded before it can be armed at all.

Pass 4 added the last clause, and it closes the loop back on the document you are
reading. Every countermeasure above is itself a component, and a component can
disagree with reality just as quietly as the ones it watches. The scan that
returned zero because it was looking for a word rather than a behaviour was not a
hypothetical example in the paragraph above. It was `tf_security_scan`, it had
been returning that zero to every dashboard and every control on this platform,
and it was correct in outcome and wrong in method for its entire life. So the
final rule is recursive: whatever you build to make disagreement loud, build
something above it that goes loud when it stops listening. **Nothing on this
platform is allowed to be the last thing in the chain, including this document.**
