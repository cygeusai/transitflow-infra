# Function Safety Audit — and the two ways a refusal fails

`public.tf_function_safety_audit()` is the checker behind control
`CM-FNDRIFT-018` and auto-ticket key `safety:function_drift`. It answers one
question: does every `tf_*` function in `public` behave the way
`tf_function_registry` says it behaves?

State captured 2026-07-25 against Supabase project `kjooyhvynkzuvsixsutt` at
migration 269. Every number below was read out of the live database.

---

## What it does

The audit reads the source text of every `tf_*` function out of
`pg_get_functiondef`, strips nothing, and matches it against
`public.tf_function_safety_patterns`, a fifteen-row table of regular expressions
grouped into five signal classes.

| Signal | Rows | What it detects |
| --- | --- | --- |
| `dml` | 5 | `insert` / `update` / `delete` / `merge` / `truncate` |
| `http` | 4 | outbound calls through `net.http_post` and friends |
| `vault_write` | 2 | writes into the Vault |
| `vault_read` | 3 | reads out of the Vault |
| `cron_mutation` | 1 | `cron.schedule` / `cron.unschedule` |

From those signals it computes, per function, a `computed_kind` of `read` or
`write`, compares it against the declared `side_effect` in
`tf_function_registry`, and returns the disagreements.

The payload has fifteen top-level keys. The ones that matter to an operator:

| Key | Meaning | Gates |
| --- | --- | --- |
| `ok` | the checker completed and its answer is usable | yes, since migration 269 |
| `drift_total` | declared kind disagrees with computed kind | `CM-FNDRIFT-018` |
| `undeclared_total` | a `tf_*` function with no registry row | `CM-FNDRIFT-018` |
| `stale_total` | a registry row naming a function that no longer exists | `CM-FNDRIFT-018` |
| `diagnostic_violation_total` | a function documented as a diagnostic that writes | `CM-FNDRIFT-018` |
| `misleading_total` | a function whose *name* implies a read and which writes | nothing, deliberately, see below |
| `secret_touchers` | every function that reads or writes the Vault | nothing, it is an inventory |
| `totals` | `functions`, `reads`, `writers`, `transitive_writers`, `documented_diagnostics` | population, see below |

Live at migration 269: `ok` true, 84 functions, 55 writers, 29 reads, 7
transitive writers, 20 documented diagnostics, `drift_total` 0,
`undeclared_total` 0, `stale_total` 0, `diagnostic_violation_total` 0,
`misleading_total` 7, `secret_touchers` 18.

---

## The defect at migration 268: a refusal that omitted one of its own inputs

Because detection rules live in a table (convention 14), the table is an input
to the checker, and an input that goes missing has to be a refusal rather than a
silent zero. The audit already knew this. It carried a guard:

```sql
if v_dml is null or v_http is null or v_vw is null or v_cron is null then
  return jsonb_build_object('ok', false, 'error', 'pattern_table_empty');
end if;
```

Four signals. There are five. `v_vr`, the vault-read pattern, was not checked.

That omission is not cosmetic, because of how the signals are consumed. Each
per-function classification is a regex match of the form `body ~* v_vr`. In
Postgres, `anything ~* null` evaluates to **null**, not false, and the surrounding
expression coalesces it to false. So deleting the three `vault_read` rows does
not raise, does not warn, and does not empty anything visible. It makes
`vault_read` read false for all 84 functions at once.

The observable consequence: `secret_touchers`, the list of every function that
touches the Vault, is computed as `where vault_read or vault_write`. With the
vault-read signal silently dead it collapses from **18 entries to 1** — the one
function that also writes — underneath a payload still reporting `ok: true`,
still reporting 84 functions, still reporting zero drift. The inventory of
secret-touching code on this platform can be emptied by deleting three rows from
a table, and nothing anywhere says so.

Migration 268 closed it three ways.

**The refusal covers every signal it reads, and names what is missing.**

```sql
if v_dml is null or v_http is null or v_vw is null or v_vr is null or v_cron is null then
  return jsonb_build_object(
    'ok', false,
    'error', 'pattern_table_empty',
    'missing_signals', coalesce((
      select jsonb_agg(s.signal order by s.signal)
        from unnest(array['dml','http','vault_write','vault_read','cron_mutation']) as s(signal)
       where not exists (select 1 from public.tf_function_safety_patterns p where p.signal = s.signal)
    ), '[]'::jsonb));
end if;
```

Naming the missing signal is the part that turns a refusal into a diagnosis. The
old form told an operator the pattern table was empty. It did not tell them
*which* rules had gone, which is the only fact that lets them put the right ones
back.

**It refuses to certify an empty population.** House rule eleven, applied here:

```sql
if coalesce((v_out->'totals'->>'functions')::int, 0) = 0 then
  raise exception 'tf_function_safety_audit refuses to certify an empty population: 0 tf_ function(s) in schema public. A safety audit that examined nothing is not a pass.';
end if;
```

