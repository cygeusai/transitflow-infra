# Checker Axis Declaration

**Migrations 291 through 306. Transit & Flow platform data layer.**

**Thesis: a detector that does not say what it detects cannot be audited for
whether anyone is listening.**

The preceding batch (284 through 287) established that detection without
consumption is not a control, and built one detector, `tf_controls_signal_coverage`,
to prove it over a single checker. This batch generalises that result. It makes
every checker on the platform declare, in machine-readable form, the exact set of
signals it expects a control to read. It then rebuilds the coverage detector so it
tests that declaration against the evaluator for the entire roster, not for one
member of it.

The outcome is a closed loop with a stated denominator: ten checkers, twenty-four
declared axes, zero unread, zero undeclared, zero unmeasured, zero unrostered
callees, zero refusal-ungated checkers.

> **Roster since this batch.** Migration 309 added
> `tf_declaration_enforcement_audit` as the eleventh checker, taking the live
> figures to **eleven checkers and twenty-five axes**, still zero unread. The
> ten-and-twenty-four numbers throughout this document are the state at the close
> of migration 306, which is what the reasoning below was worked out against. For
> current figures read the checker, not this file. See
> [`DECLARATION_ENFORCEMENT.md`](./DECLARATION_ENFORCEMENT.md).

---

## Why declaration, and not inspection

Before this batch the coverage detector inferred a checker's signals by reading
its payload keys and filtering for things that looked like counters. That is
inspection, and inspection has a failure mode that is fatal for a control: it
cannot distinguish a number the checker publishes as a **finding** from a number
it publishes as **population**, **complement**, or **narrative colour**.

Consider `tf_automation_out_of_band`. It publishes `enabled_total` and
`out_of_band_total`. Only the second is a finding. The first is the denominator
the finding is measured against. An inspecting detector that treats both as axes
demands that a control consume `enabled_total`, which no control should, and the
platform is then permanently one axis short of full coverage for a reason that is
an artefact of the detector rather than a real gap. Teams respond to that by
adding a fake consumer, and the register now contains a control that exists to
satisfy a checker rather than to protect the business.

Declaration inverts the burden. The checker, which is the only code that knows
what its numbers mean, states its own axes. The detector's job stops being
semantic guessing and becomes a mechanical question with a correct answer: for
each declared axis, does the evaluator actually read it?

**Convention: an axis is the consumption surface.** An axis is a signal a control
is expected to READ. It is not an inventory of everything the checker counts.

---

## The migration set

True ordinals, verified live against `supabase_migrations.schema_migrations` with
`row_number() over (order by version)`.

| Ordinal | Version | Name |
|---|---|---|
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

**Ordinal reconciliation.** The header comments written inside migrations 301
through 306 use an informal counter that runs two behind the true ordinal. The
migration whose body says "Migration 300" is true ordinal 301, and so on through
the batch. This is the same class of drift already recorded for earlier batches in
`MIGRATIONS_INDEX.md`. The rule stands: **the ordinal in the index is correct and
the migration name is the unambiguous identifier. Cite migrations by name.**

---

## The checker roster

A checker is a function whose numbers drive a control's status. The roster is
declared in the body of `tf_controls_signal_coverage` itself, never in a side
table, per the seeded-register convention established in migration 276.

| Checker | Evaluator variable(s) | Declared axes |
|---|---|---|
| `tf_security_scan` | `v_scan`, `v_scan_raw` | 6 |
| `tf_grant_tier_audit` | `v_gtj` | 1 roll-up (`violation_total`) plus 4 component axes |
| `tf_function_safety_audit` | `v_fnaud` | 4 |
| `tf_guard_detection_audit` | `v_gdj` | 5 |
| `tf_automation_note_drift` | `v_ndj` | 1 (`drift_count`) |
| `tf_boolean_default_hazards` | `v_boolh` | 2 (`hazard_total`, `unclassified_total`) |
| `tf_automation_out_of_band` | `v_oobj` | 1 (`out_of_band_total`) |
| `tf_data_quality_audit` | `v_dqj` | 1 (`total_issues`) |
| `tf_controls_board` | `v_board` | 2 (`unscored_total`, `tautological_total`) |
| `tf_controls_signal_coverage` | `v_sigcov` | 1 roll-up (`gap_total`) plus 5 component axes |

