# Migration Index

The full, ordered migration history of the Transit & Flow backend (320 migrations
as of 2026-07-25). Ordinals are the true `row_number() over (order by version)`
from `supabase_migrations.schema_migrations`, not hand-counted. Run `./scripts/pull-backend.sh` to materialize the actual `.sql`
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
| 176-180 | 202607250021xx-0025xx | cygeus_0001..0005 (tenancy/identity/RBAC, workflows/agents/knowledge, API grants, has_permission definer fix, set_updated_at hardening) |
| 181 | 20260725003732 | tf_integration_health_report_primitive |
| 182 | 20260725003838 | tf_system_health_uniform_error_awareness |
| 183 | 20260725003941 | cygeus_0006_access_token_hook_and_onboarding |
| 184 | 20260725005005 | integration_provider_add_slack |
| 185 | 20260725005013 | slack_integration_settings_seed |
| 186 | 20260725005101 | tf_system_health_slack_error_awareness |
| 189 | 20260725005724 | cygeus_0007_governance_enforcement_and_loop_rpcs |
| 190 | 20260725010016 | tf_integration_health_report_immediate_ticket |
| 191 | 20260725010055 | tf_request_ticket_null_safe_list |
| 192 | 20260725010111 | tf_integration_health_report_immediate_ticket_v2 |
| 193 | 20260725010359 | cygeus_0008_ui_read_views |
| 194 | 20260725010432 | tf_scheduler_health |
| 195 | 20260725010736 | cygeus_0009_v_approvals_add_agent_workflow_ids |
| 196 | 20260725010740 | tf_scheduler_health_null_safe_flags |
| 197 | 20260725010758 | tf_queue_health |
| 198 | 20260725010846 | tf_queue_health_v2_platform_wide_stranded_and_skipped |
| 199 | 20260725010923 | tf_queue_requeue_and_discard |
| 200 | 20260725010948 | tf_queue_requeue_partial_apply |
| 201 | 20260725011052 | tf_system_health_add_scheduler_and_queue_components |
| 202 | 20260725011132 | tf_queue_health_v3_backlog_age_from_eligibility |
| 203 | 20260725011140 | cygeus_0010_ai_budgets_and_redaction |
| 204 | 20260725011205 | cygeus_0011_fix_redact_array_concat |
| 205 | 20260725011206 | tf_reliability_autoticket_scheduler_and_queue |
| 206 | 20260725011303 | integration_event_status_add_discarded |
| 207 | 20260725011335 | tf_queue_discard_v2_and_health_v4_terminal_states |
| 208 | 20260725011834 | tf_scheduler_health_v2_first_seen_grace_and_thresholds |
| 209 | 20260725011916 | create_studio_prototype_public_bucket |
| 210 | 20260725012110 | lockdown_studio_prototype_bucket |
| 211 | 20260725012620 | cygeus_0012_fix_workflow_run_errors |
| 212 | 20260725012901 | tf_customer_360_and_index |
| 213 | 20260725013320 | tf_customer_360_defect_fixes |
| 214 | 20260725013422 | tf_customer_360_estimate_amount_fix |
| 215 | 20260725013521 | tf_customer_360_supporting_indexes |
| 216 | 20260725015147 | intake_send_guards_and_reminder_ladder |
| 217 | 20260725015210 | intake_sweep_reminder_ladder_and_expiry |
| 218 | 20260725015721 | intake_phone_match_trailing_ten |
| 219 | 20260725021308 | revenue_convention_and_marketing_roi |
| 220 | 20260725023021 | revenue_linkage_sweep_and_audit |
| 221 | 20260725023406 | fix_linkage_guard_arity |
| 222 | 20260725023419 | fix_linkage_uuid_aggregate |
| 223 | 20260725023458 | linkage_sweep_reentrant_temp_tables |
| 224 | 20260725091758 | security_scan_fifth_axis_and_gap_total |
| 225 | 20260725091845 | guard_unguarded_definer_business_functions |
| 226 | 20260725091919 | tf_queue_health_v5_production_scoped_verdict |
| 227 | 20260725092053 | cygeus_0013_auth_org_membership_fallback |
| 228 | 20260725092629 | grc_control_ac_defn_017_definer_authorization |
| 229 | 20260725092821 | queue_lane_registry_and_health_v6_orphan_lanes |
| 230 | 20260725093324 | fix_queue_lane_registry_enum_type_and_full_seed |
| 231 | 20260725093446 | tf_queue_health_v7_honest_orphan_evidence_and_registry_gap |
| 232 | 20260725101452 | create_studio_products_bucket |
| 233 | 20260725101459 | temp_studio_products_upload_window |
| 234 | 20260725101532 | close_studio_products_upload_window |
| 235 | 20260725101735 | temp_studio_products_seed_window |
| 236 | 20260725101754 | temp_grant_anon_seed_studio_products |
| 237 | 20260725101814 | normalize_bare_quickbooks_invoice_external_ids |
| 238 | 20260725101919 | close_studio_products_seed_window |
| 239 | 20260725102720 | tf_function_safety_audit_and_registry |
| 240 | 20260725102927 | tf_function_safety_close_http_detection_gap |
| 241 | 20260725103527 | tf_intake_sweep_tenant_scoping |
| 242 | 20260725103811 | tf_automation_arming_safety |
| 243 | 20260725103941 | tf_boolean_default_hazards_and_cutover_age_fix |
| 244 | 20260725104122 | it_controls_evidence_integrity_and_attestation |
| 245 | 20260725105044 | tf_safety_autoticket_and_out_of_band_arming |
| 246 | 20260725105218 | boolean_default_hazard_remediation |
| 247 | 20260725110148 | grant_tier_remediation |
| 248 | 20260725111529 | grant_tier_drift_control |
| 249 | 20260725113932 | sweep_tenant_scoping_and_ai_booking_guard |
| 250 | 20260725115002 | automation_blast_radius_transcription_and_bounding_model |
| 251 | 20260725115531 | automation_registry_note_drift_checker |
| 252 | 20260725120338 | note_drift_control_and_register_reconciliation |
| 253 | 20260725123300 | guard_predicate_registry |
| 254 | 20260725123404 | security_scan_reads_guard_registry |
| 255 | 20260725123524 | guard_detection_control_ac_guardreg_023 |
| 256 | 20260725123605 | guard_detection_autoticket_wiring |
| 257 | 20260725123649 | guard_detection_induced_failure_proof |
| 258 | 20260725125437 | grant_tier_full_surface_declaration |
| 259 | 20260725125625 | grant_tier_audit_widen_undeclared_sweep |
| 260 | 20260725130147 | grant_tier_coverage_induced_failure_proof |
| 261 | 20260725130356 | grant_tier_coverage_evidence_and_autoticket_widening |
| 262 | 20260725131610 | grant_tier_audit_coverage_self_enforcement |
| 263 | 20260725131923 | grant_tier_audit_empty_population_refusal |
| 264 | 20260725132224 | grant_tier_coverage_enforcement_consumer_widening |
| 265 | 20260725133630 | guard_detection_exemption_visibility_and_enforcement |
| 266 | 20260725134042 | guard_detection_empty_population_refusal |
| 267 | 20260725134156 | guardreg_control_evidence_denominator_widening |
| 268 | 20260725135604 | function_safety_signal_completeness_and_empty_population_refusal |
| 269 | 20260725140116 | controls_evaluate_honor_checker_refusal_flag |
| 270 | 20260725142025 | studio_founding_access_and_event_taxonomy *(concurrent agent)* |
| 271 | 20260725142046 | studio_founding_guard_and_stats *(concurrent agent)* |
| 272 | 20260725142434 | least_privilege_revoke_truncate_trigger_references_from_client_roles |
| 273 | 20260725142709 | studio_funnel_indexes_and_reporting *(concurrent agent)* |
| 274 | 20260725143527 | reconcile_founding_and_studio_definer_functions_to_declared_grant_tiers |
| 275 | 20260725143849 | safety_audit_classifies_returns_trigger_functions_as_write_paths |
| 276 | 20260725144112 | registers_validate_their_own_rows_against_the_catalog |
| 277 | 20260725144141 | studio_founding_anon_insert_grant *(concurrent agent)* |
| 278 | 20260725144550 | studio_reporting_security_exemptions *(concurrent agent, both rows retired by 281)* |
| 279 | 20260725145159 | studio_events_prelaunch_baseline_reset *(concurrent agent)* |
| 280 | 20260725150224 | security_scan_declares_its_population_and_refuses_to_report_clean_on_integrity_failure |
| 281 | 20260725150253 | retire_security_scan_exemptions_that_suppress_nothing |
| 282 | 20260725150606 | security_scan_exemptions_refuse_rows_that_suppress_nothing |
| 283 | 20260725150711 | security_scan_monitors_truncate_grants_and_separates_unreachable_tables_from_unpoliced_ones |
| 284 | 20260725152401 | controls_listen_to_the_security_scan_refusal_and_its_two_unread_axes |
| 285 | 20260725152534 | detect_the_axis_that_nobody_reads |
| 286 | 20260725152754 | declare_the_signal_coverage_reader_in_the_function_registry |
| 287 | 20260725152915 | the_unread_axis_detector_is_itself_read |
| 288 | 20260725154849 | control_board_publishes_its_own_freshness_and_names_the_rows_the_evaluator_never_scores |
| 289 | 20260725155210 | the_control_board_detects_a_branch_that_asserts_a_pass_instead_of_computing_one |
| 290 | 20260725155435 | continuous_monitoring_stops_asserting_itself_and_the_board_freshness_control_is_wired |
| 291 | 20260725161311 | grant_tier_audit_declares_its_detection_axes_and_couples_them_to_a_gap_total |
| 292 | 20260725161621 | an_axis_is_the_consumption_surface_and_a_rollup_axis_must_assert_it_covers_its_components |
| 293 | 20260725161748 | function_safety_audit_declares_its_axes_and_every_counter_is_classified_gating_or_not |
| 294 | 20260725162003 | three_unread_guard_signals_are_wired_into_the_control_and_the_audit_declares_its_axes |
| 295 | 20260725162341 | automation_note_drift_declares_its_axis_and_the_counter_sweep_widens_beyond_total |
| 296 | 20260725162359 | verify_295_axis_declaration_consumer_read_and_register_aggregate |
| 297 | 20260725162807 | data_quality_audit_refuses_by_return_and_runs_for_definer_owned_callers |
| 298 | 20260725162855 | controls_evaluate_treats_a_refused_data_quality_audit_as_unmeasured_not_clean |
| 299 | 20260725163121 | system_health_reports_an_unavailable_probe_as_degraded_not_operational |
| 300 | 20260725163221 | boolean_hazards_and_out_of_band_declare_axes_completing_the_checker_roster |
| 301 | 20260725163642 | out_of_band_declares_its_axis_on_every_success_path |
| 302 | 20260725163708 | verify_300_out_of_band_declares_on_every_success_path |
| 303 | 20260725163930 | controls_board_is_a_checker_and_must_declare_its_axes |
| 304 | 20260725164220 | signal_coverage_generalises_from_one_checker_to_the_full_roster |
| 305 | 20260725164252 | evaluator_evidence_for_signal_coverage_reports_the_full_roster |
| 306 | 20260725164321 | signalcov_control_description_states_the_roster_and_its_denominator |
| 307 | 20260725170331 | require_function_declaration_event_trigger |
| 308 | 20260725170503 | declaration_enforcement_audit_checker |
| 309 | 20260725170725 | wire_declaration_enforcement_control |
| 310 | 20260725172759 | deploy_coordination_lock_and_log |
| 311 | 20260725172901 | tf_deploy_lock_contention_probe |
| 312 | 20260725173359 | retire_deploy_lock_contention_probe |
| 313 | 20260725173532 | deploy_coordination_audit_checker |
| 314 | 20260725174503 | reconcile_ddl_serialize_declaration |
| 315 | 20260725174600 | deploy_coordination_control_and_roster |
| 316 | 20260725180906 | declaration_pending_residue_is_unmet_only |
| 317 | 20260725181016 | signal_roster_single_home_and_orphan_axis |
| 318 | 20260725181758 | require_signal_wiring_at_commit |
| 319 | 20260725181907 | prove_signal_wiring_refusal |
| 320 | 20260725183125 | signal_wiring_checker_and_control |

