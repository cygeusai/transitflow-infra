# Function Grant Tiers

How `EXECUTE` privilege is decided, applied, checked and enforced on every
function in `public`.

**State captured 2026-07-25 at migration 264.** Introduced by migration 247
(`grant_tier_remediation`), made permanent by migration 248
(`grant_tier_drift_control`), given full surface coverage by migrations 258
through 261, and given **coverage enforcement** by migrations 262 through 264.
Control `CM-GRANT-021`. Ticket key `safety:grant_tier`.

The distinction between 258–261 and 262–264 is the whole point of this document.
The first block made the checker's coverage **complete and visible**. The second
block made it **enforced**: coverage below population is now a violation, and an
empty population is refused rather than certified.

---

## The problem this exists to solve

Supabase installs the following on every project, before any application code
exists:

```sql
alter default privileges in schema public
  grant execute on functions to anon, authenticated;
```

That is a **named-role** grant. It applies to every function created in `public`
from then on, automatically, with no author and no migration attributing it.

For years this repo used the idiom:

```sql
revoke all on function public.some_fn() from public;
```

`public` there is the PUBLIC pseudo-role. Revoking it does **not** touch grants
held by `anon` or `authenticated` by name. The revoke succeeds, the migration
applies cleanly, the author reasonably believes the function is locked down, and
an unauthenticated caller can still execute it.

Nobody did anything wrong. The hole is real anyway. That combination, a defect
with no author, is exactly the class this platform handles by making the
convention data and checking it continuously rather than by asking people to
remember.

The correct form is:

```sql
revoke all on function public.some_fn() from public, anon, authenticated;
grant execute on function public.some_fn() to postgres, service_role;
```

In practice, never write that by hand. See *Applying a tier* below.

### The Postgres-native twin of the same trap

Discovered while building the migration 260 fixture, and worth stating on its
own line because it defeats the obvious half-fix.

PostgreSQL itself grants `EXECUTE` to **PUBLIC** on every newly created
function, independently of anything Supabase installs. So a migration that
carefully revokes `anon` by name and stops there has closed nothing:

```sql
-- WRONG. anon still executes, through PUBLIC.
revoke execute on function public.some_fn() from anon;
```

`has_function_privilege('anon', oid, 'execute')` stays `true`, because privilege
resolution walks role membership and every role is a member of PUBLIC. Both
revokes are required, always, in one statement:

```sql
revoke all on function public.some_fn() from public, anon, authenticated;
```

The first attempt at migration 260 failed on exactly this. The fixture was
supposed to be reachable by `authenticated` and **not** by `anon`, and its own
setup assertion caught that `anon` could still reach it. The checker's proof
harness caught the trap on the person writing the proof. That is the harness
working.

---

## The three tiers

| Tier | Roles granted EXECUTE | In-body authorization predicate | Use when |
| --- | --- | --- | --- |
| `admin` | `postgres`, `service_role` | not required, the grant **is** the control | cron-driven work, anything that writes to a third party, anything that changes platform behaviour |
| `staff` | `postgres`, `service_role`, `authenticated` | **required, always** | operator read models and staff actions performed from the Hub |
| `anon` | `postgres`, `service_role`, `authenticated`, `anon` | required | a function an unauthenticated caller may safely run, referenced by a PUBLIC-role RLS policy |

Two rules follow from the table and neither is optional.

**A `staff` grant is not an authorization decision.** It only says an
authenticated session may reach the body. Who that session is, and whether they
belong to the company, is decided inside the body by
`public.user_is_internal_staff(cid uuid)`. A `staff`-tier function without that
predicate is an open door for any signed-up user in any tenant. This is why
`tf_security_scan()` carries the `secdef_authenticated_no_guard` axis and why
`AC-DEFN-017` exists.

**An `admin` grant is a complete control on its own.** `authenticated` cannot
reach the body at all, so there is nothing for a body predicate to protect
against. Admin-tier functions still commonly carry the cron-tolerant form
(`if auth.uid() is not null and not user_is_internal_staff(...) then raise`) as
defence in depth, but the grant is what actually holds.

---

## The coverage defect, and why 258 through 261 exist

Migration 248 shipped a working drift checker over **twelve declared rows**. It
was correct about everything it looked at. The problem was what it looked at.

