# Migration Index

The full, ordered migration history of the Transit & Flow backend (277 migrations
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
> `tf_function_safety_audit_and_registry`). Where the two disagree, **the ordinal
> in this file is correct and the migration name is the unambiguous identifier**.
> Cite migrations by name.

> Note: rows are abbreviated for readability; `supabase db pull` writes every
> migration in full. The complete authoritative list is the Supabase migration
> history for project `kjooyhvynkzuvsixsutt`.
