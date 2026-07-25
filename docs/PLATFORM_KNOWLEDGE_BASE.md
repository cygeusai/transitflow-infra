# Transit & Flow — Platform Knowledge Base

The single troubleshooting reference for the Transit & Flow backend. Written to
be read at 2am by someone who did not build it.

State captured 2026-07-25 against Supabase project `kjooyhvynkzuvsixsutt` at
migration 290. Every number in this document was read out of the live database,
not remembered.

Migrations 270 through 279 were applied by **two agents interleaved into one
version stream**, so ordinals in that range are not contiguous per author. Cite
migrations by name. See the note at the head of `MIGRATIONS_INDEX.md`.

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
| `CM-FNDRIFT-018` reads `attention` with no evidence string | since migration 269 the evaluator honours a checker's `ok: false` instead of coalescing it to zero, so this means the audit refused | `select public.tf_function_safety_audit();` → read `error` and `missing_signals`; see `FUNCTION_SAFETY_AUDIT.md` |
| `tf_function_safety_audit()` returns `error: pattern_table_empty` | one or more of the five signal classes has no rows in `tf_function_safety_patterns` | `missing_signals` names exactly which; reseed that class, never a placeholder regex |
| `secret_touchers` dropped from 18 to 1 between readings | the `vault_read` pattern rows were deleted; `body ~* null` is null, not false, so every function reads as not touching the Vault | `select count(*) from tf_function_safety_patterns where signal='vault_read'`, expect 3. Since migration 268 the audit refuses instead of reporting this |
| A control reads `passing` while its checker plainly cannot run | the deployed `tf_controls_evaluate` predates migration 269 and reads past the `ok` flag | count occurrences of `->>'ok','false'` in `pg_get_functiondef`; it must appear six times |
| A trigger function is classified `read` by the safety audit | the deployed audit predates migration 275 and classifies by DML keyword only; a `RETURNS trigger` body has no DML keyword in it | `select proname from pg_proc where pronamespace='public'::regnamespace and prorettype='pg_catalog.trigger'::regtype`, then check `totals->'trigger_writers'` is non-zero |
| `tf_grant_tier_audit` reports `missing_total` above 0 with rows that look correct | a register row was hand-written with the bare type list (`'integer'`) instead of the identity-argument string (`'p_days integer'`), so it resolves to no function and applies no ACL | `select proname, ident_args from tf_function_grant_tiers t where not exists (select 1 from pg_proc p where p.pronamespace='public'::regnamespace and p.proname=t.proname and pg_get_function_identity_arguments(p.oid)=t.ident_args)`. Since migration 276 the table canonicalises or refuses these |
| A definer function returns aggregate counts over a table the caller cannot `SELECT` | aggregation is not anonymisation; a `SECURITY DEFINER` function over a policy-gated table bypasses that gate unless it re-asserts it in its own body | read `pg_get_functiondef`, confirm the guard idiom is present; see migration 274 and `tf_studio_funnel` |
| A migration asserting an end-state rolls back for no apparent reason | a concurrent agent deployed to production mid-transaction and the population grew | assert deltas measured inside the transaction, never absolute counts pinned earlier; report concurrent arrivals by `raise notice`. See the head of `MIGRATIONS_INDEX.md` |
| `tf_security_scan()` raises `empty population (tables 0, security definer functions 0)` | the scan cannot see its own subject, usually a `search_path` problem or a role that cannot read `pg_proc` the way the definer owner can | the raise is deliberate. A scan over nothing returns zero gaps and that is not the same as clean. Check `current_setting('search_path')` and the function owner before assuming the catalog is empty |
| `tf_security_scan()` returns `ok: false` with `stale_exemptions_present` | one or more rows in `security_scan_exemptions` name a function that is not currently reachable-and-unguarded, so the exemption suppresses nothing and will hide the finding the day the guard is removed | read `stale_exemptions` for the names, confirm each function is guarded or gone, then delete the rows. Never add a guard-removal to make the exemption "real" |
| `tf_security_scan()` returns `ok: false` with `every_reachable_definer_function_exempted` | the exemption lever has been pulled to its limit; the guard axis reads zero because the denominator is zero | `population.unexempt_reachable` is 0. This is the limit case of the migration 265-267 finding and the scan now refuses rather than reporting clean |
| `tf_security_scan()` returns `ok: false` with `guard_scan_partition_mismatch` | the exempt and unexempt counts do not sum to the reachable total, or the unguarded count exceeds the unexempt set | the three counts come from one `with reach as (...)` CTE, so a mismatch means the deployed body predates migration 280 or was patched inconsistently. Re-read `pg_get_functiondef('public.tf_security_scan'::regproc)` |
| `tf_security_scan()` returns `ok: false` with `rls_no_policy_partition_mismatch` | `rls_enabled_no_policy_reachable` exceeds `rls_enabled_no_policy`, which is arithmetically impossible for a subset | the reachable predicate and the superset predicate have diverged; both must filter on `relrowsecurity` and absent `pg_policies` rows. See migration 283 |
| `rls_enabled_no_policy` is non-zero but the named table looks correctly built | the table has RLS on and no policies **and no client-role grants at all**, which is correct construction, not a gap | since migration 283 read `rls_enabled_no_policy_reachable` instead. Unreachable is not unpoliced. `studio_events_prelaunch_archive` is the worked example |
| `insert into security_scan_exemptions` raises `A standing exemption over a guarded function is a trap` | the target already carries a recognised guard predicate, so the exemption would suppress nothing today and hide the finding tomorrow | do not exempt it. If the guard is wrong, fix the guard. See convention 30 |
| `insert into security_scan_exemptions` raises `A one line reason is not a review` | the `reason` is under 40 characters | write the review: what the function exposes, why that is acceptable, and what was checked. The length floor is a proxy for the thinking, not the point of it |
| A new `SECURITY DEFINER` function shows up in `secdef_authenticated_no_guard` moments after deployment | the grant tier was applied in a later migration than the create, so the function sat in the creation exposure window | house rule fifteen. Apply `tf_apply_grant_tier` in the same transaction as `CREATE FUNCTION` |
| A table is emptied and no RLS policy could have allowed it | `TRUNCATE` does not visit rows, so no policy constrains it | `select count(*) from pg_class c where c.relnamespace='public'::regnamespace and c.relkind='r' and has_table_privilege('authenticated', c.oid, 'TRUNCATE')`, expect 0 since migration 272 |
| A migration raises `P0001: controls left failing after this migration` and the control it wrote is correct | a **different** control regressed, almost always `CM-FNDRIFT-018` because a `tf_*` function was created without a `tf_function_registry` row | run `select public.tf_function_safety_audit()` and read the `undeclared` array, which names the function. Declare it, then re-submit. Convention 33 and house rule seventeen |
| `tf_controls_signal_coverage()` returns `unread_total` above 0 | a checker declares a detection axis that no control's status or evidence CASE references, so the finding is computed and never rendered | `unread_axes` names them. Wire each into a control's status branch in `tf_controls_evaluate`, or state in writing why it is deliberately unrendered. Convention 31 |
| `tf_controls_signal_coverage()` returns `refusal_flag_honoured: false` | `tf_controls_evaluate` reads `tf_security_scan` without gating on the scan's `ok` flag, so a refusing scan renders as `passing` | re-read `pg_get_functiondef('public.tf_controls_evaluate'::regproc)` and confirm the `coalesce(v_scan_raw->>'ok','false') <> 'true'` gate is present. This is the migration 284 finding; convention 26 |
| `tf_controls_signal_coverage()` returns `ok: false` with `scan_published_no_axis_list` or `axis_list_empty` | the deployed `tf_security_scan` body predates migration 280 or its `axes` array is empty, so coverage cannot be measured over anything | the checker refuses rather than reporting zero unread axes over zero axes. Same undeclared-denominator logic as convention 29, applied to itself |
| `tf_controls_signal_coverage()` returns `ok: false` with `consumer_not_found` | `tf_controls_evaluate` is absent from `pg_proc`, or is not `prokind = 'f'` | the coverage checker resolves its consumer by catalog lookup, not by name string. If this fires, the evaluator has been dropped and the whole control board is dark |
| `tf_controls_board()` returns `authoritative: false` while every control reads `passing` | the board is stale, or an automated control is unscored, or a status branch asserts a literal; any one of the three drops the boolean and a green board proves none of them | read `board_age_hours` against `threshold_hours`, then `unscored_controls` and `tautological_controls`, which name the rows. `CM-BOARDFRESH-027` carries the same three numbers in its evidence. Conventions 34 and 35 |
| `tf_controls_board()` returns `ok: false` with `status_case_marker_not_found` | `tf_controls_evaluate` was reformatted and the reader can no longer locate `status = case control_key` or `else status end` in its catalog text | fix the reader in a migration. **Do not** trust a zero from a parser that cannot see its subject. The refusal exists precisely so a reformat cannot silently turn the detector into a source of green |
| `tf_controls_board()` returns `ok: false` with `never_evaluated` | no automated control carries a `last_evaluated_at`, so there is no age to publish | run `select public.tf_controls_evaluate();`. If the register was just seeded this is expected once and only once |
| `tf_controls_board()` returns `ok: false` with `empty_register` | there are no automated controls for this company | the register was truncated or the `company_id` is wrong. A board with no rows is not a clean board, which is why this refuses rather than reporting zero gaps. Convention 29 applied to the register |
| `tf_controls_board()` returns `ok: false` with `evaluator_not_found` | `tf_controls_evaluate` is missing from the catalog | restore it. Nothing is scoring the board, and every status in `it_controls` is a frozen cache of the last run before it disappeared |
| `board_age_hours` reads 0 every single time no matter when you look | the reading was taken after the write it measures, so it is scoring its own stamp | house rule eighteen, second half. `tf_controls_evaluate` must call `tf_controls_board()` before its `UPDATE`, not after. Confirm the call sits above the update in `pg_get_functiondef` |
| A control has read `passing` for months and nothing has ever moved it | its status branch may assert a literal rather than compute one, the `GV-CCM-016` defect | `select public.tf_controls_board()` and read `tautological_controls`. A branch of the form `when 'KEY' then 'passing'` is a decoration, not a judgement. Convention 35 |
| A migration raises `... anchor occurred 0 time(s), expected 1; refusing to patch` | a textual splice into a function body could not find its anchor, usually because the deployed body differs from the one the migration was written against | this is the refusal working. Re-read `pg_get_functiondef` of the target, confirm the exact bytes with `encode(convert_to(substring(...), 'UTF8'), 'escape')`, and rewrite the anchor. Never relax the count check to `>= 1` |
| A migration raises `... anchor occurred 2 time(s), expected 1; refusing to patch` | the anchor text is ambiguous and `replace` would have patched both sites | narrow the anchor by including surrounding whitespace or an adjacent line until it is unique. A splice that lands twice is worse than one that lands nowhere, because it commits |
| A coverage check reports an axis as read when nothing reads it | the axis name is a strict prefix of a sibling axis, which convention 21 guarantees will keep occurring, and the match was against the bare identifier | match the axis name wrapped in single quotes so the needle is the SQL literal. **The prefix-collision gotcha** |

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

