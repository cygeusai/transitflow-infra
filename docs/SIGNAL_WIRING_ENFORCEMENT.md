# Signal Wiring Enforcement

**Migrations 316 through 320. Control `CM-SIGWIRE-030`. Status: closed and green as of 2026-07-25.**

This document records the closure of **obligation three of convention 33**, the
oldest open structural gap in the Transit & Flow control platform. Six prior
verification passes recorded it as unclosable. It is now closed, not by
detection after the fact, but by refusal at commit time.

---

## 1. What obligation three says, and why it stayed open

Convention 33 governs what an author owes when they add a function to the
platform. Obligation one is that the function is declared in
`tf_function_registry`. Obligation two is that it carries a grant tier.
Obligation three is that **a new checker must have its signal wired into a
control**, so that what it measures actually reaches the register a human reads.

Obligations one and two were closed years of migrations ago, because each rests
on a single unambiguous catalog fact: a row exists, or it does not. Obligation
three was repeatedly written up as unclosable, and the reason given each time
was the same, quoted from the verification log:

> "wire its signal into a control" has no single catalog fact testable at commit
> time.

That premise had two problems. It assumed there was no way to know whether a
function *was* a checker without asking its author, and it assumed "wired" was a
fuzzy predicate rather than a conjunction of exact ones. Both turned out to be
false, and the answer to the first was already sitting in convention 37.

---

## 2. The definition that unlocked it (migration 317)

Convention 37 says the axis is the consumption surface: a checker publishes an
`axes` array naming the counters a control is expected to gate on. Migration 317
takes that literally and makes it the **definition**, not a downstream
consequence:

> A checker is a `public.tf_*` function of `prokind = 'f'` whose
> `pg_get_functiondef` text contains the literal `'axes',`.

The force of this is that being a checker becomes a property of the function's
own source text, readable from the catalog, rather than an intention its author
declares. An author cannot opt out of being a checker except by not publishing
an axis, which is the same thing as not being one. That closes, by construction,
the exemption route that migration 265 had to close by hand.

Migration 317 also gave `tf_controls_signal_coverage` a new component axis,
`orphan_checker_total`, measured from function text rather than from the roster.
Its own note, quoted from the live payload, states the point:

> The other five components can only see checkers that are already wired
> somewhere; this one sees the ones that are wired nowhere, which is the
> direction obligation three of convention 33 was blind in.

The test is textual, and it will count a function that merely contains the
literal. That is a false positive the roster resolves in one line, and it is the
cheaper error to make.

---

## 3. What "wired" means, exactly

Three catalog facts, all re-tested at COMMIT:

| # | Fact | How it is tested |
|---|------|------------------|
| 1 | The function is a rostered checker | `jsonb_exists(public.tf_controls_signal_roster(), proname)` |
| 2 | The register consumes it | `strpos(pg_get_functiondef(public.tf_controls_evaluate), 'public.<proname>()') > 0` |
| 3 | A control names it | some `public.it_controls` row has `strpos(signal, '<proname>') > 0` |

Use `strpos(...) > 0`, never `LIKE`. Underscore is a `LIKE` wildcard and every
identifier in this platform contains one.

The refusal **enumerates all three unmet facts at once** rather than
short-circuiting on the first, so an author fixing them one at a time does not
pay three round trips to discover three problems.

---

## 4. The mechanism (migration 318)

The enforcement is the commit-time pattern already proved on declarations in
migrations 307 through 309, instantiated a second time:

```
CREATE FUNCTION / ALTER FUNCTION
        |
        v
event trigger  tf_require_signal_wiring        (ddl_command_end)
        |  function publishes 'axes', and is not yet wired
        v
queue table    public.tf_signal_wiring_pending
        |
        v  at COMMIT
constraint trigger tf_signal_wiring_pending_deferred_check
        |  DEFERRABLE INITIALLY DEFERRED, FOR EACH ROW
        v
public.tf_signal_wiring_pending_check()  -> enforce, then sweep
```

Deferral is what makes the rule usable rather than hostile. A conforming
migration must create the checker before it can wire it, so a check that fired at
statement time would refuse every correct migration. Because the check is
deferred, **any ordering inside the transaction is accepted and only the end
state is judged**.

The queue table mirrors `tf_declaration_pending` exactly, which is the live and
green precedent: RLS enabled, **no policy**, `ALL` revoked from `public`, `anon`
and `authenticated`, granted to `postgres` and `service_role`. `ensure_rls`
auto-enables RLS on every new table, so a transient queue needs this shape
deliberately rather than by omission.

---

## 5. The falsifiability proof (migration 319)

Per the migration 311 precedent, an enforcement that has never been observed
refusing anything is an enforcement nobody has tested. A control that cannot fail
is not a control, it is a decoration.