`tf_grant_tier_audit()` measured three classes: drift on a declared tier, a
declaration pointing at a function that no longer exists, and an undeclared
function that `anon` could execute. Read those three together and the shape of
the hole appears:

> **Not declaring a tier was a way to never be checked for tier drift.**

The audit's own coverage was decided by the thing being audited. A function with
a declaration was held to its ACL forever. A function with no declaration was
invisible unless `anon` specifically could reach it, and on this platform `anon`
reaches almost nothing, so the undeclared class read zero and kept reading zero.
`violation_total: 0` was true and meant far less than it appeared to.

**Measured exposure at discovery**, before migration 258:

| Measurement | Value |
| --- | --- |
| `tf_*` functions in `public` | 84 |
| Carrying a declared tier | 18 |
| Untiered, therefore unchecked | 66 |
| Of those, reachable by `authenticated` | 27 |
| Of those, reachable by `anon` | 0 |
| Violations reported by the pre-258 audit | 0 |

Twenty-seven `SECURITY DEFINER` functions were reachable by every signed-in
identity in the system with no declaration stating that this was intended, and
the control watching for exactly that class reported green because none of them
happened to be reachable by `anon`.

### The decision not to demote

The tempting fix is to sweep the twenty-seven down to `admin` and revoke
`authenticated`. That was rejected deliberately.

Several of those functions are called by the Lovable frontend as the signed-in
operator. Revoking `authenticated` in a bulk migration would break the Hub at a
time and in a way nobody could attribute, which is the platform's definition of
quiet corruption. The house rule is *prefer loud failure to quiet corruption*,
and a silent frontend breakage is the opposite of loud.

The disciplined path taken instead, in four steps:

1. **Migration 258, `grant_tier_full_surface_declaration`.** Declare every
   `tf_*` function at its *current live reality*, not at an aspirational tier.
   The migration asserts that reachability did not change for a single function:
   before and after, the exact same set of roles can execute the exact same set
   of functions. It is a pure declaration migration with a proven zero-effect
   footprint.
2. **Migration 259, `grant_tier_audit_widen_undeclared_sweep`.** Widen the
   undeclared sweep from *reachable by `anon`* to *reachable by `anon` **or**
   `authenticated`*, and add `tf_population_total`, `tf_covered_total` and
   `coverage_pct` so the audit reports its own coverage in its own payload. The
   original `undeclared_anon_total` key is retained with its original meaning as
   a strict subset, so nothing downstream that reads it breaks.
3. **Migration 260, `grant_tier_coverage_induced_failure_proof`.** Prove the
   widened sweep catches the case the old one was blind to. Details below.
4. **Migration 261, `grant_tier_coverage_evidence_and_autoticket_widening`.**
   Update the two consumers that were still reading the narrow number. Details
   below.

Demotion is now a separate, evidence-driven decision that can be made one
function at a time, against a declaration that states what today's grant is.
Tightening a grant with a written record of what it used to be is a normal
change. Tightening it blind is an outage.

---

## Current tier assignments

**Eighty-five declared rows as of migration 261**: 48 `admin`, 36 `staff`,
1 `anon`. Eighty-four of those cover the eighty-four `tf_*` functions, giving
`coverage_pct` of 100.0. The eighty-fifth is `studio_is_staff`, which is not a
`tf_*` function but is declared anyway because it is the platform's one
deliberate anon exception.

The authoritative list is the table, never this document:

```sql
select tier, proname, ident_args, rationale
  from public.tf_function_grant_tiers
 order by tier, proname;
```

### `admin` — 48 functions

Cron-driven sweeps, third-party writers, ticket producers, platform mutators.
`authenticated` cannot reach any of them.

