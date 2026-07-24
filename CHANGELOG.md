# Changelog

All notable changes to the Transit & Flow platform. Newest first.

## 2026-07-24
- Document template + shortcode system (`document_templates`, `document_shortcodes`,
  `tf_render_document`, `tf_fill_shortcodes`) with four on-brand templates.
- Owner statement generation (`tf_generate_owner_statement` + period batch).
- Stripe rent payments live: `tf-rent-pay`, `tf-stripe-webhook`, gated flag.
- Owner + tenant portals; maintenance-to-work-order bridge; PM health component.
- Repository established in GitHub with CI, templates, and contributor docs.

## Earlier
- Field-service core, QuickBooks finance sync, omnichannel CX, reporting, and the
  system health/status layer. See `supabase/migrations/MIGRATIONS_INDEX.md`.
