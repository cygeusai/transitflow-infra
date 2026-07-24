# IT Governance, Risk & Compliance (GRC)

Continuous controls monitoring, access certification, and service objectives for
Transit & Flow, mapped to **NIST CSF**, **SOC 2**, and **CIS Controls v8**.

## Objects

| Object | Purpose |
|--------|---------|
| `it_controls` | Controls register (16 controls) with framework mapping, owner, status, evidence |
| `tf_controls_evaluate()` | Re-scores automated controls from live signals (security scan, cron presence, MFA gaps, data-quality) |
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
authenticated). Post-deploy security scan: 0 gaps on every axis.

## Current posture (2026-07-24)

14 of 16 controls passing, 0 failing, 2 in attention:
- `AC-MFA-003` — enable MFA on the owner account.
- `DP-PITR-007` — enable Supabase Point-in-Time Recovery.

Both are owner actions; the next automated evaluation flips each to passing once done.