`tf_access_review`, `tf_ai_booking_kickoff_sweep`, `tf_apply_grant_tier`,
`tf_assign_job_number`, `tf_automation_arm`, `tf_automation_note_autoticket`,
`tf_capture_rating`, `tf_capture_rating_by_phone`, `tf_claim_job`,
`tf_clickup_pending_apps`, `tf_close_paid_jobs`, `tf_controls_evaluate`,
`tf_cx_first_response_sweep`, `tf_cx_sequence_sweep`, `tf_decline_offer`,
`tf_engagement_sweep`, `tf_eta_reminder_sweep`, `tf_governance_autoticket`,
`tf_grant_tier_autoticket`, `tf_guard_detection_autoticket`, `tf_guard_pattern`,
`tf_intake_sweep`, `tf_integration_health_report`, `tf_integration_watchdog`,
`tf_it_governance_report`, `tf_late_penalty_sweep`,
`tf_merge_duplicate_customers`, `tf_offer_job`, `tf_offer_sweep`,
`tf_platform_overview`, `tf_queue_discard`, `tf_queue_health`,
`tf_queue_requeue`, `tf_reliability_autoticket`, `tf_report_with_sync`,
`tf_request_ticket`, `tf_resolve_ticket`, `tf_review_request_sweep`,
`tf_safety_autoticket`, `tf_scheduler_health`, `tf_security_autoharden`,
`tf_slo_report`, `tf_sop_reminder`, `tf_strip_sql_comments`, `tf_system_health`,
`tf_upsert_lead_for_job`, `tf_user_can_manage_secrets`, `tf_vault_set_secret`.

Four of these deserve a note.

| Function | Why `admin` and not `staff` |
| --- | --- |
| `tf_automation_arm(p_key text, p_enable boolean)` | Flips customer-reaching automation flags. The only sanctioned arming path. Backend only. |
| `tf_apply_grant_tier(...)` | Executes GRANT and REVOKE. Security invoker, so it lends no privilege, but it has no business being reachable from the app. |
| `tf_vault_set_secret(...)` | Writes credentials. |
| `tf_safety_autoticket()` / the four other `*_autoticket` functions | Open and close ClickUp tickets over HTTP on a pg_cron schedule. An authenticated caller invoking one directly would create real tickets in a real workspace. |

Note that seven of the `admin` names read like diagnostics and write anyway:
`tf_access_review`, `tf_controls_evaluate`, `tf_integration_health_report`,
`tf_it_governance_report`, `tf_ops_report`, `tf_scheduler_health`,
`tf_system_health`. `tf_function_safety_audit()` reports them as
`misleading_total: 7`. The name is not the contract, `tf_function_registry` is.

### `staff` — 36 functions

Operator read models and staff actions performed from the Hub. **Every one of
these requires an in-body authorization predicate**, and `AC-DEFN-017` fails if
one is missing.

`tf_automation_blast_radius`, `tf_automation_note_drift`,
`tf_automation_out_of_band`, `tf_automation_readiness`,
`tf_boolean_default_hazards`, `tf_control_attest`,
`tf_convert_maintenance_request`, `tf_create_lead`, `tf_customer_360`,
`tf_customer_index`, `tf_cx_metrics`, `tf_data_quality_audit`,
`tf_draft_review_reply`, `tf_executive_snapshot`, `tf_fill_shortcodes`,
`tf_function_safety_audit`, `tf_generate_owner_statement`,
`tf_generate_owner_statements_for_period`, `tf_grant_tier_audit`,
`tf_guard_detection_audit`, `tf_link_revenue`, `tf_log_lead_cost`,
`tf_log_lead_spend`, `tf_marketing_roi`, `tf_nav_counts`, `tf_ops_report`,
`tf_owner_approve_maintenance`, `tf_owner_dashboard`, `tf_render_document`,
`tf_rent_payments_enabled`, `tf_resolve_late_penalty`,
`tf_revenue_linkage_audit`, `tf_run_metrics_export`, `tf_run_site_ingest`,
`tf_security_scan`, `tf_send_intake`.

Read paths in this list refuse by **return value**,
`{"ok": false, "error": "forbidden"}`. Mutating paths refuse by **raise**. That
split is deliberate: a dashboard that gets a forbidden payload can render an
empty state, whereas a write that silently returns a forbidden object and does
nothing looks like success.

`tf_send_intake` is the one on this list to be most careful with. It sends real
SMS to real customers through the Quo API. Any test of it must use reserved
fictional numbers, `(614) 555-0142` and `(614) 555-0143`.

### `anon` — 1 function

| Function | Why |
| --- | --- |
| `studio_is_staff()` | **The one deliberate exception.** Referenced by RLS policies whose role is PUBLIC, covering public reads on `studio_plans`, `studio_products`, `studio_product_categories` and `studio_conversion_credit_rules`. Revoking `anon` EXECUTE breaks the public storefront. |

