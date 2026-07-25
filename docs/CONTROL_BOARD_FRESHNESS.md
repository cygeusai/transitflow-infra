# Control Board Freshness — the cache nobody dated, and the branch that asserted a pass

Migrations 288, 289 and 290 against Supabase project `kjooyhvynkzuvsixsutt`.
State captured 2026-07-25 at migration 290.

> **Thesis.** A control register is a cache of judgements. A cache with no date
> on it is not evidence, it is decoration. And a judgement that was written as a
> constant was never a judgement at all. This batch put a date on the board and
> then discovered that one of the twenty controls on it had never been computed
> in its life.

---

## Where this sits

The chain that produced migrations 268 through 287 kept escalating the same
question. First: does the checker find things? Then: does anything read what the
checker publishes (migration 285, the unread axis)? This batch asks the next one
down:

**When something does read it, is the number it reads actually being produced?**

Three answers were needed, and the first design for the first one was wrong.

---

## Part one: the freshness gate, and the detector that would have found nothing

`it_controls.status` is written by `tf_controls_evaluate()` and read by every
dashboard, report and auditor conversation downstream. Nothing on the row carried
a staleness concept. `last_evaluated_at` existed as a column, and nothing
consumed it. A board scored once in February and never again would render exactly
like a board scored this morning.

The first design for the gate reasoned like this. The evaluator writes every
automated control in one `UPDATE` sharing one `v_now`. Therefore a row whose
`last_evaluated_at` differs from `max(last_evaluated_at)` is a row the evaluator
did not touch, which means a control with no branch in its `CASE`. Neat, cheap,
catalog-free.

It is also structurally incapable of finding anything, and the catalog said so
before a line was written:

```sql
select count(distinct last_evaluated_at) from public.it_controls
 where company_id = 'ff000000-0000-4000-b000-000000000001' and automated;
-- 1
```

The reason is the last arm of the evaluator's status expression:

```sql
      when 'CM-SIGNALCOV-026'  then case when v_sig is null then 'attention'
                                         when v_sig=0 then 'passing' else 'failing' end
      else status end,
```

`else status end`. A control the `CASE` has no branch for keeps its previous
status and **still gets stamped with the fresh timestamp**, because the timestamp
is set by the same `UPDATE` for every automated row regardless of which arm the
`CASE` took. The stamp is a write timestamp, not an evaluation timestamp. A skew
detector built on it would report zero forever and the zero would mean nothing.

That is the undeclared-denominator defect from migration 280 wearing a new
costume, and it is the exact failure mode this whole chain exists to prevent. It
was discarded.

### What migration 288 built instead

`public.tf_controls_board()`, staff tier, pure read, publishes two independent
things:

- **Freshness.** `board_age_hours` measured from `max(last_evaluated_at)`,
  compared against `threshold_hours` of 792 (33 days: the declared monthly
  cadence plus a two-day grace). The cadence string it was derived from is
  published alongside the number, so the threshold is auditable rather than
  magic.
- **Scoring coverage.** It reads `pg_get_functiondef` for
  `tf_controls_evaluate`, slices out the status `CASE` specifically, and names
  any automated control with no arm in it.

The slice matters. The evaluator has a second `CASE` immediately below, over
`evidence`, which also names control keys. A control with an evidence branch but
no status branch is precisely the failure being hunted, so matching the whole
definition would have hidden it. The reader takes the text between
`status = case control_key` and `else status end` and looks nowhere else.

It refuses rather than reporting zero on four conditions: `empty_register`,
`never_evaluated`, `evaluator_not_found`, and `status_case_marker_not_found`.
The last one is the important one. If someone reformats the evaluator so the
parse anchors no longer match, the function does **not** return `unscored_total:
0`. It refuses, and says so:

> the evaluator no longer matches the shape this reader parses; fix the reader,
> do not trust the zero

Verification in migration 288 inserted a probe control with no branch, asserted
the detector named it and dropped `authoritative` to false, then rolled the probe
back through a caught exception and asserted the register held no residue.

`unscored_total` read **0** over 20 automated controls. Every control had a
branch.

---

## Part two: presence was the wrong property

`GV-CCM-016` is titled "Continuous controls monitoring". It is the control that
tells an auditor the controls-monitoring programme is running. Its branch was:

```sql
      when 'GV-CCM-016'        then 'passing'
```

A constant. It could not fail. It had never failed. It would have kept rendering
green if pg_cron were dropped, the evaluator disabled and the board frozen for a
year. Its evidence string was `'controls evaluated '||to_char(v_now, ...)`, the
timestamp of its own write, so the audit trail said "controls evaluated
<now>" on every run and carried no information whatsoever.

