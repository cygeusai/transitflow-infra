# Control Signal Coverage — the axis nobody reads

Migrations 284 through 287, applied 2026-07-25 against Supabase project
`kjooyhvynkzuvsixsutt`.

The one-line thesis:

> A checker that finds something and publishes it has done nothing at all
> unless something downstream turns that publication into a status a human
> acts on. Detection without consumption is not a control.

This is the same defect migration 269 closed on five audit consumers. It came
back three more times, in three different ways, and this batch closes all three
and then builds the detector that would have caught them on the day they
landed.

---

## The migration ordinals

Verified against `supabase_migrations.schema_migrations` with
`row_number() over (order by version)`. Contiguous, with no concurrent-agent
interleave this time.

| Ordinal | Version | Name |
| --- | --- | --- |
| 284 | 20260725152401 | `controls_listen_to_the_security_scan_refusal_and_its_two_unread_axes` |
| 285 | 20260725152534 | `detect_the_axis_that_nobody_reads` |
| 286 | 20260725152754 | `declare_the_signal_coverage_reader_in_the_function_registry` |
| 287 | 20260725152915 | `the_unread_axis_detector_is_itself_read` |

Read them as one change split into four so each property could be asserted
before the next was applied. 286 exists only because 287's own assertion
refused to let 287 apply, which is covered below and is the most instructive
part of the batch.

---

## Migration 284 — three unread signals and one false positive

### Defect one: the refusal flag nobody honoured

`tf_security_scan` acquired an `ok` flag in migration 280, along with a
population declaration, an empty-population refusal and a set of axis-coupling
assertions. Any of those can set `ok: false`.

Migration 269 had already swept the control evaluator and fixed five consumers
to gate on the flag before reading the counters. The scan was not one of the
five, and the reason is worth stating precisely because it is a scheduling
hazard rather than a coding one:

> **At the time the consumers were fixed, the scan had no flag to gate on. It
> acquired one eleven migrations later, and nothing went back to re-check the
> consumer.**

The live code read:

```sql
begin v_scan := public.tf_security_scan(); exception when others then v_scan := null; end;
v_rls := case when v_scan is null then null else coalesce((v_scan->>'rls_disabled_tables')::int,0) end;
```

It checks for a raise. It does not check for a refusal. A scan that had
declared itself untrustworthy still populated `v_rls`, `v_anon`, `v_sp`,
`v_nopol` and `v_unguarded` with whatever partial numbers it had computed, and
`AC-RLS-001`, `AC-PRIV-002` and `AC-DEFN-017` rendered `passing` off them.

The fix separates the raw payload from the trusted payload:

```sql
begin v_scan_raw := public.tf_security_scan(); exception when others then v_scan_raw := null; end;

v_scan := case when v_scan_raw is null or coalesce(v_scan_raw->>'ok','false') <> 'true'
               then null else v_scan_raw end;
```

Every axis reads `v_scan`. Exactly one control reads `v_scan_raw`, and that is
deliberate:

> **A refusal reporter gated on the flag it reports goes silent exactly when it
> matters.** `CM-SCANINTEG-025` exists to say "the scan refused". If it read
> the gated payload it would read null on refusal and render `attention`
> instead of naming the refusal.

### Defect two and three: two axes with no consumer

`tables_truncatable_by_client` was added as the sixth declared axis in
migration 283. `integrity_total` and `stale_exemption_total` were added in 280
and 283. Between those migrations and this one, all three were computed on
every scan and read by nobody.

Two new control rows close them:

| Key | Title | Signal |
| --- | --- | --- |
| `CM-TRUNCGRANT-024` | Privileges outside the RLS-evaluated set are not held by client roles | `tf_security_scan tables_truncatable_by_client` |
| `CM-SCANINTEG-025` | The security scan vouches for its own population and its refusals are heard | `tf_security_scan integrity_total + stale_exemption_total` |

### Key presence, not coalesce-to-zero