Migration 319 creates an unwired checker inside a plpgsql subtransaction,
satisfies obligation two so that only obligation three can refuse, and forces the
deferred trigger to fire early with `SET CONSTRAINTS ALL IMMEDIATE`. The refusal
aborts the subtransaction, which unwinds the `CREATE FUNCTION`, the registry row
and the queue row together. The migration then asserts that nothing survived,
rather than assuming it.

The critical detail is the handler. It catches **`check_violation` only**. If the
enforcement fails to fire, control reaches a deliberate `raise_exception` that is
not caught, and the migration fails loudly. A probe that passes when the thing it
probes is broken is worse than no probe.

The refusal, captured verbatim on 2026-07-25 and retained in migration history:

```
SQLSTATE: 23514
ERROR: Refused at commit: public.tf_probe_unwired_checker() publishes an axes
key, which makes it a checker, and it is not wired to a control.
Unmet: not a key in public.tf_controls_signal_roster()
     | public.tf_controls_evaluate() does not call public.tf_probe_unwired_checker()
     | no public.it_controls row has a signal naming tf_probe_unwired_checker
HINT: Convention 33 obligation three. In the same transaction: add the function
and its axis names to public.tf_controls_signal_roster(), add a call to
public.tf_probe_unwired_checker() inside public.tf_controls_evaluate(), and
insert or update a public.it_controls row whose signal names
tf_probe_unwired_checker. This check runs at COMMIT, so any order inside the
transaction is accepted. If the function is not meant to be a checker, stop
publishing an axes key, because publishing one is the definition.
```

---

## 6. The checker and the control (migration 320)

`public.tf_signal_wiring_enforcement_audit()` publishes the roll-up axis
`wiring_gap_total`, which is the sum of five components. The roll-up identity is
asserted inside the function body before the roll-up is published.

| Component | Reads | Non-zero means |
|-----------|-------|----------------|
| `wiring_enforcement_missing_total` | `pg_event_trigger` | the enqueue trigger is gone |
| `wiring_enforcement_disabled_total` | `pg_event_trigger.evtenabled` | it is `D` disabled, `R` replica-only, or an unrecognised flag |
| `wiring_deferred_check_missing_total` | `pg_trigger` | the commit-time check is absent, disabled, or **wrongly timed** |
| `wiring_residue_total` | `tf_signal_wiring_pending` | queue rows whose obligation is still unmet |
| `unwired_checker_total` | live function text | a checker exists in the schema that is wired nowhere |

Two counters are published as **non-gating population**, not findings:
`checker_population_total` (every `tf_*` function publishing an axis key) and
`wiring_queue_total` (every queue row, met or unmet).

### Why replica-only counts as disabled

An event trigger with `evtenabled = 'R'` exists and is not disabled, and it does
not fire for ordinary origin DDL, which is the only kind of session anyone
deploys from. It counts as disabled. The raw catalog letter travels with the
payload as `event_trigger_flag` so a reader can still tell `D` from `R`.

### Why a wrongly timed check counts as a missing one

A constraint trigger recreated without `DEFERRABLE INITIALLY DEFERRED` still
exists, is still enabled, and still fires, but at statement time. It would refuse
every conforming migration and be switched off within the week. That is not
enforcement, it is a fault, so it is counted as missing rather than present.

### The axis that can contradict the others

Four components read the trigger catalog and answer *is the enforcement
installed*. The fifth sweeps live function text and answers *did it hold*. An
enforcement reported present, enabled and deferred that nonetheless left an
unwired checker in the schema reads zero on the four catalog axes and non-zero on
the one measuring the claim. That is the only direction in which this checker can
contradict itself, and it is deliberate. The same design appears in
`tf_deploy_coordination_audit`, where the interleave axis is measured from
recorded command spans rather than from the trigger catalog.

---

## 7. Why 320 could not be split into two migrations

The original plan was 320 for the checker and 321 for the control. That plan
became impossible the moment migration 318 committed.
`tf_signal_wiring_enforcement_audit` publishes an axis key, which by the
definition in 317 makes it a checker, so 318 refuses to let it commit unwired.
Splitting it would have been refused at the COMMIT of 320.

That is the enforcement working on its own author at the first opportunity, which
is the only kind of enforcement worth having. Every future checker is now subject
to the same constraint: **the checker and its wiring ship in one transaction, or
they do not ship.**

---

## 8. The pending-queue collision, and why it was designed for in advance

Creating the checker enqueues it *before* the wiring lands, and the queue row is
only swept at COMMIT. So inside the transaction there is a window in which the
obligation is met and the queue row still exists.

Migration 316 learned this on the declaration queue the hard way: counting queue
rows as residue makes **house rule twenty-two guarantee a red**, because a
conforming migration fails its own control precisely at the moment it does the
right thing. Migration 316 corrected `tf_declaration_enforcement_audit` so that
`pending_residue_total` counts only the unmet subset and `pending_queue_total`
publishes the raw count beside it as non-gating population.