This is the **tautological control**: a branch that asserts a status instead of
computing one. It is the same family as the seeded register at migration 276
("agreement between a checker and a register it wrote is not corroboration") and
the unread axis at 285. Migration 288 asked whether a branch was *present*.
Presence was never the property worth checking.

Migration 289 added the second axis to `tf_controls_board()`. For each automated
control it isolates that control's arm, from `when '<key>'` to the next
`when '`, strips the leading `then`, and tests whether what remains is nothing
but a status literal:

```sql
      if v_branch ~ '^''(passing|failing|attention|manual)''$' then
        v_taut := v_taut || r.control_key;
      end if;
```

Inner `CASE` arms are spelled `when v_x ...` or `when coalesce(...)`, never
`when '`, so they do not terminate the slice. The detector is deliberately
biased toward false positives: a branch it cannot parse fails loudly rather than
being waved through as evaluated.

`authoritative` now requires all three: fresh, zero unscored, zero tautological.

**Migration 289 deliberately did not fix `GV-CCM-016`.** It landed the detector
and let it report the real finding, and its own verification block asserts the
finding:

```sql
  if not (v->'tautological_controls' @> '["GV-CCM-016"]'::jsonb) then
    raise exception 'detector did not name GV-CCM-016: %', v::text;
  end if;
```

It also asserts the detector does **not** slander `AC-RLS-001` or
`CM-SIGNALCOV-026`, whose branches genuinely compute. A detector proven only
against a synthetic probe has been proven against its author's imagination. This
one was proven against a real defect that was already in production.

---

## Part three: the fix, and the ordering that makes it honest

Migration 290 does two things to `tf_controls_evaluate`.

**`GV-CCM-016` stops asserting itself.** It now reads a property that can
actually be false:

```sql
  select exists(select 1 from cron.job
                 where jobname='tf-controls-evaluate-monthly' and active) into v_ccm_cron;
```

Same idiom as `RE-INTMON-010`, `MO-HEALTH-011` and `MO-AUTOHARDEN-012`, which
were built correctly from the start. Its evidence now names the job and its
schedule, and says plainly when the job is missing.

**`CM-BOARDFRESH-027` is wired** to `tf_controls_board()`'s `authoritative`
flag, so one control row covers all three properties and the 792-hour threshold
lives in exactly one place.

### The ordering trap, avoided by design rather than by luck

The board must be read at the **top** of the evaluator, before its single
`UPDATE`:

```sql
  begin v_board := public.tf_controls_board(); exception when others then v_board := null; end;
```

If it were read afterwards, the update would already have stamped every
automated row with `v_now`, `board_age_hours` would be zero on every run, and
`CM-BOARDFRESH-027` would be scoring its own write. That is the identical trap
`GV-CCM-016` fell into: a control whose signal is produced by the act of
evaluating it. The evidence string says so explicitly, so a reader six months
from now does not have to reconstruct the argument:

> Age is measured before this run stamps the board

The consequence is worth stating: on a run where cron has been down for two
months, `CM-BOARDFRESH-027` renders `failing` **and then the same run makes the
board fresh again**. That is correct. The control reports the gap that existed,
not the state it just created.

### The evaluator was patched textually, and refuses to guess

`tf_controls_evaluate` is a 17,000-character function. Migration 290 patches it
by reading `pg_get_functiondef`, applying five replacements, and executing the
result. Every anchor is asserted to occur **exactly once** before it is used:

```sql
  v_hits := (length(v_new) - length(replace(v_new, a, ''))) / length(a);
  if v_hits <> 1 then
    raise exception 'GV-CCM-016 status anchor occurred % time(s), expected 1; refusing to patch', v_hits;
  end if;
```

Five anchors, five assertions, plus two sanity checks on the generated text
before `execute`: it must mention `CM-BOARDFRESH-027`, and it must be longer than
what it replaced. A textual patch that cannot find its anchor does not patch the
wrong place. It aborts the migration.

---

## Verified live state at migration 290

```json
{"ok": true, "fresh": true, "authoritative": true,
 "board_age_hours": 0.01, "threshold_hours": 792,
 "cadence": "tf-controls-evaluate-monthly (0 14 1 * *)",
 "automated_total": 21, "scored_total": 21,
 "unscored_total": 0, "unscored_controls": [],
 "tautological_total": 0, "tautological_controls": [],
 "distinct_stamps": 1, "stamp_uniform": true,
 "population": {"controls_total": 27, "automated_total": 21, "manual_total": 6,
                "status_case_length": 3217, "evaluator_def_length": 19742}}
```