The new axes are read with `jsonb_exists` rather than a bare coalesce:

```sql
v_trunc := case when v_scan is null or not jsonb_exists(v_scan, 'tables_truncatable_by_client') then null
                else coalesce((v_scan->>'tables_truncatable_by_client')::int,0) end;
```

`coalesce((v_scan->>'missing_key')::int, 0)` is zero, and zero is a perfect
score. An axis that was never computed must read `attention`, not `passing`.
This is the same distinction as house rule fourteen, applied one level down: a
checker that refused is not a checker that found nothing, and an axis that was
never computed is not an axis that came back clean.

Note the form. `jsonb_exists(v, 'k')` is the function spelling of the `?`
operator. The operator spelling is preferred inside application SQL, but the
function spelling is safer inside migration payloads that travel through
transports which may treat a bare `?` as a bind placeholder.

### The `AC-RLS-001` false positive

`AC-RLS-001` was reading `failing` and had been for some time. The cause:

```
rls_enabled_no_policy = 1, tables = ["studio_events_prelaunch_archive"]
```

That table has RLS enabled, zero policies, and an ACL of
`{postgres=arwdDxtm/postgres,service_role=arwdDxtm/postgres}`. No client role
holds any privilege on it at all. It is correctly built. A table no client role
can reach needs no policy, because there is no client-role query for a policy
to constrain.

Migration 283 had already decomposed the axis under convention 21, decompose
never narrow, producing `rls_enabled_no_policy_reachable` alongside the
original. Migration 284 moves the control's **status** onto the reachable
subset and keeps **both numbers plus the denominator** in the evidence:

```
0 tables without RLS, 0 client-reachable with no policy at all
(of 1 RLS-enabled-no-policy across 174 tables). Status weighs the
reachable subset since migration 284: a table no client role can
reach needs no policy
```

The correction is visible in the audit trail rather than silently applied.
Someone reading the board later can see that one table is still unpoliced, see
why it does not count, and disagree if they want to.

`AC-DEFN-017` picked up the same treatment: its evidence now carries the
population it was measured against, `57 unexempt of 60 reachable, 3 exempted,
across 120 definer fn(s)`, per convention 29.

---

## Migration 285 — build the detector, not just the fix

Migration 284 fixed three instances of one defect by hand. Fixing an instance
is a changelog entry. Detecting the class is a control.

`public.tf_controls_signal_coverage()` compares the machine-readable axis list
that `tf_security_scan` publishes against the catalog definition of
`tf_controls_evaluate`, and reports any axis with no branch.

```sql
select array_agg(a) into v_axes from jsonb_array_elements_text(v_scan->'axes') as t(a);

select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'tf_controls_evaluate' and p.prokind = 'f';

foreach v_axis in array v_axes loop
  v_needle := '''' || v_axis || '''';
  if strpos(v_def, v_needle) = 0 then
    v_unread := v_unread || v_axis;
  end if;
end loop;
```

It reads the **catalog definition**, not a register, so the answer cannot drift
from the deployed code. That is the lesson of migration 276 applied here:
agreement between a checker and a register it wrote is not corroboration.

### The prefix-collision gotcha, encoded in the body

The needle is the axis name **wrapped in single quotes**, not the bare name.
This matters because of a collision the platform created on purpose:

> `rls_enabled_no_policy` is a strict prefix of
> `rls_enabled_no_policy_reachable`.

A bare `strpos(v_def, 'rls_enabled_no_policy')` returns non-zero on a body that
only ever references the reachable variant, so the original axis would report
as read when it was not. Wrapping in quotes makes the match exact, because in
the consumer both appear as `->>'axis_name'` with a closing quote.

Convention 21 says decompose, never narrow. This is the cost of that
convention, and the detector has to pay it explicitly.

### Refusal semantics

The checker is deliberately **ungated on the scan's `ok` flag**. A refusing
scan still declares its axis list, and coverage of that list is precisely what
is being measured. It refuses on its own terms instead, with four distinct
error codes:

| Error | Meaning |
| --- | --- |
| `forbidden` | Non-staff caller under a live `auth.uid()` |
| `scan_raised` | The scan threw and returned no payload |
| `scan_published_no_axis_list` | The payload has no `axes` key |
| `axis_list_empty` | The axis list exists and is empty, so coverage is vacuous |
| `consumer_not_found` | `tf_controls_evaluate` is missing from the catalog |

`axis_list_empty` is the population refusal from convention 29 applied to this
checker: 0 unread of 0 declared is a perfect score and a meaningless one.

### The creation exposure window, closed in the same transaction

`tf_controls_signal_coverage` is a brand-new `SECURITY DEFINER` function, so it
was reachable by `authenticated` at the instant `CREATE FUNCTION` returned.
The tier is applied in the same migration and the migration asserts both sides:

```sql
select public.tf_apply_grant_tier('tf_controls_signal_coverage', '', 'staff', '...');

if has_function_privilege('anon', v_oid, 'EXECUTE') then
  raise exception 'creation exposure window left open: anon holds EXECUTE on tf_controls_signal_coverage';
end if;
if not has_function_privilege('authenticated', v_oid, 'EXECUTE') then
  raise exception 'staff tier did not grant EXECUTE to authenticated on tf_controls_signal_coverage';
end if;
```

Staff tier is correct here because the function carries the guard idiom:

```sql
if auth.uid() is not null and not public.user_is_internal_staff(v_company) then
  return jsonb_build_object('ok', false, 'error', 'forbidden');
end if;
```

---

## Migration 286 — the migration that exists because an assertion refused

This is the part of the batch worth reading twice.

Migration 287 was written and submitted before 286 existed. Its final assertion
is:

```sql
if coalesce((v_sum->>'failing')::int, -1) <> 0 then
  raise exception 'controls left failing after this migration: %', v_sum::text;
end if;
```

It fired:

```
ERROR: P0001: controls left failing after this migration:
{"total": 26, "failing": 1, "passing": 22, "attention": 3, ...}
```

House rule sixteen says: when your own assertion fails, ask whether it found
something before assuming it is wrong. It had found something.
`CM-FNDRIFT-018` was failing because `tf_function_safety_audit` read
`undeclared_total: 1`:

```json
"undeclared": [{"name": "tf_controls_signal_coverage", "computed": "read"}]
```

Migration 285 created a `tf_*` function and never declared it in
`tf_function_registry`. The whole of 287 rolled back on that, correctly.

### The general shape, stated because it will recur

Creating a `tf_*` function carries three obligations, and only one of them is
enforced at creation time.

| Obligation | Enforced at creation? | Detected afterwards by |
| --- | --- | --- |
| Apply a grant tier in the same migration | **Yes**, the creation exposure window is asserted since migration 282 | `tf_grant_tier_audit` `uncovered_total` |
| Declare it in `tf_function_registry` | No | `tf_function_safety_audit` `undeclared_total` |
| Wire its signal into a control | No | `tf_controls_signal_coverage` (scan axes only) |

Obligation two has a detector and no gate. That turned out to be acceptable,
because the detector fired within one migration of the omission. But it only
fired because migration 287 asserted **no control is left failing** inside its
own transaction rather than eyeballing the board afterwards. Without that
assertion the register would have carried a failing control silently until the
next manual review.

> **House rule seventeen. A migration that touches the control register must
> assert the register's aggregate state before it commits.** Not the state of
> the row it changed, the state of the whole board. Cross-control regressions
> are invisible to a per-row assertion.

Migration 286 is a single `insert ... on conflict (proname) do update` plus a
verification block that asserts `undeclared_total = 0` and `drift_total = 0`.

---

## Migration 287 — the detector is itself read

Leaving `tf_controls_signal_coverage` unwired would have been the same defect
one level up: a detector that publishes a gap and nothing reads it.