`studio_is_staff` is in the table specifically so the checker treats it as
*declared* rather than reporting it as an undeclared anon-executable definer
function every fifteen minutes. A documented exception in a data table is a
decision. The same exception left undeclared is indistinguishable from a defect,
and it trains operators to ignore the alert.

---

## Applying a tier

```sql
select public.tf_apply_grant_tier(
  'tf_some_function',                    -- proname
  'p_key text, p_enable boolean',        -- identity arguments, '' for none
  'staff',                               -- admin | staff | anon
  'Why this tier and not a tighter one.' -- rationale, stored
);
```

The function revokes from `public, anon, authenticated` first, then grants the
tier's role set, then upserts the row into `tf_function_grant_tiers`
(`on conflict (proname, ident_args)`) so the declaration and the live ACL are
written in the same statement. Doing those two things separately is how they
drift.

The `ident_args` argument is `pg_get_function_identity_arguments(oid)`. Get it
right or the checker will report the declaration as pointing at a function that
does not exist:

```sql
select p.proname, pg_get_function_identity_arguments(p.oid) as ident_args
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'tf_some_function';
```

**Every migration that creates a `tf_*` function must end with a
`tf_apply_grant_tier` call, in the same transaction that creates the function.**
Since migration 259 this is enforced rather than advised: an undeclared function
reachable by `anon` or `authenticated` is a `CM-GRANT-021` violation within
fifteen minutes. A function created without a tier call is anon-executable by
default, which is the whole point of this document.

---

## Checking

```sql
select public.tf_grant_tier_audit();
```

### Violation classes, summed as `violation_total`

- **`drift_total`** — a declared tier whose live ACL no longer matches. Something
  granted or revoked outside `tf_apply_grant_tier`.
- **`missing_total`** — a declared tier naming a function identity that no longer
  exists. Usually a signature change that did not update the declaration.
- **`uncovered_total`** — **the gating class since migration 262.** Every `tf_*`
  function with no row in `tf_function_grant_tiers`, whether or not anybody can
  currently execute it. This is the class that makes the register complete by
  construction rather than by good intentions.

`violation_total` is `drift_total + missing_total + uncovered_total`. It is
**not** the sum of every key below, because two of them are strict subsets of
`uncovered_total` and adding them would double count:

- **`undeclared_reachable_total`** — the subset of `uncovered_total` reachable by
  `anon` **or** `authenticated`. This was the gating class between migrations 259
  and 262, and it is still the number that says how much privilege is actually
  exposed right now. It is what the platform's default privileges create on their
  own, and what an author creates by forgetting the tier call.
- **`uncovered_unreachable_total`** — the complementary subset, added by
  migration 262: undeclared and reachable by nobody today. Nothing has leaked,
  but the function is absent from the register the checker reads, so a future
  `GRANT` would drift unobserved. Being unreachable is not the same as being
  *intended* to be unreachable, and only the register records intent.

The two subsets must partition the shortfall exactly. The audit asserts this in
its own body and raises `tf_grant_tier_audit internal inconsistency` if they ever
disagree, on the reasoning that if three catalog predicates stop agreeing with
each other then every number the function returns is untrustworthy and loud
failure beats quiet arithmetic.

### Coverage keys, added by migration 259, enforced by migration 262

- **`tf_population_total`** — how many `tf_*` functions exist. 84 today.
- **`tf_covered_total`** — how many of them carry a declared tier. 84 today.
- **`coverage_pct`** — the ratio, `100.0` today. A checker that does not state
  its own coverage is asking to be trusted on the strength of a number whose
  denominator nobody wrote down.
- **`undeclared_anon_total`** — retained with its **original** meaning, a strict
  subset of `undeclared_reachable_total` counting only the `anon`-reachable
  cases. It reads 0 and has always read 0. It is kept because removing a key
  breaks consumers, and it is no longer what gates anything.

Each violation carries a `remedy` string containing the exact
`tf_apply_grant_tier` call that fixes it. Copy it, run it, re-run the audit.

### The empty-population refusal, added by migration 263

If `tf_population_total` comes back **zero**, the audit does not return. It
raises:

> `tf_grant_tier_audit refuses to certify: the tf_* population read from pg_proc returned zero functions. An empty population is a failed measurement, not full coverage. Emptying the input must never be a way to pass a control.`

Zero `tf_*` functions is not a clean platform, it is a catalog read that did not
do what it was asked. Before 263 that case returned `coverage_pct: null` beside
`violation_total: 0`, and `CM-GRANT-021` went green over a measurement that had
failed. This is the same shape as `x !~* null` and the same reason
`tf_guard_pattern()` is `plpgsql`: emptying the input must never be a way to pass
a control.

`tf_controls_evaluate` wraps the call in
`begin ... exception when others then v_gtj := null; end`, so the refusal
propagates as `null` and the control reports **`attention`**, never `passing`.
That wiring predates this migration and is asserted intact by migration 264.

**Live today:** `declared_total: 85`, `tf_covered_total: 84`,
`tf_population_total: 84`, `coverage_pct: 100.0`, `uncovered_total: 0`,
`uncovered_unreachable_total: 0`, `undeclared_reachable_total: 0`,
`violation_total: 0`.

### A PostgreSQL gotcha, documented because it cost time

`has_function_privilege(role, text, 'execute')` parses its second argument as a
**type list**. `pg_get_function_identity_arguments(oid)` returns parameter
*names* as well as types, for example `p_key text, p_enable boolean`. GRANT and
REVOKE accept that string happily. `has_function_privilege` raises
`invalid type name`.

The checker therefore resolves `pg_proc.oid` first and calls
`has_function_privilege(role, oid, 'execute')`. Never pass the identity-argument
string to a privilege function.

---

## Enforcement

Three layers, each of which fails independently of the others.

**Control `CM-GRANT-021`**, domain Change Management, owner CISO, automated.
Signal `tf_grant_tier_audit violation_total`. Mapped to SOC 2 `CC6.1`, `CC6.3`,
`CC8.1`; CIS v8 `3.3`, `6.8`; NIST CSF `PR.AC-4`, `PR.DS-5`. Evaluated on every
`tf_controls_evaluate()` run and wired into both the status CASE and the evidence
CASE.

Migration 261 widened the evidence string, because the old one stated the
violation count without stating the surface it was counted over, which is
precisely how the coverage defect stayed invisible for thirteen migrations.
Migration 264 widened it again, to state the shortfall and the exposed subset
separately and to name the two behaviours that are now enforced. It reads,
verbatim, today:

> `0 function grant-tier violation(s) across 84 of 84 tf_* fn(s) declared (100.0 pct), of which 0 undeclared and 0 of those reachable: live EXECUTE grants versus tf_function_grant_tiers, plus every tf_* fn with no declared tier whether reachable or not. Coverage is enforced since 262, and an empty population is refused rather than certified since 263`

A reader who sees `across 61 of 84` now knows the green is partial without
having to go and query anything, and a reader who sees `23 undeclared and 4 of
those reachable` knows immediately how much of the gap is live exposure and how
much is register debt. **A control's evidence must state its denominator, and
when it enforces something it must say so, because an operator reading evidence
at 2am is deciding how much to trust the green.**

**Ticket key `safety:grant_tier`**, produced by `tf_grant_tier_autoticket()`,
reached by `tf_safety_autoticket()` as section 4, driven by pg_cron job 46 at
minutes 7, 22, 37 and 52 of every hour. The ticket body carries the full finding
list, each with its remedy, plus the explanation of why grants drift on their
own.

Migration 261 widened this producer too, and it was the more dangerous of the
two. Before 261 the ticket body, the auto-close message and one return key all
read `undeclared_anon_total`. A real undeclared `authenticated`-reachable
function would therefore have opened a ticket whose body said
`Undeclared: 0`, and the auto-close message certified "zero undeclared
anon-executable definer functions", a property nobody was measuring against the
thing that had actually failed. The ticket now carries:

```
Undeclared (reachable by anon or authenticated, no declared tier): N
  of which anon-reachable: M
Undeclared in total (no declared tier at all, reachable or not): U
  of which reachable by nobody today: V
Surface measured: 84 of 84 tf_* function(s) carry a declared tier
```