Forty-one conventions. Repeatedly, the highest-yield defect on this platform has been two writers
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
| 26 | A refusal must cover every input the checker reads, and every consumer of a refusal must listen to it | a checker's completeness guard names all of its own inputs and says which are missing; on the consuming side, a payload carrying `ok: false` becomes null, never zero, so the control reads `attention` rather than `passing` | `tf_function_safety_audit` `missing_signals` across all five signal classes since migration 268; all six consumers in `tf_controls_evaluate` gated on `coalesce(payload->>'ok','false') <> 'true'` since migration 269, verified by a count of the idiom in the patched body |
| 27 | A table a checker reads must refuse to hold a row the checker cannot verify | the register carries a `BEFORE INSERT OR UPDATE` validator that resolves every row against the live catalog, refuses what cannot exist, and canonicalises what is unambiguously mis-keyed rather than accepting it silently; validators are `SECURITY INVOKER` so hardening one control does not widen another's surface | `tf_function_registry_validate` and `tf_grant_tier_registry_validate` since migration 276, proved by four inductions each asserting the refusal fired **and** fired for the right reason, the fourth replaying a real mis-keyed production row |
| 28 | A privilege that no policy can constrain is not covered by the policy layer | privileges outside the RLS-evaluated set (`TRUNCATE`, `TRIGGER`, `REFERENCES`, `MAINTAIN`) are revoked from `anon` and `authenticated` on every table, leaving only the four verbs PostgREST uses; unreachability through the current front door is not a reason to hold a privilege | migration 272, live count of tables `TRUNCATE`-able by a client role is 0 of 174, was 172 of 173; monitored since migration 283 by the `tables_truncatable_by_client` axis of `tf_security_scan`, see `LEAST_PRIVILEGE_TABLE_GRANTS.md` and `SECURITY_SCAN_INTEGRITY.md` |
| 29 | A checker must publish the population it counted over | every gap count is accompanied by the denominator that produced it, and a checker whose population comes back empty raises rather than returning zero; the declared axis list and the computed axis object are coupled by an assertion so an axis cannot be declared and left out of the total, nor computed and left out of the declaration | `tf_security_scan()` `population` block and empty-population raise since migration 280; `gap_total` derived by iterating `v_axis_order` rather than summing named variables; the same shape already in `tf_grant_tier_audit` and `tf_guard_detection_audit` |
| 30 | An exemption must suppress something, or it is a trap | a standing exemption over a function that is already guarded hides the finding the day the guard is removed; staleness is detected by the exact inverse of the axis predicate, published as its own count, escalated into `ok: false`, and refused at write time by a validating trigger that also requires a reason long enough to be a review | `tf_security_scan()` `stale_exemptions` and the `stale_exemptions_present` integrity error since migration 280; two live rows retired by migration 281; `tf_security_scan_exemption_validate` since migration 282, proved by three inductions |
| 31 | Every declared detection axis has a consumer that renders it | detection without consumption is not a control, it is a log line; the axis list a checker publishes is matched against the **catalog definition** of its consumer, not against a register, and any axis nobody renders is a gap that fails a control of its own | `tf_controls_signal_coverage()` since migration 285, read by `CM-SIGNALCOV-026` since migration 287; generalised from one checker to the full roster by migration 304, live `unread_total 0` over **26 declared axes across 12 checkers** since migration 315. The match is the strict counter-read needle of convention 39, which supersedes the earlier single-quoted-name match |
| 32 | A checker that reports on refusals is not gated on its own refusal flag | every other consumer treats `ok: false` as null per convention 26, but the checker whose job is to notice unheard refusals must run and report regardless, or the failure it exists to surface is the failure that silences it | `tf_controls_signal_coverage()` is deliberately ungated on the checkers it inspects. The single-checker `refusal_flag_honoured` boolean was retired by migration 304 and replaced by `ungated_refusal_total`, which asserts the property across all twelve rostered checkers in either spelling of the gate idiom; live 0 |
| 33 | Creating a `tf_*` function carries three obligations in the same migration | apply a grant tier, declare the function in `tf_function_registry`, and wire its signal into a control; **all three are now structurally enforced** | tier enforced and asserted since migration 282, detected by `tf_grant_tier_audit` `uncovered_total`; **declaration enforced at `COMMIT` since migration 307** by the `tf_require_function_declaration` event trigger plus the `tf_declaration_pending_deferred_check` constraint trigger, monitored by `tf_declaration_enforcement_audit` and read by `CM-FNDECL-028` since 309, live `enforcement_gap_total 0` over 104 functions and 104 registry rows; **signal wiring enforced at `COMMIT` since migration 318** by the `tf_require_signal_wiring` event trigger plus the `tf_signal_wiring_pending_deferred_check` constraint trigger, monitored by `tf_signal_wiring_enforcement_audit` and read by `CM-SIGWIRE-030` since 320, live `wiring_gap_total 0` over a checker population of 13, refusal observed verbatim in migration 319. **Wired** is a conjunction of three catalog facts: a key in `tf_controls_signal_roster()`, a `public.<proname>()` call in `pg_get_functiondef(tf_controls_evaluate)`, and an `it_controls.signal` naming it. A **checker** is a `public.tf_*` function of `prokind='f'` whose definition text contains the literal `'axes',`, which is a catalog fact rather than a self-declared intent, so no exemption lever was created |
| 34 | A stored status is a cache, so publish its age beside it against a stated threshold | a register of judgements with no date on it renders an evaluation from any point in the past as current; the age, the threshold and the cadence that produced the threshold are all published so the freshness claim is falsifiable rather than asserted | `tf_controls_board()` `board_age_hours` / `threshold_hours` / `cadence` since migration 288; threshold 792 hours, the `0 14 1 * *` monthly cadence plus a two-day grace; read by `CM-BOARDFRESH-027` since migration 290 |
| 35 | A control's status branch must compute a status, never assert one | a branch that reads `then 'passing'` survives every failure it exists to detect; the property worth checking was never whether a branch exists but whether it decides anything, so the register is measured on both axes, controls with no branch at all and controls whose branch asserts a literal | `tf_controls_board()` `unscored_total` since migration 288 and `tautological_total` since migration 289, both parsed out of `pg_get_functiondef` of the evaluator; found `GV-CCM-016` hardcoded to `'passing'` on its first run, fixed in migration 290; live 0 and 0 |
| 36 | A signal must not be produced by the act of evaluating it | a freshness reading taken after the write it measures is always zero, so the prior state is read and held before anything is stamped, and the evidence string states the ordering so a reader can verify it without the source | `tf_controls_evaluate` calls `tf_controls_board()` in its opening statements since migration 290 and the `CM-BOARDFRESH-027` evidence ends *"Age is measured before this run stamps the board"* |
| 37 | An axis is the consumption surface, and a checker declares its own | an axis is a signal a control is expected to READ, not an inventory of everything the checker counts; only the checker knows which of its numbers are findings and which are population or complement, so the checker declares and the detector verifies, because an inspecting detector that cannot tell a finding from a denominator demands consumers for numbers no control should read and the platform grows fake controls to satisfy it | all twelve rostered checkers publish `axes` since migrations 291 through 303, 308 and 313; every non-axis counter is mapped to a written rationale in `non_gating`; live 26 axes across 12 checkers |
| 38 | Every published counter is classified, and classification recognises every naming convention | a checker's tail asserts that each declared axis appears in the payload, that each non-gating key carries a rationale, and that **every** counter key is one of axis, component axis, or explained non-gating, so nothing ships unclassified; the sweep matches `_total`, `_count` and `_issues`, because a classification rule that only recognises one naming convention does not classify, it filters | the three couplings in every declaring checker since migration 291; migration 295 found the `_total`-only sweep passing `drift_count` while examining zero keys, which is an assertion that can never fail |
| 39 | A consumer read is proved by the strict counter-read needle | `coalesce((<evaluator variable>->>'<axis>')::int` is the only form that proves consumption, because the variable qualifier defeats axis names published by more than one checker and the `coalesce(...)::int` shape defeats a signal that appears only inside a human-readable evidence string; a bare `strpos` over a function definition proves neither | `tf_controls_signal_coverage` since migration 304, verified live across all 25 (checker, axis) pairs. Supersedes the single-quoted-name match of convention 31. The collision case is real: `drift_total` is published by both `tf_grant_tier_audit` and `tf_function_safety_audit` |
| 40 | A roll-up may stand in for its primitives only if the checker asserts the identity | a checker may declare one roll-up axis instead of five primitives, which makes the consuming control simpler to reason about, but only if it asserts in its own body that the roll-up equals the sum of the primitives it stands for; without that assertion a roll-up is where findings disappear, because adding a sixth primitive and forgetting the sum leaves the number at zero while the blind spot grows | `tf_grant_tier_audit` `violation_total` and `tf_controls_signal_coverage` `gap_total` since migration 292 and 304; both publish their primitives as `component_axes` and assert the identity before returning |
| 41 | A checker declares on every success path, and zero is the passing branch while null is the attention branch | an early return that bypasses the declaring tail is a conditional declaration, which is no declaration at all; and an exception handler that defaults a gap counter to zero converts an unrunnable check into a passing control, so the board goes green *because* the detector broke | `tf_automation_out_of_band` collapsed to one declaring tail in migration 301, enforced structurally by migration 302's assertion that the function has exactly two return statements; refuse-by-return applied to `tf_data_quality_audit` in 297, honoured as unmeasured by the evaluator in 298, and extended to system health in 299; every migration in the batch runs a pre-install regex guard refusing `exception when others then ... := 0;` |
| 42 | An obligation that holds "in the same migration" is an obligation that holds at `COMMIT`, and that is where it should be enforced | a rule stated as "do X in the migration that does Y" is a rule about a transaction, so the enforcement point is the transaction boundary, not the statement; enforcing at the statement forces an ordering, and an ordering can be impossible for reasons that have nothing to do with the rule; enforcing at commit accepts every ordering and refuses only the outcome the rule actually forbids | `tf_require_function_declaration` (event trigger, enqueue only) plus `tf_declaration_pending_deferred_check` (`DEFERRABLE INITIALLY DEFERRED` constraint trigger, refuse at commit) since migration 307. The statement-level design was impossible here because `tf_function_registry_validate` refuses a declaration for a function that does not exist yet, so no ordering satisfies both. Proved transactional first: an `apply_migration` that raises leaves no object and writes no version row |
| 43 | Enforcement has a kill switch, so the kill switch is a monitored axis | any guard strong enough to block a deploy needs a documented way to turn it off, and a guard that can be turned off invisibly has an expiry date nobody reads; the off switch is therefore made auditable by construction (DDL, owner-only) **and** its use is published as its own counter, so disabling enforcement turns a control red instead of quietly widening tolerance | `tf_declaration_enforcement_audit` publishes `enforcement_missing_total` and `enforcement_disabled_total` as separate gating axes since migration 308; `evtenabled` is mapped across all four values `O`/`D`/`R`/`A` into a published `event_trigger_state` word rather than tested against one; proved falsifiable by disabling and re-enabling the trigger inside one self-aborting migration |

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

**The swallowed refusal.** An exception handler that defaults a gap counter to
zero, converting an unrunnable check into a passing control. See house rule
twenty. It belongs in this library and not only in the rules because it is the
only defect in the collection whose output is indistinguishable from success, and
because it can be reintroduced in three lines by anyone tidying up an error path.
Recognise it by the shape `exception when others then <counter> := 0`, and by any
control whose evidence is confident and whose underlying checker nobody has run
by hand recently.

**The unresolved failure path.** A `raise exception` that references an identifier
which does not exist, sitting inside a branch that never executes. plpgsql parses
a function body for syntax at creation time and resolves names at execution time,
per statement, so the branch is never checked and the function is created,
committed and reported healthy. Found in migration 320 as `coaleske_placeholder`.
The output is indistinguishable from a working assertion, and the assertion is
worth nothing. Recognise it by asking, of any guard, whether its failure branch
has ever run even once. In a repository where refusals are the whole design, the
honest answer is almost always no. See house rule twenty-three. The systematic
countermeasure is `plpgsql_check`, which resolves identifiers in unreachable
branches; a full-schema scan of this database costs 447 ms.

**The coalesce default that manufactures a pass.** Closely related and more
common. An assertion reads a key out of a jsonb payload, wraps it in
`coalesce(..., 0)` to be defensive, and compares it to the expected clean value.
If the key is absent or misspelled, the read yields SQL `NULL`, the coalesce
substitutes the passing value, and the assertion certifies a measurement that was
never taken. **In an assertion, the safe default for a `coalesce` is the FAILING
value, never the passing one.** `coalesce((v->>'gap_total')::int, -1) <> 0` fails
loudly on a missing key; `coalesce(..., 0)` passes silently. The live instance
that taught this: `public.tf_controls_board()` has **no `summary` key**, so an
assertion reading `v_board->>'summary'` gets `NULL` forever. The register summary
is the return value of `public.tf_controls_evaluate()`.

**The conditional declaration.** A checker with an early return that bypasses the
tail where its axes are declared. `tf_automation_out_of_band` returned a
well-formed zero payload when no `openphone` settings row existed for the company,
and that payload carried no `axes` key. The declaration was therefore true on the
normal path and absent on the edge path, which is the path where the platform is
least able to explain itself. A property that holds conditionally is not a
property. Recognise it by counting return statements: a declaring checker should
have exactly two, the refusal and the declaring tail. A third return is a success
path that ships no axes. Fixed by collapsing the early return into an assignment
that falls through to the shared tail, and enforced by asserting the return count
in migration 302 rather than asserting the instance.

**The population mistaken for a finding.** A detector that infers a checker's
signals by inspecting its payload keys cannot tell a finding from the denominator
the finding is measured against. `enabled_total` and `out_of_band_total` look
identical to a key-name filter; one is a gap and the other is the population it
came out of. The consequence is not a missed defect but a **manufactured** one:
the platform sits permanently one axis short of full coverage for a reason that
exists only inside the detector, and the natural remedy is to add a control whose
purpose is to satisfy a checker rather than to protect the business. Recognise it
whenever a coverage number cannot be driven to its target without inventing a
consumer. Fix by inverting the burden: the checker declares, the detector
verifies.

**The classification rule that filters.** An assertion that sweeps a payload for
counter keys using one naming convention, and therefore examines zero keys in any
checker that uses another. `tf_automation_note_drift` publishes `drift_count`; a
sweep matching only `%_total` passed it every time while checking nothing. This
is the seeded-register failure in miniature, an assertion that cannot fail is not
an assertion, and it is particularly hard to see because the code reads as
thorough. Recognise it by asking how many rows the assertion actually examined,
not whether it passed. Any classification sweep should publish or log its own
match count.

**The narrative read.** A signal that appears in the consumer's text only inside a
`format()` call that builds a human-readable evidence string. Textually it is
indistinguishable from a signal read into a status comparison, so any coverage
check built on `strpos` over the whole definition certifies it as consumed. It is
not consumed. Nothing changes state on it. Recognise it by requiring the shape of
a numeric comparison rather than the presence of a name, which is what the strict
counter-read needle `coalesce((<var>->>'<axis>')::int` does without needing to
parse regions of the function.

**The write-timestamp trap.** A column named for when something was *evaluated*
records when the row was *written*, and those are the same only if every write
was preceded by an evaluation. `it_controls.last_evaluated_at` is written by one
`UPDATE` covering every automated row, sharing one `v_now`. That statement's
status CASE ends `else status end`, so a control the CASE has no branch for keeps
its old status and is stamped as freshly as one that was genuinely re-scored.
`count(distinct last_evaluated_at)` reads **1** across the whole board. A
detector built on the premise "a row whose stamp lags the maximum was skipped"
therefore returns zero forever, over a population it never declared. This was
caught by querying the catalog before writing the detector, and it is the exact
undeclared-denominator failure convention 29 exists to prevent, aimed at a
timestamp instead of a count. Fix: measure the property directly. The evaluator's
own `pg_get_functiondef` names which controls it has branches for, so parse that
rather than inferring it from side effects.

**The tautological control.** A status branch that **asserts** a literal instead
of computing one: `when 'GV-CCM-016' then 'passing'`. It renders green on every
run since the day it was written and will keep doing so through the exact failure
it was created to detect. The one found here was the control certifying
continuous controls monitoring, and its evidence string was the timestamp of its
own write, so it was self-referential on both axes. Same family as the seeded
register of migration 276 and the unread axis of migration 283: in each, the
presence of a mechanism was mistaken for the property the mechanism was supposed
to have. A branch existing is not a branch deciding. Fix, now convention 35:
regex the evaluator's catalog text for branches matching
`^'(passing|failing|attention|manual)'` and count them as a gap of their own.
Whenever a register is scored by a CASE, this shape is possible and nothing but
an explicit check will find it.

**The self-stamping signal.** A freshness metric computed downstream of the write
it measures. `CM-BOARDFRESH-027` reports the board's age. Read the board from
inside the `UPDATE` that stamps it and the age is zero on every run, forever, not
because the board is fresh but because the reading and the write are the same
event. The detector is structurally incapable of a non-zero answer, which is a
strictly worse failure than a wrong answer because nothing about the output looks
anomalous. Fix: hoist the read above the write, hold the prior state in a
variable, and state the ordering in the evidence string so a reader can verify it
without opening the source. Generalises to any metric a component publishes about
itself: establish whether the measurement can observe a state the act of
measuring did not create.

**The unread axis.** A checker gains a new detection axis. The axis is computed
correctly, summed into the total correctly, published correctly, and nothing
downstream renders it. The board stays green because no control's status
depends on it. Migration 283 added `tables_truncatable_by_client` and migration
284 found it unread, along with `rls_enabled_no_policy_reachable` from the same
batch. Fix, now convention 31: match the checker's declared axis list against the
catalog definition of its consumer and fail a control when any axis has no
reader. The generalisation is the sentence the whole batch turns on: *detection
without consumption is not a control.*

**The refusal reporter gated on its own flag.** Convention 26 says a consumer
treats `ok: false` as null so the control reads `attention` rather than
`passing`. Apply that uniformly and the checker whose job is to notice unheard
refusals goes quiet exactly when refusals start happening. The coverage checker
is therefore deliberately ungated and publishes `refusal_flag_honoured` as an
observation rather than consuming it. Recognise the shape whenever a monitor
monitors the thing it depends on.

**The consumer that was swept before the signal existed.** Migration 269 taught
all six control consumers to honour their checker's `ok` flag. Migration 280 then
*added* an `ok` flag to `tf_security_scan`, which had not had one during the
sweep. Three security controls were left reading past a refusal into a
`coalesce(..., 0)` for four migrations. A remediation sweep is correct only over
the population that existed when it ran. Any signal added afterwards is
unswept by construction. Fix: when a checker gains a refusal channel, re-run the
consumer sweep as part of the same batch, and assert the count of the gating
idiom in the deployed body rather than trusting the edit.

**The prefix-collision needle.** Convention 21 requires a refined axis to sit
beside the original rather than replace it, which produces names where one is a
strict prefix of another: `rls_enabled_no_policy` and
`rls_enabled_no_policy_reachable`. A textual coverage check on the bare name
matches the longer string and reports the shorter axis as read when nothing reads
it. Fix: wrap the needle in single quotes, `'''' || v_axis || ''''`, so the match
is against the SQL literal rather than the identifier fragment. Any code that
searches for one convention-21 name inside a body containing its sibling has this
bug until proved otherwise.

