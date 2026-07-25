# IT Governance, Risk & Compliance (GRC)

Continuous controls monitoring, access certification, and service objectives for
Transit & Flow, mapped to **NIST CSF**, **SOC 2**, and **CIS Controls v8**.

## Objects

| Object | Purpose |
|--------|---------|
| `it_controls` | Controls register (**30 controls** as of migration 320, 24 automated and 6 manual) with framework mapping, owner, status, evidence. Keyed by `control_key`, unique. `status` is constrained to exactly `passing`, `attention`, `failing`, `manual`; there is no `pending` |
| `tf_controls_evaluate()` | Re-scores automated controls from live signals (security scan, grant-tier audit, function-safety audit, guard-detection audit, signal coverage, board freshness, declaration enforcement, cron presence, MFA gaps, data-quality). Takes **no arguments** |
| `tf_signal_wiring_enforcement_audit()` | Reports whether the `tf_require_signal_wiring` event trigger and the `tf_signal_wiring_pending_deferred_check` constraint trigger both exist, are enabled and are correctly timed, whether the wiring queue holds unmet residue, and whether any checker in the schema is unwired. Folds all five into `wiring_gap_total`. Added migration 320, read by `CM-SIGWIRE-030` since 320 |
| `tf_signal_wiring_pending` | Transient queue. Holds a row only between the creation of an unwired checker and the commit of the transaction that created it. Empty outside a transaction by construction |
| `tf_controls_signal_roster()` | The single home of the checker roster, thirteen entries as of migration 320, each mapping a checker's `proname` to the evaluator variable names its axes are read through. Given its single home by migration 317 so that the coverage checker and the wiring checker read the same list |
| `tf_controls_signal_coverage()` | Verifies, for a declared roster of thirteen checkers, that each one declares its axes, that every declared axis is read by `tf_controls_evaluate` via the strict counter-read needle, that every `tf_*` callee of the evaluator is on the roster, and that every checker's refusal flag is honoured. Added migration 285 over one checker, generalised to the full roster by migration 304, read by `CM-SIGNALCOV-026` since 287 |
| `tf_controls_board()` | Publishes the age of the register, names every automated control the evaluator has no status branch for, and names every branch that asserts a status literal instead of computing one. Folds all three into `authoritative`. Added migration 288, extended 289, read by `CM-BOARDFRESH-027` since 290 |
| `tf_declaration_enforcement_audit()` | Reports whether the `tf_require_function_declaration` event trigger exists and is enabled, whether the pending queue holds residue, and whether any `public.tf_*` function lacks a `tf_function_registry` row. Folds all four into `enforcement_gap_total`. Added migration 308, read by `CM-FNDECL-028` since 309 |
| `tf_deploy_coordination_audit()` | Reports whether the `tf_serialize_deploy_ddl` lock trigger and the `tf_deploy_ddl_log` logging trigger both exist and are enabled, and counts DDL transactions whose recorded command spans overlap another transaction's. Folds the four catalog axes into `coordination_gap_total` and publishes `interleaved_deploy_total` separately. Added migration 313, read by `CM-DEPLOY-029` since 315 |
| `tf_deploy_log` | Append-only record of every DDL command executed against this project: transaction id, backend pid, application name, command tag, object identity, and a `clock_timestamp()` stamp so spans have width. Written by the `tf_deploy_ddl_log` event trigger. Staff-readable under RLS |
| `tf_declaration_pending` | Transient queue. Holds a row only between the creation of an undeclared `public.tf_*` function and the commit of the transaction that created it. Empty outside a transaction by construction |
| `access_reviews` | Access certification snapshots with findings |
| `tf_access_review()` | Snapshots accounts/roles/MFA/last-sign-in; flags MFA gaps, stale, terminated-active, SoD |
| `service_slos` | SLO definitions (availability, security posture, integration reliability) |
| `tf_slo_report()` | Computes attainment + error-budget consumption from `system_health_checks` history |
| `tf_it_governance_report(boolean)` | Consolidated posture: controls + access + SLOs; optional Slack post |

## Cadence (pg_cron)

| Job | Schedule | Function |
|-----|----------|----------|
| `tf-controls-evaluate-monthly` | `0 14 1 * *` | `tf_controls_evaluate()` |
| `tf-access-review-quarterly` | `0 14 1 1,4,7,10 *` | `tf_access_review()` |
| `tf-governance-report-monthly` | `30 14 1 * *` | `tf_it_governance_report(true)` |

