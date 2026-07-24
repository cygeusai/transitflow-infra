# Architecture

Transit & Flow is a multi-tenant, RLS-isolated platform built on Supabase with a
Lovable (TanStack Start) frontend. It spans field-service operations and a full
property-management domain with external owner and tenant portals.

## Principles

- **Isolation in the database.** Every access rule is a PostgreSQL Row-Level
  Security policy. The UI never decides who sees what. This is what makes the
  platform safe to resell to other companies.
- **Company scoping.** Every business table carries `company_id`. Helper functions
  (`user_is_internal_staff`, `user_is_internal_writer`, `current_owner_ids`,
  `current_tenant_lease_ids`, and related) resolve identity to scoped id sets.
- **Automation-first with human gates.** Approvals that commit cost (work orders)
  and money movement (payments) are explicitly gated.
- **Isolated troubleshooting.** A component-aware health check (`tf_system_health`)
  reports each subsystem independently so issues are diagnosed without touching
  the rest of the platform.

## Domains

### Field service
Customers, jobs, estimates (Good/Better/Best), work orders, technicians, vendors,
compliance (W-9, insurance, licenses), payouts, leads and lead economics, and an
omnichannel CX layer. Finance truth syncs from QuickBooks.

### Property management + portals
- Tables: `property_owners`, `property_units`, `leases`, `lease_tenants`,
  `lease_ledger`, `maintenance_requests`, `owner_statements`, `rental_applications`,
  `rent_payments`.
- **Closed loop:** a tenant submits maintenance → owner or staff approves →
  a DB trigger auto-creates a Job + numbered Work Order and links them back →
  dispatch → cost/income post to the ledger and owner statement.
- **Portals:** `/portal/owner` (read-first + authorize maintenance),
  `/portal/tenant` (maintenance, ledger, balance, rent payment).
- **Payments:** Stripe rent payments via `tf-rent-pay` (Checkout) and
  `tf-stripe-webhook` (signature-verified settlement + ledger posting), gated by a
  `rent_payments_enabled` flag.

### Documents
- `document_templates` + `document_shortcodes` with a render engine
  (`tf_render_document`, `tf_fill_shortcodes`) that fills clean, on-brand templates
  from live data. Seeded: owner statement, lease agreement, late-rent notice,
  tenant welcome.

## Key backend functions (selected)

- `tf_convert_maintenance_request`, `tg_maintenance_autoconvert` — the bridge.
- `tf_owner_approve_maintenance` — owner-authorized approval.
- `tf_generate_owner_statement`, `tf_generate_owner_statements_for_period`.
- `tf_render_document`, `tf_fill_shortcodes`.
- `tf_system_health`, `tf_ops_report`, `hcp_sync_incremental`.

## Data flow (finance accuracy)

Housecall Pro (field ops) → app; QuickBooks (money truth) → app every 2 hours;
reports post to Slack; health checks every 15 minutes. PM-origin jobs use
`source = 'other'` so paid-marketing economics stay accurate.