**The undeclared new function.** A migration creates a `tf_*` function, applies
its grant tier correctly, and stops. The `tf_function_registry` row is missing,
`tf_function_safety_audit` reports `undeclared_total: 1`, and `CM-FNDRIFT-018`
goes `failing` in a **later** migration that has nothing to do with the omission.
Symptom: `P0001: controls left failing after this migration` on a migration whose
own row is correct. Fix: convention 33, three obligations in the same migration.
Diagnosis: run `tf_function_safety_audit()` and read the `undeclared` array,
which names the function.

**The undeclared denominator.** A checker publishes a count of findings and never
says what it counted over. Zero findings over an empty population is byte-identical
to zero findings over a hardened one, so the payload cannot distinguish "clean"
from "blind". This was `tf_security_scan` for its entire life until migration 280.
Fix: publish a `population` object next to the counts, and raise rather than
return zero when the population is empty. The shape generalises. Any number that
is a numerator needs its denominator in the same payload.

**The exemption that suppresses nothing.** A row is added to a suppression list
for a target that is not currently firing. It looks redundant and harmless. It is
neither: it is a standing instruction to stop looking, and it activates the moment
the underlying protection is removed, at which point it is the only thing left and
the checker reports clean. Found live when a concurrent agent exempted two
functions ten minutes after they had already been guarded. Fix: detect staleness
with the exact inverse of the axis predicate, escalate it into `ok: false`, and
refuse the write at the register. Detection alone is not enough, because the row
that suppresses nothing today is written by someone who has not read this.

**The creation exposure window.** A `SECURITY DEFINER` function is executable by
`anon` and `authenticated` between `CREATE FUNCTION` and `tf_apply_grant_tier`,
because Postgres grants `EXECUTE` to `PUBLIC` on creation and Supabase default
privileges add the two client roles. Inside one transaction this is invisible and
harmless. Split across two migrations it is a real, live, unguarded definer
function for however long the gap lasts. Proved at both ends in migration 282.
Fix: house rule fifteen, tier in the same migration as the create.

**The same-transaction measurement trap.** A migration's `DO` block measures a
catalog population "before" and "after" some work, but the `CREATE FUNCTION` it is
measuring ran earlier in the same transaction, so both readings already include
it. The assertion "population grew by one" then fails against an unchanged count
and looks like a defect in the catalog. Fix: assert what the block itself changes.
A register write moves no catalog population, so assert zero movement plus the
row's presence by name.

**Unreachable read as unpoliced.** A table with RLS enabled and zero policies
looks like a gap. If no client role holds any of `SELECT`, `INSERT`, `UPDATE` or
`DELETE` on it, it is correctly built and needs no policy. Counting the two cases
together produces a permanent non-zero gap that operators learn to ignore, which
is worse than not measuring it. Fix: decompose, never narrow. Keep the original
count for existing consumers and publish the client-reachable subset alongside it,
with a partition assertion between them.

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

**The null that is not false.** `tf_function_safety_audit` classifies each
function by matching its body against patterns pulled out of a table, one regex
per signal class, in expressions of the form `body ~* v_vr`. If the table has no
row for that class the variable is null, and in SQL `anything ~* null` is
**null**, not false. The surrounding boolean collapses it to false and the
classification proceeds, confidently, on a signal that has been switched off.

This is what makes it a distinct pattern rather than an instance of the empty-
input problem. An empty *population* is loud, the counters go to zero and
somebody notices. An empty *rule set for one signal* is silent, because every
other signal still fires and the payload still looks fully populated. Deleting
the three `vault_read` rows left 84 functions classified, 55 writers, zero drift,
`ok: true`, and `secret_touchers` down from 18 to 1. The one number that moved is
the one nothing gates on.

Wherever a checker reads its rules from a table, the enumeration of expected rule
classes belongs in the checker's own refusal guard, and the refusal must say
which class is missing. Grep any checker for `~* v_` and count the variables;
every one of them must appear in the null-check above it. See
`FUNCTION_SAFETY_AUDIT.md`.

**The refusal with no listener.** The consumer-side twin, and the broadest defect
found so far. A checker returns `{"ok": false, ...}` and the caller reads
`coalesce((payload->>'some_total')::int, 0)`. The key is absent because the
checker refused, the coalesce supplies zero, and zero is the value that means
healthy. Five of six control consumers in `tf_controls_evaluate` did exactly
this. Four of the five checkers involved can *only* refuse by return value, so
there was no raise for the evaluator's exception handler to catch either.

The tell is easy to grep for and easy to miss by eye: any `coalesce(x->>'k', 0)`
where `x` is a payload that also carries an `ok` key. The fix is to null the
whole quantity on refusal rather than defaulting the counter, so that the
already-existing `null → attention` path carries it to the board:

```sql
v_x := case when v_xj is null or coalesce(v_xj->>'ok','false') <> 'true' then null
            else coalesce((v_xj->>'violation_total')::int,0) end;
```

Note the order inside the `case`. Defaulting the *flag* to `'false'` means a
payload that has lost its `ok` key entirely is treated as a refusal, not as a
pass. Defaulting the *counter* is only safe once the flag has already been
honoured.

**The write path with no keyword in it.** Every text-matching classifier on this
platform decides "does this function mutate?" by looking for `insert`, `update`,
`delete`, `merge`, `truncate`. For one class of function that question cannot be
answered from the text at all. A function that `RETURNS trigger` executes inside
another statement's DML and **its return value is the row that statement writes**.
The mutation is `new.job_number := ...`. There is no keyword to find, no comment
hiding it, and no regex that would help.

`tf_assign_job_number` was classified `read` on this basis while rewriting the
customer-facing identifier of every job the business creates. The fix is not a
better pattern, it is a different instrument: classify structurally on
`pg_proc.prorettype = 'pg_catalog.trigger'::regtype`.

The generalisation is worth carrying to the next checker. **Ask of any classifier:
is there a class of input for which my evidence source is structurally silent?**
Text matching is the default reflex and it is blind to anything the language
expresses through typing rather than through statements. See migration 275 and
`REGISTER_INTEGRITY.md`.

**The register that agrees with itself.** Two independent statements of the truth,
compared, drift published. Except the second statement was generated from the
first. `tf_function_registry` was seeded from `tf_function_safety_audit()` output
at migration 233, so from that day the checker and the register could never
disagree about anything the checker had been wrong about. `drift_total` read 0 for
dozens of migrations while three write paths sat declared as reads.

This is the hardest defect in the library to see, because it presents as health.
Every other entry here shows up as a number behaving oddly. This one shows up as a
number behaving perfectly.

Two tells. First, **read the rationale strings in any register**: a bulk-seeded
population will say so, and if it does not, ask where the rows came from. Second,
**count the independent sources**. If a checker, a register and a control board
all trace back to one query run once, that is one opinion with three renderings.
The countermeasure applied at migration 276 was to add a source no checker wrote:
the catalog itself, consulted by a `BEFORE INSERT OR UPDATE` validator that
refuses rows the catalog contradicts.

**The declaration with no applier behind it.** `tf_function_grant_tiers` rows are
supposed to be written through `tf_apply_grant_tier`, which both records the
intent **and** executes the `revoke`/`grant` statements that realise it. A row
inserted directly into the table records the intent and changes nothing.

The concurrent agent did exactly this, and compounded it by keying on the bare
type list `'integer'` rather than the `pg_get_function_identity_arguments` output
`'p_days integer'`. The rows resolved to no function, counted toward
`missing_total`, and the live ACL was never touched.

> A register row written by hand instead of through its applier is a declaration
> with no enforcement behind it and no key discipline in front of it.

Wherever a table is the record of an action rather than a description of a state,
the table alone cannot be the interface. Either the applier is the only writer, or
the table validates what direct writers hand it. Migration 276 chose the second,
because the first cannot be enforced against an agent that has SQL access.

---

## The house rules

Twenty-three rules, each of which exists because breaking it cost real time.

**Twenty-three. An assertion's failure path is code, and it is untested code.**
Found in migration 320, in the worst possible way: the migration committed clean
and the defect shipped into the immutable migration history.

The assertion was ordinary.

```sql
if coalesce((v_j->>'enforcement_gap_total')::int, -1) <> 0 then
  raise exception 'migration 320: enforcement_gap_total is %, expected 0. Payload: %',
    coaleske_placeholder, v_j::text;
end if;
```

`coaleske_placeholder` is not an identifier. It is not a variable, not a column,
not a function. It is a typo, and it would raise `42703 column
"coaleske_placeholder" does not exist` the instant that line executed. It never
executed, because `enforcement_gap_total` was 0, and **plpgsql does not resolve
identifiers inside a branch it never enters**. The body is parsed for syntax at
creation time and resolved for names at execution time, per statement. A branch
that is never taken is never resolved.

So the assertion passed. And it passed on its success path in total silence, which
is precisely the shape of failure this whole platform is built to refuse: two
components each doing something reasonable and disagreeing quietly. The migration
believed it had a gate. It had a gate on one side and a `42703` on the other.

The damage in this instance is bounded. No database object contains that text, so
the live schema is unaffected; only the `supabase_migrations.schema_migrations`
row does, and that row is immutable. The checked-in repository copy carries the
correction plus an inline comment recording the divergence, so a replay onto a
fresh database reports the intended message instead of a missing-column error.

The general form is worse than the instance. **Every refusal in this repository is
a branch that has never run.** That is the point of a refusal. It means the entire
population of failure paths across three hundred and twenty migrations is code
that was written once, never executed, and assumed correct because the thing it
guards kept passing. A guard whose failure path is broken is not a weak guard. It
is not a guard at all, and it is indistinguishable from a working one from the
outside.

Two countermeasures, and both are required.

Prove the refusal, not just the success. That is the observed-refusal proof
pattern this platform already uses at the migration level: migration 319 exists
solely to create an unwired checker, observe `SQLSTATE 23514` and roll back. Where
a refusal matters, induce it once and transcribe the message.

Run static analysis, because inducing every refusal is not affordable.
`plpgsql_check` resolves identifiers in **unreachable** branches, which is exactly
the blind spot. A full-schema scan of this database runs in 447 ms over 119
functions. That is cheap enough to sit inside the control register rather than in
a developer's habit, and installing it is the next batch.

**Twenty-two. A migration that writes a row into `tf_function_registry` must
re-evaluate the control register before it commits.** Found in migration 315,
when an assertion caught a drift that migration 310 had introduced fifteen minutes
earlier and that no migration since had surfaced.

A declaration is a claim, not a fact. `tf_function_registry.declared_kind` is
written by a human or an agent, and `tf_function_safety_audit` computes the same
property from the function body. When the two disagree the audit publishes drift
and `CM-FNDRIFT-018` renders it. That machinery worked exactly as designed here.
What failed was the interval.

Migration 310 declared `tf_ddl_serialize` as `write`, applying the migration-272
rule by analogy: the function is part of a serialization mechanism, therefore it
must write. Its body does not write. It acquires an advisory lock and raises, so
the audit computed `read` and refuted the claim. Migrations 311 through 313 all
committed cleanly on top of that, because none of them re-scored the register.
The board displayed **26 passing, 0 failing** the entire time, over a live
`drift_total 1`. The number on the board was not wrong when it was written. It was
wrong when it was read, which is worse, because a reader has no way to tell.

House rule seventeen already required a migration that touches the register to
assert the register's aggregate state. This rule extends the same obligation to
migrations that touch the register's *inputs*. A registry write is a register
write with a delay.

> **A stale green is worse than a red, because nobody investigates a green.**

The second half of this rule is where the fix goes. The drift was real, so there
were two ways to make it disappear: change the declaration, or teach
`tf_function_safety_audit` that acquiring a lock counts as a write. The second
would have been faster, would have made the original claim true, and would have
been the wrong fix, because it makes the claim true by weakening the instrument
that tests claims. Convention 21 says decompose, never narrow. The declaration
changed to `read`, and the rationale in the registry row now records that the
function's write effect is on lock state rather than on rows, which is a fact
about the mechanism rather than an exception to the detector.

**Twenty-one. When a rule cannot be enforced by ordering, stop trying to order it
and enforce the outcome at `COMMIT`.** Found in migration 307, while trying to
make obligation two of convention 33 structural.

The obvious design was to refuse at `CREATE FUNCTION` time. An event trigger on
`ddl_command_end` sees the new `public.tf_*` function, finds no
`tf_function_registry` row, and raises. The author is forced to write the
declaration first, and the migration reads in dependency order.

That design cannot work here, and the catalog says so in one query.
`tf_function_registry_validate`, attached by migration 276, contains:

```sql
if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                where n.nspname='public' and p.proname=new.proname and p.prokind='f')
then raise exception '...' using errcode = 'check_violation'; end if;
```

A declaration **cannot precede its function**. That rule is correct and was added
deliberately, to stop the register drifting into a wish list. Combined with the
proposed guard it produces a contradiction: the declaration must come first and
cannot come first. There is no valid migration.

The resolution is to notice that the rule was never about ordering. Convention 33
says "in the same migration", and a migration is a transaction, so the rule is a
statement about what may be true at `COMMIT`. Enforce it there and every ordering
becomes legal, including the only one that works.

```sql
create constraint trigger tf_declaration_pending_deferred_check
  after insert on public.tf_declaration_pending
  deferrable initially deferred
  for each row execute function public.tf_declaration_pending_check();
```

The event trigger now only enqueues, and never raises. The deferred constraint
trigger fires at commit and raises if the registry row is still missing. It
re-reads the registry rather than trusting the queue, so deleting the queue row
does not bypass it: the queue schedules the check, it is never the source of
truth.

Two secondary lessons came out of the same migration. **Prove the transaction
boundary before designing against it**: a probe migration that created a table and
then raised left no table behind and did not increment
`supabase_migrations.schema_migrations`, which establishes that `apply_migration`
is transactional and that every end-of-migration assertion block in this
repository is a genuine pre-commit gate. And **a refusal should teach the correct
ordering**, because the failure mode it guards against is exactly one the next
author will try to fix in the wrong direction. The hint on this raise states the
constraint that makes the naive fix impossible and then gives the working
sequence.

**Twenty. Zero is the passing branch and null is the attention branch, so a check
that could not run must never report clean.** Found in `tf_data_quality_audit`
while giving it an axis declaration in migration 297.

The shape is three lines long and it is the most dangerous thing in the
governance layer:

```sql
exception when others then
  v_gap := 0;
```

The checker throws. The handler catches. The counter is set to the value that
means "nothing wrong". The control reads zero gaps and renders green. The board
is now green **because** the detector is broken, and there is no output anywhere
that looks anomalous. Every other failure mode in this document produces a wrong
number a careful reader could question. This one produces the *right-looking*
number for the wrong reason, and the more thoroughly a team trusts its board, the
more completely this defeats them.

The correction is a type distinction, not a code change. Zero is a measurement
that found nothing. Null is the absence of a measurement. They are not the same
value and a control must not treat them the same way. `tf_data_quality_audit` was
rebuilt to refuse by return value rather than by exception, `tf_controls_evaluate`
was taught to treat a refused data-quality audit as **unmeasured** rather than
clean, and `tf_system_health` was corrected to report an unavailable probe as
**degraded** rather than operational. This is convention 26 applied one level
deeper: convention 26 says a consumer must listen to a refusal, rule twenty says
the checker must be capable of issuing one in the first place.

It is enforced structurally, because a rule this easy to reintroduce by accident
cannot be left to review. Every migration in the 291 to 306 batch runs a regex
over the function text **before** installing it:

```sql
if v_new ~ 'exception when others then[^;]*:=\s*0\s*;' then
  raise exception 'refusing to install a handler that defaults a gap counter to zero';
end if;
```

