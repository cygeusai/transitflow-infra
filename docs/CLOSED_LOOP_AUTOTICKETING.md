# Closed-Loop Auto-Ticketing

The platform automatically opens (and closes) ClickUp tickets when something
needs human action, so remediation never depends on someone watching a
dashboard. Built on the existing `tf-clickup-worker` queue pattern; no new
credentials.

## Flow

```
producer (DB fn)  ->  auto_tickets (registry, de-dup)  ->  integration_events (queue)
                                                              -> tf-clickup-worker v2 -> ClickUp task
recovery (DB fn)  ->  tf_resolve_ticket -> ops_ticket_close event -> worker posts resolution comment
```

## Objects

| Object | Purpose |
|--------|---------|
| `auto_tickets` | Ticket registry with a partial unique index on `(company_id, dedup_key) WHERE status IN ('queued','created')` — guarantees one open ticket per issue |
| `tf_request_ticket(key, source, title, body, priority, list)` | Idempotent producer; returns existing ticket on dedup, else enqueues |
| `tf_resolve_ticket(key, note)` | Marks the registry resolved and enqueues a ClickUp resolution comment |
| `tf_governance_autoticket()` | Opens tickets for FAILING controls; auto-resolves tickets for controls that recovered |
| `tf-clickup-worker` v2 | Drains `ops_ticket` (create) and `ops_ticket_close` (comment) events |

## Wiring

- **Integration watchdog** (`tf_integration_watchdog`): opens a ticket when a
  connector error reaches the **escalation tier (>=72h)**; auto-resolves it the
  moment the connector self-heals. Deduped by `integration:<provider>:<code>`.
- **Governance scanner** (`tf_governance_autoticket`, daily cron
  `tf-governance-autoticket-daily` at 14:05 UTC): opens a ticket for any control
  that drops to **failing**; closes it when the control recovers. Deduped by
  `control:<control_key>`.

## Cadence

| Job | Schedule |
|-----|----------|
| `tf-clickup-worker-hourly` | drains the queue every hour (:25) |
| `tf-governance-autoticket-daily` | `5 14 * * *` |
| `tf-integration-watchdog-daily` | `15 13 * * *` |

## Security

All producer functions are SECURITY DEFINER with pinned `search_path`, executable
only by `service_role` (no anon, no authenticated). `auto_tickets` enforces RLS
(internal-staff read). Post-deploy security scan: 0 gaps.

## Worker self-observability (v3)

`tf-clickup-worker` v3 closes the gap where the worker returned HTTP 200 even when
the ClickUp API rejected the token. It now detects auth failures (401/403 or an
"invalid token" body), writes a de-duplicated `clickup / reauth_required`
`integration_errors` row, and sets `integration_settings.last_sync_status =
'reauth_required'`. On the next successful create it self-heals: resolves the
error, flips status to `connected`, and closes the ClickUp reauth ticket.
`tf_system_health` reflects an open ClickUp error as **degraded** (not a false
green), with detail "worker running, ClickUp API auth issue, rotate token".

## Verified

End-to-end tested: a producer call created a real ClickUp task via the worker and
wrote the task id/url back to the registry (`ops.processed: 1`); de-dup confirmed
(a repeat producer call returned the existing ticket with no new queue event).
