# Integration Health & Self-Healing

Transit & Flow monitors every external connector and remediates the common
failure modes automatically. Three cooperating layers keep integration health
self-correcting and honestly reported.

## Layers

1. **Graceful degradation (edge).** `qbo-sync` v2 returns HTTP 200 with a
   structured `reauth_required` body when an OAuth token expires, instead of a
   hard 502. It writes a de-duplicated `integration_errors` record and, on the
   next good sync, resolves that record and flips `last_sync_status` back to
   `connected` (inline self-heal).

2. **Health monitor.** `public.tf_system_health(boolean)` runs every 15 minutes
   (`tf-system-health-check`) and posts a daily Slack summary
   (`tf-system-health-daily`, 13:45 UTC). Severity is classified correctly: a
   non-critical, read-only finance sync losing its token is **component-degraded**,
   never a platform-wide outage. Provider reads are scoped to the live
   (non-deleted) `integration_settings` row.

3. **Watchdog.** `public.tf_integration_watchdog(boolean)` runs daily
   (`tf-integration-watchdog-daily`, 13:15 UTC). On each run it:
   - **self-heals**: auto-resolves any open error whose connector is healthy and
     fresh within its window;
   - **escalates**: alerts on remaining open errors by age tier;
   - **de-duplicates**: at most one alert per error per 24h
     (`last_alerted_at` / `alert_count`);
   - **audits**: every action is recorded in `integration_errors`.

## Escalation tiers

| Tier | Age of open error | Cadence |
|------|-------------------|---------|
| Monitoring | < 24h (retryable) | silent |
| Reminder | 24h – 72h | once / 24h |
| Escalation | 72h – 7d | once / 24h |
| Critical | > 7d | once / 24h |

Non-retryable owner-action errors (e.g. `reauth_required`, `OAUTH_019`) begin
alerting from 1h, since no automated retry will clear them. Retryable errors
(e.g. `rate_limited`) stay silent until 24h.

## Freshness windows (self-heal)

| Connector | Stale after |
|-----------|-------------|
| QuickBooks, Housecall Pro | 6h |
| ClickUp, OpenPhone, Stripe | 10d |
| Other | 7d |

## Data hygiene

- Unique partial index `uq_integration_settings_active_provider` on
  `(company_id, provider) WHERE deleted_at IS NULL` guarantees one active row
  per connector per tenant.

## Security

All functions are `SECURITY DEFINER` with pinned `search_path` and least-privilege
grants. `tf_integration_watchdog` is executable only by `service_role`
(no anon, no authenticated). Current security scan: 0 gaps on every axis.