> **Migrations 316 through 320 are one change**, and they close **obligation
> three of convention 33**, the last of the three obligations of creating a
> `tf_*` function to remain unenforced. Obligation one, the registry row, has been
> enforced at commit since migration 307. Obligation two, the grant tier, has been
> enforced since the grant-tier coverage batch. Obligation three, wire its signal
> into a control, was recorded as unenforceable in a prior verification log on the
> stated premise that it "has no single catalog fact testable at commit time."
> That premise was correct and the conclusion drawn from it was wrong. It has no
> *single* fact. It has **three**, and all three are catalog facts testable at
> commit time: the function's name is a key in
> `public.tf_controls_signal_roster()`, the text of
> `pg_get_functiondef(public.tf_controls_evaluate)` contains `public.<proname>()`,
> and at least one `public.it_controls` row carries a `signal` naming it. A
> function is wired when all three hold, and unwired otherwise.
>
> **Migration 317 supplies the definition the whole batch stands on.** A checker
> is not a function that says it is a checker. A checker is a `public.tf_*`
> function of `prokind = 'f'` whose `pg_get_functiondef` text contains the literal
> `'axes',`. That is a catalog fact rather than self-declared intent, which is the
> only kind of fact convention 21 permits an instrument to rest on. 317 also gives
> the roster a single home and adds the orphan axis.
>
> **Migration 318 makes the obligation impossible to skip rather than merely
> detectable**, using the commit-time enforcement pattern established by 307: an
> event trigger on `ddl_command_end` enqueues the created function into
> `public.tf_signal_wiring_pending`, and a `CREATE CONSTRAINT TRIGGER ... AFTER
> INSERT ... DEFERRABLE INITIALLY DEFERRED` fires at COMMIT to re-test all three
> facts and sweep the queue. Enqueue-then-test-at-commit is what allows a single
> transaction to create a checker and wire it, in either order, while still
> refusing a transaction that creates one and never wires it.
>
> **Migration 319 is the falsifiability proof and is deliberately retained.** It
> creates `public.tf_probe_unwired_checker()`, observes the refusal, and rolls
> back. The verbatim `SQLSTATE 23514` refusal, which names each of the three unmet
> facts separately rather than reporting a single opaque failure, is transcribed
> in its header and in the document.
>
> **Migration 316 is a correction to the 307 batch that 318 would otherwise have
> inherited.** The declaration pending queue published its raw row count as
> residue. Residue must be the **unmet** subset, because a queue row for a
> function that has since been wired is population, not debt. The raw count is
> still published, as an explicitly non-gating figure. House rule 22's
> re-evaluation requirement is what surfaced the collision.
>
> **Migration 320 could not be split.** It creates the checker
> `public.tf_signal_wiring_enforcement_audit()`, and creating a checker is exactly
> the act 318 now refuses unless the same transaction also wires it. The roster
> entry, the evaluator splice, the `CM-SIGWIRE-030` control row, the registry row
> and the grant tier therefore all land in one transaction with the checker, and
> the batch's most satisfying assertion is 320's own: it requires
> `wiring_queue_total >= 1` at assertion time, proving the enforcement observed
> its own author, and the queue reads 0 after commit, proving the deferred sweep
> ran.
>
> **These five files are checked into this directory verbatim** and were verified
> byte-exact against `supabase_migrations.schema_migrations.statements` by md5
> before commit. There is **one deliberate, documented divergence**: the applied
> text of 320 contains a misspelled identifier, `coaleske_placeholder`, inside a
> `raise exception` on a branch that only executes when
> `enforcement_gap_total <> 0`. It committed clean because plpgsql does not
> resolve identifiers inside a branch it never executes. The live schema is
> unaffected, since no database object contains that text, but a replay onto a
> fresh database would report `42703` instead of the intended message, so the
> checked-in file carries the corrected `coalesce(...)` plus an inline comment
> recording the divergence. That defect produced **house rule twenty-three**: an
> assertion's failure path is code, and untested code. It also opened the
> `plpgsql_check` static-analysis workstream.
>
> The full design, the three-fact definition, the refusal transcript, the
> component axis table, the pending-queue collision and the operator runbook are
> in
> [`docs/SIGNAL_WIRING_ENFORCEMENT.md`](../../docs/SIGNAL_WIRING_ENFORCEMENT.md).