A pre-install guard is worth more than a post-hoc detector here, because the
window between introducing this defect and noticing it is unbounded by
construction.

**Nineteen. Whether a function is a checker is not a property of its name. It is
a property of whether the consumer reads a counter out of it.** Found while
building the ten-checker roster in migration 304, against an inherited
classification that said eight.

The roster was going to be written from the existing documentation, which listed
eight checkers and three non-checkers. Before writing it, the evaluator's actual
text was read for each supposed non-checker. `tf_controls_board` turned up
`coalesce((v_board->>'unscored_total')::int,0)` and
`coalesce((v_board->>'tautological_total')::int,0)`, both driving the status of
`CM-BOARDFRESH-027`. That is the definition of a checker. It had been one since
migration 288 and had never declared an axis. The same test showed
`tf_controls_signal_coverage` is consumed via its own `gap_total`, making the
coverage detector a member of the population it measures.

Had the roster been written from the inherited classification, the platform would
have published **one hundred percent coverage over a population silently narrowed
by two**, which is precisely the undeclared-denominator failure convention 29
exists to prevent, arriving through a door convention 29 does not watch. A
denominator can be wrong not only by being unpublished but by being published and
mis-derived.

The rule has a structural half. A roster maintained by hand goes stale the first
time somebody adds a consumer, so migration 304 gave it closure: the detector
scans `tf_controls_evaluate` for every `public.tf_*()` call it makes and refuses
any callee that is neither on the roster nor on an explicit, named non-checker
list. Membership is now derived from the consumer rather than asserted about it.

**Eighteen. A control's status branch must compute a status, never assert one,
and a signal must not be produced by the act of evaluating it.** Two halves of
one rule, both found in `tf_controls_evaluate` while placing an unrelated branch
in migration 290.

The first half. `GV-CCM-016`, the control certifying that continuous controls
monitoring is in place, read:

```sql
when 'GV-CCM-016'        then 'passing'
```

Not a judgement. A literal. It rendered `passing` on every run since the day it
was written, and its evidence string was
`'controls evaluated '||to_char(v_now,...)`, which is the timestamp of the write
that produced it. The control asserting that monitoring works was the one control
that was not being monitored, and it would have certified a dead `pg_cron` job
indefinitely. The fix computes from live catalog state:

```sql
select exists(select 1 from cron.job
               where jobname='tf-controls-evaluate-monthly' and active)
  into v_ccm_cron;
...
when 'GV-CCM-016'        then case when v_ccm_cron then 'passing' else 'failing' end
```

This is the same family as the seeded register of migration 276 and the unread
axis of migration 285. In each case the presence of a thing was mistaken for the
property the thing was supposed to have. A branch existing is not the same as a
branch working, and `tf_controls_board`'s `tautological_total` axis now measures
the difference by regex over the evaluator's own catalog text.

The second half. `CM-BOARDFRESH-027` reports how old the board was. If it reads
the board from inside the `UPDATE` that stamps it, it measures its own write and
publishes zero hours old forever. `tf_controls_evaluate` therefore calls
`tf_controls_board()` in its first statements, before anything is written, holds
the result in `v_board`, and the control's evidence ends with the words *"Age is
measured before this run stamps the board"* so a reader can verify the ordering
without reading the source. Any freshness signal computed downstream of the
write it measures is structurally incapable of being non-zero.

**Seventeen. A migration that touches the control register asserts the
register's aggregate state before it commits, not the state of the row it
changed.** Migration 287's first attempt rolled back on its own final assertion,
`controls left failing after this migration: {"total": 26, "failing": 1, ...}`.
The row it had just written was correct. A **different** control,
`CM-FNDRIFT-018`, had gone `failing` because migration 285 created
`tf_controls_signal_coverage` without a `tf_function_registry` row, and
`tf_function_safety_audit` had duly reported `undeclared_total: 1`. A per-row
assertion sees none of that. Cross-control regressions are invisible to anything
that only looks at what it changed, and the register would have carried a
silently failing control until the next manual review. The assertion is one
line:

```sql
if coalesce((v_sum->>'failing')::int, -1) <> 0 then
  raise exception 'controls left failing after this migration: %', v_sum::text;
end if;
```

That line paid for itself the first time it ran.

**Fifteen. Apply the grant tier in the same migration that creates the function,
never in a follow-up.** Proven by assertion in migration 282. Postgres grants
`EXECUTE` to `PUBLIC` on every newly created function and Supabase's
`ALTER DEFAULT PRIVILEGES` adds `anon` and `authenticated` on top, so a
`SECURITY DEFINER` function is a reachable, unguarded definer function from the
instant `CREATE FUNCTION` returns until `tf_apply_grant_tier` runs.
`has_function_privilege('authenticated', oid, 'EXECUTE')` reads **true**
immediately after the create and **false** after the tier, and the guard axis
falls by exactly one across those two statements. Inside one transaction the
window is not exploitable. Split across two migrations it is a live exposure for
however long the second one takes to write.

**Sixteen. When your own assertion fails, ask whether it found something before
assuming it is wrong.** Migration 282 asserted that adding a validator which
changes no grant and no guard could not move the guard axis. It failed with
`guard axis moved 1 to 0`. The assertion was correct and the model behind it was
incomplete: house rule fifteen above exists only because that failure was
investigated rather than relaxed. Relaxing a failing assertion converts a finding
into a blind spot, and it does it silently, which is the worst combination this
document knows of. The correct move is to encode the discovery as the new
assertion so the property is re-proved on every replay.

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

**A refusal is only real if every consumer listens to it, and a refusal that
omits one of its own inputs is not a refusal.** The thirteenth rule came from
turning the eleventh on a third checker and finding that the previous two passes
had been building something nobody downstream was reading. It has two halves and
they were found one after the other.

The first half is inside `tf_function_safety_audit`. It already had a
completeness guard on its pattern table, and the guard checked four of the five
signal classes it reads. The missing one was `vault_read`, and the reason the gap
was invisible is a Postgres detail worth memorising: `anything ~* null` evaluates
to **null**, not false. Deleting three rows from a table therefore made every
function on the platform read as not touching the Vault, collapsed
`secret_touchers` from 18 entries to 1, and returned `ok: true` while doing it.
A guard that enumerates its inputs and misses one is not a partial guard, it is a
blind spot that has been given a reassuring name.

The second half is worse and it is general. Six checkers feed
`tf_controls_evaluate` and all six can return `ok: false`. Exactly one consumer
read the flag, the one written after migration 265. The other five read straight
past it to the counter they wanted, and because every counter is pulled with
`coalesce(..., 0)`, a checker that had refused arrived as a clean zero, and zero
maps to `passing`. Four of those five can only refuse by return value, never by
raise, so for them the refusal channel was completely unheard. Every refusal
migrations 262, 263, 265, 266 and 268 taught a checker to emit was landing in a
consumer that could not tell refusal from cleanliness. Migration 269 gave all six
the same null-on-refusal shape.

The question this rule adds to the other two: **who reads this, and what do they
do when it says no?** Building a refusal is half the work. A refusal with no
listener is an unhandled exception with better manners.

**Agreement between a checker and a register it wrote is not corroboration.** The
fourteenth rule came from turning the eleventh on a fourth checker, and it is the
one that undermines the previous thirteen if it is not held.

The whole architecture here rests on convention 7: conventions live in tables,
checkers read the tables. Two independent statements of the truth, compared, and
a drift count published when they disagree. That only works if the two statements
are actually independent.

`tf_function_safety_audit` classifies a function as a read or a write by matching
its body against signal patterns. `tf_function_registry` declares what each
function is supposed to be. `drift_total` had read 0 for dozens of migrations.
Then migration 275 fixed a structural blind spot in the classifier, a function
that `RETURNS trigger` is a write path by construction and contains no DML
keyword for a pattern sweep to find, and the drift row that appeared carried this
rationale: **"Baseline classification seeded from `tf_function_safety_audit()` at
migration 233."**

The register agreed with the checker because the register was populated by the
checker. Three functions that rewrite production rows had been declared reads, the
drift checker had been confirming the declaration matched, and both were reading
from the same mistake. The comparison had been running correctly against a
duplicate of one opinion.

Seeding a register from a checker is often the only practical way to bootstrap
one, and it was the right call for eighty-odd functions at migration 233. What
was missing was any mechanism that could ever disagree. Migration 276's answer is
to make the register refuse rows the catalog contradicts, which is a third
statement of the truth and one that no checker wrote. It also makes the seeding
visible: the rationale string is the only reason this was diagnosable at all, and
it is now the reason every corrected row says what corrected it.

The question this rule adds: **where did the rows in this register come from, and
is there anything in this system that could ever tell me they are wrong?** If the
answer to the second half is "the checker," the drift count is decorative.

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

**30 controls, 27 `passing`, 3 `attention`, 0 `failing`** as of migration 320,
24 automated and 6 manual. The three in `attention` are `AC-PRIV-002` (one
intentionally anon-exposed definer function, carrying a live exemption row that
suppresses a real finding), `AC-MFA-003` and `DP-PITR-007`, the latter two being
owner actions 3 and 4 above. Evaluated monthly by `tf-controls-evaluate-monthly`,
and on demand by `tf_controls_evaluate()`, which is a writer and takes no
arguments.

Six of the 30 are manual and **none of the six has ever been attested**. That is
counted rather than assumed, and it is an owner action, not an engineering one.

`it_controls.status` is constrained to exactly four values, verified from
`pg_get_constraintdef`: `passing`, `attention`, `failing`, `manual`. There is no
`pending`. Seeding a new automated control that has not been evaluated yet takes
`attention`, since unmeasured is not clean, and `tf_controls_evaluate()` promotes
it inside the same transaction.

Before reading any status on this board, read the board itself:

```sql
select public.tf_controls_board();
```

Expect `authoritative: true`. That single boolean is false if the register is
older than 792 hours, if any automated control has no status branch in
`tf_controls_evaluate`, or if any branch asserts a status literal instead of
computing one. A board of green statuses proves nothing until `authoritative`
reads true, because `it_controls.status` is a cache and until migration 288
nothing on the platform knew how old that cache was. `CM-BOARDFRESH-027` renders
the same three numbers as a control. See
[`CONTROL_BOARD_FRESHNESS.md`](./CONTROL_BOARD_FRESHNESS.md), which also records
why `last_evaluated_at` cannot be used for this: it is a **write** timestamp. The
evaluator stamps every automated row from one `UPDATE` sharing one `v_now` and
its status CASE ends `else status end`, so an unscored row is stamped as fresh as
a scored one and `count(distinct last_evaluated_at)` reads 1.

The most recently added, by migration 315, is `CM-DEPLOY-029`, owned by `CISO`,
automated, reading `tf_deploy_coordination_audit` `coordination_gap_total`. It
certifies that concurrent schema deployments are serialized by the
`tf_serialize_deploy_ddl` advisory-lock trigger and that every DDL command is
recorded by the `tf_deploy_ddl_log` trigger into `tf_deploy_log`. Four of its five
axes are catalog facts, both triggers present and both enabled. The fifth,
`interleaved_deploy_total`, is computed from recorded command spans, which makes
it the only axis that can contradict the other four: the triggers can be correctly
installed today and the log can still show two deploys overlapped yesterday. Live
0 interleaved pairs across 12 DDL transactions on 12 backends and 41 logged
commands. See [`DEPLOY_COORDINATION.md`](./DEPLOY_COORDINATION.md).

Before that, by migration 290, `CM-BOARDFRESH-027`, owned by
`CISO`, automated, reading `tf_controls_board` `authoritative`. The same
migration fixed `GV-CCM-016`, which had been hardcoded to `'passing'` since it
was written: the control certifying continuous controls monitoring was the one
control not being monitored. It now computes from live `cron.job` state and
would read `failing` if `tf-controls-evaluate-monthly` were dropped or
deactivated.

The three before that are the signal-consumption tier, all owned by
`CISO`, all automated, added by migrations 284 and 287:

- `CM-TRUNCGRANT-024` — privileges outside the RLS-evaluated set are not held by
  client roles. Reads `tf_security_scan` `tables_truncatable_by_client`, which
  monitors the migration 272 hardening. Live 0.
- `CM-SCANINTEG-025` — the security scan vouches for its own population and its
  refusals are heard. Reads `integrity_total` plus `stale_exemption_total`, and
  is the reason the evaluator now honours the scan's `ok` flag at all.
- `CM-SIGNALCOV-026` — every declared detection axis on the checker roster has a
  consumer that renders it. Reads `tf_controls_signal_coverage` `gap_total`,
  which since migration 304 is a roll-up of five primitives: unread axes,
  undeclared checkers, unmeasured checkers, unrostered callees and
  refusal-ungated checkers. Live 0 over **26 axes across 12 checkers**, up from
  6 axes across 1 checker before migration 291.
- `CM-FNDECL-028` — creating a `tf_*` function without declaring it is
  impossible, not merely detectable. Reads `tf_declaration_enforcement_audit`
  `enforcement_gap_total`, a roll-up of four primitives: enforcement missing,
  enforcement disabled, pending-queue residue and unregistered functions. Live 0
  over 100 functions and 100 registry rows, with the event trigger in `origin`
  state. Added by migration 309.

The structural change in that batch matters more than the three rows.
`tf_controls_evaluate` had never honoured `tf_security_scan`'s `ok` flag, because
that flag was added in migration 280 **after** the migration 269 sweep that
taught the other consumers to stop reading past a refusal. Three security
controls could have rendered `passing` against a scan that had declared itself
untrustworthy. See `docs/CONTROL_SIGNAL_COVERAGE.md`.

The six controls before those are the convention-enforcement tier:
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

Since migration 269 the same is true of a checker that refuses **by return
value** rather than by raising. All six checker consumers now null out on
`coalesce(payload->>'ok','false') <> 'true'` before summing, so a refusal reaches
the board as `attention`. Before 269 only `AC-GUARDREG-023` did this; the other
five read past the flag into a `coalesce(..., 0)` and rendered `passing` over a
checker that had declined to answer. Four of the six checkers involved can only
refuse by return, never by raise, which is why the exception handler above was
not sufficient on its own.

### One published metric that deliberately gates nothing

`tf_function_safety_audit().misleading_total` reads **7** and no control consumes
it. The seven are `tf_access_review`, `tf_controls_evaluate`,
`tf_integration_health_report`, `tf_it_governance_report`, `tf_ops_report`,
`tf_scheduler_health` and `tf_system_health`, each a report or evaluator whose
name implies a read and which legitimately persists what it computed.

