# Documentation

Operational and technical documentation lives in Notion (the living source) and is
mirrored operationally in ClickUp. This folder is the code-side index.

## Notion — Operations Hub → Property Management & Portals suite
1. Solution Overview & Business Requirements (BRD)
2. Functional Specification & User Stories
3. Data Dictionary
4. Security & Access Model (RLS) + Verified Isolation Results
5. Architecture, Bridge & Health Monitoring
6. Standard Operating Procedures (SOPs)
7. Runbook — PM Troubleshooting
8. Owner Portal — User Guide
9. Tenant Portal — User Guide
10. Release Notes & Changelog
11. Stripe Rent-Payment Activation Guide
12. QA Test Report & Defect Log
13. Owner Statement Generation
14. Document Templates & Shortcode Reference

## ClickUp
- List: "Property Management — Roadmap & Ops" (roadmap, action items, defects).
- Doc: "Property Management & Portals — Ops Reference".

## Start here

- [`PLATFORM_KNOWLEDGE_BASE.md`](./PLATFORM_KNOWLEDGE_BASE.md) — **the operator
  wiki.** First-ten-minutes triage, symptom routing table, every health
  component explained, the guard model, the queue, the conventions register, the
  defect-pattern library, all scheduled work, and the open owner-action register.
  Written to be read at 2am by someone who did not build the platform. Every
  other note in this folder is a deep dive on one section of it.

## Platform engineering notes (this folder)
- [`CUSTOMER_360.md`](./CUSTOMER_360.md) — customer read model, index + 360 RPCs
- [`JOB_PREP_INTAKE.md`](./JOB_PREP_INTAKE.md) — prep-text guard ladder, reminder ladder, expiry
- [`SCHEDULER_AND_QUEUE_RELIABILITY.md`](./SCHEDULER_AND_QUEUE_RELIABILITY.md) — pg_cron + queue health
- [`CLOSED_LOOP_AUTOTICKETING.md`](./CLOSED_LOOP_AUTOTICKETING.md) — self-ticketing and self-healing
- [`RELIABILITY_INTEGRATION_WATCHDOG.md`](./RELIABILITY_INTEGRATION_WATCHDOG.md) — connector watchdog
- [`IT_GOVERNANCE_GRC.md`](./IT_GOVERNANCE_GRC.md) — controls, access certification, SLOs
- [`MARKETING_ROI_AND_REVENUE.md`](./MARKETING_ROI_AND_REVENUE.md) — collected-revenue convention, channel P&L
- [`REVENUE_LINKAGE.md`](./REVENUE_LINKAGE.md) — invoice-to-job sweep, natural-key integrity, traceability
- [`SECURITY_GUARDS_AND_QUEUE_LANES.md`](./SECURITY_GUARDS_AND_QUEUE_LANES.md) — definer-guard axis, `AC-DEFN-017`, queue lane registry, orphan reason codes
- [`FUNCTION_GRANT_TIERS.md`](./FUNCTION_GRANT_TIERS.md) — the three-tier `EXECUTE` model, the Supabase default-privileges trap, `tf_apply_grant_tier`, `CM-GRANT-021`

## Interactive artifacts (this folder)
Self-contained HTML. Open directly in a browser, no build step, no network.
- [`COMMAND_CENTER.html`](./COMMAND_CENTER.html) — executive command center
- [`ONCALL_RUNBOOK.html`](./ONCALL_RUNBOOK.html) — operations & on-call runbook
- [`data-engineering-report.html`](./data-engineering-report.html) — data-engineering assessment
- [`data-model-erd.html`](./data-model-erd.html) — entity-relationship diagram

## Conventions
- The database is the source of truth for access control (RLS).
- Documents are generated from `document_templates` + shortcodes, not hard-coded.
- Finance truth comes from QuickBooks; PM income/expense from the lease ledger.
- Phone identity is `right(regexp_replace(phone,'\D','','g'), 10)`.
- Collected revenue is `total_amount - balance`. Never `total_amount`.
- A migration that creates or replaces a function must CALL it in a `do $drive$`
  post-check and assert on the output. Inspecting the catalog is not verification.
- A runbook is code. Every command a document gives an operator must be executed,
  with the operator's credentials, before that document is published.
- A `tf_*` name does not tell you whether the function writes. Read
  `pg_get_functiondef` before putting any call in a runbook. Seven functions on
  this platform are named like diagnostics and write; the register in
  `tf_function_registry` is authoritative, the name is not.
- `revoke all on function ... from public` is **not sufficient** on Supabase.
  `ALTER DEFAULT PRIVILEGES` grants EXECUTE to `anon` and `authenticated` by
  name, and revoking the PUBLIC pseudo-role leaves both grants in place. Use
  `tf_apply_grant_tier`, which names them explicitly and records the intent.
- A guard never observed refusing is not a guard, and a checker never observed
  catching anything is not a checker. Induce the failure in the same transaction
  and assert on the catch. Note that `set local role authenticated` alone leaves
  `auth.uid()` null; a guard test must set `request.jwt.claims` and clear it
  afterwards.
- Conventions live in tables, checkers read the tables. A detection rule compiled
  into a function body can only be changed by someone willing to rewrite that
  function. See `tf_function_safety_patterns`, `tf_boolean_param_conventions`,
  `tf_automation_registry`, `tf_function_grant_tiers`.
- Never string-splice prose into a generated function body. Every quote needs
  doubling twice and every escape needs escaping twice. Put the prose in its own
  function and splice in the call.
- Automation flags flip only through `tf_automation_arm`. A direct `update` on
  `integration_settings` is detected as out-of-band and treated as an incident.