Migration 320 was built with that shape from the first line rather than
rediscovering it. The assertion block deliberately requires
`wiring_queue_total >= 1`: if the queue were empty at that point, the enqueue
trigger would not have observed this migration creating a checker, and the
commit-time sweep would have had nothing to enforce against. A green from an
enforcement that never saw the event is exactly the failure mode this batch
exists to prevent.

> **Supersedes.** `docs/DECLARATION_ENFORCEMENT.md` states that obligation three
> of convention 33 remains open. As of migration 320 it is closed. That statement
> is retained there as a dated record with a forward pointer to this document.

---

## 9. Rules established or paid for by this batch

**The coalesce-default rule.** In an assertion, the safe default for a `coalesce`
is the **failing** value, never the passing one. Migration 318 read
`tf_controls_board()->'summary'`, which does not exist, and
`coalesce((v_sum->>'failing')::int, -1) <> 0` turned the NULL into a loud red.
Had it defaulted to `0`, migration 318 would have committed on a reading it never
actually took.

**`tf_controls_board()` has no `summary` key.** The register summary is the
return value of `public.tf_controls_evaluate()` itself. The board's twenty keys
are `authoritative, automated_total, axes, board_age_hours, cadence,
distinct_stamps, evaluated_at, fresh, gap_total, non_gating, ok, population,
scored_total, stamp_note, stamp_uniform, tautological_controls,
tautological_total, threshold_hours, unscored_controls, unscored_total`.

**`it_controls.status` allows exactly four values:** `passing`, `attention`,
`failing`, `manual`. `pending` is not one of them, and attempting it cost
migration 320 an attempt. A newly seeded automated control takes `attention`,
because a control that has never been evaluated is unmeasured, not clean, which
matches the platform's "null, never zero" principle. `tf_controls_evaluate()`
promotes it inside the same transaction, and the migration asserts that it did.

**`SET CONSTRAINTS ALL IMMEDIATE` inside a plpgsql subtransaction** forces a
`DEFERRABLE INITIALLY DEFERRED` constraint trigger to fire without reaching
COMMIT. This is how a commit-time refusal is provoked and captured inside a
migration that still commits.

**A label on a top-level `DO` block is invalid SQL.** Labels are only valid on
plpgsql block statements inside a function body. `mylabel: do $x$ ... $x$;`
raises `42601`.

### House rule twenty-three

> **An assertion's failure path is code, and untested code. plpgsql does not
> resolve identifiers inside a branch it never executes, so an assertion whose
> failure path is broken passes its success path in total silence.**

This rule was paid for during migration 320, which committed clean while carrying
a typo, `coaleske_placeholder`, in the first argument of a `raise` that only runs
when `enforcement_gap_total` is non-zero. It was zero, the branch was never
entered, and Postgres never resolved the identifier. The live schema is
unaffected, because no database object contains that text; only the immutable
migration history row does. The checked-in file
`supabase/migrations/20260725183125_signal_wiring_checker_and_control.sql`
carries the corrected expression together with an inline comment recording the
divergence, so a replay onto a fresh database reports the intended message rather
than `42703 column "coaleske_placeholder" does not exist`.

The generalisation is uncomfortable and worth stating plainly: **every assertion
in every migration in this repository has a failure path that has, by
construction, never run.** The success path is what gets exercised. This is the
same class of defect the whole 316-320 batch exists to eliminate, discovered one
level up, in the tooling that verifies rather than in the thing verified.

---

## 10. Follow-on workstream, opened by house rule twenty-three

`plpgsql_check` version 2.8 is **available and not installed** on the project. It
catches precisely this defect class. Measured on 2026-07-25 against the live
schema, rolled back:

```
error:42703:5:RAISE:column "coaleske_placeholder" does not exist
```

A full static scan of every plpgsql function in `public` completed in **447 ms**
across 119 functions: 93 plain, 21 trigger, 5 event trigger, 0 skipped. It
returned 5 errors, 67 warnings and 263 informational messages. The five errors
triage as follows and are recorded here so the workstream starts from evidence
rather than from a blank page:

| Function | Message | First read |
|----------|---------|-----------|
| `tf_link_revenue` | relation `_cust_fix` does not exist | runtime temp table, invisible to static analysis; annotate its shape |
| `tf_merge_duplicate_customers` | relation `_merge_map` does not exist | same |
| `current_user_role` | relation `users` does not exist | needs investigation; possibly a real unqualified reference |
| `tf_cx_sequence_sweep` | record `l` is not assigned yet | needs investigation |
| `tf_guard_detection_audit` | malformed array literal: `tf_guard_predicate_registry is empty` | **likely a real defect**, a scalar assigned into a `text[]` on a branch |