`CM-SIGNALCOV-026`, "Every declared detection axis has a consumer that renders
it", reads `tf_controls_signal_coverage`'s `gap_total`, which is
`unread_total` plus one if the refusal flag is no longer honoured. It fails the
day an axis is added without a branch, and the day someone removes the `ok`
gate from the evaluator.

The recursion terminates. The coverage checker reads the evaluator's
definition; the evaluator reads the coverage checker's payload; the control
that closes the loop is the coverage control itself. Nothing else is left
publishing into a void.

### What 287 asserts

| Assertion | Why |
| --- | --- |
| `has_function_privilege('authenticated', tf_controls_evaluate, 'EXECUTE')` is false | `CREATE OR REPLACE` preserves the ACL, so the exposure window should not reopen. Assert it rather than assume it. |
| `CM-SIGNALCOV-026` appears at least twice in `pg_get_functiondef` | Convention 12. A control key must be wired into both the status branch and the evidence branch. A key present in only one is half-wired. |
| Summary `total` equals the register row count | The summary is computed from the same table, so disagreement means the company filter drifted. |
| Register holds exactly 26 controls | The batch's declared outcome. |
| The control's status agrees with an **independently re-read** coverage payload | Migration 276's lesson. The control must not agree only with itself. |
| Zero controls failing | House rule seventeen, above. This is the assertion that found migration 286. |

The count-occurrences idiom, worth keeping:

```sql
v_hits := (length(v_def) - length(replace(v_def, 'CM-SIGNALCOV-026', ''))) / length('CM-SIGNALCOV-026');
```

---

## Verified live state

Captured 2026-07-25T15:29:26Z, after migration 287.

### `tf_controls_evaluate()`

| Field | Value |
| --- | --- |
| `total` | 26 |
| `passing` | 23 |
| `attention` | 3 |
| `failing` | **0** |
| `automated` | 20 |
| `manual_controls` | 6 |
| `manual_never_attested` | 6 |

The three on `attention`: `AC-PRIV-002` (one anon-exposed definer function,
`tf_founding_stats`, which is a deliberate public intake surface),
`AC-MFA-003` (one privileged account without MFA, owner action `86bb3ae6c`),
`DP-PITR-007` (manual, owner action `86bb3ayzr`).

### `tf_controls_signal_coverage()`

```json
{
  "ok": true,
  "consumer": "public.tf_controls_evaluate",
  "declared_axes": 6,
  "axes": ["rls_disabled_tables", "anon_secdef_nonpublic", "secdef_no_searchpath",
           "rls_enabled_no_policy", "secdef_authenticated_no_guard",
           "tables_truncatable_by_client"],
  "unread_total": 0,
  "unread_axes": [],
  "refusal_flag_honoured": true,
  "gap_total": 0
}
```

### The three corrected controls

```
AC-RLS-001        passing   0 tables without RLS, 0 client-reachable with no policy at all
                            (of 1 RLS-enabled-no-policy across 174 tables)
CM-TRUNCGRANT-024 passing   0 table(s) on which anon or authenticated holds TRUNCATE ...
                            across 174 table(s). Hardened by migration 272, monitored
                            since 283, read by a control since 284
CM-SCANINTEG-025  passing   0 scan integrity failure(s) plus stale exemption(s); ok=true,
                            errors=[], declared over 120 definer fn(s) and 174 table(s)
```

### Registers

| Checker | Reading |
| --- | --- |
| `tf_grant_tier_audit` | `ok true`, violations 0, missing 0, uncovered 0, drift 0, coverage 100 pct, 93 of 93 `tf_*` declared |
| `tf_function_safety_audit` | 93 functions, 32 reads, 61 writers, undeclared 0, drift 0, stale 0, diagnostic violations 0 |
| `tf_security_scan` | `ok true`, integrity 0, gap_total 2, six axes, stale exemptions 0 |

---

