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
  This tier exists for *transient* errors, which often clear themselves and do
  not deserve a ticket on first sight.
- **Immediate escalation for auth-class failures**
  (`tf_integration_health_report`): a credential rejection is deterministic. It
  never recovers with time, so the 72h tier would leave a dead connector silent
  for up to three days. A `reauth_required` error therefore opens a priority-2
  ticket on **first detection**, using the same `integration:<provider>:<code>`
  dedup key, so the watchdog, the primitive, and the recovery path all address
  one open ticket and never race each other.
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

## Reusable primitive (generalized)

`tf_integration_health_report(provider, ok, error_code, http_status, message)` is
the standard self-report / self-heal call for **any** worker:
- `ok=false` → sets `last_sync_status`, writes a de-duplicated `integration_errors` row.
- `ok=true` → resolves the open error, sets status `connected`, and closes the
  matching ClickUp reauth ticket.

`tf_system_health` is uniformly error-aware: QuickBooks, ClickUp, Housecall Pro,
and messaging (Twilio/OpenPhone) components all degrade when an open
`reauth_required` error exists for that provider. Verified end-to-end by driving
Housecall Pro degraded → operational through the primitive.

Drop-in for a worker: `await sb.rpc('tf_integration_health_report', {p_provider:'twilio', p_ok:false, p_error_code:'reauth_required', p_http_status:401})`.

## All connectors wired (2026-07-25)

Every API worker now self-reports through the primitive, so no connector can fail
authentication while its health component stays green.

| Connector | Worker | Detection |
|-----------|--------|-----------|
| QuickBooks | `qbo-sync` v2 | OAuth refresh rejection |
| ClickUp | `tf-clickup-worker` v3 | 401/403 or "invalid token" body |
| Slack | `tf-slack` v3 | `invalid_auth`, `not_authed`, `token_revoked`, `token_expired`, `account_inactive`, `missing_scope`, `invalid_token`, `no_permission`, or 401/403 |
| Twilio | `tf-omni-send` v3 | 401/403 or Twilio codes 20003, 20005, 20008, 20404 |
| Meta Graph | `tf-omni-send` v3 (reported as `other`) | 401 or Graph codes 190, 102 |
| Housecall Pro | `tf-hcp-sync-techs` v2 | 401/403 inside the fetch helper; loops break early |

**Auth-class vs config-class.** Only credential rejections degrade a connector.
A Slack `channel_not_found` or `not_in_channel`, an invalid SMS destination, a
`not_configured` provider, and a 404 on a single record are configuration or
data problems, not auth problems, and are deliberately excluded. This keeps the
status page honest: a connector credential failure is component-degraded, never
a platform outage.

`slack` was added to the `integration_provider` enum to make it a first-class
connector. Note the Postgres rule that forced two migrations: an enum value may
be added inside a transaction but not *used* in that same transaction, so the
`ALTER TYPE` and the `integration_settings` seed ship separately.

### Defect found and fixed by the escalation drill

Driving the new immediate-escalation path surfaced a latent bug in
`tf_request_ticket`: `p_list` defaults to the Roadmap & Ops list, but an
*explicit* null argument bypasses the default and violates the `list_id`
not-null constraint deep inside the insert. Every existing caller happened to
omit the argument, so the trap was never sprung. `tf_request_ticket` now
coalesces `p_list` defensively, meaning no caller can break ticket creation by
passing null. Ticket creation inside the primitive is additionally
exception-guarded, so a ticketing failure can never swallow the health signal
that triggered it.

**Verified end to end.** Drove Slack degraded → healthy through the primitive:
`ok=false` returned `{"action":"recorded"}`, health `reports` flipped to
`degraded · "Slack API auth issue, rotate slack_bot_token"`, settings read
`reauth_required` with 1 open error; `ok=true` returned `{"action":"healed"}`,
settings returned to `connected`, open errors and open tickets to 0, and the
health component back to `operational · scheduled & connected`.

Escalation drill (2026-07-25): first failure returned a real `ticket_id` with
priority 2 on list `901418420453`; a second failure returned `ticket_id: null`
with open tickets still at 1, proving dedup; recovery closed the ticket and the
error, returning open tickets and open errors to 0. Security scan after the
change: 0 gaps on all four axes.

## Verified

End-to-end tested: a producer call created a real ClickUp task via the worker and
wrote the task id/url back to the registry (`ops.processed: 1`); de-dup confirmed
(a repeat producer call returned the existing ticket with no new queue event).