The decision recorded at migration 269 is to publish and not gate, because making
it gate flips `CM-FNDRIFT-018` to `failing` over seven pre-existing naming
choices and trains operators to read a failing control as noise. House rule
eleven requires that an ungating metric be either promoted or explained; this one
is explained, and it is listed here so the decision is revisited rather than
forgotten. The alternative under consideration is a rename pass with a
compatibility shim, which is a larger change than it looks because every one of
the seven is called from cron.

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
| Migrations applied | 320 |
| Base tables in `public` | 177 |
| Tables with RLS enabled | 177 (100%) |
| RLS policies | 590 |
| `tf_*` operator functions | 104 |
| `tf_*` functions declared in `tf_function_registry` | 104 (100%), structurally enforced at `COMMIT` since migration 307 |
| `tf_*` functions with a declared grant tier | 104 (100%) |
| Declared grant-tier rows | 105 |
| Checkers on the signal roster | 13, publishing 27 declared axes, 0 unread, 0 orphan |
| Checker signal wiring | structurally enforced at `COMMIT` since migration 318, `wiring_gap_total 0` |
| Tables `TRUNCATE`-able by `anon` or `authenticated` | 0 of 177 |
| Registers with catalog-validating triggers | 2 (`tf_function_registry`, `tf_function_grant_tiers`) |
| Event triggers | 11 |
| Views | 7 |
| Enums | 80 |
| Indexes | 669 |
| Active pg_cron jobs | 37 |
| Edge functions | 37 |
| GRC controls | 30 |
| Controls passing / attention / failing | 27 / 3 / 0 |
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
- `FUNCTION_SAFETY_AUDIT.md` — the signal-pattern table, `CM-FNDRIFT-018`, the null-that-is-not-false defect closed by migration 268, the unheard refusal channel closed by migration 269, and the written reason `misleading_total` is published but does not gate
- `REGISTER_INTEGRITY.md` — **the checker that seeded its own oracle.** The trigger-function classifier blind spot closed by migration 275, the seeded-register finding it surfaced, the mis-keyed register row the concurrent agent wrote, the catalog-validating triggers migration 276 attached to both registers, the four inductions that prove each refusal fires for the right reason, and the savepoint-probe technique
- `LEAST_PRIVILEGE_TABLE_GRANTS.md` — **the privilege RLS does not gate.** Why `TRUNCATE` cannot be constrained by any policy, the 172-of-173 exposure closed by migration 272, the `TRIGGER` / `REFERENCES` / `MAINTAIN` companions, the `supabase_admin` default-ACL residual, the missing scanner axis, and the evidence the hardening held under a later concurrent deploy
- `SECURITY_SCAN_INTEGRITY.md` — why a scan must vouch for its own population, the undeclared denominator, the exemption-that-suppresses-nothing rule, `CM-SCANINTEG-025`
- `CONTROL_SIGNAL_COVERAGE.md` — the three obligations of creating a `tf_*` function, house rule seventeen, the five refusal primitives of `tf_controls_signal_coverage`, `CM-SIGNALCOV-026`
- `CONTROL_BOARD_FRESHNESS.md` — why `it_controls.status` is a cache, why `last_evaluated_at` cannot measure its age, the unscored and tautological axes, house rule eighteen, `CM-BOARDFRESH-027`
- `CHECKER_AXIS_DECLARATION.md` — the checker roster, the three couplings, the strict counter-read needle, house rules nineteen and twenty, and why a checker declares its own axes rather than a detector inferring them
- `DECLARATION_ENFORCEMENT.md` — **the first control that certifies an impossibility.** The discarded statement-level design and the catalog fact that disproved it, the enqueue-plus-deferred-constraint mechanism, house rule twenty-one, the monitored kill switch, `CM-FNDECL-028`
- `DEPLOY_COORDINATION.md` — **the risk six passes named and this one closed.** The advisory-lock refusal trigger, the deploy log and why it stamps `clock_timestamp()` rather than `now()`, the MCP serialization finding, the `pg_cron` backend that made the refusal provable, the axis that can contradict the other four, house rule twenty-two, `CM-DEPLOY-029`
- `SIGNAL_WIRING_ENFORCEMENT.md` — **the last of the three obligations, closed.** Why "no single catalog fact" was true and "therefore unenforceable" was false, the three-fact definition of wired, the catalog definition of a checker that closes the exemption lever, the verbatim `SQLSTATE 23514` refusal, the wrongly-timed-check-counts-as-missing rule, the pending-queue residue correction, house rule twenty-three, `CM-SIGWIRE-030`
- `MIGRATIONS_INDEX.md` — the ordered migration manifest; migrations 249 through 252 are checked in verbatim beside it as worked examples of the anchored catalog-patch idiom, 253 through 257 are indexed with their reasoning carried in `GUARD_DETECTION.md`, 258 through 264 with theirs in `FUNCTION_GRANT_TIERS.md`, 265 through 267 with theirs back in `GUARD_DETECTION.md`, 268 through 269 with theirs in `FUNCTION_SAFETY_AUDIT.md`, and 270 through 277 with theirs split across `LEAST_PRIVILEGE_TABLE_GRANTS.md` and `REGISTER_INTEGRITY.md` plus the concurrent-deployment note at the head of the index

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

**Pass 8, 2026-07-25, at migration 269.** Pass 7 named the next checker in the
sweep and pass 8 took it. `tf_function_safety_audit` produced a defect one level
below the shape pass 7 was hunting, and then reading its consumer produced a
defect one level above, which turned out to be the largest of the three passes.

| Claim carried into this pass | What the catalog said | Resolution |
| --- | --- | --- |
| The audit refuses when its pattern table is emptied | it refused on four of the five signal classes it reads. `vault_read` was not in the guard | migration 268 checks all five and returns `missing_signals` naming exactly which are absent |
| A missing pattern class is loud | `body ~* null` is null, not false. Deleting three rows silently made every function read as not touching the Vault | migration 268's refusal fires first; proved by deleting the rows live and observing the pre-fix clone certify while the fixed function refuses |
| `secret_touchers` is a stable inventory of 18 | it drops to 1 when the `vault_read` rows are deleted, under an `ok: true` payload reporting 84 functions and zero drift | asserted as exact arithmetic, `pre = 18 - vault_read_only`, inside migration 268's proof |
| The audit cannot be emptied | a zero-function population returned every counter at zero under `ok: true` | migration 268 raises: *"A safety audit that examined nothing is not a pass."* |
| Every catalog sweep filters `prokind` | this one did not; a `tf_*` aggregate would have raised `42809` and taken the audit down | migration 268 adds `and p.prokind = 'f'` |
| One control consumer ignores its checker's `ok` flag | **five of six did.** `v_gt`, `v_nd`, `v_fn_bad`, `v_bool_haz`, `v_oob`. Only `v_gd` read it | migration 269 gives all six the same null-on-refusal shape |
| A refusing checker is caught by the evaluator's exception handler | only if it refuses by *raise*. Four of the six can refuse **only** by return value, and those refusals were completely unheard | the `ok` flag is now honoured on the return path, independently of the raise path |
| Migrations 267, conventions 25, house rules 12 | 269 / 26 / 13 | inventory, conventions register, house rules, defect-pattern library, symptoms table, open register, and a new `FUNCTION_SAFETY_AUDIT.md` |

One convention went into the register this pass, number 26: **a refusal must
cover every input the checker reads, and every consumer of a refusal must listen
to it**. Two defect classes went into the library, **the null that is not false**
and **the refusal with no listener**. One house rule went in as the thirteenth,
carrying both halves.

**On the strongest proof in the set, again, and this time there is no clone in
the load-bearing arm.** Pass 6 had to label its proof as the weak kind. Pass 7
could induce against the live object because the lever was a table. Pass 8 went
further: migration 269 demonstrates the defect **live, before the patch, in the
same transaction that applies it**, then demonstrates the fix after it, then
restores and asserts exact recovery.

The mechanism is worth writing down because it was assumed impossible for several
passes. Inside a migration `auth.uid()` is null, so every `forbidden` guard on the
platform is unreachable and nothing refuses. That is not true. Setting
`request.jwt.claims` through `set_config` to a non-staff identity makes
`auth.uid()` non-null and makes every read-path checker take its refusal branch
at once. The migration asserts the induction actually took, that `auth.uid()` is
non-null and that the chosen identity is genuinely not internal staff, before it
asserts anything about the defect. Then it observes five controls reading
`passing` while their checkers return `ok: false`, with `AC-GUARDREG-023` in the
same evaluation as an in-transaction **control group** reading `attention` under
the identical refusal. Same board, same call, same broken condition, different
answer, and the only difference is which side of migration 265 the consumer was
written on. That control group is what rules out "the evaluation was not really
refusing" as an alternative explanation, and it is the piece that makes this the
strongest proof shape on the platform.

Everything re-measured this pass agreed on the second reading: 269 migrations,
271 functions in `public`, 84 `tf_*` functions, the audit `ok: true` with 55
writers, 29 reads, 7 transitive writers, 20 documented diagnostics, 0 drift, 0
undeclared, 0 stale, 0 diagnostic violations, 18 secret touchers, 15 pattern rows
across five signal classes, no `zz\_%` proof-fixture residue, and 23 controls at
21 passing / 2 attention / 0 failing. The two in `attention` remain `AC-MFA-003`
and `DP-PITR-007`, both owner actions. All thirteen automation flags read `false`.

The finding worth carrying forward inverts the direction of the last two passes.
Pass 6 asked what happens when the verifier's own number goes bad. Pass 7 asked
who is allowed to move it. Pass 8 asks **who is listening when it says no**, and
the answer across five of six consumers was nobody. Three passes of teaching
checkers to refuse rather than certify nothing had been landing in a consumer that
could not distinguish a refusal from a clean bill of health. Build the refusal,
then walk the call graph and read every consumer of it. A refusal with no listener
is not a safety feature, it is an unhandled exception with better manners.

The sweep continues at `tf_security_scan`, then `tf_access_review`, then
`tf_revenue_linkage_audit`, `tf_queue_health` and `tf_scheduler_health`. The
three checkers already touched in passing here, `tf_automation_note_drift`,
`tf_boolean_default_hazards` and `tf_automation_out_of_band`, now have listened-to
refusals but still have no population or empty-input concept of their own.

**Pass 9, 2026-07-25, at migration 276.** Pass 9 did not start where pass 8 said
it would. A second agent began deploying the Studio Founding Access and Studio
Analytics features to production while this session was open, and the drift it
introduced took priority over the planned `tf_security_scan` rebuild. That
interruption turned out to be the most productive input of the whole sweep: three
of the four findings below exist only because two authors wrote to the same schema
without coordinating, which is a permanent condition of this platform and not an
accident to be cleaned up once.

| Claim carried into this pass | What the catalog said | Resolution |
| --- | --- | --- |
| Tenant isolation rests on RLS, and RLS is at 100% | `TRUNCATE` is not evaluated per row, so no policy constrains it. 172 of 173 tables granted `TRUNCATE` to `authenticated`, all 173 granted `TRIGGER`, `REFERENCES` and `MAINTAIN` | migration 272 revoked all four from both client roles. Live count now 0 of 173. Never reachable through PostgREST, which is why it survived |
| The five new definer functions are feature code, not security surface | `tf_studio_funnel` and `tf_studio_quality_gates` were `SECURITY DEFINER`, executable by `anon` and `authenticated`, unguarded, aggregating `studio_events` whose only `SELECT` policy is `studio_is_staff()` and on which `anon` holds no `SELECT` at all | migration 274 converted both to plpgsql and added the guard idiom, bodies otherwise byte-identical. `gap_total` 10 to 1, `secdef_authenticated_no_guard` 5 to 0 |
| `tf_function_safety_audit` classifies every function correctly, `drift_total` 0 | three `RETURNS trigger` functions were classified `read`, including `tf_assign_job_number`, which rewrites the job identifier of every job the business creates. A trigger body contains no DML keyword to match | migration 275 classifies structurally on `pg_proc.prorettype`, proved by exact partition. `trigger_writers` published as its own total |
| `tf_function_registry` independently corroborates the audit | the surfaced drift row read "Baseline classification seeded from `tf_function_safety_audit()` at migration 233". The register was populated by the checker that reads it | migration 276 corrected the class, then attached catalog-validating triggers to both registers so a third source exists that no checker wrote |
| A register row is a declaration of intent | rows inserted by hand into `tf_function_grant_tiers`, keyed on the bare type list, resolved to no function and applied no ACL | the grant-tier validator canonicalises unambiguous mis-keys and refuses the rest. Induction 4 replays the exact production row |
| A migration can assert its own end-state | migration 274's first attempt rolled back because the population grew mid-transaction under a concurrent deploy | assert deltas measured inside the transaction; report concurrent arrivals by `raise notice`. Now house practice, applied in 272, 274, 275 and 276 |

Two results from this pass are worth separating from the rest because they change
how future work should be checked rather than closing a specific hole.

The first is **the savepoint probe**. A PL/pgSQL `BEGIN ... EXCEPTION` block is an
implicit savepoint, and plain variables are not transactional, so a probe row can
be inserted into a production table, its post-trigger state captured into
variables, and the whole thing rolled back by a deliberate `raise` that the
handler swallows. Live behaviour, zero residue. It is what proved that
`tf_founding_guard` still fires after its `EXECUTE` privilege was revoked, which
is counter-intuitive until you know that **Postgres checks `EXECUTE` on a trigger
function at `CREATE TRIGGER` time, not at fire time**. Every trigger function on
this platform can therefore be tiered `admin` at no functional cost.

The second is that **the concurrent-deployment problem is now the largest
unmitigated governance risk in the backend**, larger than any individual finding
above. Two agents hold DDL rights on one production schema with no lock, no
advisory alert and no post-deploy drift notification between them. The failures
observed were benign only because one of the two agents was auditing. Nothing
structural produced that outcome. Ordinals became unpredictable mid-session, this
block was drafted as "270 through 273" and is in fact 272, 274, 275 and 276, which
is why the migration **name** is the only citable identifier.

The sweep resumes at `tf_security_scan`, which is fully drafted and unapplied:
convert to plpgsql, preserve all twelve payload keys, add `ok`, `errors`,
`population`, `stale_exemptions` and `integrity_total`, couple the declared axis
list to the computed axis object with a drift raise, and express the guard axis as
an explicit partition with a mismatch check. Behind it sit three items this pass
created rather than closed: a `tables_truncatable_by_client` axis so migration
272 is monitored and not merely done, a freshness gate on `it_controls.status`
which remains a cache with no staleness concept, and the deployment-coordination
decision above.

**Pass 10, 2026-07-25, at migration 283.** Pass 9 ended by naming
`tf_security_scan` as fully drafted and unapplied. Pass 10 applied it and then
kept going, because the rebuild immediately produced two findings that the old
body could not have surfaced. Ordinals 280 through 283 are contiguous only
because the concurrent agent happened not to deploy during the window. That is
luck, not coordination, and the governance ticket remains open.

| Claim carried into this pass | What the catalog said | Resolution |
| --- | --- | --- |
| `tf_security_scan()` reporting `gap_total 1` means the platform is one gap from clean | the payload contained no statement of what had been counted. A scan over an empty population returns the same `gap_total 0` as a perfectly hardened one, and every control and dashboard on the platform reads this function | migration 280 publishes a seven-field `population` block, raises on an empty population, couples the declared axis list to the computed axis object, and derives `gap_total` by iterating the declaration. All twelve legacy keys preserved, eight added |
| The three exemptions in `security_scan_exemptions` are the three deliberate ones | five rows were present. The concurrent agent had exempted `tf_studio_funnel` and `tf_studio_quality_gates` at 14:45:50, ten minutes **after** migration 274 had already guarded both at 14:35:27 | migration 281 retired both, asserting that removing an exemption which suppresses nothing cannot move the guard axis. It did not move. Back to the three deliberate rows |
| Retiring the two bad rows closes it | nothing prevented the next one. The rows were written in good faith by an author who could not have known the functions were already guarded | migration 282 attached `tf_security_scan_exemption_validate`, refusing six classes of bad row including the already-guarded case and a `reason` under 40 characters, proved by three inductions each requiring its specific refusal marker |
| Adding a validator that changes no grant and no guard cannot move the guard axis | it moved 1 to 0. A brand-new `SECURITY DEFINER` function is executable by `authenticated` from `CREATE FUNCTION` until `tf_apply_grant_tier`, through the Supabase default privileges layered on the Postgres `PUBLIC` grant | the finding was encoded as the assertion rather than the assertion relaxed. Migration 282 now proves `has_function_privilege` true before the tier and false after, and the axis falling by exactly one, on every replay. House rules fifteen and sixteen |
| Migration 272 hardened the `TRUNCATE` grants, so that finding is closed | nothing watched them. The `supabase_admin` default-ACL residual is the mechanism by which the finding silently returns, and no axis would have seen it | migration 283 added `tables_truncatable_by_client` as the sixth declared axis. Reads 0, names the offenders when non-zero. `LEAST_PRIVILEGE_TABLE_GRANTS.md` closed its own open item |
| `rls_enabled_no_policy 1` is a real gap | `studio_events_prelaunch_archive` has RLS on, zero policies, and **no `anon` or `authenticated` grants of any kind**. It is correctly built. The axis could not distinguish unreachable from unpoliced | migration 283 decomposed rather than narrowed. The original key still reads 1 for existing consumers; `rls_enabled_no_policy_reachable` reads 0, with `rls_no_policy_partition_mismatch` guarding the subset relation |