> **Migrations 310 through 315 are one change**, and they close the item that six
> consecutive verification passes named the largest unmitigated governance risk in
> this backend: deployment coordination. More than one channel can write DDL to
> this project, the MCP tools this agent uses, the Supabase dashboard SQL editor,
> a direct `psql` session, CI, or a second agent. Nothing serialized them and
> nothing recorded them. The batch does prevention and measurement as two
> separable things: a `ddl_command_start` event trigger that takes a bounded
> advisory transaction lock and refuses with `55P03` when another deploy holds it,
> and a `ddl_command_end` trigger that appends every DDL command to
> `public.tf_deploy_log` with `clock_timestamp()` so spans have width and overlap
> is measurable. Control `CM-DEPLOY-029` scores five axes off
> `tf_deploy_coordination_audit()`, and the interleave axis is computed from
> recorded spans rather than the trigger catalog, so it is the one axis that can
> contradict the other four.
>
> **Migration 311 is deliberately retained in the history even though 312 retires
> it.** It is the contention probe, a function whose only purpose was to hold the
> deploy lock long enough for a second backend to be refused. Deleting it from the
> chain would delete the evidence that the refusal branch was ever observed rather
> than merely reasoned about. The proof required an independent backend, and the
> route to one is itself worth recording: `dblink` is unusable on this project
> (available but not installed, and `postgres` is not a superuser, so a
> passwordless loopback connection is impossible), and this agent cannot produce a
> DDL interleave through MCP at all, because two `execute_sql` calls issued in one
> tool block are serialized before they reach Postgres. `pg_cron` supplied the
> second backend, and the verbatim `55P03` refusal with its DETAIL, HINT and
> CONTEXT lines is transcribed in the document.
>
> **Migration 314 is the batch's most valuable accident.** Migration 315's
> pre-commit assertion caught a drift that migration 310 had introduced fifteen
> minutes earlier: `tf_ddl_serialize` was declared `write` by analogy with the
> migration-272 rule, but its body only acquires a lock and raises, so
> `tf_function_safety_audit` computed `read` and refuted the claim. No migration
> between 310 and 313 re-scored the register, so the board displayed a stale green
> over a live drift. The fix went to the declaration, not the detector: teaching
> the detector that a lock acquisition counts as a write would have made the claim
> true by weakening the instrument, which convention 21 forbids. That produced
> **house rule twenty-two**: a migration that writes a row into
> `tf_function_registry` must re-evaluate the control register before it commits,
> because a stale green is worse than a red, since nobody investigates a green.
>
> The full design, the falsifiability transcript, the checker contract, the
> `clock_timestamp()` reasoning and the operator runbook are in
> [`docs/DEPLOY_COORDINATION.md`](../../docs/DEPLOY_COORDINATION.md).

> **Migrations 307 through 309 are one change**, and they convert an obligation
> from detected to impossible. Convention 33 says creating a `public.tf_*`
> function carries three obligations in the same migration: apply a grant tier,
> declare it in `tf_function_registry`, wire its signal into a control. Only the
> first was structurally enforced. This batch closes the second. A
> `ddl_command_end` event trigger enqueues every undeclared `tf_*` function into a
> transient table, and a `DEFERRABLE INITIALLY DEFERRED` constraint trigger fires
> at **COMMIT** and aborts the transaction if the declaration is still missing.
>
> The obvious design, refusing at `CREATE FUNCTION` time and forcing the author to
> declare first, is impossible here and the catalog said so before any code was
> written: `tf_function_registry_validate` raises `check_violation` for a row whose
> function does not exist yet, so a declaration **cannot precede its function**.
> There is no ordering that satisfies both requirements, which is what forced
> enforcement to the transaction boundary. Two probes established the ground
> conditions first, that `apply_migration` is transactional (a deliberate abort
> left no table and did not increment the version count) and that `postgres` can
> create event triggers on this project despite `rolsuper = false`.
>
> The guard was proved in three directions, each inside a self-aborting migration:
> it **refuses** an undeclared function with `ERROR 23514` and a hint that teaches
> the correct ordering, it does **not over-fire** on the compliant path, and the
> control built on it is **falsifiable**, disabling the event trigger drove
> `CM-FNDECL-028` to `failing` and re-enabling it drove it back to `passing`
> within one transaction. 308 adds `tf_declaration_enforcement_audit`, whose own
> commit is the production proof of the satisfied path, and whose axes include
> whether the enforcement itself is missing or disabled, so the kill switch cannot
> be used quietly. 309 wires `CM-FNDECL-028` with a five-anchor asserted splice.
> The register moved 27 controls to **28, 25 passing, 0 failing**, and the roster
> moved ten checkers and twenty-four axes to **eleven and twenty-five**. Full
> reasoning, the discarded design, the verbatim refusal transcripts and the
> operator runbook are in
> [`docs/DECLARATION_ENFORCEMENT.md`](../../docs/DECLARATION_ENFORCEMENT.md).