The last two lines were added by migration 264, keeping the 261 lines exactly as
they were. The auto-close message names the surface it closed over and, since
264, certifies the enforced fact rather than the narrower one: it now reads *zero
`tf_*` functions carrying no declared tier at all, reachable or not*, where
before 264 it certified only *zero functions reachable by anon or authenticated
without a declared tier*. Closing a ticket on a narrower property than the one
the control now enforces is how a ticket queue drifts out of agreement with the
control register.

The return payload gained `undeclared_reachable_total`, `tf_covered_total` and
`tf_population_total` at 261, then `uncovered_total` and
`uncovered_unreachable_total` at 264, all **additively**, keeping
`undeclared_anon_total` intact, so no consumer of any earlier shape breaks.

**The `anon_secdef_nonpublic` axis of `tf_security_scan()`**, which catches the
same hole from the opposite direction and predates this work.

---

## How the checker was proved

Twice, by two different migrations, against two different defects. A checker
that returns zero on a clean database is indistinguishable from a checker that
returns zero always.

### Migration 248 proved drift detection

Inside its own transaction, committing only if every assertion held:

1. Assert baseline `ok: true` and `violation_total = 0`.
2. Deliberately open a hole:
   `grant execute on function public.tf_automation_arm(text, boolean) to authenticated;`
3. Assert `drift_total = 1`. The checker caught it.
4. Run `tf_controls_evaluate()`, assert `CM-GRANT-021` now reads `failing`. The
   control is genuinely wired, not merely seeded.
5. Revert: `revoke all on function public.tf_automation_arm(text, boolean) from authenticated;`
6. Assert `violation_total = 0` again, `CM-GRANT-021` back to `passing`, control
   board `failing = 0`.
7. Impersonate non-staff user `dddddddd-0000-4000-a000-0000000000d1` by setting
   `request.jwt.claims`, call `tf_grant_tier_audit()`, assert it returns
   `{"ok": false, "error": "forbidden"}`. Clear the claims.
8. Same impersonation against `tf_grant_tier_autoticket()`, assert it **raises**.
   Clear the claims.
9. Last, call `tf_safety_autoticket()` and assert the new `grant_tiers` key is
   present in its return shape.

Step 9 is last on purpose. It reaches ClickUp over HTTP, and nothing after it may
fail and roll back a transaction that has already created a ticket in a system
the rollback cannot reach.

Steps 7 and 8 are the ones people get wrong. `set local role authenticated` alone
does **not** make `auth.uid()` non-null. `auth.uid()` reads
`request.jwt.claims`. A guard test that sets only the role passes trivially and
proves nothing. The claims must be cleared afterwards with
`set_config('request.jwt.claims', '', true)` or every later call in the same
transaction runs as that non-staff user.

### Migration 260 proved coverage detection

Migration 248's proof induces drift on a **declared** function. It could not
have caught the coverage defect, because the coverage defect lives entirely in
the undeclared population. Migration 260 induces exactly the case the pre-259
sweep was blind to: a `SECURITY DEFINER` function, reachable by
`authenticated`, **not** reachable by `anon`, with no declared tier.

```sql
create function public.tf__granttier_fixture_undeclared()
returns int language sql stable security definer set search_path to 'public'
as $fx$ select 1; $fx$;

revoke all on function public.tf__granttier_fixture_undeclared()
  from public, anon, authenticated;
grant execute on function public.tf__granttier_fixture_undeclared()
  to authenticated;
```

The migration refuses to run at all if the audit reports any violation before the
fixture exists, if the population is implausibly small, or if coverage is not
already complete, because a post-fixture count would then be unattributable.

A fixture-setup assertion runs before anything else and checks
`has_function_privilege` for both roles. That assertion is what caught the
PUBLIC-grant trap described at the top of this document, on the first attempt.

Then, while the fixture is live:

1. The **pre-259 predicate**, the anon-only undeclared sweep, run inline against
   the catalog, returns **0**. If this assertion failed, the fixture would not be
   exercising the defect and nothing after it would mean anything.
2. `undeclared_reachable_total = 1`, and the `violations` array **names** the
   fixture. Counting it is not enough; an operator needs the name.
3. `undeclared_anon_total = 0`, confirming the retained subset key kept its
   original meaning and did not silently widen underneath its consumers.
