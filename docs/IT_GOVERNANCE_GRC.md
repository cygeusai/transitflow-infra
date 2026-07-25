# IT Governance, Risk & Compliance (GRC)

Continuous controls monitoring, access certification, and service objectives for
Transit & Flow, mapped to **NIST CSF**, **SOC 2**, and **CIS Controls v8**.

## Objects

| Object | Purpose |
|--------|---------|
| `it_controls` | Controls register (**26 controls** as of migration 287) with framework mapping, owner, status, evidence. Keyed by `control_key`, unique |
| `tf_controls_evaluate()` | Re-scores automated controls from live signals (security scan, grant-tier audit, function-safety audit, guard-detection audit, signal coverage, cron presence, MFA gaps, data-quality). Takes **no arguments** |
| `tf_controls_signal_coverage()` | Compares the axis list `tf_security_scan()` declares against the catalog definition of `tf_controls_evaluate`, and names any axis no control renders. Added migration 285, read by `CM-SIGNALCOV-026` since 287 |
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
authenticated), except `tf_controls_signal_coverage()`, which is `staff` tier and
carries the `user_is_internal_staff` predicate in its body as that tier requires.

Post-deploy `tf_security_scan()` reads `ok: true`, `integrity_total: 0`,
`gap_total: 2` over a declared population of 174 tables and 120 definer
functions. The two are `anon_secdef_nonpublic: 1`, an intentional public surface
with a live exemption row, and `rls_enabled_no_policy: 1`, which is
`studio_events_prelaunch_archive`. That table has RLS on, zero policies, and an
ACL with no client-role grants at all, so no client role can reach it. The
decomposed axis `rls_enabled_no_policy_reachable` reads **0**, and that is the
number `AC-RLS-001` weighs. Both numbers stay in the control's evidence so the
correction is auditable rather than silent.

## Current posture (2026-07-25, after migration 287)

`tf_controls_evaluate()` reads:

```json
{"total": 26, "manual": 0, "failing": 0, "passing": 23, "attention": 3,
 "automated": 20, "manual_controls": 6, "manual_never_attested": 6}
```

23 of 26 passing, **0 failing**, 3 in attention:

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

**Read the board directly.**

```sql
select control_key, status, owner_role, left(evidence, 120) as evidence
  from public.it_controls
 where company_id = 'ff000000-0000-4000-b000-000000000001'
 order by status desc, control_key;
```
