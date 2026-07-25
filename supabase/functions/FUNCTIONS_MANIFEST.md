# Edge Functions Manifest

Deployed Supabase edge functions (Deno) for project `kjooyhvynkzuvsixsutt`.
Two are included in full as reference (`tf-rent-pay`, `tf-stripe-webhook`); run
`./scripts/pull-backend.sh` to download the rest into this folder.

| Function | verify_jwt | Purpose |
|----------|-----------|---------|
| tf-rent-pay | true | Create Stripe Checkout for a tenant's rent balance (gated) |
| tf-stripe-webhook | false | Settle payment + post ledger (signature-verified) |
| tf-status | false | Branded public status page (v2: availability = operational+degraded; only outage counts against uptime) |
| qbo-sync / qbo-connect | false | QuickBooks OAuth + read-only finance sync (v2: graceful reauth, self-heal, 200-on-expiry) |
| tf-omni-inbound / tf-omni-send | false | Omnichannel CX messaging (send v3: self-reports Twilio + Meta credential rejections and self-heals) |
| tf-meta-webhook | false | Meta Messenger/Instagram webhook |
| tf-clickup-worker | false | ClickUp worker (v3: closed-loop auto-ticket + self-reports ClickUp API auth failures & self-heals) |
| tf-slack | false | Slack post worker (v3: self-reports Slack API token rejection and self-heals; `slack` is a first-class integration provider) |
| hcp-webhook / hcp-estimate-push / tf-hcp-sync-techs | false | Housecall Pro (sync-techs v2: self-reports HCP auth failures, breaks early instead of hammering a dead credential) |
| ai-assist / ai-booking / intake-* | mixed | AI intake + booking |
| estimate-approve | true | Approve estimate + optional HCP push |
| tf-review-sweep / tf-draft-review-reply | mixed | Reviews |
| tf-metrics-export / tf-site-ingest / tf-fair-credit / tf-live-connect / tf-twilio-setup | mixed | Ops utilities |

> The authoritative list is `supabase functions list --project-ref kjooyhvynkzuvsixsutt`.

## `verify_jwt: false` is deliberate, not an oversight

Worker functions are called machine-to-machine by pg_cron, by SECURITY DEFINER
database functions, and by third-party webhooks. None of those callers carry a
Supabase user JWT. They authenticate with an `x-worker-secret` header (or, for
webhooks, a provider signature) checked inside the function body. Leaving
`verify_jwt` at its default of `true` on one of these silently breaks the caller
at the gateway with a 401 before the function ever runs. Always pass
`verify_jwt` explicitly on redeploy of any worker-secret-gated function.

## Connector self-observability

Beyond the connectors, the platform watches the two systems that carry all of
this: `tf_scheduler_health()` grades every pg_cron job for stall and failure, and
`tf_queue_health()` grades `integration_events` across dead, stranded, skipped,
discarded, and stuck-in-flight. Both are scored components of
`tf_system_health()` (11 components total) and both auto-ticket hourly. See
[`docs/SCHEDULER_AND_QUEUE_RELIABILITY.md`](../../docs/SCHEDULER_AND_QUEUE_RELIABILITY.md).

Five connectors now self-report credential failures through one primitive,
`tf_integration_health_report(provider, ok, error_code, http_status, message)`:
QuickBooks (`qbo-sync`), ClickUp (`tf-clickup-worker`), Slack (`tf-slack`),
Twilio and Meta (`tf-omni-send`), and Housecall Pro (`tf-hcp-sync-techs`). Each
returns HTTP 200 on a credential failure so uptime probes measure the function,
not the third party, and each self-heals on its next successful call. Only
auth-class failures degrade a connector; config-class failures
(`channel_not_found`, invalid destination, 404 on a single record) do not.
