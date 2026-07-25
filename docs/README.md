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
- [`FUNCTION_GRANT_TIERS.md`](./FUNCTION_GRANT_TIERS.md) — the three-tier `EXECUTE` model, the Supabase default-privileges trap and its Postgres-native PUBLIC twin, `tf_apply_grant_tier`, `CM-GRANT-021`, **the coverage defect closed by migrations 258 through 261** (a checker whose own coverage was decided by the population it was checking), and **the coverage enforcement added by migrations 262 through 264** (publishing a denominator is not the same as failing on it)
- [`AUTOMATION_ARMING.md`](./AUTOMATION_ARMING.md) — **read before arming anything that reaches a customer.** The thirteen-automation registry, the four-value bounding model, the blast-radius predicate contract, the eight-step arming sequence and its five refusal classes, and the copy-paste arm/disarm/audit runbook
- [`GUARD_DETECTION.md`](./GUARD_DETECTION.md) — **how the platform decides a `SECURITY DEFINER` function is guarded, and why that decision was wrong until migration 254.** The guard predicate registry, the comment-stripping match, the comments-gated / literals-advisory line, control `AC-GUARDREG-023`, the induced comment-only guard that proves the whole chain catches, and **the exemption-lever defect closed by migrations 265 through 267** (a scan whose denominator could be shrunk by anyone with insert access, with no counter in the payload saying so)
- [`FUNCTION_SAFETY_AUDIT.md`](./FUNCTION_SAFETY_AUDIT.md) — the fifteen-row signal-pattern table behind `CM-FNDRIFT-018`, **the null-that-is-not-false defect closed by migration 268** (a completeness guard that enumerated four of its five inputs, so deleting three rows silently collapsed the Vault-touching inventory from 18 functions to 1 under an `ok: true` payload), **the unheard refusal channel closed by migration 269** (five of six control consumers read past their checker's `ok` flag into a `coalesce(..., 0)`, turning every refusal into a green light), and the written reason `misleading_total` is published but deliberately gates nothing
- [`REGISTER_INTEGRITY.md`](./REGISTER_INTEGRITY.md) — **the checker that seeded its own oracle.** The trigger-function classifier blind spot closed by migration 275 (a function that `RETURNS trigger` is a write path by construction and contains no DML keyword for a pattern sweep to find, so `tf_assign_job_number` was classified a read while rewriting the identifier of every job the business creates), **the seeded-register finding it surfaced** (the register declaring it a read had been populated by the audit that read it, so the two had been agreeing with each other wrongly since migration 233), the catalog-validating triggers migration 276 attached to both registers, the four inductions that prove each refusal fires for the right reason, and the savepoint-probe technique for testing live behaviour with zero residue
- [`LEAST_PRIVILEGE_TABLE_GRANTS.md`](./LEAST_PRIVILEGE_TABLE_GRANTS.md) — **the privilege RLS does not gate.** `TRUNCATE` does not visit rows, so no policy can constrain it, and 172 of 173 tables granted it to `authenticated`; the revoke in migration 272, the `TRIGGER` / `REFERENCES` / `MAINTAIN` companions, the `supabase_admin` default-ACL residual that would silently restore it, the scanner axis added by migration 283 that now monitors it, and the evidence the hardening held when a different agent granted `anon` insert access four migrations later
- [`SECURITY_SCAN_INTEGRITY.md`](./SECURITY_SCAN_INTEGRITY.md) — **the scan that could not tell "hardened" from "empty".** `tf_security_scan()` published `gap_total` without ever declaring what it counted over, so zero gaps over an empty population was indistinguishable from zero gaps over a clean one. Migrations 280 through 283 add the `population` block and a hard `raise` on the empty case, derive `gap_total` by iterating the declared axis list so an axis cannot be declared and left out of the sum, add an `ok: false` refusal ladder, retire **the exemption that suppresses nothing** (a standing exemption over an already-guarded function is not redundant, it hides the finding the day the guard is removed), attach a validating trigger that refuses new ones, prove **the creation exposure window** at both ends (a `SECURITY DEFINER` function is reachable by `anon` and `authenticated` from `CREATE FUNCTION` until `tf_apply_grant_tier`), and add the sixth axis `tables_truncatable_by_client` alongside a decomposition that separates a table no client role can reach from one that is genuinely unpoliced

- [`CONTROL_SIGNAL_COVERAGE.md`](./CONTROL_SIGNAL_COVERAGE.md) — **detection without consumption is not a control.** A checker that finds something and publishes it has done nothing at all unless something downstream turns that publication into a status a human acts on. Migration 283 added a sixth detection axis and nothing read it; worse, `tf_controls_evaluate` had never honoured `tf_security_scan`'s `ok` flag because that flag landed in migration 280, after the migration 269 consumer sweep, so three security controls could render `passing` against a scan that had declared itself untrustworthy. Migrations 284 through 287 wire `CM-TRUNCGRANT-024`, `CM-SCANINTEG-025` and `CM-SIGNALCOV-026`, correct the `AC-RLS-001` false positive by weighing the reachable subset while keeping both numbers in evidence, and escalate from the instances to the class with `tf_controls_signal_coverage()`, which matches the scan's declared axis list against the **catalog definition** of its consumer rather than a register. Also: **the three obligations of creating a `tf_*` function**, **house rule seventeen** (assert the register's aggregate state, not the row you changed), and **the prefix-collision gotcha** that makes a bare substring match report a short axis name as read when only its longer sibling is referenced

- [`CONTROL_BOARD_FRESHNESS.md`](./CONTROL_BOARD_FRESHNESS.md) — **a control register is a cache of judgements, and a cache with no date on it is not evidence, it is decoration.** `it_controls.status` had no staleness concept, so the board could render an evaluation from any point in the past as current. Migrations 288 through 290 build `tf_controls_board()`, which publishes the register's age against the monthly cadence, names every automated control the evaluator has no status branch for, names every branch that **asserts** a status literal instead of computing one, and folds all three into one boolean, `authoritative`, read by `CM-BOARDFRESH-027`. Contains: **the write-timestamp trap** that killed the first design before a line was written (`last_evaluated_at` records when a row was written, not when it was judged, because the evaluator stamps every automated row from one `UPDATE` whose status CASE ends `else status end`, so `count(distinct last_evaluated_at)` reads 1 and a lag-based detector reports zero forever); **the tautological control** the second axis found on its first run, `when 'GV-CCM-016' then 'passing'`, where the control certifying continuous controls monitoring was a hardcoded constant that could never fail and carried the timestamp of its own write as evidence, left deliberately unfixed for one migration so the history records the machine finding it; **the self-stamping signal** (a freshness control must read the board before the evaluator's `UPDATE` or it scores its own write); and **the asserted textual splice**, the discipline for patching a large function through `pg_get_functiondef`

- [`CHECKER_AXIS_DECLARATION.md`](./CHECKER_AXIS_DECLARATION.md) — **a detector that does not say what it detects cannot be audited for whether anyone is listening.** The previous batch proved that detection without consumption is not a control, over a sample of one checker. Migrations 291 through 306 generalise it: every checker now **declares** the signals it expects a control to read, and the coverage detector verifies those declarations against the evaluator across a ten-checker roster with twenty-four axes, zero unread. Declaration replaced inspection because an inspecting detector cannot tell a **finding** from a **population**, so it demands consumers for denominators and the natural remedy is a fake control. Contains: **an axis is the consumption surface**; the **three couplings** every checker's tail asserts; the **roll-up axis rule** (a roll-up may stand in for its primitives only if the checker asserts the identity, or a roll-up is where findings disappear); the **strict counter-read needle** `coalesce((<var>->>'<axis>')::int`, which defeats both the axis name-collision blind spot and the narrative-versus-status blind spot that a bare `strpos` cannot; **the swallowed refusal**, house rule twenty, where `exception when others then v_gap := 0` turns an unrunnable check into a passing control and the board goes green *because* the detector broke, now enforced by a pre-install regex; **declare on every success path**, where an early return that ships no axes is a conditional declaration and therefore no declaration at all; and the largest finding, **whether a function is a checker is not a property of its name, it is a property of whether the consumer reads a counter out of it**, which caught `tf_controls_board` having been an undeclared checker since migration 288 and stopped the platform certifying 100 percent coverage over a population silently narrowed by two

- [`DECLARATION_ENFORCEMENT.md`](./DECLARATION_ENFORCEMENT.md) — **detected and enforced are not the same guarantee.** Convention 33 says creating a `public.tf_*` function carries three obligations in the same migration, and until migration 307 only the first, applying a grant tier, was structurally enforced. The second, declaring the function in `tf_function_registry`, was detected monthly, which means the registry could be wrong for up to a month and everything downstream of it with it. Migrations 307 through 309 make it impossible instead. Contains: **the design the catalog killed before a line was written** (refusing at `CREATE FUNCTION` time requires the declaration to come first, and `tf_function_registry_validate` refuses a row for a function that does not exist yet, so no statement ordering satisfies both and enforcement had to move to the transaction boundary); **the proof that `apply_migration` is transactional**, which is what makes "the same migration" mean "the same transaction" and makes every end-of-migration assertion block in this repository a genuine pre-commit gate; **the queue plus deferred constraint trigger idiom**, where a `ddl_command_end` event trigger only ever enqueues and a `DEFERRABLE INITIALLY DEFERRED` trigger refuses at `COMMIT`, fail-closed because it re-reads the registry rather than trusting the queue; **a refusal that teaches the correct ordering** rather than just saying no; **enforcement whose own presence is a monitored axis**, so the `ALTER EVENT TRIGGER ... DISABLE` kill switch cannot be used quietly; the three probes that prove the guard refuses, does not over-fire, and produces a **falsifiable** control; and control `CM-FNDECL-028`, the first row in this register that certifies an impossibility rather than an observation

## Interactive artifacts (this folder)
Self-contained HTML. Open directly in a browser, no build step, no network.
- [`COMMAND_CENTER.html`](./COMMAND_CENTER.html) — executive command center
- [`ONCALL_RUNBOOK.html`](./ONCALL_RUNBOOK.html) — operations & on-call runbook
- [`data-engineering-report.html`](./data-engineering-report.html) — data-engineering assessment
- [`data-model-erd.html`](./data-model-erd.html) — entity-relationship diagram

## Conventions
- A checker must publish the population it counted over. A gap count with no
  denominator cannot distinguish "hardened" from "blind", and a checker whose
  population comes back empty must raise rather than return zero.
- Apply the grant tier in the **same migration** that creates the function. A
  `SECURITY DEFINER` function is executable by `anon` and `authenticated` from
  `CREATE FUNCTION` until `tf_apply_grant_tier` runs. Inside one transaction that
  window is invisible; split across two migrations it is a live exposure.
- An exemption must suppress something. A standing exemption over an already
  guarded function hides the finding the day the guard is removed.
- Decompose a checker's counts, never narrow them. Add the refined subset beside
  the original key so every existing consumer keeps reading the same number.
- Every axis a checker declares must have a consumer that renders it. Detection
  without consumption is not a control, it is a log line. When a checker gains an
  axis, the same batch wires it to a control row.
- A checker that reports on refusals must not be gated on its own refusal flag,
  or the failure it exists to surface silences it.
- Creating a `tf_*` function carries three obligations in the same migration:
  apply a grant tier, declare it in `tf_function_registry`, and wire its signal
  into a control. Only the first is structurally enforced today.
- A migration that touches the control register asserts the register's
  **aggregate** state before it commits. A per-row assertion cannot see a
  cross-control regression.
- A control's status branch must **compute** a status, never assert one. A branch
  that reads `then 'passing'` is not a judgement, it is a decoration that
  survives every failure it exists to detect.
- A signal must not be produced by the act of evaluating it. A freshness reading
  taken after the write it measures is always zero. Read the prior state first,
  then stamp.
- A stored status is a cache. Publish its age beside it, against a stated
  threshold, or a reader cannot tell a current judgement from an abandoned one.
- Patching a function through `pg_get_functiondef` and `replace` is legitimate
  only when every anchor is first asserted to occur **exactly once**. An anchor
  matching zero or two places must refuse the whole migration, not splice
  silently.
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
- Revoking `anon` alone is **also** not sufficient, for a second and independent
  reason. PostgreSQL itself grants EXECUTE to PUBLIC on every newly created
  function, so `has_function_privilege('anon', oid, 'execute')` stays true after
  `revoke execute ... from anon` because every role is a member of PUBLIC. Both
  revokes must appear in one statement:
  `revoke all on function ... from public, anon, authenticated`. Migration 260's
  fixture-setup assertion caught this on its own author.
- A checker must publish what it found, what it looked at, and what it could not
  see. `tf_grant_tier_audit` counted violations correctly over twelve declared
  rows out of eighty-four functions and reported `violation_total: 0`, because
  **not declaring a tier was a way to never be checked for tier drift**: the
  checker's coverage was decided by the population it was checking. Any register
  that a checker reads must be complete by construction, the audit must return
  its own coverage (`tf_population_total`, `tf_covered_total`, `coverage_pct`),
  and the control's evidence string must state its denominator. See
  `FUNCTION_GRANT_TIERS.md`.
- A checker's own coverage is a violation class, not a statistic. Publishing a
  denominator is not the same as failing on it. Between migrations 258 and 261
  `tf_grant_tier_audit` printed `coverage_pct` in the evidence string and an
  operator could see a shortfall, but nothing failed and no ticket opened, so the
  shortfall was visible and inert. Migration 262 folded `uncovered_total` into
  `violation_total`: an undeclared function is now a violation whether or not
  anyone can call it, because being unreachable is not the same as being
  *intended* to be unreachable and only the register records intent. A number
  that only a diligent reader acts on is a number that gets acted on until the
  first busy week.
- A checker must refuse on an empty population, not certify one. Zero rows is a
  failed measurement, not a clean result. `tf_grant_tier_audit` raises rather
  than returning when the `tf_*` population reads zero, `tf_controls_evaluate`
  propagates the raise as `null`, and the control reports `attention` rather
  than `passing`. This is the same rule as `tf_guard_pattern()` refusing a null
  pattern from an empty registry, applied to a count instead of a regex.
- Where a failure cannot be induced against the live object without breaking the
  platform, prove it on a **clone derived from the live catalog text** by
  asserted mechanical substitutions, and name the clone outside the namespace
  being measured so the proof does not perturb its own population. Assert that
  each substitution landed and that the branch under test survived into the
  clone. Label such a proof as weaker than an induced one, in the document, in
  writing. Migration 263 does this for the empty-population refusal.
- Every lever that shrinks what a checker measures must appear in what the
  checker reports. `tf_guard_detection_audit` published a scanned count of 55 and
  said nothing about the 57 definer functions actually reachable or the two
  excused into `security_scan_exemptions`, a table with no cardinality limit and
  no approval workflow beyond a text column. That made inserting a row the
  cheapest way to stop an unguarded function being reported, and made the drop
  look like the population had simply shrunk. Since migration 265 the audit
  publishes `reachable_total`, `exempted_total` and `exempted_fns`, asserts
  `reachable = scanned + exempted` in its own body, and treats an exemption
  naming nothing real as a gating violation. Since 266 it refuses an emptied
  population, and since 267 the decomposition is on the control board. Ask of any
  checker with an exemption, skip or ignore list: if somebody adds everything to
  it, what does this report? If the answer is "success", the list is the attack.
- A refusal must cover every input the checker reads, and every consumer of a
  refusal must listen to it. `tf_function_safety_audit` guarded four of its five
  signal classes; because `body ~* null` is null rather than false, the unguarded
  fifth could be deleted silently and every function on the platform read as not
  touching the Vault. Since migration 268 the guard names all five and returns
  `missing_signals`. On the consuming side, five of six checker consumers in
  `tf_controls_evaluate` read past `ok: false` into a `coalesce(..., 0)`, and zero
  is the value that means healthy, so a checker that had declined to answer
  rendered `passing`. Since migration 269 all six null out on
  `coalesce(payload->>'ok','false') <> 'true'`. Grep for any
  `coalesce(x->>'k', 0)` where `x` also carries an `ok` key; that is the shape.
  Building a refusal is half the work, walking the call graph is the other half.
- Widen a signal, never repurpose a key. When migration 259 widened the
  undeclared sweep, `undeclared_anon_total` kept its original meaning as a strict
  subset and `undeclared_reachable_total` was added beside it. Redefining a key
  in place silently changes what every existing consumer believes it is reading,
  and the consumers do not fail, they just become wrong.
- A guard never observed refusing is not a guard, and a checker never observed
  catching anything is not a checker. Induce the failure in the same transaction
  and assert on the catch. Note that `set local role authenticated` alone leaves
  `auth.uid()` null; a guard test must set `request.jwt.claims` and clear it
  afterwards. That is also the strongest induction lever on the platform:
  `set_config('request.jwt.claims', '{"sub":"<non-staff uuid>","role":"authenticated"}', true)`
  makes every read-path `forbidden` guard fire at once, live, inside a migration,
  which is how migration 269 demonstrated its defect before the patch and its fix
  after it in a single transaction with no clone anywhere in the load-bearing arm.
  `set_config(..., '', true)` clears it, because the empty string passes through
  `nullif` to null.
- Conventions live in tables, checkers read the tables. A detection rule compiled
  into a function body can only be changed by someone willing to rewrite that
  function. See `tf_function_safety_patterns`, `tf_boolean_param_conventions`,
  `tf_automation_registry`, `tf_function_grant_tiers`,
  `tf_guard_predicate_registry`.
- Guard detection is data, and it matches executable code, not source text.
  `tf_security_scan` builds its guard pattern from `tf_guard_predicate_registry`
  and matches it against `tf_strip_sql_comments(pg_get_functiondef(oid))`. A
  guard-helper name that appears only in a comment used to satisfy the check
  without guarding anything. Never add a helper name by editing the scanner;
  insert a registry row. `AC-GUARDREG-023` fails the moment an inline
  alternation reappears in the scanner body. See `GUARD_DETECTION.md`.
- `x !~* null` is null, not true. Any checker that builds its pattern from a
  table must refuse to run on an empty table rather than return null, because a
  null pattern makes every row pass and turns the control green while it
  protects nothing. `tf_guard_pattern()` is `plpgsql` for this one reason.
  Emptying a table must never be a way to pass a control.
- A control must never pass because its own evaluation crashed.
  `tf_controls_evaluate` wraps every audit call it makes, propagates `null`
  rather than `0` when a call raises, and reports `attention` on null. A zero
  substituted for a failed measurement is a false green.
- Never string-splice prose into a generated function body. Every quote needs
  doubling twice and every escape needs escaping twice. Put the prose in its own
  function and splice in the call.
- Automation flags flip only through `tf_automation_arm`. A direct `update` on
  `integration_settings` is detected as out-of-band and treated as an incident.
- Every sweep carries a company predicate. A sweep that scans a shared table
  with no `company_id = v_company` filter is a cross-tenant send waiting for the
  flag to flip, and the enable flag it reads must be scoped the same way.
  Migration 249 closed three such sweeps; migration 250 closed two more settings
  reads the first pass missed.
- Every automation declares how it is bounded. `tf_automation_registry.bounded_by`
  takes one of four values: `cutover` (a config key pins the start),
  `natural_window` (the predicate has a moving time bound of its own),
  `unbounded` (neither, so the first tick processes all history), or
  `edge_function` (the work happens outside Postgres and SQL cannot size it).
  `tf_automation_arm` refuses to arm an `unbounded` automation while its blast
  radius is non-zero. See `AUTOMATION_ARMING.md`.
- A blast-radius predicate must reference **both** `$1` and `$2`. The registry
  executes every predicate as `using coalesce(v_since, now()), v_company`, and
  PL/pgSQL raises `too many parameters specified for EXECUTE` if a predicate
  ignores one. Where a sweep has no cutover bound, reference `$1` through the
  visible tautology `and ($1::timestamptz is not null or $1::timestamptz is null)`
  rather than dropping it.
- The registry note is part of the change, not documentation of it. A migration
  that alters a sweep, a predicate or a bounding must rewrite the matching
  `tf_automation_registry.notes` in the same transaction. The note is projected
  into `tf_automation_readiness()` and is the text an operator reads at the
  moment they decide whether to arm a customer-reaching automation.
  `tf_automation_note_drift()` and control `CM-NOTEDRIFT-022` fail when a note
  contradicts the catalog.
- A migration that creates a function must declare it in `tf_function_registry`
  and `tf_function_grant_tiers` in the same migration. Migration 251 created
  `tf_automation_note_drift` without declaring it, and `tf_function_safety_audit`
  reported `undeclared_total = 1` within minutes. That is `CM-FNDRIFT-018`
  working, but the register should never have drifted in the first place.
- Prove a guard by inducing the failure and forcing the rollback. When the
  trigger condition does not exist in live data, insert a synthetic row that
  forces it, observe the refusal, then delete the fixture. Wrap the attempt in a
  subtransaction that raises its own sentinel exception on success, so the
  mutation rolls back under every code path, and assert afterwards that the
  fixture did not survive and the row count is back where it started.
- Use a single `%` per argument in **every** `raise` format string. `%%` is a
  literal escaped percent that consumes zero arguments, so the statement fails
  with `42601: too many parameters specified for RAISE`. This bites hardest
  inside an anchored catalog patch, where there is **no format-string doubling
  layer**: a `%%` written into a `replace()` payload lands as a literal `%%` in
  the function source. But the rule is not specific to patches. Write `%`.
- Inside a dollar-quoted literal (`$j$ ... $j$`) single quotes are **literal and
  must not be doubled**. Doubling produces two literal apostrophes in the stored
  text. This is the exact inverse of the ordinary quoted-string rule, and it is
  easy to get wrong when moving a JSON payload between the two forms.
- Name the real arbiter in `on conflict`. `it_controls` carries
  `UNIQUE (control_key)`, not `(company_id, control_key)`; guessing the composite
  raises `42P10: there is no unique or exclusion constraint matching the ON
  CONFLICT specification`. Query `pg_constraint` before writing an upsert against
  a table this session has not already written to, the same way you query
  `information_schema.columns` before writing a select.