## Security

All GRC tables enforce RLS (internal-staff read; writes via SECURITY DEFINER
functions / service_role). All GRC functions are SECURITY DEFINER with pinned
`search_path` and are executable only by `service_role` (no anon, no
authenticated), except `tf_controls_signal_coverage()`, `tf_controls_board()`,
`tf_declaration_enforcement_audit()` and `tf_deploy_coordination_audit()`, which
are `staff` tier and each carry the `user_is_internal_staff` predicate in the
function body as that tier requires.

Post-deploy `tf_security_scan()` reads `ok: true`, `integrity_total: 0`,
`gap_total: 3` over a declared population of 176 tables and 126 definer
functions. The three are `anon_secdef_nonpublic: 1`, an intentional public surface
with a live exemption row, and `rls_enabled_no_policy: 2`, which is
`studio_events_prelaunch_archive` and `tf_declaration_pending`. Both tables have
RLS on, zero policies, and an ACL with no client-role grants at all, so no client
role can reach either. `tf_deploy_log`, added by migration 310, is deliberately
not a third: it was given `tf_deploy_log_staff_read` in the same migration that
created it, because `ensure_rls` enables RLS on every new table and a new table
with no policy is a new finding. The decomposed axis `rls_enabled_no_policy_reachable` reads
**0**, and that is the number `AC-RLS-001` weighs. Both numbers stay in the
control's evidence so the correction is auditable rather than silent.

`tf_declaration_pending` joined that axis in migration 307. It is the transient
queue behind declaration enforcement, RLS was enabled on it automatically by the
`ensure_rls` event trigger, and it was deliberately **not** given a suppressing
exemption. A standing exemption over a table no role can reach suppresses nothing
today and hides the finding on the day somebody grants it to `authenticated`,
which is the retired-exemption rule from migration 282.

## Current posture (2026-07-25, after migration 315)

`tf_controls_evaluate()` reads:

```json
{"total": 29, "manual": 0, "failing": 0, "passing": 26, "attention": 3,
 "automated": 23, "manual_controls": 6, "manual_never_attested": 6}
```

26 of 29 passing, **0 failing**, 3 in attention:

- `AC-PRIV-002` — 1 anon-exposed definer function, 0 without a pinned
  `search_path`. The exposed function is an intentional public surface carrying a
  declared exemption row that suppresses a real finding, per the migration 281
  and 282 rule that an exemption must suppress something.
- `AC-MFA-003` — 1 privileged account without MFA. Owner action.
- `DP-PITR-007` — manual. Enable Point-in-Time Recovery in Supabase under
  Database then Backups. Owner action.

The two owner actions flip to passing at the next automated evaluation once done.

**Six manual controls have never been attested.** Attestation is an owner
action, not an engineering one, and the register counts it rather than assuming
it.

## Controls added by migrations 284 through 287

| Key | Control | Signal | Status |
|-----|---------|--------|--------|
| `CM-TRUNCGRANT-024` | Privileges outside the RLS-evaluated set are not held by client roles | `tf_security_scan` `tables_truncatable_by_client` | passing |
| `CM-SCANINTEG-025` | The security scan vouches for its own population and its refusals are heard | `tf_security_scan` `integrity_total` + `stale_exemption_total` | passing |
| `CM-SIGNALCOV-026` | Every declared detection axis on the checker roster has a consumer that renders it | `tf_controls_signal_coverage` `gap_total` over a twelve-checker roster | passing |

All three are `automated`, owned by the `CISO` role, and mapped across SOC 2,
CIS v8 and NIST CSF. The framework mappings are stored on the row, not in this
document, so an auditor reads them from the register.

The important structural change in that batch is not the three rows. It is that
`tf_controls_evaluate` now honours `tf_security_scan`'s `ok` flag. That flag was
added in migration 280, **after** the migration 269 sweep that taught the other
consumers to stop reading past a refusal into a `coalesce(..., 0)`. Until
migration 284, three security controls would have rendered `passing` against a
scan that had declared itself untrustworthy.

Read [`CONTROL_SIGNAL_COVERAGE.md`](./CONTROL_SIGNAL_COVERAGE.md) for the
reasoning, the coverage checker, and the runbook.

## Controls added by migrations 288 through 290