Register: **27 controls, 24 passing, 3 attention, 0 failing.** (Migrations 307
through 309 subsequently took this to **28 controls, 25 passing, 3 attention, 0
failing**, with `automated_total` at 22.)

The three on attention are unchanged and all are owner actions or intentional:
`AC-PRIV-002` (one anon-exposed definer function carrying a live exemption),
`AC-MFA-003` (one privileged account without MFA), `DP-PITR-007` (Point-in-Time
Recovery not yet enabled).

Corroborating checkers, all still clean after the evaluator was rewritten:
`tf_controls_signal_coverage` `gap_total 0` over 6 declared axes with
`refusal_flag_honoured true`; `tf_grant_tier_audit` `coverage_pct 100.0` over 94
functions with 0 violations; `tf_function_safety_audit` `undeclared_total 0`,
`drift_total 0`; `tf_security_scan` `ok true`.

`stamp_uniform` reads true and **that is not evidence of anything**. The payload
carries a note saying so, because the uniform stamp is exactly the observation
that made the first design wrong:

> `last_evaluated_at` is a write timestamp. The evaluator stamps every automated
> row from one statement, including rows its status CASE has no branch for, so a
> uniform stamp is not evidence that every row was scored. `unscored_total` and
> `tautological_total` are.

---

## The three obligations, discharged

Creating a `tf_*` function carries three obligations in the same migration.
Migration 288 discharged all three for `tf_controls_board`:

| Obligation | How | Enforced? |
|---|---|---|
| Apply a grant tier | `tf_apply_grant_tier('tf_controls_board', '', 'staff', ...)` | Yes, via `tf_grant_tier_audit uncovered_total` |
| Declare in the function registry | `insert into tf_function_registry ... 'read'` | No, detected by `tf_function_safety_audit undeclared_total` |
| Wire the signal into a control | `CM-BOARDFRESH-027`, migration 290 | No, detected by `tf_controls_signal_coverage` for scan axes |

Staff tier requires an in-body authorization predicate, and the function carries
the standard idiom. Migration 288's verification proved it by induction rather
than by inspection: it set `request.jwt.claims` to a known non-staff user, called
the function, and asserted the return value was `{"ok": false, "error":
"forbidden"}`.

---

## Runbook

**Is the board worth reading right now?**

```sql
select public.tf_controls_board();
```

Expect `ok: true`, `authoritative: true`. If `authoritative` is false, one of
three things is true and the payload says which: `fresh` is false and the board
is past its cadence, `unscored_total` is non-zero and `unscored_controls` names
the controls with no branch, or `tautological_total` is non-zero and
`tautological_controls` names the branches that assert instead of compute.

**The board refused. Now what?**

| `error` | Meaning | Action |
|---|---|---|
| `forbidden` | Caller is authenticated but not internal staff | Expected. Not a fault |
| `empty_register` | No automated controls for this company | The register was truncated or the company id is wrong |
| `never_evaluated` | No automated control carries a timestamp | Run `select public.tf_controls_evaluate();` |
| `evaluator_not_found` | `tf_controls_evaluate` is missing from the catalog | Restore it. Nothing is scoring the board |
| `status_case_marker_not_found` | The evaluator was reformatted and the reader can no longer parse it | Fix the reader in a migration. **Do not** trust a zero from a reader that cannot see |

**A migration refused with "anchor occurred N time(s), expected 1".**

Someone edited `tf_controls_evaluate` and moved a splice anchor. That is the
patch mechanism working. Re-read the live definition, pick a new anchor, and
assert it the same way.

**Re-score and confirm nothing is left failing.**

```sql
select public.tf_controls_evaluate();
```

House rule seventeen: any migration touching the register asserts the board's
aggregate state before it commits, not the state of the row it changed.

---

## Related

- `docs/CONTROL_SIGNAL_COVERAGE.md` — the migration 285 checker this one is the
  register-side twin of. 285 asks whether every declared axis has a consumer,
  288 through 290 ask whether every automated control has a scorer
- `docs/IT_GOVERNANCE_GRC.md` — the register itself, the cadence, and the
  current posture
- `docs/SECURITY_SCAN_INTEGRITY.md` — the undeclared-denominator finding that
  made the first design for this gate recognisable as wrong before it was built
- `docs/REGISTER_INTEGRITY.md` — the seeded register, migration 276, the
  original form of "the checker and the thing it checks must be independent"
- `docs/PLATFORM_KNOWLEDGE_BASE.md` — conventions 34 through 36, house rule
  eighteen, and the Pass 12 verification log