Twenty-four axes total. One function, `tf_controls_evaluate`, is explicitly
rostered as a non-checker: the evaluator calls itself in its own CREATE header and
that match must not be mistaken for an unrostered callee.

---

## The three couplings

Every checker in this batch was given the same tail. The tail is not decoration.
Each of its three assertions closes a specific way a declaration can be true and
useless at the same time.

**Coupling one: every declared axis must appear in the payload.** A checker that
declares an axis it does not publish has produced a promise the detector will
faithfully verify against a key that is never there. The tail asserts membership
of each element of `v_axes` in the returned object before returning it.

**Coupling two: every non-gating key must carry a written rationale.** The
`v_non_gating` object maps each published counter that is deliberately not an axis
to a sentence explaining why. `enabled_total` reads: *"Population, not findings.
The count of automations currently switched on. out_of_band_total is the subset of
that population which reached the on state without passing through
tf_automation_arm."* This is the mechanism that makes "not an axis" a decision on
the record rather than an omission.

**Coupling three: every counter must be classified.** The tail sweeps the payload
for keys matching the counter naming conventions and asserts each one is either a
declared axis, a component axis, or an explained non-gating key. Nothing may be
published unclassified. This is what stops a future edit from adding a finding
counter that silently escapes the coverage requirement.

The sweep pattern is `k like '%\_total' or k like '%\_count'`, widened in
`tf_data_quality_audit` to include `or k like '%\_issues'`.

**Convention: counter suffix coverage.** *A classification rule that only
recognises one naming convention does not classify, it filters.* Migration 295
found this the hard way: a sweep for `_total` alone silently passed
`drift_count`, meaning the checker whose only finding was a `_count` had a
classification assertion that examined zero keys and therefore always passed.

---

## The roll-up axis rule

Two checkers publish a single number that stands for several. `tf_grant_tier_audit`
publishes `violation_total`; `tf_controls_signal_coverage` publishes `gap_total`.

Declaring only the roll-up is legitimate and often preferable, because a control
that reads one number and goes red is easier to reason about than a control that
reads five. But it is legitimate **only under a condition**, and the condition has
to be enforced in code:

**Convention: the roll-up axis rule.** *A checker may declare a roll-up as its
axis instead of its primitives, but only if the checker asserts, in its own body,
that the roll-up equals the sum of the primitives it stands for.*

Without that assertion, a roll-up is a place for findings to disappear. Add a
sixth primitive to the coverage detector, forget to add it to the sum, and
`gap_total` stays at zero while the platform grows a blind spot. The identity
assertion turns that mistake into a migration failure at install time. Both
roll-up checkers publish their primitives as `component_axes` and assert the
identity before returning.

---

## The strict counter-read needle

The coverage detector answers one question per (checker, axis) pair: does the
evaluator read this axis? The obvious implementation is `strpos(v_eval_def,
axis_name) > 0`. That implementation is wrong in two directions, and both showed
up live.

**The axis name-collision blind spot.** `drift_total` is published by both
`tf_grant_tier_audit` and `tf_function_safety_audit`. A bare textual search for
the axis name finds a hit no matter which checker's variable produced it, so
either checker can be certified as read on the strength of the other's consumer.

**The narrative-versus-status blind spot.** `strpos` over a whole function
definition cannot distinguish a signal read into a status branch from one
interpolated into a human-readable evidence string. A checker whose only textual
appearance is inside a `format()` call that builds a note for a dashboard is not
being consumed by a control at all, and yet it passes.

Both are defeated by one needle, which requires no region parsing:

```
coalesce((<variable>->>'<axis>')::int
```

The variable qualifier defeats the collision because the needle is built from the
checker's own evaluator variable. The `coalesce(...)::int` shape defeats the
narrative case because that is the form a numeric read into a comparison takes,
and it is not the form used to interpolate a value into a string. Verified live
across all twenty-four (checker, axis) pairs on the ten-checker roster: all
twenty-four pass.

A related trap, worth stating because it cost time on an earlier batch: **the
prefix-collision gotcha.** Textual coverage checks must match the identifier
wrapped in single quotes, not bare, or `unread_total` matches inside
`unread_total_prior` and every other name that contains it.

---

## Four defects this batch found and closed

### The swallowed refusal

An exception handler that defaults a gap counter to zero converts an unrunnable
check into a passing control.