| Key | Control | Signal | Status |
|-----|---------|--------|--------|
| `CM-BOARDFRESH-027` | The control board is fresh and every automated control is genuinely scored | `tf_controls_board` `authoritative` | passing |

One row, but the batch that produced it changed what the register means.

Until migration 288 the board had no staleness concept. `it_controls.status` is
a cache of judgements, and a cache with no date on it renders an evaluation from
any point in the past as current. `tf_controls_board()` closes that: it reads
`max(last_evaluated_at)` across the automated rows, compares the age against a
792-hour threshold (the monthly cadence plus a two-day grace), and publishes
`board_age_hours` alongside the threshold so the number is falsifiable.

The first design for that detector was wrong and the catalog disproved it before
any code was written. The idea was that a row whose `last_evaluated_at` lags
`max(last_evaluated_at)` is a row the evaluator did not score. It cannot be.
`tf_controls_evaluate` writes every automated row in **one** `UPDATE` sharing one
`v_now`, and its status CASE ends in `else status end`, so a control with no
branch keeps its old status **and is still stamped fresh**.
`count(distinct last_evaluated_at)` reads **1** across the whole board. The
detector would have reported zero forever. That is exactly the undeclared
denominator the 280 through 287 chain exists to prevent, and it is why
`last_evaluated_at` is documented here as a **write** timestamp, not an
evaluation timestamp.

What replaced it parses the evaluator's own catalog definition. `unscored_total`
names automated controls the status CASE has no `when` branch for.
`tautological_total`, added in migration 289, names branches that **assert** a
status literal instead of computing one.

That second axis found a real defect on its first run. `GV-CCM-016`, the control
certifying continuous controls monitoring, read `when 'GV-CCM-016' then
'passing'`. A hardcoded constant that could never fail, carrying as evidence the
timestamp of its own write. The control asserting that monitoring works was the
one control not being monitored.

Migration 289 deliberately did **not** fix it. The detector was shipped first and
allowed to report the finding, so the history records it as something the machine
found rather than something the author fixed quietly while adding the check that
would have caught it. Migration 290 then fixed `GV-CCM-016` to compute from live
`cron.job` state and wired `CM-BOARDFRESH-027`.

One ordering trap is worth naming. A freshness control must read the board
**before** the evaluator's `UPDATE` runs, otherwise it scores its own write and
reads zero hours old every time. `tf_controls_evaluate` therefore calls
`tf_controls_board()` at the top of the function and holds the result, and the
control's evidence string ends with the words *"Age is measured before this run
stamps the board"* so a reader can tell.

Read [`CONTROL_BOARD_FRESHNESS.md`](./CONTROL_BOARD_FRESHNESS.md) for the full
narrative, the discarded design, the asserted-splice technique used to patch the
evaluator, and the refusal table.

## What migrations 291 through 306 changed about the register

No new control rows. Sixteen migrations, and the register still read 27 at the
close of that batch. What changed is what one of those rows is capable of
asserting.

`CM-SIGNALCOV-026` used to certify that six declared axes on one checker were
read. It now certifies four properties across the whole roster, **twelve checkers
and twenty-six axes** after migrations 309 and 315 extended it: that every rostered
checker declares its axes, that every declared axis is read by the evaluator into
an actual comparison, that every `tf_*` function the evaluator calls is on the
roster or on an explicit non-checker list, and that every checker's refusal flag
is honoured. Its title, description and signal string were rewritten in migration
306 so the register states the roster and the denominator rather than leaving both
implicit.

Live evidence:

> 11 of 11 rostered checker(s) declare axes; 25 axis(es) declared, 0 unread by
> this evaluator []; undeclared [], unmeasured [], unrostered callee(s) [],
> refusal-ungated []

Two findings from that batch bear directly on how this register should be read by
an auditor.

**The roster was inherited wrong and the correction happened before publication.**
Documentation claimed eight checkers. Reading the evaluator's actual use of
`v_board` showed two numeric reads driving `CM-BOARDFRESH-027`, which makes
`tf_controls_board` a checker that had never declared an axis, and the same test
showed the coverage detector is consumed via its own `gap_total`. Publishing the
inherited number would have certified one hundred percent coverage over a
population narrowed by two. **Whether a function is a checker is not a property of
its name. It is a property of whether the consumer reads a counter out of it**,
and roster membership is now derived from the consumer's catalog text rather than
maintained by hand.