## Runbook

**Is any detection axis unread?**

```sql
select public.tf_controls_signal_coverage();
```

`gap_total` of 0 means every declared axis has a branch in the evaluator and
the refusal gate is intact. Anything else names the axes in `unread_axes`.

**I added an axis to `tf_security_scan`. What now?**

1. Add it to the `axes` array in the scan so it is declared, and to
   `gap_total` through the declared-axis list rather than a hand-written sum.
2. Add a branch for it in `tf_controls_evaluate`, both status and evidence,
   reading it with `jsonb_exists` before coercing.
3. Either wire it to an existing control or add a new control row.
4. Run `tf_controls_signal_coverage()` and confirm `gap_total` is 0. If you
   skip steps 2 and 3, `CM-SIGNALCOV-026` fails on the next evaluation.

**I created a new `tf_*` function. What now?**

1. `select public.tf_apply_grant_tier('name', 'ident_args', 'tier', 'rationale');`
   in the **same migration**, before the transaction commits.
2. `insert into public.tf_function_registry (proname, declared_kind, ...)`.
3. Assert `tf_function_safety_audit()->>'undeclared_total'` is `'0'` and
   `tf_controls_evaluate()->>'failing'` is `'0'` before you commit.

**Did a control regress and nobody noticed?**

```sql
select control_key, status, last_evaluated_at, left(evidence, 120)
  from public.it_controls
 where company_id = 'ff000000-0000-4000-b000-000000000001'
   and status <> 'passing'
 order by automated desc, control_key;
```

---

## Governing principles from this batch

1. **Detection without consumption is not a control.** A published signal with
   no consumer is a log line.
2. **A refusal reporter must read the ungated payload.** Gate it on the flag it
   reports and it goes silent exactly when it matters.
3. **An absent key is not a zero.** Coalescing a never-computed axis to zero
   reports a perfect score for a measurement that never happened.
4. **Correct a false positive in the status, explain it in the evidence.** A
   silent correction is indistinguishable from a bug.
5. **When your own assertion fails, ask what it found.** Migration 286 exists
   because migration 287 refused to commit.
6. **Assert the aggregate, not the row.** Cross-control regressions are
   invisible to a per-row check.
7. **Match identifiers with their delimiters.** Decomposed axis names collide
   by prefix, which is the price of convention 21.

---

## Open items

- ~~**`it_controls.status` is a cache with no freshness gate.**~~ **Closed by
  migrations 288 through 290.** `tf_controls_board()` publishes the register's
  age against a 792-hour threshold derived from the monthly cadence, and
  `CM-BOARDFRESH-027` renders it. The obvious implementation was wrong and the
  catalog said so before it was built: `last_evaluated_at` is a **write**
  timestamp, so an unscored control is stamped as fresh as a scored one. The
  board therefore parses the evaluator's catalog text instead, which surfaced a
  second and larger defect, a control whose status branch asserted `'passing'`
  rather than computing it. See
  [`CONTROL_BOARD_FRESHNESS.md`](./CONTROL_BOARD_FRESHNESS.md).
- ~~**Coverage is measured over `tf_security_scan` only.**~~ **Closed by
  migrations 291 through 306.** See the generalisation section below.
- **Obligation two has no gate.** Nothing stops a migration creating a `tf_*`
  function without a `tf_function_registry` row. The detector is fast enough
  that this has not hurt, but an event trigger on `ddl_command_end` would close
  it structurally.
- **Six manual controls have never been attested.** Owner action.
- **The `supabase_admin` default-ACL residual remains open**, per
  `LEAST_PRIVILEGE_TABLE_GRANTS.md`.
- **Two agents deploy to one production migration stream with no lock**, filed
  as ClickUp `86bb3etah`.

---

## The generalisation, migrations 291 through 306

This document proved a principle over a sample of one. The next batch closed the
gap between the principle and the platform.