> **Migrations 270 through 277 were applied by two agents interleaved into one
> version stream, and that is itself the finding.** Four of these eight (270,
> 271, 273, 277) were deployed to production by the Lovable agent building the
> Studio Founding Access and Studio Analytics features while this session's
> hardening migrations (272, 274, 275, 276) were open. During that window the
> base-table count moved 171 to 173 and the `tf_*` function count moved 84 to 91.
>
> **There is no lock, no alert and no drift notification on this.** Two agents
> can write DDL to the same production schema with no coordination primitive
> between them. The practical consequences were immediate and are worth recording
> because they generalise:
>
> 1. **Absolute-count assertions become races.** Migration 274's first attempt
>    asserted an end-state (`a_unguarded <> 0`) and rolled back, not because the
>    remediation failed but because the population grew mid-transaction. The rule
>    that survives is: **assert deltas measured inside the transaction, never
>    absolute counts pinned from an earlier query.** Report anything that arrived
>    concurrently by `raise notice`, never by `raise`.
> 2. **Ordinals cannot be predicted while a session is open.** This block was
>    written up in-session as "migrations 270 through 273" and is in fact 272,
>    274, 275 and 276. The migration **name** is the only stable identifier. Cite
>    migrations by name, per the ordinal-reconciliation note at the foot of this
>    file.
> 3. **Register rows arrive un-applied.** The concurrent agent inserted rows into
>    `tf_function_grant_tiers` by hand rather than through `tf_apply_grant_tier`,
>    keyed on the bare type list `'integer'` instead of the identity-argument
>    string `'p_days integer'`. They resolved to nothing, counted as violations,
>    and never applied the ACL they declared. Migration 276 makes the table refuse
>    or canonicalise such rows.
>
> The governance decision this needs, a deployment lock or at minimum a
> post-deploy drift notification, is open and unassigned.

> **Migration 272** revokes `TRUNCATE`, `TRIGGER`, `REFERENCES` and `MAINTAIN`
> from `anon` and `authenticated` on every base table in `public`. `TRUNCATE` is
> **not gated by RLS**: it does not visit rows, so no policy can constrain it, and
> 172 of 173 tables granted it to `authenticated`. It was never reachable through
> PostgREST, which has no HTTP verb mapping to `TRUNCATE`, which is exactly why
> nothing broke and why nobody looked. `SELECT`, `INSERT`, `UPDATE` and `DELETE`
> are left intact so no application path changes. The residual, the
> `supabase_admin`-owned default ACL still reading `anon=arwdDxtm`, and the
> monitoring gap, no scanner axis watches this yet, are recorded in
> [`docs/LEAST_PRIVILEGE_TABLE_GRANTS.md`](../../docs/LEAST_PRIVILEGE_TABLE_GRANTS.md)
> along with the evidence that the hardening held under migration 277's later
> anon grant.

> **Migration 274** reconciles the five definer functions the concurrent agent
> deployed. Two of them, `tf_studio_funnel` and `tf_studio_quality_gates`, were
> `SECURITY DEFINER` with `EXECUTE` held by `anon` and `authenticated`, no guard,
> aggregating `public.studio_events` whose only `SELECT` policy is
> `events_staff_read = studio_is_staff()` and on which `anon` holds no `SELECT` at
> all. **Aggregation is not anonymisation.** A definer function over a staff-gated
> table is a hole in that gate unless it re-asserts the gate itself. Both were
> converted to plpgsql and given the studio guard idiom, bodies otherwise
> byte-identical. The three founding functions were tiered `admin`, `admin`,
> `anon`. A savepoint probe proved `tf_founding_guard` still fires after its
> `EXECUTE` revoke, confirming that **Postgres checks `EXECUTE` on a trigger
> function at `CREATE TRIGGER` time, not at fire time**. `gap_total` moved 10 to
> 1, `secdef_authenticated_no_guard` 5 to 0.

> **Migrations 275 and 276 are one change**, and they are the fourth checker in
> the sweep. 275 fixes a classifier blind spot: a function that `RETURNS trigger`
> is a write path **by construction**, since it runs inside another statement's
> DML and its return value is the row that statement writes, so there is no DML
> keyword in the body for a pattern sweep to find. Three functions were classified
> `read` on that basis, including `tf_assign_job_number`, which rewrites the
> customer-facing job identifier of every job the business creates. The fix
> classifies structurally on `pg_proc.prorettype`, and proves itself by an exact
> partition: `reads` down by exactly the pre-computed flip count, `writers` up by
> exactly that count, `transitive_writers` unmoved.
>
> 276 is the larger half. The one drift row 275 surfaced carried the rationale
> "Baseline classification seeded from `tf_function_safety_audit()` at migration
> 233" — **the register agreed with the checker because the register was populated
> by the checker.** A register seeded from a checker inherits every blind spot
> that checker had on the day it was seeded, and from then on the two agree with
> each other forever. 276 corrects the class rather than the instance, then
> attaches `BEFORE INSERT OR UPDATE` validators to both `tf_function_registry` and
> `tf_function_grant_tiers` so that a table a checker reads refuses to hold a row
> the checker cannot verify. Both validators are deliberately `SECURITY INVOKER`,
> so they add nothing to the reachable-definer population `AC-DEFN-017` reasons
> about. Four inductions prove each refusal live and assert it fired for the right
> reason, the fourth replaying the concurrent agent's exact mis-keyed row and
> requiring it to land canonicalised.
>
> The full reasoning, the savepoint-probe technique, both validator bodies and the
> operator runbook are in
> [`docs/REGISTER_INTEGRITY.md`](../../docs/REGISTER_INTEGRITY.md).

> **Migrations 262 through 264 are one change**, and they are the sequel to
> 258–261 rather than a repeat of it. That block made the checker's coverage
> complete and visible. This block makes it **enforced**. Publishing a
> denominator is not the same as failing on it: between 258 and 261 an operator
> could see a coverage shortfall in the evidence string, but nothing failed,
> nobody was paged and no ticket opened. A number that only a diligent reader
> acts on is a number that gets acted on until the first busy week.
>
> 262 makes any `tf_*` function with no row in `tf_function_grant_tiers` a
> violation regardless of who can execute it, adds `uncovered_total` and
> `uncovered_unreachable_total` beside the retained
> `undeclared_reachable_total`, folds the shortfall into `violation_total`, and
> asserts inside the function body that the two subsets partition the shortfall
> exactly, raising loudly if three catalog predicates ever stop agreeing. It
> proves the new class by inducing the shape nothing was watching: a real `tf_*`
> function, untiered, reachable by **nobody**, with every assertion taken against
> a baseline measured moments earlier rather than against a typed constant. The
> load-bearing assertion is that `undeclared_reachable_total` does **not** move,
> which is what shows the state of the art one migration earlier saw nothing
> wrong.
>
> 263 makes `tf_grant_tier_audit()` **refuse** rather than certify when the `tf_*`
> population reads zero. Before it, that case returned `coverage_pct: null`
> beside `violation_total: 0` and the control went green over a failed
> measurement, which is the `x !~* null` shape and the reason
> `tf_guard_pattern()` is `plpgsql`. The refusal cannot be induced live without
> dropping the platform, so it is proved on a clone derived from the live catalog
> text by exactly two asserted substitutions, the header rename and the
> population source forced to zero, named outside the `tf_*` namespace so the
> proof does not perturb the population it tests. That proof is deliberately
> labelled the weakest of the three in the doc.
>
> 264 widens the two consumers again, additively. The `CM-GRANT-021` evidence now
> separates the shortfall from the exposed subset and names both enforced
> behaviours, and `tf_grant_tier_autoticket` publishes both halves and closes on
> the enforced fact rather than the narrower pre-262 one. Closing a ticket on a
> narrower property than the control enforces is how a ticket queue drifts out of
> agreement with the control register.
>
> Full reasoning, both fixtures, the clone-proof method and the widened runbook
> are in [`docs/FUNCTION_GRANT_TIERS.md`](../../docs/FUNCTION_GRANT_TIERS.md).