**A control must never report clean because its checker could not run.** An
exception handler that defaults a gap counter to zero produces green output that
is indistinguishable from a healthy system. Zero is the passing branch, null is
the attention branch. `tf_data_quality_audit` now refuses by return value,
`tf_controls_evaluate` treats that refusal as **unmeasured** rather than clean,
and `tf_system_health` reports an unavailable probe as **degraded** rather than
operational. Every migration in the batch runs a pre-install regex guard refusing
any handler of that shape.

Read [`CHECKER_AXIS_DECLARATION.md`](./CHECKER_AXIS_DECLARATION.md) for the
roster table, the three couplings, the strict counter-read needle and the
runbook.

## Controls added by migrations 307 through 309

| Key | Control | Signal | Status |
|-----|---------|--------|--------|
| `CM-FNDECL-028` | Creating a tf_ function without declaring it is impossible, not merely detectable | `tf_declaration_enforcement_audit` `enforcement_gap_total` | passing |

One row, and it is the first control in this register that certifies an
**impossibility** rather than an observation.

Convention 33 requires three things in the migration that creates a `public.tf_*`
function: apply a grant tier, declare it in `tf_function_registry`, wire its
signal into a control. Only the first was structurally enforced. The second was
detected by `tf_function_safety_audit` `undeclared_total` and rendered by a
control that runs monthly, which means an undeclared function could sit in the
inventory for up to a month while everything downstream of the registry, the
read/write classification, the safety audit, the function count, was quietly
wrong.

Migration 307 makes it impossible. A `ddl_command_end` event trigger enqueues
every undeclared `tf_*` function into `tf_declaration_pending`, and a
`DEFERRABLE INITIALLY DEFERRED` constraint trigger fires at **COMMIT** and aborts
the transaction if the declaration is still absent.

The design is enforced at the transaction boundary rather than at
`CREATE FUNCTION` because the catalog rules the simpler design out.
`tf_function_registry_validate` raises `check_violation` for a row whose function
does not exist, so a declaration **cannot precede its function**, and there is no
statement ordering that satisfies both requirements at once. That disproof cost
one query. Shipping the naive design would have cost a migration that looked
correct and refused everything.

Two ground conditions were probed before any of it was built, because the design
depends on both: `apply_migration` is **transactional** (a deliberate abort left
no table behind and did not increment the migration count), and the `postgres`
role **can create event triggers** on this project despite `rolsuper = false`.

The control is falsifiable and was falsified on purpose. Inside one self-aborting
migration the event trigger was disabled, driving `enforcement_gap_total` to 1 and
`CM-FNDECL-028` to `failing`, then re-enabled, driving both back. The kill switch
is `ALTER EVENT TRIGGER ... DISABLE`, it requires ownership, and its use is itself
a monitored axis, so enforcement cannot be turned off quietly.

Read [`DECLARATION_ENFORCEMENT.md`](./DECLARATION_ENFORCEMENT.md) for the
discarded design, the queue-plus-deferred-trigger mechanism, the verbatim refusal
transcripts from all three probes, and the operator runbook.

## Controls added by migrations 310 through 315

| Key | Control | Signal | Status |
|-----|---------|--------|--------|
| `CM-DEPLOY-029` | Concurrent schema deployments are serialized and every DDL command is recorded | `tf_deploy_coordination_audit` `coordination_gap_total` | passing |

This closes the item six consecutive verification passes named as the largest
unmitigated governance risk in the backend. The risk was never that this agent
would collide with itself. It was that **more than one channel can write DDL to
this project**, the MCP tools, the Supabase dashboard SQL editor, a direct `psql`
session, CI, or a second agent, and nothing serialized them, and, worse, nothing
recorded them. An interleaved deploy that corrupted state would have left no
trace to reconstruct from.

The batch treats prevention and measurement as two separable things, because they
fail differently. Prevention is a `ddl_command_start` event trigger,
`tf_serialize_deploy_ddl`, which takes a bounded advisory transaction lock and
raises `55P03` naming the holding backend when another deploy has it. It is an
event trigger rather than a convention because a convention that says "take the
lock first" is exactly the control that is not there when someone is in a hurry.
The lock is re-entrant within a transaction, so there is no unlock to forget.
Measurement is a `ddl_command_end` trigger, `tf_deploy_ddl_log`, appending every
command to `tf_deploy_log` with `clock_timestamp()` rather than `now()`, because
`now()` is transaction-fixed and would collapse every deploy to a single point,
making overlap unmeasurable and the control clean for every possible input.

