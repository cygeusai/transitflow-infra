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

## Platform engineering notes (this folder)
- [`CUSTOMER_360.md`](./CUSTOMER_360.md) — customer read model, index + 360 RPCs
- [`JOB_PREP_INTAKE.md`](./JOB_PREP_INTAKE.md) — prep-text guard ladder, reminder ladder, expiry
- [`SCHEDULER_AND_QUEUE_RELIABILITY.md`](./SCHEDULER_AND_QUEUE_RELIABILITY.md) — pg_cron + queue health
- [`CLOSED_LOOP_AUTOTICKETING.md`](./CLOSED_LOOP_AUTOTICKETING.md) — self-ticketing and self-healing
- [`RELIABILITY_INTEGRATION_WATCHDOG.md`](./RELIABILITY_INTEGRATION_WATCHDOG.md) — connector watchdog
- [`IT_GOVERNANCE_GRC.md`](./IT_GOVERNANCE_GRC.md) — controls, access certification, SLOs
- [`MARKETING_ROI_AND_REVENUE.md`](./MARKETING_ROI_AND_REVENUE.md) — collected-revenue convention, channel P&L

## Conventions
- The database is the source of truth for access control (RLS).
- Documents are generated from `document_templates` + shortcodes, not hard-coded.
- Finance truth comes from QuickBooks; PM income/expense from the lease ledger.