> **Migrations 268 and 269 are one change**, and they are the third checker in
> the sweep plus the discovery that the previous two passes had been shipping
> refusals nobody downstream was reading.
>
> 268 takes `tf_function_safety_audit`. Its completeness guard on
> `tf_function_safety_patterns` enumerated four of the five signal classes the
> body reads; `vault_read` was missing. That is not a partial guard, because
> `body ~* null` evaluates to **null**, not false. Deleting the three
> `vault_read` rows therefore made every one of the 84 functions read as not
> touching the Vault, collapsed `secret_touchers` from 18 entries to 1, and
> returned `ok: true` with zero drift while doing it. 268 checks all five
> classes, returns `missing_signals` naming exactly which are absent, adds the
> empty-population refusal house rule eleven requires, and brings the population
> CTE in line with every other catalog sweep by filtering `prokind = 'f'` so a
> `tf_*` aggregate is classified out rather than raising `42809` and taking the
> audit down.
>
> 269 is the larger half. Reading the consumer side found that **five of six**
> checker consumers in `tf_controls_evaluate` ignore their checker's `ok` flag
> and read straight into a `coalesce(..., 0)`, so a refusing checker arrives as a
> clean zero and every status rule maps zero to `passing`. Only `v_gd` was
> correct, and only because it was written after migration 265. Four of the six
> checkers involved can refuse **only** by return value, never by raise, so the
> evaluator's existing exception handler never saw them. Every refusal migrations
> 262, 263, 265, 266 and 268 taught a checker to emit was landing somewhere that
> could not tell refusal from cleanliness. 269 gives all six the same
> null-on-refusal shape and verifies by counting the idiom in the patched body.
>
> The proof is the strongest shape used on this platform: no clone in the
> load-bearing arm. `set_config('request.jwt.claims', ...)` pointed at a known
> non-staff identity makes `auth.uid()` non-null inside the migration and drives
> every read-path `forbidden` guard at once, which had been assumed impossible
> for several passes. 269 therefore demonstrates the defect live **before** the
> patch, applies it, demonstrates the fix **after**, restores and asserts exact
> recovery of both status and evidence, with `AC-GUARDREG-023` serving as an
> in-transaction control group reading `attention` under the identical refusal
> that leaves the other five reading `passing`.
>
> Full reasoning, both proofs, the payload reference, the written reason
> `misleading_total` is published but does not gate, and the operator runbook are
> in [`docs/FUNCTION_SAFETY_AUDIT.md`](../../docs/FUNCTION_SAFETY_AUDIT.md).

> **Migrations 265 through 267 are one change**, and they are house rule eleven
> applied to a second checker. Migrations 262 through 264 taught the platform to
> fail on its own coverage number; a sweep of all eleven checker functions then
> found that `tf_grant_tier_audit` was the **only** one with any population or
> coverage concept at all. `tf_guard_detection_audit` was taken first, because
> `AC-GUARDREG-023` depends on it and because it decides whether every
> `SECURITY DEFINER` function on the platform carries an authorization predicate.
>
> Its defect was worse than the one house rule eleven was written for. It
> published a bare `scanned` count of 55 and nothing else about its population:
> not the 57 definer functions actually reachable by `authenticated`, not the two
> excused into `security_scan_exemptions`, and not their names. That table is a
> live lever with no cardinality limit and no approval workflow beyond a text
> column, which made inserting a row the cheapest available way to stop an
> unguarded function being reported, and made the resulting drop in `scanned`
> indistinguishable from functions having been deleted.
>
> 265 publishes `reachable_total`, `exempted_total` and `exempted_fns`, asserts
> the partition `reachable = scanned + exempted` inside the audit body so the
> accounting cannot drift silently, and makes a **stale** exemption, a row naming
> anything that is not a definer function reachable by `authenticated`, a gating
> integrity violation. A stale exemption is a pre-authorised hole waiting for
> something to be created under that name. Proved by planting one, asserting
> `stale_exemption_total` rose while `exempted_total` did **not**, asserting
> `AC-GUARDREG-023` went `failing`, then removing it and asserting full recovery.
>
> 266 makes the audit refuse an empty population. Unlike migration 263's
> equivalent, this failure is inducible against the live object, because the lever
> that empties it is a table anybody can insert into: exempt all 57 and `scanned`
> is zero while the partition still holds at `57 = 0 + 57`. The proof inserts
> exactly one row per reachable definer function, asserts the count inserted
> equals the previous scan size, captures the raise, asserts the message names the
> denominator it refused over, asserts the control stopped reading `passing`, then
> restores and asserts every counter and the evidence string returned to baseline.
>
> 267 widens the `AC-GUARDREG-023` evidence string additively, per convention 21,
> so the board reads `[population 57 reachable, 2 exempted, 0 stale exemption(s)]`
> beside the scanned count. Its proof has two parts: exempting a real function
> must show the shrink **and** attribute it, without failing the control; planting
> a stale exemption must name it, fail the control, and not inflate
> `exempted_total`.
>
> Full reasoning, both raises verbatim, the runbook for stale exemptions and the
> re-measured state are in
> [`docs/GUARD_DETECTION.md`](../../docs/GUARD_DETECTION.md).

> **Migrations 258 through 261 are one change**, split into four so each half of
> the work could be asserted before the next was applied. They close a coverage
> defect in the grant-tier checker: not declaring a tier was a way to never be
> checked for tier drift, so `tf_grant_tier_audit()`'s own coverage was decided
> by the population it was auditing. At discovery, 18 of 84 `tf_*` functions
> carried a declared tier, 27 of the 66 undeclared were reachable by
> `authenticated`, and the audit reported `violation_total: 0` because none of
> them happened to be reachable by `anon`.
>
> 258 declares every `tf_*` function **at its current live reality** and asserts
> that not one function's reachability changed, because silently revoking
> `authenticated` in bulk would have broken the Lovable Hub with no attribution,
> which is quiet corruption. 259 widens the undeclared sweep from *anon* to
> *anon or authenticated* and adds `tf_population_total`, `tf_covered_total` and
> `coverage_pct` so the audit publishes its own denominator. 260 proves the
> widened sweep by creating a definer function reachable by `authenticated` and
> not by `anon` with no declared tier, asserting the pre-259 predicate reads 0
> on it, then observing the new sweep name it, coverage fall below 100 pct and
> `CM-GRANT-021` turn `failing`, then observing full recovery. 261 widens the two
> stale consumers: the `CM-GRANT-021` evidence string now states its surface,
> and `tf_grant_tier_autoticket` now tickets on `undeclared_reachable_total`
> instead of the always-zero anon subset, additively, so no consumer breaks.
>
> The reasoning, the measured exposure, the decision not to demote grants, both
> induced-failure proofs and the operator runbook are in
> [`docs/FUNCTION_GRANT_TIERS.md`](../../docs/FUNCTION_GRANT_TIERS.md).