The control scores five axes. Four are catalog facts, both triggers present and
both enabled. The fifth, `interleaved_deploy_total`, is computed from recorded
command spans, so it is the one axis that can contradict the other four: the
triggers can be perfectly installed today and the log can still show that two
deploys overlapped yesterday.

The refusal branch was proved, not assumed, and proving it was the hard part.
This agent **cannot produce a DDL interleave through MCP**, because two
`execute_sql` calls issued in one tool block are serialized before they reach
Postgres, measured at 0.64 s after lock release rather than inside the holder
window. `dblink` is unusable here. `pg_cron` supplied the independent backend,
and the verbatim `55P03` with its DETAIL, HINT and CONTEXT lines is transcribed
in the document.

Read [`DEPLOY_COORDINATION.md`](./DEPLOY_COORDINATION.md) for the full design,
the falsifiability transcript, the checker contract, the `clock_timestamp()`
reasoning, house rule twenty-two, and the operator runbook including the
monitored emergency bypass.

## Controls added by migrations 316 through 320

| Key | Control | Signal | Status |
|-----|---------|--------|--------|
| `CM-SIGWIRE-030` | Creating a checker without wiring its signal into a control is impossible, not merely detectable | `tf_signal_wiring_enforcement_audit` `wiring_gap_total` | passing |

One row, and it closes the last of the three obligations of convention 33. Every
obligation this register places on the act of creating a `public.tf_*` function is
now structural rather than advisory: the grant tier since migration 282, the
registry declaration since 307, the signal wiring since 318.

The obligation stayed open for four batches on a stated premise that was true and
a conclusion that was false. The premise: "wire its signal into a control" has no
single catalog fact testable at commit time. The conclusion drawn from it: the
obligation is therefore unenforceable, and enforcing it would require a
self-declared intent flag, which is an exemption lever. The premise is correct.
There is no single fact. There are **three**, and every one of them is a catalog
fact readable at commit time:

| # | Fact | Read from |
|---|------|-----------|
| 1 | the function's name is a key in the roster | `public.tf_controls_signal_roster()` |
| 2 | the evaluator calls it | `pg_get_functiondef(public.tf_controls_evaluate)` contains `public.<proname>()` |
| 3 | a control names it | some `public.it_controls` row has `signal` containing the proname |

A function is **wired** when all three hold and unwired otherwise. A conjunction
of three catalog facts is exactly as testable as one.

The exemption-lever objection was answered rather than waived. Migration 317
defines a checker as a `public.tf_*` function of `prokind = 'f'` whose
`pg_get_functiondef` text contains the literal `'axes',`. Publishing an axes key
**is** the declaration. An author cannot mark a function "not a checker" without
also making it stop publishing axes, at which point it is not a checker. There is
no flag, so there is nothing to set wrongly.

Migration 318 installs the gate on the same pattern migration 307 established: a
`ddl_command_end` event trigger, `tf_require_signal_wiring`, enqueues into
`public.tf_signal_wiring_pending`, and a `DEFERRABLE INITIALLY DEFERRED`
constraint trigger re-tests all three facts at **COMMIT** and sweeps the queue.
Enqueue-then-test-at-commit is what lets one transaction create a checker and wire
it in either order while still refusing a transaction that creates one and never
wires it.

Migration 319 falsified the control on purpose and is retained in the history as
the evidence. It creates an unwired checker, observes `SQLSTATE 23514`, and rolls
back. The refusal names each unmet fact separately rather than reporting one
opaque failure, which is what makes it a message an engineer can act on at 2am
rather than a message they file a ticket about.

The checker scores five axes. Four are catalog facts about whether the enforcement
is installed, enabled and correctly timed. The fifth, `unwired_checker_total`,
sweeps live function text and answers whether the enforcement actually **held**.
That fifth axis is the only direction in which the checker can contradict itself,
and it is deliberate, the same design choice `interleaved_deploy_total` embodies
in `CM-DEPLOY-029`. A wrongly-timed constraint trigger is counted as **missing**
rather than present, because a statement-time check would refuse every conforming
migration and be switched off within the week.