This is the most dangerous shape in the whole governance layer, because it fails
in exactly the direction that produces silence. The checker throws, the handler
catches, the counter is set to `0`, the control reads zero gaps and reports green.
The board is now green *because* the detector is broken.

**Zero is the passing branch. Null is the attention branch.** A counter that could
not be computed must be null, and the consumer must treat null as unmeasured
rather than clean. Migration 297 rebuilt `tf_data_quality_audit` to refuse by
return value rather than by exception, migration 298 taught the evaluator to treat
a refused data-quality audit as unmeasured, and migration 299 made system health
report an unavailable probe as degraded rather than operational.

It is also enforced structurally. Every subsequent migration in this batch runs a
regex guard over the function body before installing it:

```sql
if v_new ~ 'exception when others then[^;]*:=\s*0\s*;' then
  raise exception 'migration NNN: refusing to install a handler that defaults a gap counter to zero';
end if;
```

### Declare on every success path

A checker with an early return that bypasses the payload tail declares
conditionally, which is the same as not declaring.

`tf_automation_out_of_band` had a legitimate early return for the case where no
`openphone` settings row exists for the company. That path returned a well-formed
payload with zero counts and no `axes` key. Under normal conditions the checker
declared correctly; under the specific condition of a missing settings row it
declared nothing, and the coverage detector would have recorded it as undeclared
at exactly the moment the platform was least able to explain why.

Migration 301 converted the early return into an assignment that falls through to
the shared tail, so both branches build `v_out` and both exit through the single
declaring return. Migration 302 then enforced the structure rather than the
instance, by counting return statements in the installed definition:

```sql
if v_returns <> 2 then
  raise exception 'tf_automation_out_of_band has % return statements. Exactly 2 are permitted, the refusal and the declaring tail. A third return is a success path that ships no axes, which is a conditional declaration and therefore no declaration at all.', v_returns;
end if;
```

### Whether a function is a checker is not a property of its name

This is the largest finding in the batch. It is a property of whether the consumer
reads a counter out of it.

The inherited state asserted eight checkers and three non-checkers. Reading
`tf_controls_evaluate`'s actual use of `v_board` showed
`coalesce((v_board->>'unscored_total')::int,0)` and
`coalesce((v_board->>'tautological_total')::int,0)` driving the status of
`CM-BOARDFRESH-027`. By the only test that matters, `tf_controls_board` had been a
checker since migration 288 and had never declared an axis. The same test proved
`tf_controls_signal_coverage` is itself consumed, via
`coalesce((v_sigcov->>'gap_total')::int,0)`.

Had the roster been written from the inherited classification, the platform would
have certified one hundred percent coverage over a population silently narrowed by
two, which is precisely the failure the undeclared-denominator convention exists to
prevent. The roster was corrected to ten before it was written into the generalised
checker. Migration 303 gave `tf_controls_board` its axes via a three-anchor
asserted textual splice.

### The undeclared denominator, restated

A checker publishing a gap count with no population statement cannot distinguish
"hardened" from "blind". Every checker in this batch publishes its population
alongside its findings, and `tf_controls_signal_coverage` publishes
`checkers_total`, `declaring_checker_total` and `axes_total` so that a reader of
the register can tell ten-of-ten from one-of-one.

---

## The generalised coverage detector

`tf_controls_signal_coverage` after migration 304 asserts four properties, and
publishes a counter for each.

**Declaration.** Every rostered checker returns an `axes` key. Failures land in
`undeclared_checker_total` with the offending names in `undeclared_checkers`.

**Consumer read.** Every declared axis of every rostered checker is read by the
evaluator using the strict counter-read needle built from that checker's own
evaluator variable. Failures land in `unread_total` with the pairs in
`unread_axes`.

**Roster closure.** The detector scans the evaluator's definition for every
`public.tf_*()` call it makes and asserts each one is either on the roster or on
the explicit non-checker list. This is the mechanism that stops the roster
silently going stale as the evaluator grows. Failures land in
`unrostered_callee_total`.

```sql
for v_callee in
  select distinct m[1]
    from regexp_matches(v_def, 'public\.(tf_[a-z0-9_]+)\(\)', 'g') as m
loop
  if not jsonb_exists(v_roster, v_callee) and not (v_callee = any(v_non_checkers)) then
    v_unrostered := v_unrostered || v_callee;
  end if;
end loop;
```