| Verified at the start of this pass | Verified at the end | What was re-read |
| --- | --- | --- |
| Migrations 279, conventions 28, house rules 14, axes 5 | 283 / 30 / 16 / 6 | inventory, conventions register, house rules, defect-pattern library, symptoms table, `LEAST_PRIVILEGE_TABLE_GRANTS.md`, and a new `SECURITY_SCAN_INTEGRITY.md` |

Live state at 15:10:42Z: `tf_security_scan()` `ok true`, `integrity_total 0`,
`errors []`, `gap_total 2`, `secdef_authenticated_no_guard 0`,
`tables_truncatable_by_client 0`, `rls_enabled_no_policy_reachable 0`,
`stale_exemption_total 0`, population 174 tables and 120 definer functions with
60 reachable by `authenticated`, 3 exempt and 57 unexempt.
`tf_grant_tier_audit()` `ok true` at 100% coverage over 92 functions with zero
violations, zero missing, zero uncovered and zero drift.
`tf_function_safety_audit()` 92 functions, 31 reads, 61 writers, 6 trigger
writers. `tf_controls_evaluate()` 23 controls, 19 passing, 3 attention, 1
failing, 6 manual and all 6 never attested.

Two results from this pass change how future work should be checked rather than
closing a specific hole.

The first is that **a suppression mechanism needs a staleness concept from the
day it is created**. The exemption list was added in migration 265 to give the
guard axis a legitimate escape hatch, with a counter so the lever was visible.
That was correct and insufficient. Visibility told you how many rows existed, not
whether any of them still did anything. The general form: any list that tells a
checker to stop looking must itself be checked for entries that are no longer
looking at anything, and the check must be the exact inverse of the predicate it
suppresses, or the two will drift and the inverse will stop being an inverse.

The second is that **the three unclosed items from pass 9 are now two, and the
remaining two are both about listening rather than detecting**. `tf_controls_evaluate`
has 23 control rows and not one of them reads `tables_truncatable_by_client` or
`tf_security_scan`'s `integrity_total`. The scan refuses correctly, publishes the
refusal, and nothing consumes it. That is precisely the shape migration 269
closed on the other five consumers, reappearing on a new axis within a day,
which suggests the wiring step needs to be part of the axis-adding procedure
rather than a follow-up. Alongside it, `it_controls.status` is still a cache with
no freshness gate, so the board can render a stale evaluation as authoritative.

The sweep resumes there: wire `CM-TRUNCGRANT` and `CM-SCANINTEG` control rows
onto the two unread signals, then put a staleness threshold on
`it_controls.evaluated_at` and refuse to render past it. Behind those sits the
deployment-coordination decision, ClickUp `86bb3etah`, which pass 9 named the
largest unmitigated governance risk in the backend and which pass 10 did nothing
to reduce.

**Pass 11, 2026-07-25, at migration 287.** Pass 10 ended by naming two unread
signals and asking for two control rows. Pass 11 wired them, then found a third
defect underneath that was larger than either, then escalated from fixing
instances to detecting the class. Ordinals 284 through 287 are contiguous with no
concurrent-agent interleave.

| Claim carried into this pass | What the catalog said | Resolution |
| --- | --- | --- |
| Two axes are unread, wire two controls and the batch is done | three signals were unread, not two. `rls_enabled_no_policy_reachable` had been added by migration 283 in the same breath as `tables_truncatable_by_client` and was equally unconsumed, so `AC-RLS-001` was still weighing the superset and reading a correctly-built table as a gap | migration 284 moved `AC-RLS-001` onto the reachable subset while keeping both numbers plus the 174-table denominator in its evidence string, so the correction is auditable rather than silent |
| The consumers were swept for refusal handling by migration 269, so scan-derived controls honour `ok: false` | `tf_security_scan` had no `ok` flag when that sweep ran. It gained one in migration 280, four migrations later, and nothing went back. Three security controls would have rendered `passing` against a scan that had declared itself untrustworthy | migration 284 split `v_scan_raw` from `v_scan`, gating every scan-derived status on the refusal flag, and added `CM-SCANINTEG-025` so the refusal itself has a control. A remediation sweep is correct only over the population that existed when it ran |
| Wiring the three controls closes the finding | it closes three instances of a class that had already recurred twice within a day, on migration 269 and again on migration 283. The wiring step was a follow-up rather than part of the axis-adding procedure, and follow-ups get dropped | migration 285 built `tf_controls_signal_coverage()`, which matches the scan's declared axis list against the **catalog definition** of `tf_controls_evaluate`, per the migration 276 rule that agreement between a checker and a register it wrote is not corroboration. It would have caught migration 283's unread axis the day it landed |
| The coverage checker should be gated on the scan's `ok` flag like every other consumer, per convention 26 | applying convention 26 here would silence the checker exactly when refusals start happening, because its whole purpose is to notice unheard refusals | deliberately ungated, with five refusal codes of its own and `refusal_flag_honoured` published as an observation read out of the consumer's catalog text. Convention 32 |
| A substring search for the axis name proves the axis is read | `rls_enabled_no_policy` is a strict prefix of `rls_enabled_no_policy_reachable`, which convention 21 guarantees will keep happening. A bare match reports the short axis as read when only the long one is referenced | the needle is wrapped in single quotes, `'''' \|\| v_axis \|\| ''''`, matching the SQL literal rather than the identifier fragment. **The prefix-collision gotcha** |
| The wiring migration is a clean re-submit | it rolled back on its own final assertion, `controls left failing: {"total": 26, "failing": 1}`. The failing control was `CM-FNDRIFT-018`, not the one being written. Migration 285 had created a `tf_*` function with a correct grant tier and no `tf_function_registry` row | house rule sixteen applied. `tf_function_safety_audit()` named `tf_controls_signal_coverage` in its `undeclared` array. Migration 286 declared it, migration 287 re-submitted unchanged and passed. That failure produced **the three obligations** and **house rule seventeen** |
| Replacing `tf_controls_evaluate` reopens the creation exposure window | `CREATE OR REPLACE` preserves the existing ACL. Only `CREATE` installs the default grants | asserted live in migration 287: `has_function_privilege('authenticated', oid, 'EXECUTE')` reads false immediately after the replace. House rule fifteen applies to creates, not replaces, and that distinction is now proved rather than assumed |

| Verified at the start of this pass | Verified at the end | What was re-read |
| --- | --- | --- |
| Migrations 283, conventions 30, house rules 16, controls 23, axes 6 | 287 / 33 / 17 / 26 / 6 | inventory, conventions register, house rules, defect-pattern library, symptoms table, open register, `SECURITY_SCAN_INTEGRITY.md`, `LEAST_PRIVILEGE_TABLE_GRANTS.md`, `IT_GOVERNANCE_GRC.md`, and a new `CONTROL_SIGNAL_COVERAGE.md` |

Live state at 15:29:26Z. `tf_controls_evaluate()`: 26 controls, 23 passing,
**0 failing**, 3 attention, 20 automated, 6 manual and all 6 never attested.
`tf_controls_signal_coverage()`: `ok true`, `declared_axes 6`, `unread_total 0`,
`unread_axes []`, `refusal_flag_honoured true`, `gap_total 0`.
`tf_grant_tier_audit()`: `ok true`, 100 pct coverage over 93 functions, zero
violations, zero missing, zero uncovered, zero drift.
`tf_function_safety_audit()`: 93 functions, 32 reads, 61 writers, 6 trigger
writers, 7 transitive writers, `undeclared_total 0`, `drift_total 0`.
`tf_security_scan()`: `ok true`, `integrity_total 0`, `gap_total 2`,
`rls_enabled_no_policy_reachable 0`, `tables_truncatable_by_client 0`,
population 174 tables and 120 definer functions.

Three results from this pass are worth carrying forward.

The first is the sentence the batch turns on: **detection without consumption is
not a control**. A checker that finds something and publishes it has done nothing
at all unless something downstream turns that publication into a status a human
acts on. Every finding in this pass is a variation on it. The generalisation is
that adding an axis and wiring an axis are one change, not two, because the
second half of a two-part change is the half that gets dropped.

The second is that **a remediation sweep ages**. Migration 269 swept six
consumers for refusal handling and was correct on the day. Migration 280 added a
refusal channel to a seventh signal and the sweep did not extend to cover it,
because a sweep is a snapshot and nothing marks it stale. The countermeasure is
not diligence, it is a checker: when the property a sweep established can be
expressed as a predicate over the live catalog, express it, and the sweep becomes
a control instead of an event.

The third is that **house rule seventeen paid for itself on its first run**.
Without the aggregate assertion the register would have carried a silently
failing control until somebody looked. The per-row assertion that the batch
started with would have passed, and been wrong.

The sweep resumes at the freshness gate, now the oldest untouched item in this
chain: `it_controls.status` is a cache with no staleness concept, so the board
can render an evaluation from any point in the past as current. Behind it sit
axis lists for the other four checkers, `tf_grant_tier_audit`,
`tf_function_safety_audit`, `tf_guard_detection_audit` and
`tf_automation_note_drift`, none of which publish a machine-readable `axes` array
and none of which can therefore be coverage-checked; and an event trigger on
`ddl_command_end` to make obligation two structural rather than detected. Behind
all of it sits ClickUp `86bb3etah`, the deployment-coordination decision, which
pass 9 named the largest unmitigated governance risk in the backend and which
passes 10 and 11 have both left untouched.

**Pass 12, 2026-07-25, at migration 290.** Pass 11 resumed the sweep at the
freshness gate, the oldest untouched item in the chain. Pass 12 built it, and in
doing so found a strictly more serious defect the gate had not been designed to
look for. Ordinals 288 through 290 are contiguous with no concurrent-agent
interleave.

| Claim carried into this pass | What the catalog said | Resolution |
| --- | --- | --- |
| A row whose `last_evaluated_at` lags `max(last_evaluated_at)` is a row the evaluator did not score | it cannot be. `tf_controls_evaluate` writes every automated row in one `UPDATE` sharing one `v_now`, and its status CASE ends `else status end`, so an unscored row keeps its old status **and is stamped fresh anyway**. `count(distinct last_evaluated_at)` reads 1 across the whole board | the design was discarded before a line of it was written. `last_evaluated_at` is a **write** timestamp, not an evaluation timestamp, and a detector built on it would have reported zero forever over a population it never declared. Replaced with a reader that parses the evaluator's own `pg_get_functiondef`. **The write-timestamp trap** |
| Every automated control has a status branch, so the only question is whether the board is stale | the question was never whether a branch exists. `GV-CCM-016` had a branch, and the branch read `when 'GV-CCM-016' then 'passing'`. The control certifying continuous controls monitoring was a hardcoded constant that could not fail, carrying the timestamp of its own write as evidence | migration 289 added a second axis, `tautological_total`, matching branches against `^'(passing\|failing\|attention\|manual)'`. It named `GV-CCM-016` on its first run and correctly declined to name `AC-RLS-001` or `CM-SIGNALCOV-026`, both of which compute. **The tautological control**, convention 35 |
| Ship the detector and the fix together, it is one batch | shipping them together makes the finding indistinguishable from an author fixing something quietly while adding the check that would have caught it | migration 289 shipped the detector and **left `GV-CCM-016` broken on purpose**, so the history records the machine finding it. Migration 290 fixed it. The cost is one migration where the board reads `authoritative: false`; the value is that the finding is evidence rather than assertion |
| The freshness control can read the board wherever it is convenient in the evaluator | read after the `UPDATE` and it scores its own write. `board_age_hours` would read 0.00 on every run forever, and nothing about that output looks anomalous | the `tf_controls_board()` call was hoisted into the evaluator's opening statements, before anything is stamped, and the `CM-BOARDFRESH-027` evidence string ends *"Age is measured before this run stamps the board"* so the ordering is verifiable without the source. **The self-stamping signal**, house rule eighteen |
| Patching `tf_controls_evaluate` textually is routine, the idiom is established | the deployed body is 17103 characters and five separate splices were needed. A `replace` whose anchor matches zero places is a silent no-op; one that matches twice commits both | every anchor was asserted to occur **exactly once** first, via `(length(v_new) - length(replace(v_new, a, ''))) / length(a)`, refusing the whole migration otherwise. Before writing the anchors, the exact bytes were read with `encode(convert_to(substring(...), 'UTF8'), 'escape')`, confirming eight spaces between `'GV-CCM-016'` and `then`. **The asserted textual splice** |
| Replacing the evaluator risks reopening the creation exposure window | `CREATE OR REPLACE` preserves the ACL, as asserted live in migration 287 | relied on again rather than re-derived. House rule fifteen governs creates, not replaces, and `tf_controls_board` itself, a genuine create, took its grant tier in the same migration per convention 33 |

| Verified at the start of this pass | Verified at the end | What was re-read |
| --- | --- | --- |
| Migrations 287, conventions 33, house rules 17, controls 26, axes 6 | 290 / 36 / 18 / 27 / 6 | inventory, conventions register, house rules, defect-pattern library, symptoms table, open register, `IT_GOVERNANCE_GRC.md`, `LEAST_PRIVILEGE_TABLE_GRANTS.md`, `MIGRATIONS_INDEX.md`, and a new `CONTROL_BOARD_FRESHNESS.md` |

Live state at 15:54Z. `tf_controls_evaluate()`: 27 controls, 24 passing,
**0 failing**, 3 attention, 21 automated, 6 manual and all 6 never attested.
`tf_controls_board()`: `ok true`, `authoritative true`, `fresh true`,
`board_age_hours 0.01` against `threshold_hours 792`, `automated_total 21`,
`scored_total 21`, `unscored_total 0`, `tautological_total 0`,
`controls_total 27`, `manual_total 6`, `distinct_stamps 1`, `stamp_uniform true`,
`status_case_length 3217`, `evaluator_def_length 19742`.
`tf_controls_signal_coverage()`: `ok true`, `gap_total 0`, `unread_total 0`,
`declared_axes 6`, `refusal_flag_honoured true`.
`tf_grant_tier_audit()`: `ok true`, 100 pct coverage, `declared_total 95`,
`tf_population_total 94`, `tf_covered_total 94`, zero violations, zero missing,
zero uncovered, zero drift. `tf_function_safety_audit()`: `undeclared_total 0`,
`drift_total 0`. `tf_security_scan()`: `ok true`, `gap_total 2` over 174 tables.