**What changed.** The detector no longer infers a checker's signals by inspecting
its payload keys. Every checker now **declares** its axes, and the detector tests
those declarations against the evaluator across the whole roster. Coverage went
from one checker with six axes to **ten checkers with twenty-four axes**, and the
control now publishes its own denominator so a reader can tell ten-of-ten from
one-of-one.

**Why declaration beats inspection.** Inspection cannot distinguish a **finding**
from a **population**. `tf_automation_out_of_band` publishes `enabled_total`, the
count of automations currently on, and `out_of_band_total`, the subset that got
there without passing through `tf_automation_arm`. Only the second is a finding.
An inspecting detector demands a consumer for both, the platform sits permanently
one axis short for a reason that is an artefact of the detector, and the natural
response is to add a control that exists to satisfy a checker rather than to
protect the business. The convention that came out of it: **an axis is the
consumption surface**, a signal a control is expected to READ, not an inventory of
everything the checker counts.

**Two of this document's own findings were upgraded.** The prefix-collision
gotcha recorded here, that textual coverage checks must match the identifier
wrapped in single quotes rather than bare, turned out to be the weaker half of the
problem. Two further blind spots surfaced. `drift_total` is published by both
`tf_grant_tier_audit` and `tf_function_safety_audit`, so an unqualified textual
search certifies either checker on the strength of the other's consumer. And a
signal interpolated into a human-readable evidence string is textually
indistinguishable from one read into a status comparison, so a checker nobody acts
on can pass. Both are defeated by the **strict counter-read needle**,
`coalesce((<var>->>'<axis>')::int`: the variable qualifier kills the collision, the
`coalesce(...)::int` shape kills the narrative case.

**Roster closure got a mechanism.** This document's detector had no way to notice
that its own roster had gone stale. Migration 304 scans `tf_controls_evaluate` for
every `public.tf_*()` call it makes and refuses any callee that is neither on the
roster nor on an explicit non-checker list. That is what stops the coverage
percentage staying at one hundred while the evaluator quietly grows a new
consumer.

**The roster was wrong when it was inherited, and the mechanism caught it.** The
state carried into that batch asserted eight checkers. Reading the evaluator's
actual use of `v_board` showed `coalesce((v_board->>'unscored_total')::int,0)`
driving `CM-BOARDFRESH-027`, which means `tf_controls_board` had been a checker
since migration 288 and had never declared an axis. The same test proved
`tf_controls_signal_coverage` is itself consumed. **Whether a function is a checker
is not a property of its name. It is a property of whether the consumer reads a
counter out of it.**

Full treatment, including the three couplings, the swallowed-refusal rule and the
declare-on-every-success-path rule, is in
[`CHECKER_AXIS_DECLARATION.md`](./CHECKER_AXIS_DECLARATION.md).

---

## Related

- `docs/CHECKER_AXIS_DECLARATION.md` — migrations 291 through 306, which
  generalise this document's detector from one checker to ten and give the
  control a stated denominator
- `docs/SECURITY_SCAN_INTEGRITY.md` — migrations 280 through 283, the
  population declaration and the `ok: false` refusal ladder this batch teaches
  the consumer to hear
- `docs/LEAST_PRIVILEGE_TABLE_GRANTS.md` — migration 272, whose hardening
  `CM-TRUNCGRANT-024` now watches
- `docs/CONTROL_BOARD_FRESHNESS.md` — migrations 288 through 290, which close
  this document's freshness item and add the two axes that ask whether a control
  is genuinely scored at all
- `docs/IT_GOVERNANCE_GRC.md` — the control register, now 27 rows
- `docs/REGISTER_INTEGRITY.md` — why the coverage checker reads the catalog
  rather than a register
- `docs/FUNCTION_GRANT_TIERS.md` — `tf_apply_grant_tier` and the creation
  exposure window
- `docs/PLATFORM_KNOWLEDGE_BASE.md` — conventions, house rules and the Pass 11
  and Pass 12 verification logs