**Refusal gating.** Every rostered checker's result must be gated on its own `ok`
flag by the evaluator, in either spelling. A checker whose refusal the evaluator
ignores is a checker whose failure reads as a pass. Failures land in
`ungated_refusal_total`.

A checker that cannot be executed at all lands in `unmeasured_checker_total`, and
the payload is set to null rather than to an empty object, per the swallowed-refusal
rule.

The detector is a member of its own roster, which it cannot resolve by calling
itself. Its axis is therefore read from a constant in its body, and its consumer
read is checked identically to every other entry. That exclusion is **published**
rather than left for a reader to infer from a count, in a `self_note` key on the
payload. An exclusion a reader has to derive from arithmetic is an exclusion
nobody will notice has gone stale. The payload also publishes the roster itself,
the non-checker list, and the name of the consumer it measured against, so the
result can be audited without reading the function source.

`gap_total` is the sum of all five, asserted equal to that sum before return.

Live result at close of batch:

```
ok true
checkers_total 10
declaring_checker_total 10
axes_total 24
unread_total 0
undeclared_checker_total 0
unmeasured_checker_total 0
unrostered_callee_total 0
ungated_refusal_total 0
gap_total 0
```

---

## The control

`CM-SIGNALCOV-026` was rewritten in migrations 305 and 306 so the register states
what is actually being measured.

**Title.** Every declared detection axis on the checker roster has a consumer that
renders it.

**Signal.** `tf_controls_signal_coverage gap_total over a ten-checker roster`.

**Evidence, live:** *"10 of 10 rostered checker(s) declare axes; 24 axis(es)
declared, 0 unread by this evaluator []; undeclared [], unmeasured [], unrostered
callee(s) [], refusal-ungated []"*.

The evidence string was the point of migration 305. The previous version reported
`unread_total`, `unread_axes`, `declared_axes` and `refusal_flag_honoured`, and the
last two were retired by the generalisation. An evidence string that reports keys
the checker no longer publishes is a control whose narrative and whose status have
come apart, which is the condition house rule eighteen exists to prevent.

---

## Techniques worth reusing

**The asserted textual splice.** Three of these migrations modified an existing
function by fetching `pg_get_functiondef`, replacing anchors, and executing the
result. That is only legitimate if every anchor is proved to occur exactly once
before any substitution runs:

```sql
v_hits := (length(v_new) - length(replace(v_new, v_n[v_i], ''))) / length(v_n[v_i]);
if v_hits <> 1 then
  raise exception 'migration NNN: anchor % occurs % time(s), refusing to splice. Anchor was: %', v_i, v_hits, v_n[v_i];
end if;
```

This was chosen deliberately over retyping `tf_controls_board`, whose body contains
the literal `E' \t\r\n,'`. Retyping a body that contains escape-heavy literals is a
transcription risk with no upside; splicing with proved anchors is not.

**Create or replace preserves the ACL.** A brand-new `SECURITY DEFINER` function
with no guard is reachable at the instant it is created. `CREATE OR REPLACE`
preserves the existing ACL, so replacing a function does not reopen that exposure
window. Relied on in 301 and 304, both of which replaced privileged functions
wholesale.

**House rule seventeen holds.** Every migration in this batch that touched the
control register asserted the register's aggregate state before it committed:
`perform public.tf_controls_evaluate();` then a count of failing controls.

---

## Register state at close of batch

**306 migrations applied. 27 controls: 24 passing, 3 attention, 0 failing.**
(Migrations 307 through 309 subsequently took this to **28 controls: 25 passing,
3 attention, 0 failing**.)

The three attention controls are `AC-MFA-003`, `AC-PRIV-002` and `DP-PITR-007`. All
three are owner actions outside the database, tracked in ClickUp, and none are
blocked by anything in this batch.

---

## Open items this batch did not close

**Obligation two has no gate.** Nothing structurally prevents a migration creating
a `tf_*` function without a `tf_function_registry` row. An event trigger on
`ddl_command_end` would close it. This remains the cheapest available hardening
win.

**The default-privilege residual.** The `supabase_admin`-owned default ACL for
public tables still reads `anon=arwdDxtm`. Migration 283 monitors the symptom. The
mechanism is untouched.

**Deployment coordination remains the largest unmitigated governance risk.** Two
agents can write DDL to the same production schema with no coordination primitive
between them. Four consecutive verification passes have named this. The
recommendation stands: advisory lock, deploy log, and a `CM-DEPLOY` control.