Live evidence strings, quoted because they are the audit artifact:
`GV-CCM-016` reads *"tf-controls-evaluate-monthly scheduled and active
(0 14 1 * *); last run stamped 2026-07-25 15:54 UTC"*. `CM-BOARDFRESH-027` reads
*"board was 0.42h old entering this run against a 792h threshold from
tf-controls-evaluate-monthly (0 14 1 * *); 0 automated control(s) with no status
branch [] and 0 branch(es) asserting a status literal []. Age is measured before
this run stamps the board"*.

Three results from this pass are worth carrying forward.

The first is that **a register of judgements is a cache, and a cache with no date
on it is not evidence**. Every control on this board could read `passing` against
an evaluation that last ran in March, and until migration 288 nothing on the
platform could tell. The fix is not a bigger checker, it is publishing the age
beside the verdict, against a threshold derived from the cadence that is supposed
to refresh it, so the freshness claim is falsifiable.

The second is that **the detector and the thing it detects must not be the same
event**. The freshness reading had to be hoisted above the write it measures, and
the tautology detector had to parse the evaluator's catalog text rather than ask
the evaluator how it was doing. Both are instances of the migration 276 rule that
agreement between a checker and something it wrote is not corroboration, now
extended from registers to timestamps and to a function's own self-report.

The third is that **presence was never the property worth checking**. Three
passes have now found the same shape wearing different clothes: a register row
that existed and was seeded by its own reader, an axis that existed and nothing
consumed, a status branch that existed and asserted a constant. In each case the
thing was there. Checking that it was there is what let it stay wrong. The
question to ask of any mechanism is not whether it is present but whether it can
produce an answer other than the one it is producing.

The sweep resumes at the checkers that publish no machine-readable `axes` array.
None of them can be coverage-checked, so convention 31 holds over one checker out
of a population this document could not state, and that limit is not published
anywhere the board can see it. Behind that sits obligation two of convention 33,
which is detected after the fact rather than enforced, and which an event trigger
on `ddl_command_end` would make structural. Behind all of it, still, sits ClickUp
`86bb3etah`, the deployment-coordination decision, which passes 9 through 12 have
now named the largest unmitigated governance risk in the backend four consecutive
times without reducing it.

**Pass 13, 2026-07-25, at migration 306.** Pass 12 closed by naming four checkers
that could not be coverage-checked and estimating convention 31's reach at one
checker in five. Pass 13 built the declaration mechanism that closes that gap, and
the first thing the mechanism did was prove the estimate wrong in the direction
that matters. **It was one in ten, not one in five.**

The batch is sixteen migrations, 291 through 306, and it converts convention 31
from a property proved over a sample into a property enforced over a stated
population. Every checker now declares its own axes. The coverage detector, which
previously inspected one checker's payload keys, now verifies ten checkers'
declarations against the evaluator's catalog text. Live: ten checkers,
twenty-four axes, zero unread, zero undeclared, zero unmeasured, zero unrostered
callees, zero refusal-ungated. `CM-SIGNALCOV-026` publishes all of those numbers
so a reader can tell ten-of-ten from one-of-one without leaving the register.

Four findings are worth carrying forward.

The first is that **the roster was wrong when this pass inherited it, and the only
thing that caught it was refusing to trust the classification**. Documentation
said eight checkers. Reading `tf_controls_evaluate`'s actual use of `v_board`
showed two `coalesce((v_board->>'...')::int,0)` reads driving
`CM-BOARDFRESH-027`, which means `tf_controls_board` had been a checker since
migration 288 and had never declared an axis. Writing the roster from the
inherited list would have certified one hundred percent coverage over a
population narrowed by two, in the same migration that introduced the denominator
convention was supposed to protect. **Whether a function is a checker is not a
property of its name.** It is house rule nineteen now, and its structural half,
roster closure derived from the consumer rather than asserted about it, is what
stops the same drift recurring silently.

The second is that **the population-versus-finding distinction is not a
refinement of coverage measurement, it is the reason coverage measurement has to
be declarative at all**. An inspecting detector demands a consumer for
`enabled_total`, which is a denominator. Nobody should ever write that control.
The coverage number therefore cannot reach its target honestly, and the pressure
is toward writing a dishonest one. Every metric that cannot be satisfied without
inventing something is generating that pressure, and the fix is never to relax the
metric.

The third is that **the swallowed refusal is a different class of defect from
everything in the previous twelve passes**. Every earlier finding produced a wrong
number that a careful reader could interrogate: a zero from a scan looking for a
word, an age of zero from a self-stamping read, a branch asserting a literal. Each
of them, once seen, is obviously suspicious. `exception when others then v_gap :=
0` produces a number that is correct-looking, plausible, and identical to the
output of a healthy system. It is now house rule twenty, and it is the only rule
in the collection enforced by a pre-install regex rather than a post-hoc detector,
because the window between introducing it and noticing it has no upper bound.

The fourth is that **presence was never the property worth checking, for the
fourth pass running, and this time the mechanism whose presence was mistaken for
its property was an assertion**. `tf_automation_note_drift`'s classification sweep
matched `%_total` against a payload whose only counter is `drift_count`. The
assertion ran, examined zero keys, and passed, on every run. An assertion that
cannot fail is not an assertion. The question to ask of a check is not whether it
passed but how many things it looked at.

The sweep resumes at obligation two of convention 33. It is now the oldest
structural gap in the chain and the cheapest to close: nothing prevents a
migration creating a `tf_*` function without a `tf_function_registry` row, and an
event trigger on `ddl_command_end` would make it impossible rather than merely
detectable. Behind that, the `supabase_admin` default-ACL residual, whose symptom
migration 283 monitors and whose mechanism is untouched. Behind all of it, for the
fifth consecutive pass, ClickUp `86bb3etah`, the deployment-coordination decision.
Two agents can still write DDL to this production schema with no coordination
primitive between them. Five passes have named it the largest unmitigated
governance risk in the backend. Naming it a sixth time is not a plan.
**Recommendation stands: advisory lock, deploy log, `CM-DEPLOY` control.**

**Pass 14, 2026-07-25, at migration 309.** Pass 13 closed by naming obligation two
of convention 33 as the oldest structural gap in the chain and the cheapest to
close. Pass 14 closed it. Three migrations, 307 through 309, contiguous, no
concurrent-agent interleave. The register moved from 27 controls to **28: 25
passing, 3 attention, 0 failing**, and `CM-FNDECL-028` is the first row on this
board that certifies an impossibility rather than an observation.

| Claim carried into this pass | What the catalog said | Resolution |
| --- | --- | --- |
| Put an event trigger on `ddl_command_end` that raises when a new `tf_*` function has no registry row, forcing the author to declare first | it cannot work. `tf_function_registry_validate` raises `check_violation` for a row whose function does not exist yet, so the declaration cannot precede the creation. The guard would require an ordering the register forbids, and no valid migration exists | the design was discarded before a line of it was written, on the strength of one `pg_get_functiondef`. Enforcement moved to the transaction boundary: the event trigger only enqueues, and a `DEFERRABLE INITIALLY DEFERRED` constraint trigger refuses at `COMMIT`. **House rule twenty-one**, convention 42 |
| "In the same migration" is a documentation phrase, not a testable condition | a migration is a transaction. A probe that created `public.tf_txn_probe` and then raised left no table and did not increment `supabase_migrations.schema_migrations`, which still read 306 | `apply_migration` is **transactional**, so "the same migration" is exactly "the same transaction" and is enforceable at commit. A failed migration writes no version row and can be re-submitted unchanged. This also retroactively confirms every end-of-migration assertion block in this repository is a genuine pre-commit gate |
| `postgres` has `rolsuper = false`, so event triggers are not available on this project | they are. A probe created one and then raised a deliberate message; it returned the message, not a permission error. The pre-existing `ensure_rls` trigger is also `postgres`-owned | the lever exists and was verified before the design depended on it, rather than after |
| Deleting the queue row would bypass the deferred check | it does not. The check is already scheduled against that row and re-reads `tf_function_registry`, never the queue | the queue is a scheduling mechanism, not a source of truth. Fail-closed by construction |
| The guard is either correct or it is not, and the migration committing is evidence enough | a guard that refuses everything and a guard that refuses nothing both let a well-formed migration through, and only one of them is correct | three probes, each self-aborting. **Negative**: an undeclared function returned `ERROR 23514` with the full hint. **Positive**: a declared function returned "declaration accepted, pending queue holds 1 row(s) mid-transaction". **Falsifiability**: disabling the event trigger drove `CM-FNDECL-028` to `failing` and re-enabling it drove it back to `passing`, inside one transaction |
| A new table added by a hardening migration is not a scan finding | it is. `tf_declaration_pending` acquired RLS automatically from the `ensure_rls` event trigger and has zero policies, so `rls_enabled_no_policy` moved 1 to 2 and `gap_total` 2 to 3 | published, not exempted. `rls_enabled_no_policy_reachable` remains **0**, which is the number `AC-RLS-001` weighs, so no control changed status. An exemption over a table no role can reach suppresses nothing today and hides the finding the day it is granted, per migration 282 |

| Verified at the start of this pass | Verified at the end | What was re-read |
| --- | --- | --- |
| Migrations 306, conventions 41, house rules 20, controls 27, checkers 10, axes 24 | 309 / 43 / 21 / 28 / 11 / 25 | inventory, conventions register, house rules, defect-pattern library, open register, `IT_GOVERNANCE_GRC.md`, `CHECKER_AXIS_DECLARATION.md`, `CONTROL_SIGNAL_COVERAGE.md`, `CONTROL_BOARD_FRESHNESS.md`, `README.md`, `MIGRATIONS_INDEX.md`, and a new `DECLARATION_ENFORCEMENT.md` |

Live state at 17:11Z. `tf_controls_evaluate()`: 28 controls, 25 passing,
**0 failing**, 3 attention, 22 automated, 6 manual and all 6 never attested.
`tf_declaration_enforcement_audit()`: `ok true`, `enforcement_gap_total 0`,
`enforcement_missing_total 0`, `enforcement_disabled_total 0`,
`pending_residue_total 0`, `unregistered_function_total 0`,
`event_trigger_state "origin"`, `tf_function_total 97`, `registry_row_total 97`.
`tf_controls_signal_coverage()`: `ok true`, `gap_total 0`, `checkers_total 11`,
`declaring_checker_total 11`, `axes_total 25`, all five primitives 0 and all five
offender arrays empty. `tf_controls_board()`: `ok true`, `authoritative true`,
`fresh true`, `board_age_hours 0.08` against `threshold_hours 792`,
`controls_total 28`, `automated_total 22`, `scored_total 22`, `unscored_total 0`,
`tautological_total 0`, `status_case_length 3425`,
`evaluator_def_length 22871`. `tf_security_scan()`: `ok true`,
`integrity_total 0`, `gap_total 3` over 175 tables and 123 definer functions,
`rls_enabled_no_policy 2`, `rls_enabled_no_policy_reachable 0`.

Live evidence string, quoted because it is the audit artifact. `CM-FNDECL-028`
reads *"event trigger tf_require_function_declaration is origin; 0 of 97
public.tf_* function(s) undeclared []; queue residue 0, enforcement missing 0,
disabled 0. Enforced at COMMIT by the deferred check, not at CREATE."*

Three results from this pass are worth carrying forward.

The first is that **detected and enforced are not the same guarantee, and the
difference is measured in time**. A detected obligation is satisfied on the
auditor's schedule. This one ran monthly, so an undeclared function could sit in
the inventory for up to a month while the read/write classification, the safety
audit and the function count were all quietly wrong. An enforced obligation is
satisfied on the author's schedule, because the author cannot proceed until it is.
Every remaining "detected after the fact" in this document should be read as a
window with a width, and the width is the cadence of whatever notices.

The second is that **the catalog disproved the design for the third pass
running**. Migration 288's freshness detector died on the write-timestamp trap.
Migration 304's roster died on the inherited eight-checker classification. This
pass's statement-level guard died on `tf_function_registry_validate`. In all three
cases the disproof was one query against `pg_get_functiondef` or `pg_proc`, and in
all three cases the design that would have shipped looked correct. The habit that
keeps paying is reading the mechanism you are about to build on top of, before
building on top of it, rather than reading the documentation that describes it.

The third is that **an impossibility still needs a monitor, because every
impossibility has an off switch**. `ALTER EVENT TRIGGER ... DISABLE` is one
statement. Making it owner-only and auditable is necessary and not sufficient, so
the enforcement's own presence and enabled state are published as two separate
gating axes, and the control was proved falsifiable by actually turning the guard
off and watching the board go red. A guard whose absence is undetectable is a
guard with an expiry date nobody reads. That is convention 43.

The sweep resumes at **obligation three of convention 33**, now the oldest
structural gap in the chain: a migration can create a checker and never wire its
signal into a control, and `tf_controls_signal_coverage` finds it afterwards
rather than the creation being refused. It is harder than obligation two, and the
reason is worth stating so the next pass does not underestimate it. "Wire its
signal into a control" has no single catalog fact to test at commit time, because
a new function is not necessarily a checker and whether it is one is a property of
whether a consumer reads a counter out of it, which is house rule nineteen.
Enforcing it at commit would require the migration to declare its own intent, and
a self-declared intent an author can set to "not a checker" is an exemption lever
of exactly the kind migration 265 spent a batch closing. The design work is real.

Behind that, the `supabase_admin` default-ACL residual, whose symptom migration
283 monitors and whose mechanism is untouched. Behind all of it, for the **sixth**
consecutive pass, ClickUp `86bb3etah`, the deployment-coordination decision. Two
agents can still write DDL to this production schema with no coordination
primitive between them. Six passes have named it the largest unmitigated
governance risk in the backend. It is now the only item in this chain that has
been carried without progress longer than obligation two was, and obligation two
took three migrations to close. **Recommendation stands and should be executed
next unless something louder arrives: advisory lock, deploy log, `CM-DEPLOY`
control.**

**Pass 15, 2026-07-25, at migration 315.** Six consecutive passes named
deployment coordination the largest unmitigated governance risk in this backend
and recommended the same three things. Pass 15 built them. Six migrations, 310
through 315. The register moved from 28 controls to **29: 26 passing, 3 attention,
0 failing**, and `CM-DEPLOY-029` is the first control on this board whose gating
signal is computed from a **recorded history** rather than from present catalog
state.

