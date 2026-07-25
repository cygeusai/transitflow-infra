# IT Governance, Risk & Compliance (GRC)

Continuous controls monitoring, access certification, and service objectives for
Transit & Flow, mapped to **NIST CSF**, **SOC 2**, and **CIS Controls v8**.

## Objects

| Object | Purpose |
|--------|---------|
| `it_controls` | Controls register (**27 controls** as of migration 290) with framework mapping, owner, status, evidence. Keyed by `control_key`, unique |
| `tf_controls_evaluate()` | Re-scores automated controls from live signals (security scan, grant-tier audit, function-safety audit, guard-detection audit, signal coverage, cron presence, MFA gaps, data-quality). Takes **no arguments** |
| `tf_controls_signal_coverage()` | Compares the axis list `tf_security_scan()` declares against the catalog definition of `tf_controls_evaluate`, and names any axis no control renders. Added migration 285, read by `CM-SIGNALCOV-026` since 287 |
| `tf_controls_board()` | Publishes the age of the register, names every automated control the evaluator has no status branch for, and names every branch that asserts a status literal instead of computing one. Folds all three into `authoritative`. Added migration 288, extended 289, read by `CM-BOARDFRESH-027` since 290 |
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
authenticated), except `tf_controls_signal_coverage()` and
`tf_controls_board()`, which are `staff` tier and each carry the
`user_is_internal_staff` predicate in the function body as that tier requires.

Post-deploy `tf_security_scan()` reads `ok: true`, `integrity_total: 0`,
`gap_total: 2` over a declared population of 174 tables and 120 definer
functions. The two are `anon_secdef_nonpublic: 1`, an intentional public surface
with a live exemption row, and `rls_enabled_no_policy: 1`, which is
`studio_events_prelaunch_archive`. That table has RLS on, zero policies, and an
ACL with no client-role grants at all, so no client role can reach it. The
decomposed axis `rls_enabled_no_policy_reachable` reads **0**, and that is the
number `AC-RLS-001` weighs. Both numbers stay in the control's evidence so the
correction is auditable rather than silent.

## Current posture (2026-07-25, after migration 290)

`tf_controls_evaluate()` reads:

```json
{"total": 27, "manual": 0, "failing": 0, "passing": 24, "attention": 3,
 "automated": 21, "manual_controls": 6, "manual_never_attested": 6}
```

24 of 27 passing, **0 failing**, 3 in attention:

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
| `CM-SIGNALCOV-026` | Every declared detection axis has a consumer that renders it | `tf_controls_signal_coverage` `gap_total` | passing |

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

## Runbook

**Score the board.**

```sql
select public.tf_controls_evaluate();
```

**Prove no detection axis goes unread.**

```sql
select public.tf_controls_signal_coverage();
```

Expect `ok: true`, `unread_total: 0`, `refusal_flag_honoured: true`,
`gap_total: 0`. A non-zero `unread_total` names the axes in `unread_axes`.

**Prove the board is fresh and every automated control is genuinely scored.**

```sql
select public.tf_controls_board();
```

Expect `ok: true`, `authoritative: true`, `unscored_total: 0`,
`tautological_total: 0`, and `board_age_hours` well under `threshold_hours`
(792). A non-zero `unscored_total` names the controls in `unscored_controls`, a
non-zero `tautological_total` names them in `tautological_controls`, and either
one drops `authoritative` to false.

Run this **before** `tf_controls_evaluate()` if you want a true age reading. Run
after, and the age you read is the age of your own run.

**Read the board directly.**

```sql
select control_key, status, owner_role, left(evidence, 120) as evidence
  from public.it_controls
 where company_id = 'ff000000-0000-4000-b000-000000000001'
 order by status desc, control_key;
```