Migration 316 is a correction the batch flushed out of the 307 chain. The
declaration queue was publishing its raw row count as residue. Residue must be the
**unmet** subset. A queue row for an obligation already satisfied in the same
transaction is population, not debt, and gating on it fails a control for the
ordinary create-then-wire window. Both queues now publish the unmet subset as the
gating axis and the raw count separately as non-gating population.

Read [`SIGNAL_WIRING_ENFORCEMENT.md`](./SIGNAL_WIRING_ENFORCEMENT.md) for the full
design, the verbatim refusal, the component table, the pending-queue collision,
house rule twenty-three, and the operator runbook.

## Runbook

**Score the board.**

```sql
select public.tf_controls_evaluate();
```

**Prove no detection axis goes unread.**

```sql
select public.tf_controls_signal_coverage();
```

Expect `ok: true` and `gap_total: 0`, with all five primitives at zero:
`unread_total`, `undeclared_checker_total`, `unmeasured_checker_total`,
`unrostered_callee_total` and `ungated_refusal_total`. Each names its offenders in
a matching array: `unread_axes`, `undeclared_checkers`, `unmeasured_checkers`,
`unrostered_callees`, `ungated_checkers`. Migration 317 added a **sixth**,
`orphan_checker_total` with `orphan_checkers`, which is the only component
measured from function text rather than from the roster or the consumer, and
therefore the only one that can see a checker wired nowhere at all. Also expect
`checkers_total: 13`, `declaring_checker_total: 13`,
`axes_publishing_function_total: 13` and `axes_total: 27`, which are the
denominators. A `checkers_total` that has moved without a migration explaining it
is itself the finding, and a `checkers_total` below
`axes_publishing_function_total` is a roster that stopped being maintained. The
`refusal_flag_honoured` boolean was retired in migration 304 and replaced by
`ungated_refusal_total`, which asserts the same property across all thirteen
checkers rather than one.

**Prove wiring a new checker into a control is not optional.**

```sql
select public.tf_signal_wiring_enforcement_audit();
```

Expect `ok: true`, `wiring_gap_total: 0`, `event_trigger_state: "origin"`,
`deferred_check_state: "deferred"`, and all five components at zero:
`wiring_enforcement_missing_total`, `wiring_enforcement_disabled_total`,
`wiring_deferred_check_missing_total`, `wiring_residue_total`,
`unwired_checker_total`. `checker_population_total` reads 13. A
`deferred_check_state` of `immediate` is reported as a **missing** check, not a
present one, because a statement-time constraint trigger would refuse every
conforming migration. A zero on the four catalog axes with a non-zero
`unwired_checker_total` means the enforcement is installed and did not hold, which
is the one self-contradiction this checker is built to surface.

**Prove declaring a new function is not optional.**

```sql
select public.tf_declaration_enforcement_audit();
```

Expect `ok: true`, `enforcement_gap_total: 0`, `event_trigger_state: "origin"`,
and all four components at zero: `enforcement_missing_total`,
`enforcement_disabled_total`, `pending_residue_total`,
`unregistered_function_total`. `tf_function_total` and `registry_row_total` should
be equal, currently 104 and 104. Since migration 316, `pending_residue_total` is
the **unmet** subset of the queue and `pending_queue_total` is the raw count,
published separately as non-gating. A standing non-zero `pending_residue_total` outside
a transaction means a commit-time check did not run, and that is a finding no
matter what the other counters say.

**Prove the board is fresh and every automated control is genuinely scored.**

```sql
select public.tf_controls_board();
```

Expect `ok: true`, `authoritative: true`, `unscored_total: 0`,
`tautological_total: 0`, and `board_age_hours` well under `threshold_hours`
(792). A non-zero `unscored_total` names the controls in `unscored_controls`, a
non-zero `tautological_total` names them in `tautological_controls`, and either
one drops `authoritative` to false. `controls_total` reads 30 and
`automated_total` reads 24.

> **`tf_controls_board()` has no `summary` key.** Reading one back returns SQL
> `NULL`, and a `coalesce` on it silently yields whatever default you supplied,
> which in an assertion is a green that was never computed. The register summary
> is the **return value of `public.tf_controls_evaluate()`**. Read it from there.

Run this **before** `tf_controls_evaluate()` if you want a true age reading. Run
after, and the age you read is the age of your own run.

**Read the board directly.**

```sql
select control_key, status, owner_role, left(evidence, 120) as evidence
  from public.it_controls
 where company_id = 'ff000000-0000-4000-b000-000000000001'
 order by status desc, control_key;
```