With no `tf_*` function in scope the payload is every counter at zero under
`ok: true`, which on the control board is indistinguishable from a platform with
nothing wrong with it.

**It filters `prokind`.** Every other catalog sweep on this platform filters
`p.prokind = 'f'`, because `pg_get_functiondef` raises `42809` on an aggregate.
This one did not, so a `tf_*` aggregate would have taken the audit down rather
than been classified. Now it is classified out.

### How migration 268 proved it

The pattern-table deletion is inducible against the live table, so the load-
bearing arm of the proof is a genuine induction, not a clone. The clone in part A
exists only to hold the *pre-fix* behaviour side by side with the fixed function
under the same induced condition.

Baseline first computes `v_vr_only`, the count of functions flagged `vault_read`
and not `vault_write` — precisely the quantity the defect drops — and raises if it
is zero, because then the drop would be unobservable and the proof would be
vacuous.

Part A builds `zz__fnsafety_268_prefix_clone()` from the live catalog text by
three asserted substitutions: rename, strip `SECURITY DEFINER` so the clone does
not perturb the definer-scan population it is measuring, and revert the guard to
its four-signal form. Each substitution is asserted to have landed, and the
branch under test is asserted to have survived. Then, inside an exception-
protected block, the three `vault_read` rows are deleted and the two functions
are called against the same broken table:

- the clone returns `ok: true`, zero functions flagged `vault_read`, and
  `secret_touchers` of exactly `v_base_st - v_vr_only`. Not zero. The earlier
  draft of this assertion expected zero and failed, because the two
  `vault_write` patterns still fire. Asserting the exact arithmetic instead of a
  round number made the proof sharper, and it is the reason this section can
  state 18 → 1 rather than "it shrank".
- the live fixed function returns `ok: false`, `error: 'pattern_table_empty'`,
  and `missing_signals` containing exactly one entry, `vault_read`.

The handler drops the clone and re-raises. Restore is by
`jsonb_populate_recordset` from the saved rows, followed by assertions that the
row count is back to 15, the audit is `ok: true` again, functions is 84 and
`secret_touchers` is 18.

Part B builds `zz__fnsafety_268_emptypop_clone()` with the name filter
substituted to a prefix nothing matches, calls it, captures the raise through
`get stacked diagnostics`, and asserts the message names both the refusal and the
denominator it refused over. Both clones dropped, zero `zz\_%` residue asserted,
`CM-FNDRIFT-018` re-read at `passing`.

---

## The larger defect at migration 269: the refusal nobody was listening to

Fixing the audit's refusal raised the obvious next question. A refusal is a
message. Who reads it?

`public.tf_controls_evaluate()` pulls six checker payloads and turns each into a
control status:

| Consumer | Checker | Control |
| --- | --- | --- |
| `v_fn_bad` | `tf_function_safety_audit` | `CM-FNDRIFT-018` |
| `v_bool_haz` | `tf_boolean_default_hazards` | `CM-BOOLDEF-019` |
| `v_oob` | `tf_automation_out_of_band` | `CM-AUTOARM-020` |
| `v_gt` | `tf_grant_tier_audit` | `CM-GRANT-021` |
| `v_nd` | `tf_automation_note_drift` | `CM-NOTEDRIFT-022` |
| `v_gd` | `tf_guard_detection_audit` | `AC-GUARDREG-023` |

All six checkers emit an `ok` key and all six have live paths that return
`ok: false`. **Exactly one consumer read the flag.** `v_gd`, and only because it
was written after migration 265 taught the lesson. The other five read straight
past it to the counter they wanted, and every one of those reads is wrapped in
`coalesce(..., 0)`.

So a refusing checker arrived at the control board as a clean zero. And every one
of the five status rules maps zero to `passing`.

That is the whole defect, and it is worse than any single checker's blind spot,
because it is *general*: it converts every refusal any of those five checkers
will ever emit, present or future, into a green light. The work of migrations
262, 263, 265, 266 and 268 — teaching checkers to refuse rather than certify
nothing — was landing in a consumer that treated refusal and cleanliness as the
same word.

A survey of the refusal channels made the reach concrete:

| Checker | Refuses by return | Refuses by raise |
| --- | --- | --- |
| `tf_automation_note_drift` | yes, 1 path | no |
| `tf_automation_out_of_band` | yes, 1 path | no |
| `tf_boolean_default_hazards` | yes, 1 path | no |
| `tf_grant_tier_audit` | yes, 1 path | yes |
| `tf_function_safety_audit` | yes, 2 paths | yes |
| `tf_guard_detection_audit` | yes, 1 path | yes |
| `tf_security_scan` | no `ok` key at all | yes, caught by the evaluator |

Note the asymmetry that made this survive so long. A checker that refuses by
`raise` is caught by the evaluator's exception handler and propagates null, and
null maps to `attention`. A checker that refuses by *return value* was invisible.
The four checkers in the first three rows can only refuse by return, so for those
four the refusal channel was completely unheard.

Migration 269 gave all six consumers the same shape:

```sql
v_gt := case when v_gtj is null or coalesce(v_gtj->>'ok','false') <> 'true' then null
             else coalesce((v_gtj->>'violation_total')::int,0) end;
```

Null rather than zero, so the existing `null → attention` arm of every status
rule carries it onto the board. Verification counts the idiom in the patched body
and requires exactly six.

### How migration 269 proved it

This is the strongest proof shape used on the platform so far, because there is
no clone anywhere in the load-bearing arm. The defect is demonstrated **live,
before the patch, in the same transaction that applies it.**

The lever is the `forbidden` guard. Four of the five defective consumers refuse
only on that guard, which fires when `auth.uid()` is non-null and the caller is
not internal staff. Inside a migration `auth.uid()` is normally null, which is
why this looked un-inducible for a long time. It is not:

```sql
perform set_config('request.jwt.claims',
                   '{"sub":"' || v_nonstaff::text || '","role":"authenticated"}', true);
```

Pointing that at the known non-staff user makes every read-path checker on the
platform take its refusal branch simultaneously. `set_config(..., '', true)`
clears it, because the empty string passes through `nullif` to null.

The migration runs three blocks around an `on commit drop` temp table:

1. **Before the patch.** Clear claims, evaluate, snapshot the entire board.
   Assert the five target controls read `passing` at baseline. Induce the
   refusal, and assert it actually happened — assert `auth.uid()` came back
   non-null, assert the chosen identity is *not* internal staff, and assert each
   of the five checkers really returns `ok: false`. Re-evaluate, then assert the
   defect on the record: each of the five controls still reads `passing` while
   its checker is refusing.
2. **The control group, in the same evaluation.** `AC-GUARDREG-023` must read
   `attention` under the identical refusal. Same board, same call, same broken
   condition, different answer, and the only difference is that its consumer was
   written after the lesson. This is what rules out "the evaluation was not
   really refusing" as an explanation for the other five.
3. **After the patch.** Re-induce, assert all six now read `attention` and none
   reads `passing`. Clear claims, re-evaluate, and assert exact recovery: status
   and evidence string for the six, plus whole-board status equality against the
   baseline snapshot.

---

## `misleading_total` is 7 and gates nothing

Stated here rather than left to be discovered. Seven functions carry names that
imply a read and write directly: `tf_access_review`, `tf_controls_evaluate`,
`tf_integration_health_report`, `tf_it_governance_report`, `tf_ops_report`,
`tf_scheduler_health`, `tf_system_health`.

None of these is a defect. Each is a report or an evaluator that legitimately
persists what it computed. The naming is the platform's oldest convention debt
and it is documented in *The first ten minutes* side-effect table precisely so
nobody calls one expecting it to be inert.

The judgement recorded at migration 269 is that `misleading_total` should be
**surfaced in evidence, not made to gate**. Making it gate would flip
`CM-FNDRIFT-018` to `failing` over seven pre-existing naming choices, which
trains operators to read a failing control as noise. That is a worse outcome than
the naming itself. It is listed in *The open register* so the decision is
revisited rather than forgotten.

This is the one place on the platform where house rule eleven's question — *what
fails when this number goes bad?* — is answered "nothing" **on purpose**, with
the reason written down. The rule is that an ungating metric must be either
promoted or explained. This one is explained.

---

## Troubleshooting

| What you see | Cause | Do this |
| --- | --- | --- |
| `CM-FNDRIFT-018` reads `attention` with no evidence | the audit returned `ok: false` or raised, and since migration 269 the evaluator honours that | `select public.tf_function_safety_audit();` and read `error` and `missing_signals` |
| `error: pattern_table_empty`, `missing_signals: ["vault_read"]` | somebody deleted pattern rows | reseed the named signal class from the migration that created it; do not seed a placeholder regex, an over-broad pattern flags everything |
| `refuses to certify an empty population` | no `tf_*` function matched the sweep | check the name filter and `prokind`; if the schema really is empty, that is a restore problem, not an audit problem |
| `secret_touchers` shrank between two readings | either functions genuinely stopped touching the Vault, or the `vault_read` signal is gone. Since migration 268 the second case refuses instead | compare `select count(*) from tf_function_safety_patterns where signal='vault_read'` against 3 |
| `42809` from the audit | a `tf_*` aggregate exists; since migration 268 it is filtered out rather than fatal | if you see this, the deployed body predates 268 |
| Five controls all green while the platform is clearly refusing reads | the deployed `tf_controls_evaluate` predates migration 269 | count the ok-flag idiom in the body; it must appear six times |

---

## Related

- `docs/PLATFORM_KNOWLEDGE_BASE.md` — conventions 26, house rule 13, the
  defect-pattern library, and the Pass 8 verification log
- `docs/GUARD_DETECTION.md` — the sibling checker, and where conventions 24 and
  25 were established
- `docs/FUNCTION_GRANT_TIERS.md` — where conventions 20 through 23 were
  established
- `supabase/migrations/MIGRATIONS_INDEX.md` — migrations 268 and 269