| Claim carried into this pass | What the catalog said | Resolution |
| --- | --- | --- |
| The risk is that two agents interleave DDL | the risk is wider and the narrow framing was hiding half of it. Five channels can write DDL to this project: these MCP tools, the Supabase dashboard SQL editor, a direct `psql` session, CI, and a second agent. None was serialized, and, worse, none was recorded | prevention and measurement were built as two separable triggers rather than one. `tf_serialize_deploy_ddl` on `ddl_command_start` refuses; `tf_deploy_ddl_log` on `ddl_command_end` records. An interleave that corrupted state would previously have left nothing to reconstruct from |
| An interleave can be induced by issuing two DDL statements in one tool block | it cannot, and the measurement says so precisely. The lock holder held from `17:30:15.913915` to `17:30:45.942967`; the "concurrent" statement landed at `17:30:46.582`, **0.64 s after release**, with `inside_holder_window = false`. The MCP channel serializes calls before they reach Postgres | this agent structurally cannot falsify its own lock through its own tools. That is a property of the harness, not of the guard, and it is why the proof needed a backend this agent does not own |
| `dblink` will supply the second backend | it will not. `dblink` appears in `pg_available_extensions` and not in `pg_extension`, and `postgres` has `rolsuper = false`, so a passwordless loopback connection is impossible | `pg_cron` supplied it. `cron.schedule('tf-deploy-lock-probe', '30 seconds', ...)` produced a genuine second backend with `application_name = 'pg_cron'`, and the `55P03` refusal was captured verbatim with its DETAIL, HINT and CONTEXT lines |
| Timestamp the deploy log with `now()` like every other table | `now()` is transaction-fixed. Every command in one migration would carry an identical stamp, every span would have zero width, and no two spans could ever overlap | `clock_timestamp()`. Had this shipped as `now()`, `interleaved_deploy_total` would have read 0 for **every possible input**, which is house rule twenty in a new costume: a checker that cannot fail, publishing the output of a healthy system |
| The migration that installs the logger will demonstrate the logger | attempt 1 failed on exactly this: the `COMMENT` intended as the probe ran **before** the event triggers existed, so it logged nothing and the self-check refused | the `COMMENT` moved to the end. `ddl_command_end` fires for `COMMENT`, which makes a trailing comment the cheapest possible self-proving probe, and the migration that installs a logger now proves the logger inside itself |
| The register was green before this batch, so a new control can be wired against a clean baseline | it was not green. The baseline guard read **stored** statuses, which had not been re-scored since migration 309, and `tf_controls_evaluate()` immediately surfaced `CM-FNDRIFT-018 => failing :: 1 unreconciled register entr(ies)` | migration 310 had declared `tf_ddl_serialize` as `write` when its body only takes a lock and raises. The control wiring was split out to 315 and 314 reconciled the declaration first. **House rule twenty-two** |
| The drift can be resolved by teaching the audit that a lock acquisition is a write | it can, and that is the trap. The declaration would become true and the detector would become weaker, and every future function whose only effect is a lock would be silently reclassified | convention 21, decompose never narrow. The declaration changed, the detector did not. The registry rationale now records that the write effect is on lock state, which is a fact about the mechanism rather than an exemption from the instrument |

| Verified at the start of this pass | Verified at the end | What was re-read |
| --- | --- | --- |
| Migrations 309, conventions 43, house rules 21, controls 28, checkers 11, axes 25 | 315 / 43 / 22 / 29 / 12 / 26 | inventory, conventions register, house rules, defect-pattern library, open register, `IT_GOVERNANCE_GRC.md`, `DECLARATION_ENFORCEMENT.md`, `CHECKER_AXIS_DECLARATION.md`, `CONTROL_SIGNAL_COVERAGE.md`, `MIGRATIONS_INDEX.md`, and a new `DEPLOY_COORDINATION.md` |

Live state at 17:47Z, every figure read back out of the database rather than
inferred from the migration assertions. `tf_controls_evaluate()`: 29 controls,
26 passing, **0 failing**, 3 attention, 23 automated, 6 manual and all 6 never
attested. `tf_controls_signal_coverage()`: `ok true`, `gap_total 0`,
`checkers_total 12`, `declaring_checker_total 12`, `axes_total 26`, all five
primitives 0 and all five offender arrays empty. `tf_controls_board()`: `ok true`,
`authoritative true`, `unscored_total 0`, `tautological_total 0`,
`board_age_hours 0.00`. `tf_security_scan()`: `ok true`, `integrity_total 0`,
`unguarded 0`, `rls_enabled_no_policy 2`, `rls_enabled_no_policy_reachable 0`.
`tf_function_safety_audit()`: `drift_total 0`, `undeclared_total 0`,
`gap_total 0`.

Live evidence string, quoted because it is the audit artifact. `CM-DEPLOY-029`
reads *"passing :: lock trigger tf_serialize_deploy_ddl is origin and log trigger
tf_deploy_ddl_log is origin; 0 interleaved deploy pair(s) [] across a population
of 12 DDL transaction(s) on 12 backend(s), 41 logged command(s) since
2026-07-25T17:27:59.960192+00:00. The interleave axis is measured from recorded
command spans, not from the trigger catalog, so it is the axis that can contradict
the other four"*.

Three results from this pass are worth carrying forward.

The first is that **a control's most valuable axis is the one that can contradict
the rest of it**. Four of `CM-DEPLOY-029`'s five axes read the catalog and answer
"is the mechanism installed". The fifth reads the log and answers "did it work".
A control built only from the first kind certifies its own installation, which is
the seeded-register defect of migration 276 wearing different clothes. Every
checker on this roster should be asked which of its axes could return a finding on
a day when everything it inspects is correctly configured. If the answer is none,
the checker is an inventory.

The second is that **the harness is part of the threat model, in both directions**.
This agent cannot interleave DDL through MCP, which sounds reassuring and is
actually the problem: it meant the guard could not be falsified from inside, and
an unfalsifiable guard is indistinguishable from a guard that refuses nothing.
Finding a backend outside the harness, `pg_cron`, was the whole proof. The general
form is that when a tool cannot produce the failure a control detects, the
control's evidence is untested until something outside the tool produces it.

The third is that **a green board has an age, and the age is the finding**. House
rule seventeen made migrations that touch the register assert its aggregate state.
This pass showed the same hole one level upstream: migrations 310 through 313
touched the register's *inputs* and left the cached statuses untouched, so the
board read clean over a live drift for fifteen minutes and four migrations. The
correct reflex is that anything which could change what a checker computes must
re-run the checker before it commits. That is house rule twenty-two, and the
sentence to remember is that a stale green is worse than a red, because nobody
investigates a green.

The sweep resumes at **obligation three of convention 33**, unchanged from Pass 14
and now the oldest structural gap in the chain by a clear margin: a migration can
create a checker and never wire its signal into a control. The design difficulty
is unchanged, that "wire its signal into a control" has no single catalog fact
testable at `COMMIT` and self-declared intent would be an exemption lever of the
kind migration 265 spent a batch closing. Behind that, the `supabase_admin`
default-ACL residual, whose symptom migration 283 monitors and whose mechanism is
untouched. Behind that, and new to this list, `tf_deploy_log` has **no retention
policy**: it grows unbounded, one row per DDL command, and the overlap query is
O(n^2) in the window it scans. Neither matters at 41 rows. Both matter at a
million. The deployment-coordination item that headed this list for six passes is
closed.

**Pass 16, 2026-07-25, at migration 320.** Two consecutive passes named
obligation three of convention 33 the oldest structural gap in the chain and both
declined to close it, on a stated design argument. Pass 16 read the argument
again and found it half right. The register moved from 29 controls to **30: 27
passing, 3 attention, 0 failing**, and `CM-SIGWIRE-030` closes the last of the
three obligations. Every obligation this platform places on the act of creating a
`public.tf_*` function is now structural.

| Claim carried into this pass | What the catalog said | Resolution |
| --- | --- | --- |
| Obligation three is unenforceable because "wire its signal into a control" has no single catalog fact testable at `COMMIT` | the premise is **true** and the conclusion does not follow. There is no single fact and there are three: a key in `tf_controls_signal_roster()`, a `public.<proname>()` call inside `pg_get_functiondef(tf_controls_evaluate)`, and an `it_controls` row whose `signal` names the proname. All three are catalog facts readable at `COMMIT` | a conjunction is as testable as a singleton. Migration 318 tests all three at the transaction boundary and names each unmet one separately in the refusal. **Two passes were spent not closing a gap because the word "single" was doing unexamined work in a sentence** |
| Enforcing it would need a self-declared intent flag, which is an exemption lever of the kind migration 265 closed | it would not. `prokind` and `pg_get_functiondef` already answer the question. A **checker** is a `public.tf_*` function of `prokind = 'f'` whose definition text contains the literal `'axes',` | migration 317 makes that the definition. Publishing an axes key *is* the declaration, so there is no separate claim to falsify and no flag to set wrongly. The objection was correct and was answered rather than waived. The literal carries the trailing comma so the match pins to a `jsonb_build_object` key position, not to prose |
| The consumer-read test decides what a checker is, per the migration 304 finding | it decides whether a **known** function belongs on the roster, and it is circular as an enforcement predicate. A brand-new function nobody reads yet fails it by construction, so a gate built on it would refuse every checker at birth | the two definitions compose rather than compete. Consumer-read measures whether a rostered checker is genuinely wired; the catalog definition decides whether an arbitrary new function is subject to the obligation at all |
| The coverage checker sees every unwired checker | it sees none of them. All five of its components are measured from the roster or from the consumer, so each can only see a checker already wired somewhere. A function publishing axes, on no roster, called by nobody, is invisible to all five | migration 317 adds `orphan_checker_total`, measured from function text, with `axes_publishing_function_total` as its population. A roster of 13 against a population of 13 is clean; a roster of 13 against a population of 19 is a roster that stopped being maintained, and before 317 the two produced identical output |
| The pending-queue residue axis is correct as shipped in 308 | it published the **raw** row count. House rule twenty-two forced a mid-transaction re-evaluation, and a queue row for a function already declared in the same transaction counted as debt | migration 316: residue is the **unmet subset**, the raw count is republished as non-gating population. Gating on population fails a control for the ordinary create-then-wire window, which is convention 37 in a new costume |
| Seed the new control with `status = 'pending'` until the evaluator scores it | `it_controls_status_check` allows exactly `passing`, `attention`, `failing`, `manual`. Verified verbatim from `pg_get_constraintdef`. Attempt 1 died on `23514` | seeded `attention`, on the reasoning that an automated control never evaluated is **unmeasured**, not clean. `tf_controls_evaluate()` promoted it to `passing` in the same transaction and the migration's own assertion verified the promotion |
| Read the register summary out of `tf_controls_board()` | it has **no `summary` key**. The read returns SQL `NULL` and a defensive `coalesce` turns that into whatever default was supplied | the summary is the **return value of `tf_controls_evaluate()`**. Generalised: **in an assertion, the safe default for a `coalesce` is the FAILING value, never the passing one** |
| The migration's assertion block gates the commit | one branch of it did not. `coaleske_placeholder`, a misspelled identifier inside a `raise exception` that only fires when `enforcement_gap_total <> 0`, committed clean because **plpgsql does not resolve identifiers inside a branch it never executes** | **house rule twenty-three**. The live schema is unaffected, since no database object carries the text; the immutable migration-history row does. The checked-in file carries the correction plus an inline divergence comment. It opened the `plpgsql_check` workstream |

| Verified at the start of this pass | Verified at the end | What was re-read |
| --- | --- | --- |
| Migrations 315, conventions 43, house rules 22, controls 29, checkers 12, axes 26 | 320 / 43 / 23 / 30 / 13 / 27 | inventory, conventions register, house rules, defect-pattern library, open register, `IT_GOVERNANCE_GRC.md`, `DECLARATION_ENFORCEMENT.md`, `CHECKER_AXIS_DECLARATION.md`, `CONTROL_SIGNAL_COVERAGE.md`, `DEPLOY_COORDINATION.md`, `MIGRATIONS_INDEX.md`, and a new `SIGNAL_WIRING_ENFORCEMENT.md` |

Live state at 18:45Z, every figure read back out of the database rather than
inferred from the migration assertions. `tf_controls_evaluate()`: 30 controls, 27
passing, **0 failing**, 3 attention, 24 automated, 6 manual and all 6 never
attested. `tf_controls_signal_coverage()`: `ok true`, `gap_total 0`,
`checkers_total 13`, `declaring_checker_total 13`, `axes_total 27`,
`axes_publishing_function_total 13`, all six primitives 0 and all six offender
arrays empty. `tf_signal_wiring_enforcement_audit()`: `ok true`,
`wiring_gap_total 0`, `event_trigger_state origin`, `deferred_check_state
deferred`, `checker_population_total 13`, `unwired_checker_total 0`,
`wiring_residue_total 0`, `wiring_queue_total 0`.
`tf_declaration_enforcement_audit()`: `ok true`, `enforcement_gap_total 0`,
`tf_function_total 104`, `registry_row_total 104`. `tf_controls_board()`:
`ok true`, `authoritative true`, `unscored_total 0`, `tautological_total 0`.

Four results from this pass are worth carrying forward.

The first is that **a design argument is a claim and ages like one**. The sentence
that kept obligation three open for two passes was written once, was true when
written, and was re-quoted rather than re-tested in every pass that followed. Its
load-bearing word was "single", and nobody looked at it. A carried-forward reason
for not doing something should be re-derived, not re-read, and the cheapest way to
re-derive it is to ask what the sentence would look like if its strongest word
were deleted. "Wire its signal into a control has no catalog fact testable at
commit time" is obviously false, and that is one word away from what the document
said.

The second is that **an objection can be correct and still not be a blocker**. The
exemption-lever concern was right: a self-declared "this is not a checker" flag
would have reproduced exactly the defect migration 265 spent a batch closing. The
error was treating a valid objection to one implementation as a proof about the
whole problem. The fix was to find a definition the author cannot lie about,
which took one `pg_proc` query. Objections narrow the design space. They do not
close it, and the difference is worth an hour of trying before it is worth a
paragraph of explaining.

The third is that **every component measured from a register is blind in the same
direction**. Five coverage primitives, five different questions, one shared
premise: the thing being measured is already on the list. Nothing on the list can
tell you what is missing from the list. `orphan_checker_total` had to be measured
from function text for the same reason `interleaved_deploy_total` had to be
measured from recorded spans and `tf_function_safety_audit` had to compute kind
rather than read `declared_kind`. **Ask of every checker on this roster: what is
its denominator, and where did the denominator come from?** If the answer is a
register the same subsystem maintains, the checker certifies its own bookkeeping.

The fourth is house rule twenty-three, and it is the most uncomfortable finding on
this platform to date. **Every refusal in this repository is a branch that has
never run.** That is what a refusal is for. It means the whole population of
failure paths across three hundred and twenty migrations is code written once,
never executed, and believed correct because the thing it guards kept passing. One
of them was a typo away from being a `42703` instead of a gate, and it shipped,
and the board stayed green. The observed-refusal proof pattern answers this where
a refusal matters enough to induce deliberately, as migration 319 does. Static
analysis answers it everywhere else, and it is affordable: `plpgsql_check` 2.8 is
available on this project, resolves identifiers in unreachable branches, and scans
all 119 functions in **447 ms**.

The sweep resumes at **installing `plpgsql_check` and gating on it**. The scan
already run surfaced 5 errors, 67 warnings and 263 other findings. Triaged, the
five errors are: two runtime temp tables (`_cust_fix` in `tf_link_revenue`,
`_merge_map` in `tf_merge_duplicate_customers`) which get plpgsql_check **pragmas
declaring their shape, not exemptions**, because an exemption is the lever
migration 265 had to close; two needing investigation (`current_user_role`
resolving relation `users`, `tf_cx_sequence_sweep` record `l`); and one that looks
like a genuine defect, `tf_guard_detection_audit` reporting "malformed array
literal: tf_guard_predicate_registry is empty", which reads as a scalar assigned
into a `text[]` on some branch. Behind that, the `supabase_admin` default-ACL
residual, whose symptom migration 283 monitors and whose mechanism is untouched,
and `tf_deploy_log`'s absent retention policy with its O(n^2) overlap query.

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