> **Migrations 280 through 283 are one change**, split into four so each
> property could be asserted before the next was applied. 280 rebuilds
> `tf_security_scan` in plpgsql, preserving all twelve legacy keys and adding a
> `population` block, an axis-coupling raise, and an `ok: false` refusal ladder.
> 281 retires two exemptions that suppressed nothing, asserting the guard axis
> cannot move when they are removed. 282 attaches a validating trigger so no
> such exemption can be written again, and proves **the creation exposure
> window** at both ends: a `SECURITY DEFINER` function is executable by
> `authenticated` from `CREATE FUNCTION` until `tf_apply_grant_tier` runs. 283
> adds the sixth axis `tables_truncatable_by_client`, closing the monitoring gap
> migration 272 left open, and decomposes `rls_enabled_no_policy` so a table no
> client role can reach is no longer counted the same as one that is genuinely
> unpoliced. The reasoning, the assertions and the runbook are in
> [`docs/SECURITY_SCAN_INTEGRITY.md`](../../docs/SECURITY_SCAN_INTEGRITY.md).

> **Migrations 291 through 306 are one change**, the largest single batch in the
> history, and it exists because the batch before it proved a principle over a
> sample of one. 284 through 287 established that detection without consumption
> is not a control, then built `tf_controls_signal_coverage` to enforce it over a
> single checker. This batch generalises that to the whole platform: **every
> checker declares, in machine-readable form, the exact set of signals it expects
> a control to read**, and the coverage detector tests those declarations against
> the evaluator for the entire roster. The result is ten checkers, twenty-four
> declared axes, and zero unread, undeclared, unmeasured, unrostered or
> refusal-ungated.
>
> Declaration replaced inspection because inspection cannot tell a **finding**
> from a **population**. `tf_automation_out_of_band` publishes `enabled_total` and
> `out_of_band_total`; only the second is a finding, the first is the denominator.
> An inspecting detector demands a consumer for both, the platform is permanently
> one axis short for an artefact reason, and somebody adds a fake control to
> satisfy the checker. Hence the convention: **an axis is the consumption
> surface**, a signal a control is expected to READ, not an inventory of
> everything the checker counts.
>
> Each declaring checker got the same three-part tail. **Coupling one**: every
> declared axis must appear in the payload. **Coupling two**: every non-gating
> counter must carry a written rationale, which puts "not an axis" on the record
> as a decision rather than an omission. **Coupling three**: every counter key
> must be classified as axis, component axis, or explained non-gating, so no
> future edit can add a finding that silently escapes coverage. Migration 295
> found that a sweep for `_total` alone passed `drift_count` and therefore
> examined zero keys, giving **counter suffix coverage**: *a classification rule
> that only recognises one naming convention does not classify, it filters.*
>
> Two checkers declare a **roll-up** axis instead of their primitives, which is
> legitimate only under the **roll-up axis rule**: the checker must assert, in its
> own body, that the roll-up equals the sum of the primitives it stands for.
> Without that, a roll-up is where findings go to disappear.
>
> The consumer test is the **strict counter-read needle**,
> `coalesce((<var>->>'<axis>')::int`, and it defeats two blind spots a bare
> `strpos` cannot. **Name collision**: `drift_total` is published by two different
> checkers, so an unqualified search certifies either one on the other's consumer.
> **Narrative versus status**: a signal interpolated into a human-readable evidence
> string is not being consumed by a control, but textually it looks identical to
> one read into a comparison. The variable qualifier kills the first, the
> `coalesce(...)::int` shape kills the second. Verified live across all 24
> (checker, axis) pairs.
>
> Four defects were found and closed. **The swallowed refusal**: an exception
> handler that defaults a gap counter to zero converts an unrunnable check into a
> passing control, so the board goes green *because* the detector broke. Zero is
> the passing branch, null is the attention branch; 297, 298 and 299 fixed the
> instances and every later migration in the batch runs a pre-install regex guard
> refusing any `exception when others then ... := 0;` handler. **Declare on every
> success path**: `tf_automation_out_of_band` had a legitimate early return that
> shipped no `axes` key, which is a conditional declaration and therefore no
> declaration at all; 301 collapsed it into the shared declaring tail and 302
> enforced the structure by asserting the function has exactly two return
> statements. **Whether a function is a checker is not a property of its name**, it
> is a property of whether the consumer reads a counter out of it, and by that test
> `tf_controls_board` had been a checker since migration 288 without ever
> declaring an axis while `tf_controls_signal_coverage` is consumed via its own
> `gap_total`. Correcting the roster from eight to ten **before** it was written
> into the generalised checker is what stopped the platform certifying one hundred
> percent coverage over a population silently narrowed by two. **Roster closure**
> now has a mechanism: 304 scans the evaluator for every `public.tf_*()` call it
> makes and refuses any callee that is neither rostered nor on the explicit
> non-checker list. The register moved to **27 controls, 24 passing, 3 attention,
> 0 failing**, and `CM-SIGNALCOV-026` now states its own denominator. The full
> reasoning, the roster table, the three couplings and the runbook are in
> [`docs/CHECKER_AXIS_DECLARATION.md`](../../docs/CHECKER_AXIS_DECLARATION.md).

> **Migrations 288 through 290 are one change**, split into three because the
> middle one found something the batch was not looking for and shipping the
> detector before the fix is what makes the finding credible. 288 builds
> `tf_controls_board()`, the first thing in the system that knows how old the
> control register is. `it_controls.status` had been a cache of judgements with
> no staleness concept, so the board could render an evaluation from any point in
> the past as current. The **first design for the unscored-row detector was
> disproved by the catalog before any code was written**: it assumed a row whose
> `last_evaluated_at` lags the maximum is a row the evaluator skipped, but
> `tf_controls_evaluate` writes every automated row in one `UPDATE` sharing one
> `v_now` and its status CASE ends `else status end`, so an unscored row keeps
> its old status **and is stamped fresh anyway**.
> `count(distinct last_evaluated_at)` reads 1, and the detector would have
> reported zero forever. That is **the write-timestamp trap**:
> `last_evaluated_at` records when a row was written, never when it was judged.
> The replacement parses the evaluator's own `pg_get_functiondef` and names
> automated controls with no `when` branch. 289 adds a second axis to the same
> reader, `tautological_total`, which names branches that **assert** a status
> literal rather than compute one, and it immediately found
> `when 'GV-CCM-016' then 'passing'`: the control certifying continuous controls
> monitoring was a hardcoded constant that could never fail, carrying as evidence
> the timestamp of its own write. **289 deliberately did not fix it**, so the
> finding exists in the history as something the machine found rather than
> something the author fixed quietly while adding the check that would have
> caught it. 290 fixes `GV-CCM-016` to compute from live `cron.job` state and
> wires `CM-BOARDFRESH-027` over `authoritative`. Two techniques from this batch
> are reusable. **The self-stamping signal**: a freshness control must read the
> board before the evaluator's `UPDATE`, or it scores its own write and reads
> zero hours old every time, so 290 hoists the `tf_controls_board()` call to the
> top of `tf_controls_evaluate` and holds the result. **The asserted textual
> splice**: patching a large function via `pg_get_functiondef` plus `replace` is
> legitimate only if every anchor is first asserted to occur exactly once, via
> `(length(v_new) - length(replace(v_new, a, ''))) / length(a)`, refusing the
> whole migration otherwise. 290 used five such anchors. The register moved 26
> controls to **27 with 0 failing**, and now publishes one boolean,
> `authoritative`, that is false if the board is stale, if any automated control
> is unscored, or if any status is asserted. The full narrative, the discarded
> design, the refusal table and the runbook are in
> [`docs/CONTROL_BOARD_FRESHNESS.md`](../../docs/CONTROL_BOARD_FRESHNESS.md).