The correct closure is a checker plus a control on the gating axis, with temp
table shapes declared via `plpgsql_check` pragmas rather than exempted. A pragma
documents a contract; an exemption is the lever migration 265 had to close.
Tracked in ClickUp. **This is the next batch, not part of 316-320.**

---

## 11. Verified live state, 2026-07-25

```json
{"total":30,"passing":27,"attention":3,"failing":0,
 "automated":24,"manual_controls":6,"manual_never_attested":6}
```

`tf_signal_wiring_enforcement_audit()` after commit:

```json
{"ok":true,"axes":["wiring_gap_total"],
 "event_trigger_state":"origin","event_trigger_flag":"O",
 "deferred_check_state":"deferred",
 "wiring_enforcement_missing_total":0,"wiring_enforcement_disabled_total":0,
 "wiring_deferred_check_missing_total":0,"wiring_residue_total":0,
 "unwired_checker_total":0,"checker_population_total":13,
 "wiring_queue_total":0,"wiring_gap_total":0}
```

Roster size 13. `tf_controls_signal_coverage` reports `gap_total` 0,
`orphan_checker_total` 0, `axes_publishing_function_total` 13. Both pending
queues are empty, which is the proof that the commit-time sweeps ran.

The three remaining `attention` controls are unchanged owner actions and are not
related to this batch: `AC-MFA-003` (one privileged account without MFA),
`AC-PRIV-002` (one anon-exposed definer function), `DP-PITR-007` (PITR not
enabled).

---

## 12. Operator runbook

**A migration was refused with SQLSTATE 23514 and "Refused at commit".** This is
working as designed. The message names every unmet fact and the hint names the
exact remedy. Add the function and its axis names to
`public.tf_controls_signal_roster()`, add a call to it inside
`public.tf_controls_evaluate()`, and insert or update a `public.it_controls` row
whose `signal` names it. Order inside the transaction does not matter. If the
function was never meant to be a checker, stop publishing an `'axes',` key.

**`CM-SIGWIRE-030` went to `failing`.** Read the control's `evidence` string. It
names the trigger state, the commit-time check state, the unwired checkers, the
population, and the queue residue. If the catalog axes read zero and
`unwired_checker_total` is non-zero, the enforcement is installed and something
got past it, which is the contradiction case in section 6 and the more serious
one.

**`CM-SIGWIRE-030` went to `attention`.** The checker returned no payload or
refused. `attention` is the null reading, not a clean one.

**Kill switch (convention 43).** `ALTER EVENT TRIGGER tf_require_signal_wiring
DISABLE;` stops the enqueue. The checker will report
`wiring_enforcement_disabled_total = 1` and the control will go to `failing` at
the next evaluation, which is the intended behaviour: the kill switch is
available and it is not silent.

---

## 13. Objects created by this batch

| Object | Kind | Migration |
|--------|------|-----------|
| `public.tf_signal_wiring_pending` | table, RLS on, no policy | 318 |
| `public.tf_signal_wiring_required()` | event trigger function, `write`, tier `admin` | 318 |
| `public.tf_signal_wiring_pending_check()` | trigger function, `write`, tier `admin` | 318 |
| `tf_require_signal_wiring` | event trigger, `ddl_command_end` | 318 |
| `tf_signal_wiring_pending_deferred_check` | constraint trigger, deferrable initially deferred | 318 |
| `public.tf_signal_wiring_enforcement_audit()` | checker, `read`, tier `staff` | 320 |
| `CM-SIGWIRE-030` | control, CISO, Change Management, automated | 320 |
| `orphan_checker_total` | new component axis on `tf_controls_signal_coverage` | 317 |
| `pending_residue_total` / `pending_queue_total` split | corrected axes on `tf_declaration_enforcement_audit` | 316 |

Frameworks mapped by `CM-SIGWIRE-030`: SOC 2 `CC4.1`, `CC7.1`, `CC8.1`;
CIS v8 `4.1`, `16.11`; NIST CSF `PR.IP-1`, `PR.IP-3`, `DE.CM-7`.

---

## 14. See also

- `docs/DECLARATION_ENFORCEMENT.md`, migrations 307-309, the first instance of the commit-time pattern
- `docs/CHECKER_AXIS_DECLARATION.md`, migrations 291-306, convention 37 and the axis as consumption surface
- `docs/CONTROL_SIGNAL_COVERAGE.md`, the roster and its coverage checker
- `docs/DEPLOY_COORDINATION.md`, migrations 310-315, and the catalog-versus-claim axis design
- `docs/IT_GOVERNANCE_GRC.md`, the control register
- `docs/PLATFORM_KNOWLEDGE_BASE.md`, conventions, house rules and the verification log
