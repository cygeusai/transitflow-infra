# Migration Index

The full, ordered migration history of the Transit & Flow backend (155 migrations
as of 2026-07-24). Run `./scripts/pull-backend.sh` to materialize the actual `.sql`
files from the live Supabase project into this folder. This index is the manifest
of what exists so nothing is silently dropped.

| # | Version | Name |
|---|---------|------|
| 1 | 20260717152445 | tf_schema_01_enums_and_triggers |
| 2 | 20260717164106 | tf_02_org_identity |
| 3 | 20260717164423 | tf_00_preserve_legacy_scaffold |
| 4 | 20260717164545 | tf_03_recruiting_vendors_b |
| 5 | 20260717172337 | tf_04_compliance_partners |
| 6 | 20260717172449 | tf_05_fieldops_core |
| 7 | 20260717172605 | tf_06_estimating |
| 8 | 20260717173237 | tf_07_completion_money |
| 9 | 20260717173345 | tf_08_payouts_performance_knowledge |
| 10 | 20260717173454 | tf_09_integrations_ai_platform |
| 11 | 20260717173528 | tf_10_trigger_wiring |
| 12 | 20260717173633 | tf_rls_01_helpers |
| 13 | 20260717173721 | tf_rls_02_enable_and_core_policies |
| 14 | 20260717173822 | tf_rls_03_external_party |
| 15 | 20260717173942 | tf_rls_04_roles_permissions |
| 16-19 | 202607171745xx | tf_seed_01..04 (org, compliance, estimate, sops) |
| 20 | 20260717204018 | import_quickbooks_invoices |
| 21 | 20260717204816 | payout_readiness_engine |
| 22 | 20260718005353 | provision_service_divisions |
| 23-24 | 2026071801xx | security_hardening_pass_1 / _2 |
| ... | ... | (field-service, CX, AI, studio, RLS optimization tranches) |
| 128 | 20260723084026 | qb_finance_sync_schema |
| 129 | 20260723095858 | tf_ops_report_qb_accurate |
| 133 | 20260723204433 | tf_system_health_monitor |
| 134 | 20260723204626 | fix_hcp_sync_incremental_on_conflict |
| 139 | 20260723213829 | property_management_domain |
| 140 | 20260723214459 | pm_maintenance_to_work_order_bridge |
| 145 | 20260723214939 | tf_system_health_add_pm_component |
| 148 | 20260723215550 | hcp_sync_map_only_active_rows |
| 149 | 20260723220427 | pm_portal_auth_linkage |
| 150 | 20260723220458 | pm_portal_rls_policies |
| 151 | 20260723220646 | pm_portal_rls_fix_recursion |
| 152 | 20260723222906 | pm_portal_phase2_owner_approve_and_wo_visibility |
| 153 | 20260723222922 | pm_rent_payments_scaffold |
| 154 | 20260723224141 | tf_rent_payments_enabled_flag_rpc |
| 155 | 20260723234850 | pm_bridge_authz_allow_unit_owner |
| 156 | 20260723235516 | pm_owner_statement_generation |
| 157 | 20260724000838 | document_template_system_core |
| 158 | 20260724000942 | document_template_render_engine |
| 159 | 20260724001028 | document_templates_and_shortcodes_seed |
| 160 | 20260724001129 | document_templates_seed_bodies |
| 161 | 20260724064548 | tf_data_quality_audit |
| 162 | 20260724115239 | security_autoharden_engine |
| 163 | 20260724213447 | tf_system_health_qb_degraded_semantics |
| 164 | 20260724220708 | integration_settings_dedup_and_health_hardening |
| 165 | 20260724220737 | tf_integration_watchdog |
| 166 | 20260724224124 | grc_it_controls_register |
| 167 | 20260724224153 | tf_controls_evaluate |
| 168 | 20260724224225 | grc_access_reviews |
| 169 | 20260724224256 | grc_service_slos |
| 170 | 20260724224332 | tf_it_governance_report_and_crons |
| 171 | 20260724224440 | tf_controls_evaluate_distinct_accounts |
| 172 | 20260724225908 | auto_ticket_registry_and_producers |
| 173 | 20260724225950 | tf_integration_watchdog_autoticket_wiring |
| 174 | 20260724235924 | tf_platform_overview |
| 175 | 20260725001549 | tf_system_health_clickup_error_awareness |
| 176 | 20260725003732 | tf_integration_health_report_primitive |
| 177 | 20260725003838 | tf_system_health_uniform_error_awareness |

> Note: rows are abbreviated for readability; `supabase db pull` writes every
> migration in full. The complete authoritative list is the Supabase migration
> history for project `kjooyhvynkzuvsixsutt`.