> **Migrations 284 through 287 are one change**, split into four because the
> third of them exists only because the second one's assertion refused. 284
> teaches `tf_controls_evaluate` to honour the scan's `ok` flag, which it had
> never done because that flag was added in migration 280 after the migration 269
> consumer sweep had already run, and adds `CM-TRUNCGRANT-024` over
> `tables_truncatable_by_client` and `CM-SCANINTEG-025` over the scan's own
> integrity totals. Three security controls could previously render `passing`
> against a scan that had declared itself untrustworthy. 285 escalates from the
> instances to the class: `tf_controls_signal_coverage()` reads the scan's
> declared axis list against the **catalog definition** of the consumer, not a
> register, per the seeded-register lesson of migration 276, and names any axis
> nobody renders. 286 exists because 285 created a `tf_*` function without a
> `tf_function_registry` row, which drove `CM-FNDRIFT-018` to `failing` and rolled
> the wiring migration back on its own aggregate assertion. That failure produced
> **the three obligations of creating a `tf_*` function** and **house rule
> seventeen**: a migration that touches the control register must assert the
> register's aggregate state before it commits, not just the row it changed. 287
> then wires the detector into `CM-SIGNALCOV-026` so the detector is not itself an
> unread signal. The register moved 23 controls with 1 failing to **26 with 0
> failing**. The reasoning, the prefix-collision gotcha, the five refusal codes
> and the runbook are in
> [`docs/CONTROL_SIGNAL_COVERAGE.md`](../../docs/CONTROL_SIGNAL_COVERAGE.md).

> **Migrations 253 through 257 are one change**, split into five so each half of
> the work could be asserted before the next was applied. They move guard
> detection out of `tf_security_scan`'s body and into
> `tf_guard_predicate_registry`, make the match run against comment-stripped
> source, add control `AC-GUARDREG-023`, wire the `safety:guard_detection`
> ticket, and prove the whole chain by inducing a comment-only guard and
> observing it caught. The design, the before-and-after code, the proof
> transcript and the operator runbook are in
> [`docs/GUARD_DETECTION.md`](../../docs/GUARD_DETECTION.md). Read that rather
> than the raw SQL: it carries the reasoning the SQL cannot.

> **Migrations 249 through 252 are checked into this directory in full**, as
> `<version>_<name>.sql`. They are the first migrations stored here verbatim
> rather than abbreviated to a row. Read them as worked examples of the anchored
> catalog-patch idiom and of the observed-refusal proof pattern. See
> `docs/AUTOMATION_ARMING.md` for what they change and why.

> **Ordinal reconciliation.** Ordinals here are the true
> `row_number() over (order by version)`. Some `rationale` strings stored inside
> the database during the 2026-07-25 build session reference an informal counter
> that runs behind this series (for example, `tf_function_registry` rows say
> "seeded at migration 233" for what is ordinal **239**,
> `tf_function_safety_audit_and_registry`). The same drift appears in the header
> comments written *inside* migrations 301 through 306, which use an informal
> counter running **two behind** the true ordinal: the migration whose body says
> "Migration 300" is true ordinal 301, and so on through the end of that batch.
> Where the two disagree, **the ordinal in this file is correct and the migration
> name is the unambiguous identifier**. Cite migrations by name.

> Note: rows are abbreviated for readability; `supabase db pull` writes every
> migration in full. The complete authoritative list is the Supabase migration
> history for project `kjooyhvynkzuvsixsutt`.

## Migrations 331-457 (restored from the live migration history)