4. `violation_total = 1`; `tf_population_total` is one higher than before;
   `tf_covered_total` is unchanged; `coverage_pct` falls below 100.
5. `tf_controls_evaluate()` then `CM-GRANT-021` reads **`failing`**.

The whole block sits inside `begin ... exception when others then v_err :=
SQLERRM; end`, and the `drop function` runs **after** that handler, so the
fixture is removed on every code path including every failure path. Only then is
`v_err` re-raised. Recovery is asserted afterwards: the fixture is gone from
`pg_proc`, population is back where it started, coverage is complete again,
`violation_total` is 0, and `CM-GRANT-021` reads `passing`.

### Migration 262 proved coverage *enforcement*, which is not the same thing

Through migration 261 the audit **reported** coverage and did not **enforce** it.
An untiered `tf_*` function that happened to be reachable by nobody fell out of
every violation class: `tf_covered_total` dropped, `coverage_pct` dropped, and
`violation_total` stayed at zero, so `CM-GRANT-021` stayed green. Coverage that
is reported but not enforced is a number on a dashboard, not a control.

Migration 260's fixture could not have caught this, because that fixture was
deliberately reachable by `authenticated`. Migration 262 induces the
complementary shape, the one nothing was watching: a real `tf_*` function, really
untiered, reachable by **nobody**.

```sql
create function public.tf__granttier_fixture_uncovered()
returns int language sql stable security definer set search_path to 'public'
as $fx$ select 1; $fx$;

revoke all on function public.tf__granttier_fixture_uncovered()
  from public, anon, authenticated;
```

Note the absence of a `grant`. Note also that the revoke names `public`, `anon`
and `authenticated` in one statement: a fixture-setup assertion refuses to
proceed if either role can still execute it, because a reachable fixture would be
caught by the 259 sweep and would prove nothing.

Every assertion is taken relative to a **measured baseline** read immediately
before the fixture is created, not against a constant somebody typed, so the
proof does not rot the next time the platform grows a function. While the fixture
is live:

1. `undeclared_reachable_total` is **unchanged**. This is the assertion that
   makes the migration meaningful: the 259 sweep, the state of the art one
   migration earlier, sees nothing wrong.
2. `uncovered_total` is baseline **+1** and `uncovered_unreachable_total` is
   exactly **1**.
3. `violation_total` is baseline **+1**, which is what `CM-GRANT-021` reads.
4. The `violations` array **names** the fixture, with `reachable_by: none` and a
   copy-pasteable `tf_apply_grant_tier` remedy. Counting is not enough.
5. `coverage_pct` falls below 100.

The fixture is then dropped, its absence from `pg_proc` asserted, and all four of
population, covered, uncovered and violation count asserted back at baseline.

### Migration 263 proved the empty-population refusal, on a derived clone

The refusal cannot be induced against the live function without dropping every
`tf_*` function on the platform, which is not a test, it is an outage. Pretending
otherwise, or asserting only that the branch *text* exists in the catalog, would
be a checker never observed catching anything.

Migration 263 instead builds a clone from the **live catalog text** by exactly two
mechanical substitutions: the `CREATE OR REPLACE FUNCTION` header is renamed to
`public.zz__granttier_refusal_clone()`, and the population `select count(*)` is
replaced with `v_population := 0;`. Both substitutions are asserted to have
landed, and the clone is asserted to still contain the refusal branch. The branch
under test is therefore the production branch, character for character, with one
input forced.

The clone is named **outside** the `tf_*` namespace deliberately, so that its
existence does not perturb the population it is testing.

Calling it must raise. The migration asserts three things: that it raised at all
rather than returning a result, that the message contains `refuses to certify`,
and that it contains `Emptying the input must never be a way to pass a control`.
The clone is then dropped, its absence asserted, and the live population asserted
back at its pre-proof value.

This is the weakest of the three proofs in this document and it is labelled as
such on purpose. It proves the logic on identical code with a forced input. It
does not prove that `pg_proc` can return zero rows, which is the point, since if
it ever does, something has gone far more wrong than a grant tier.

---

## Runbook

**Diagnose.**

```sql
select public.tf_grant_tier_audit();
select control_key, status, evidence from public.it_controls
 where control_key = 'CM-GRANT-021';
select tier, count(*) from public.tf_function_grant_tiers group by tier;
```

