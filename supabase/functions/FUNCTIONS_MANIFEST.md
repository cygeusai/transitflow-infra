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
| tf-omni-inbound / tf-omni-send | false | Omnichannel CX messaging |
| tf-meta-webhook | false | Meta Messenger/Instagram webhook |
| tf-clickup-worker | false | ClickUp worker (v3: closed-loop auto-ticket + self-reports ClickUp API auth failures & self-heals) |
| tf-slack | false | Slack post worker |
| hcp-webhook / hcp-estimate-push / tf-hcp-sync-techs | false | Housecall Pro |
| ai-assist / ai-booking / intake-* | mixed | AI intake + booking |
| estimate-approve | true | Approve estimate + optional HCP push |
| tf-review-sweep / tf-draft-review-reply | mixed | Reviews |
| tf-metrics-export / tf-site-ingest / tf-fair-credit / tf-live-connect / tf-twilio-setup | mixed | Ops utilities |

> The authoritative list is `supabase functions list --project-ref kjooyhvynkzuvsixsutt`.