| # | Version | Name |
|---|---------|------|
| 331 | 20260726102624 | talentflow_resumes_storage_bucket |
| 332 | 20260728121048 | tf_ops_report_daily_trailing_context |
| 333 | 20260728162309 | tf_connector_watch_monitor_v2 |
| 334 | 20260728162348 | tf_connector_watch_enum_cast_fix |
| 335 | 20260730210450 | tf_connector_watch_harden_defaults_and_grant |
| 336 | 20260806001936 | afo_phase1_foundation_tables |
| 337 | 20260806002225 | afo_phase1_functions_cost_consent |
| 338 | 20260806003214 | afo_phase1_emergency_scan_and_optout |
| 339 | 20260806004836 | afo_ai_model_provider |
| 340 | 20260806004954 | afo_ai_cost_precision_and_lead_scoring |
| 341 | 20260806010551 | afo_phase3_voice_tables |
| 342 | 20260806010645 | afo_phase3_voice_read_functions |
| 343 | 20260806010747 | afo_phase3_voice_write_functions |
| 344 | 20260806010902 | afo_phase3_voice_booking_and_lead_capture |
| 345 | 20260806010933 | afo_phase3_voice_finalize_and_sweep |
| 346 | 20260806012421 | afo_fix_voice_capture_lead_urgency_domain |
| 347 | 20260806013514 | afo_voice_call_upsert_monotonic_status_and_provider |
| 348 | 20260806013556 | afo_grant_tier_tf_voice_status_rank |
| 349 | 20260806014543 | afo_voice_resolve_window_from_offered_slate |
| 350 | 20260806021042 | afo_classify_boolean_param_conventions_voice |
| 351 | 20260806021322 | afo_phase3_cost_emitters_rate_card |
| 352 | 20260806021702 | afo_classify_p_carrier_leg_convention |
| 353 | 20260806021831 | afo_voice_cost_emit_breakdown_split |
| 354 | 20260806023124 | afo_consent_enforcement_layer |
| 355 | 20260806023500 | afo_communications_channel_allowlist_complete |
| 356 | 20260806032017 | tf_sms_dispatch_consent_chokepoint |
| 357 | 20260806032111 | gate_review_request_sweep_via_dispatch |
| 358 | 20260806032442 | gate_tf_cx_first_response_sweep_via_dispatch |
| 359 | 20260806032520 | gate_tf_cx_sequence_sweep_via_dispatch |
| 360 | 20260806032558 | gate_tf_engagement_sweep_via_dispatch |
| 361 | 20260806032623 | gate_tf_eta_reminder_sweep_via_dispatch |
| 362 | 20260806032712 | gate_tf_send_intake_via_dispatch |
| 363 | 20260806032735 | gate_tf_offer_job_via_dispatch |
| 364 | 20260806032925 | tf_sms_dispatch_add_caller_meta |
| 365 | 20260806033016 | engagement_sweep_appt_reminder_is_transactional |
| 366 | 20260806035256 | tf_rent_payment_settle_atomic |
| 367 | 20260806040522 | tf_sms_dispatch_from_number_routing |
| 368 | 20260806041456 | tf_staff_page_fallback |
| 369 | 20260806041916 | tf_staff_page_fallback_wiring |
| 370 | 20260806042225 | tf_page_staff_canonical_recipients |
| 371 | 20260806042250 | tf_page_staff_enum_cast_fix |
| 372 | 20260806042412 | route_sql_pages_through_tf_page_staff |
| 373 | 20260806044905 | m253_estimate_integrity |
| 374 | 20260806052325 | m254_rate_limit_and_idempotency_primitives |
| 375 | 20260806060159 | m255_dispatch_command_primitives |
| 376 | 20260806075310 | m256_config_atomic_merge |
| 377 | 20260806075350 | m257_config_atomic_merge_enum_cast_fix |
| 378 | 20260806103806 | m258_config_atomic_merge_section |
| 379 | 20260806105712 | m259_autoticket_dedup_is_structural |
| 380 | 20260806110345 | m260_autoticket_mark_primitive |
| 381 | 20260806110521 | m261_clickup_pending_apps_retry_aware |
| 382 | 20260806114048 | m261_cygeus_ai_spend_ledger_record_before_judge |
| 383 | 20260806121936 | m262_health_separate_service_availability_from_internal_posture |
| 384 | 20260806122140 | m263_tf_status_page_payload |
| 385 | 20260806122229 | m264_tf_status_page_per_component_incidents |
| 386 | 20260806122324 | m265_tf_status_page_incident_ordering |
| 387 | 20260806122412 | m266_tf_status_page_incident_current_status |
| 388 | 20260806123514 | m267_automations_failure_rate_and_incident_duration_gate |
| 389 | 20260806142445 | grant_tf_automation_arm_staff_tier |
| 390 | 20260806214953 | fix_commission_pct_unit_defect_and_technician_integrity |
| 391 | 20260806215029 | tf_offer_job_dry_run_must_not_write_offers |
| 392 | 20260806215802 | tf_hcp_technician_provision_with_convention33_declaration |
| 393 | 20260806220056 | tf_hcp_technician_adopt_historical |
| 394 | 20260806221006 | tf_integration_health_report_scoped_multitenant |
| 395 | 20260806221940 | tf_function_safety_audit_strip_row_lock_clauses |
| 396 | 20260806222157 | tf_function_safety_row_lock_pattern_class |
| 397 | 20260806225800 | studio_events_archive_ext_e2e_probes |
| 398 | 20260806225853 | archive_skeleton_check_probe_signups |
| 399 | 20260806230515 | gate_incomplete_studio_categories |
| 400 | 20260806232637 | reprice_paint_exterior_to_exterior_grade |
| 401 | 20260806233150 | tf_sync_preferred_brands_from_catalog |
| 402 | 20260806233638 | add_exterior_scope_pricing_modifiers |
| 403 | 20260806234310 | archive_hardening_pass_probe_events |
| 404 | 20260806234346 | archive_untagged_hardening_probe_events |
| 405 | 20260806235430 | add_missing_twilio_integration_settings_row |
| 406 | 20260807000730 | archive_final_regression_probe_events |
| 407 | 20260807000913 | m300_notification_status_values |
| 408 | 20260807001012 | m301_notification_delivery_scaffold |
| 409 | 20260807001237 | m302_page_staff_severity |
| 410 | 20260807001534 | m303_notification_drain |
| 411 | 20260807001614 | m304_drain_health_reports_own_delivery_and_cron |
| 412 | 20260807001748 | m305_fix_silent_slack_alert_failure |
| 413 | 20260807002306 | m306_notification_backfill |
| 414 | 20260807002616 | m307_provision_ops_number_and_internal_ops_consent_carveout |
| 415 | 20260807002813 | m308_fix_drain_delivered_channel_attribution |
| 416 | 20260807003207 | archive_verification_probes_final |
| 417 | 20260807004232 | temp_studio_prototype_write_for_screenshot_refresh |
| 418 | 20260807004255 | drop_temp_studio_prototype_write_policies |
| 419 | 20260807004733 | m309_close_voice_lookup_customer_pii_exposure |
| 420 | 20260807005746 | archive_probes_session_close |
| 421 | 20260807011443 | aisle_p1_01_tables |
| 422 | 20260807011604 | aisle_p1_03_consent_widening |
| 423 | 20260807070454 | m310_repoint_sms_sender_and_register_oncall_page_target |
| 424 | 20260807104958 | m311_revert_sms_sender_a2p_10dlc_unregistered |
| 425 | 20260807111657 | m312_acceptance_is_not_delivery |
| 426 | 20260807111758 | m313_no_retry_storm_and_slack_first_while_sms_unregistered |
| 427 | 20260807112218 | aisle_p1_02_functions |
| 428 | 20260807120650 | m314_hcp_job_push_reconcile |
| 429 | 20260807120835 | m315_close_anon_execute_on_session_functions_and_add_read_policies |
| 430 | 20260808231524 | m316_close_cygeus_link_user_to_org_privilege_escalation |
| 431 | 20260808231708 | m317_close_resolve_page_target_and_document_anon_allowlist |
| 432 | 20260809123841 | m318_platform_regression_suite |
| 433 | 20260809124833 | m319_automation_arm_guard_and_regression_suite_correction |
| 434 | 20260809125110 | m320_regression_suite_scheduled_and_ticketed |
| 435 | 20260809125319 | m321_regression_autoticket_literal_fix |
| 436 | 20260809130253 | tf_sql_code_only_lexer |
| 437 | 20260809131327 | m322_safety_audit_lexes_properly |
| 438 | 20260809133221 | m323_guard_detection_lexes_properly |
| 439 | 20260814004908 | add_shopify_integration_provider |
| 440 | 20260814005312 | add_shopify_order_anchor_to_jobs |
| 441 | 20260815003412 | m324_authenticated_definer_surface_governed |
| 442 | 20260815003547 | m325_regression_a15_authenticated_surface_ratchet |
| 443 | 20260815025528 | m326_fail_closed_billing_gate_and_canonical_portal_host |
| 444 | 20260815025644 | m327_regression_a16_billing_gate_and_canonical_host |
| 445 | 20260815092534 | create_rebate_programs_registry |
| 446 | 20260815092606 | tf_studio_project_to_estimate_bridge_v1 |
| 447 | 20260815092735 | tf_studio_project_to_estimate_split_material_labor |
| 448 | 20260815092850 | tf_studio_project_to_estimate_v3_creates_job |
| 449 | 20260815092940 | tf_studio_project_to_estimate_v4_generated_line_total |
| 450 | 20260815093550 | create_flow_assistant_sessions |
| 451 | 20260815093727 | create_flow_catalog_snapshot |
| 452 | 20260815100517 | m328_hcp_sync_incremental_stop_fabricated_schedules |
| 453 | 20260815101047 | m329_close_flow_catalog_snapshot_anon_surface |
| 454 | 20260815101419 | trade_attribution_backfill_with_provenance |
| 455 | 20260815223419 | m329_null_fabricated_schedules_and_forbid_them_structurally |
| 456 | 20260815224136 | m330_regression_a17_fabricated_schedule_ratchet |
| 457 | 20260816091237 | tf_studio_project_to_estimate_v5_onsite_verification |