**If `coverage_pct` is below 100.** Somebody created a `tf_*` function without a
`tf_apply_grant_tier` call in the same migration. Find it:

```sql
select p.proname, pg_get_function_identity_arguments(p.oid) as ident_args,
       has_function_privilege('anon',          p.oid, 'execute') as anon_can,
       has_function_privilege('authenticated', p.oid, 'execute') as auth_can
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.prokind = 'f'
   and p.proname like 'tf/_%' escape '/'
   and not exists (
     select 1 from public.tf_function_grant_tiers t
      where t.proname = p.proname
        and t.ident_args = pg_get_function_identity_arguments(p.oid));
```

Read the body, decide the tier honestly, and declare it. Do not declare `admin`
reflexively if the Hub calls it; declare `staff` and confirm the body carries a
`user_is_internal_staff` predicate, or `AC-DEFN-017` will fail next.

Since migration 262 this is not optional housekeeping: `coverage_pct` below 100
means `uncovered_total` is non-zero, which means `violation_total` is non-zero,
which means `CM-GRANT-021` is **failing** and `safety:grant_tier` has an open
ticket naming the function. Read `undeclared_reachable_total` first to decide
urgency. Non-zero means privilege is exposed right now and the fix is same-day.
Zero, with `uncovered_unreachable_total` carrying the whole shortfall, means
nothing has leaked and the debt is a register entry, not an incident.

**If `CM-GRANT-021` reads `attention` with no evidence.** The audit raised rather
than returned, and `tf_controls_evaluate` propagated `null` instead of
substituting a zero. Run `select public.tf_grant_tier_audit();` directly and read
the error. If it is the empty-population refusal added by migration 263, the
`tf_*` population read back as zero, which is a catalog or search-path problem
and not a grant problem. Do not treat `attention` here as a softer `passing`; it
means the measurement did not happen.

**If `drift_total` is non-zero.** Somebody ran GRANT or REVOKE outside
`tf_apply_grant_tier`. The violation's `remedy` string restores the declared
state. Before running it, decide whether the declaration or the live grant is the
one that is wrong. The remedy assumes the declaration is right.

**If `missing_total` is non-zero.** A signature changed and the declaration was
not updated. Re-run `tf_apply_grant_tier` with the new `ident_args` and delete
the stale row.

**Never** edit `tf_grant_tier_audit` to add an exception. Add a declared row with
a written rationale, the way `studio_is_staff` is handled.

---

## Related

- `PLATFORM_KNOWLEDGE_BASE.md` — the guard model, conventions register,
  defect-pattern library
- `GUARD_DETECTION.md` — the sibling finding: a checker whose detection rules
  were wrong, found the same week and fixed the same way
- `SECURITY_GUARDS_AND_QUEUE_LANES.md` — the definer-guard axis and `AC-DEFN-017`
- `IT_GOVERNANCE_GRC.md` — the control register and attestation model

---

## The lesson worth carrying

`GUARD_DETECTION.md` closes on *verify the verifier*, and this finding is the
same lesson arriving from a different direction.

There, the checker's **rules** were wrong: it matched comments as if they were
code. Here, the checker's rules were right and its **coverage** was wrong, and
worse, the coverage was decided by the very population being checked. Opting out
of the register was opting out of enforcement, and the number that would have
revealed it, the denominator, was never printed anywhere a human would read it.

A checker must publish three things, not one: what it found, what it looked at,
and what it could not see. Transit & Flow now requires all three in the evidence
string of every automated control.

Migrations 262 through 264 add the sentence that turns that requirement into a
control rather than a habit. **Publishing coverage is not enforcing it.** Between
258 and 261 the denominator was printed in the evidence string and an operator
could see a shortfall, but nothing failed, nobody was paged, and no ticket
opened. A number that only a diligent reader acts on is a number that gets acted
on until the first busy week.

So the rule Transit & Flow carries forward is stricter than the one this document
opened with:

> A checker's own coverage is a violation class, not a statistic. If the register
> it reads is incomplete, the checker fails. If the population it reads is empty,
> the checker refuses. Neither case is allowed to be green, and neither case is
> allowed to be merely visible.
