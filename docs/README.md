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

## Conventions
- The database is the source of truth for access control (RLS).
- Documents are generated from `document_templates` + shortcodes, not hard-coded.
- Finance truth comes from QuickBooks; PM income/expense from the lease ledger.
