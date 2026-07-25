# Security Scan Integrity — a scan that declares its population and refuses to report clean

`tf_security_scan()` is the single most-read checker on this platform. Control
`AC-DEFN-017` reads it, the control board renders it, and every security
conversation in this build has started by calling it. Until migration 280 it
had a defect that no amount of care in reading its output could have caught:

> **It reported `gap_total` without ever saying what it had counted over.**

A scan over an empty population returns zero gaps. So does a scan over a
perfectly hardened one. The payload was identical in both cases, and there was
no field in it that distinguished them.

State captured 2026-07-25 against Supabase project `kjooyhvynkzuvsixsutt` after
migration 283.

| Ordinal | Version | Name |
| --- | --- | --- |
| 280 | 20260725150224 | `security_scan_declares_its_population_and_refuses_to_report_clean_on_integrity_failure` |
| 281 | 20260725150253 | `retire_security_scan_exemptions_that_suppress_nothing` |
| 282 | 20260725150606 | `security_scan_exemptions_refuse_rows_that_suppress_nothing` |
| 283 | 20260725150711 | `security_scan_monitors_truncate_grants_and_separates_unreachable_tables_from_unpoliced_ones` |

Ordinals are the true `row_number() over (order by version)`. They are
contiguous here only because the concurrent Lovable agent happened not to deploy
during this window. **Cite these migrations by name.**

---

## Migration 280 — the scan declares its own denominator

The pre-existing function was `LANGUAGE sql STABLE SECURITY DEFINER`, oid 40929,
no arguments, returning exactly twelve keys: `rls_disabled_tables`,
`anon_secdef_nonpublic`, `secdef_no_searchpath`, `rls_enabled_no_policy`,
`secdef_authenticated_no_guard`, `secdef_authenticated_no_guard_fns`,
`gap_total`, `axes`, `exempt`, `guard_pattern_source`, `guard_helpers`,
`scanned_at`.

Every one of those twelve survives. That is convention 21 and it is not
negotiable: a checker may be decomposed and extended, never narrowed, because
somewhere a consumer reads the key you were about to drop.

Migration 280 rebuilt the body as `plpgsql` and added eight keys on top.

### The empty-population refusal

This sits at the top of the ladder and it is a `raise`, not an `ok: false`,
because a scan that cannot see its own subject has nothing to report at all.

```sql
if v_tables_total = 0 or v_secdef_total = 0 then
  raise exception 'tf_security_scan: empty population (tables %, security definer functions %). A scan over nothing reports zero gaps, and that is not the same thing as being clean.',
    v_tables_total, v_secdef_total;
end if;
```

### The guard axis as an explicit partition

The guard axis had been a single count. It is now a partition of the reachable
set, computed once and published in four parts, so the denominator is visible
next to the numerator.

```sql
with reach as (
  select p.proname,
         exists (select 1 from public.security_scan_exemptions e where e.proname = p.proname) as is_exempt,
         (public.tf_strip_sql_comments(pg_get_functiondef(p.oid)) !~* public.tf_guard_pattern()) as is_unguarded
    from pg_proc p
   where p.pronamespace = 'public'::regnamespace
     and p.prokind = 'f' and p.prosecdef
     and has_function_privilege('authenticated', p.oid, 'EXECUTE')
)
select (count(*))::int,
       (count(*) filter (where is_exempt))::int,
       (count(*) filter (where not is_exempt))::int,
       (count(*) filter (where not is_exempt and is_unguarded))::int,
       coalesce(jsonb_agg(proname order by proname) filter (where not is_exempt and is_unguarded), '[]'::jsonb)
  into v_reach_total, v_exempt_reach, v_unexempt_reach, v_unguarded, v_unguarded_names
  from reach;
```

`p.prokind = 'f'` is load-bearing. `pg_get_functiondef` raises `42809` on
aggregates.

### The axis-coupling raise

The declared axis list and the computed axis object were two independent pieces
of code that had to agree by hand. They now agree by assertion.

```sql
if v_axis_keys is distinct from v_axis_declared then
  raise exception 'tf_security_scan: the declared axis list and the computed axis object disagree. declared %, computed %. An axis that is computed but not declared is invisible to every consumer that iterates the declared list, and an axis declared but not computed reports a null gap as a zero gap.',
    v_axis_declared, v_axis_keys;
end if;
select coalesce(sum((v_axis_vals->>a)::int), 0)::int into v_gap from unnest(v_axis_order) a;
```

`gap_total` is no longer a hand-written sum of named variables. It is derived by
iterating the declared list, so adding an axis to the declaration and forgetting
to add it to the total is now impossible rather than merely unlikely.

### The `ok: false` refusal ladder

Three conditions push `integrity_total` above zero and flip `ok` to false:

```sql
if (v_exempt_reach + v_unexempt_reach) <> v_reach_total or v_unguarded > v_unexempt_reach then
  v_errors := v_errors || to_jsonb('guard_scan_partition_mismatch'::text);
end if;
if v_reach_total > 0 and v_unexempt_reach = 0 then
  v_errors := v_errors || to_jsonb('every_reachable_definer_function_exempted'::text);
end if;
if v_stale_total > 0 then
  v_errors := v_errors || to_jsonb('stale_exemptions_present'::text);
end if;
```

The second is the exemption-lever defect from `GUARD_DETECTION.md` reduced to its
limit case. If someone exempts every reachable function, the guard axis reads
zero and the scan is lying. It now refuses instead.

Migration 283 adds a fourth, `rls_no_policy_partition_mismatch`.

---

## Migration 281 — the exemption that suppresses nothing

This was found, not planned.

The concurrent Lovable agent inserted exemption rows for `tf_studio_funnel` and
`tf_studio_quality_gates` at 14:45:50. Migration 274 had already guarded both
functions at 14:35:27, ten minutes earlier. The exemptions therefore suppressed
nothing on the day they were written.

That sounds harmless. It is not.

> **A standing exemption over a function that is already guarded is a trap. It
> suppresses nothing today and it hides the finding the day the guard is
> removed.**

The exemption is a permanent instruction to the scanner to stop looking at that
function. While the guard is present the two agree. The moment somebody edits
that function and drops the guard, the exemption is the only thing left, and the
scanner reports clean.

Migration 280 had already added the detector. The predicate is deliberately the
**exact inverse** of the guard axis, so an exemption is stale precisely when the
axis would not have fired for it:

```sql
select (count(*))::int,
       coalesce(jsonb_agg(e.proname order by e.proname), '[]'::jsonb)
  into v_stale_total, v_stale_names
  from public.security_scan_exemptions e
 where not exists (
   select 1 from pg_proc p
    where p.pronamespace = 'public'::regnamespace
      and p.prokind = 'f' and p.prosecdef
      and p.proname = e.proname
      and has_function_privilege('authenticated', p.oid, 'EXECUTE')
      and public.tf_strip_sql_comments(pg_get_functiondef(p.oid)) !~* public.tf_guard_pattern()
 );
```

Migration 281 deleted the two rows and asserted the property that makes the
delete safe:

```sql
if v_deleted <> v_stale_before then
  raise exception 'deleted % row(s) but the scan reported % stale. The delete predicate and the axis predicate must be the same predicate.', v_deleted, v_stale_before;
end if;
if v_guard_after <> v_guard_before then
  raise exception 'guard axis moved % to % while retiring exemptions that suppress nothing. An exemption that suppressed nothing cannot change the count when removed, so either the axis or the staleness predicate is wrong.', v_guard_before, v_guard_after;
end if;
```

The second assertion is the whole argument in one statement. If removing an
exemption changes the guard count, the exemption was suppressing something and
the staleness predicate was wrong. The axis did not move. `exempt` is back to
the three deliberate entries: `tf_founding_stats`, `tf_rent_payments_enabled`,
`tf_security_scan`.

---

## Migration 282 — the register refuses rows that suppress nothing

Deleting two bad rows fixes today. A validating trigger fixes every tomorrow.

`public.tf_security_scan_exemption_validate()` is `RETURNS trigger`,
`SECURITY DEFINER`, `SET search_path TO 'public','extensions'`, and fires
`before insert or update` on `public.security_scan_exemptions`. It refuses a row
whose target:

| Condition | Refusal text |
| --- | --- |
| Does not exist | `no such function in schema public` |
| Is overloaded | ambiguous target, the exemption key cannot resolve |
| Is not `SECURITY DEFINER` | nothing to exempt, the guard axis never looks at it |
| Is not executable by `authenticated` | not reachable, so not in the scanned set |
| **Already carries a recognised guard predicate** | `A standing exemption over a guarded function is a trap, it hides the finding the day the guard is removed.` |
| Has a `reason` under 40 characters | `A one line reason is not a review.` |

It also defaults `approved_by` to `'platform-architecture'` and `approved_at` to
`now()`, so an exemption always carries attribution.

```sql
drop trigger if exists tg_security_scan_exemption_validate on public.security_scan_exemptions;
create trigger tg_security_scan_exemption_validate
  before insert or update on public.security_scan_exemptions
  for each row execute function public.tf_security_scan_exemption_validate();
```

Registered in both registers in the same transaction, per the standing rule that
a migration creating a function declares it where it is created:

```sql
insert into public.tf_function_registry (proname, declared_kind, rationale)
values ('tf_security_scan_exemption_validate', 'write',
        'RETURNS trigger. Rewrites new.approved_by and new.approved_at and refuses exemption rows that suppress nothing. Declared write on the migration 275 rule that a trigger function is a write path by construction.')
on conflict (proname) do update set declared_kind = excluded.declared_kind, rationale = excluded.rationale;

perform public.tf_apply_grant_tier('tf_security_scan_exemption_validate', '', 'admin', '...');
```

Three induction probes prove the refusals fire for the right reason rather than
merely fire. Each runs in its own `BEGIN ... EXCEPTION` block, which is an
implicit savepoint, so the fixture rolls back with zero residue:

```sql
if v_hits <> 3 then raise exception 'expected 3 induction refusals, observed %', v_hits; end if;
```

The markers required were `%no such function in schema public%`,
`%already carries a recognised guard predicate%`, and
`%A one line reason is not a review%`.

### The finding this migration produced by accident

The migration originally asserted that adding a validator which changes no grant
and no guard could not move the guard axis. It failed:

```
P0001: guard axis moved 1 to 0 while adding a validator that changes no grant and no guard.
```

That is not a defect in the assertion. It is a real property of Postgres and
Supabase together, and it had never been stated on this platform before:

> **The creation exposure window.** A brand-new `SECURITY DEFINER` function is a
> reachable, unguarded definer function at the instant it is created. Postgres
> grants `EXECUTE` to `PUBLIC` on every new function, and Supabase's
> `ALTER DEFAULT PRIVILEGES` adds `anon` and `authenticated` on top. The window
> closes only when `tf_apply_grant_tier` runs.

Rather than relax the assertion, the finding was encoded as the assertion. The
migration now proves both ends of the window on every replay:

```sql
if not v_reach_before then
  raise exception 'expected a newly created function to be executable by authenticated through the Supabase default privileges. It was not, so the exposure window this migration documents no longer works the way the grant tier convention assumes.';
end if;
if v_reach_after then
  raise exception 'the admin grant tier was applied but authenticated can still execute the validator. Revoking the PUBLIC pseudo-role alone does not undo the Supabase default grant.';
end if;
if v_guard_after <> v_guard_before - 1 then
  raise exception 'guard axis moved % to %, expected exactly % . Applying the admin tier removes exactly one function, the validator created in this transaction, from the reachable set.', v_guard_before, v_guard_after, v_guard_before - 1;
end if;
```

`has_function_privilege('authenticated', v_oid, 'EXECUTE')` read **true**
immediately after `CREATE FUNCTION` and **false** after the tier was applied, and
the guard axis fell by exactly one. The window is real, it is short, and it is
inside a transaction that has not committed, so it is not exploitable through
any live path. It matters because it explains why the grant tier must be applied
in the same migration as the create, and never in a follow-up.

---

## Migration 283 — the truncate axis, and unreachable is not unpoliced

This closes the open item that `LEAST_PRIVILEGE_TABLE_GRANTS.md` left standing
in its own words: *a control that fixed something once and never looks again is
not a control, it is a changelog entry.*

A sixth axis was added to the declared list:

```sql
v_axis_order text[] := array[
  'rls_disabled_tables','anon_secdef_nonpublic','secdef_no_searchpath',
  'rls_enabled_no_policy','secdef_authenticated_no_guard',
  'tables_truncatable_by_client'
];
```

Migration 272 revoked the grants. Migration 283 is what watches them. If a
future table lands with the historical broad ACL, whether from the
`supabase_admin` default-privilege residual or a hand-written grant, the scan
now counts it and names it in `tables_truncatable_by_client_tables`.

### The second half: separating unreachable from unpoliced

`rls_enabled_no_policy` had been reading 1 against
`studio_events_prelaunch_archive`, a table the concurrent agent created. That
table's ACL is:

```
{postgres=arwdDxtm/postgres,service_role=arwdDxtm/postgres}
```

No `anon`. No `authenticated`. It is RLS-enabled with zero policies, which by the
old axis looked like a gap, and it is in fact **correctly built**. A table no
client role can reach does not need a policy. The axis could not tell the
difference.

The count was **decomposed, not narrowed**, per convention 21. The original key
still reports 1. A new key reports the subset that actually matters:

```sql
with nopolicy as (
  select c.relname,
         (has_table_privilege('anon', c.oid, 'SELECT') or has_table_privilege('anon', c.oid, 'INSERT')
       or has_table_privilege('anon', c.oid, 'UPDATE') or has_table_privilege('anon', c.oid, 'DELETE')
       or has_table_privilege('authenticated', c.oid, 'SELECT') or has_table_privilege('authenticated', c.oid, 'INSERT')
       or has_table_privilege('authenticated', c.oid, 'UPDATE') or has_table_privilege('authenticated', c.oid, 'DELETE')) as client_reachable
    from pg_class c
   where c.relkind = 'r' and c.relnamespace = 'public'::regnamespace and c.relrowsecurity = true
     and not exists (select 1 from pg_policies pp where pp.schemaname = 'public' and pp.tablename = c.relname)
)
```

`rls_enabled_no_policy_reachable` reads **0**, with an empty
`rls_enabled_no_policy_reachable_tables`. The new integrity error
`rls_no_policy_partition_mismatch` fires if the subset ever exceeds its
superset.

---

## Verified live state

`tf_security_scan()` at 2026-07-25T15:10:42Z:

| Field | Value |
| --- | --- |
| `ok` | `true` |
| `integrity_total` | 0 |
| `errors` | `[]` |
| `gap_total` | 2 |
| `rls_disabled_tables` | 0 |
| `anon_secdef_nonpublic` | 1 (the deliberate `tf_founding_stats` public-stats exemption) |
| `secdef_no_searchpath` | 0 |
| `rls_enabled_no_policy` | 1 (`studio_events_prelaunch_archive`) |
| `rls_enabled_no_policy_reachable` | **0** |
| `secdef_authenticated_no_guard` | 0 |
| `tables_truncatable_by_client` | **0** |
| `stale_exemption_total` | 0 |
| `exempt` | `tf_founding_stats`, `tf_rent_payments_enabled`, `tf_security_scan` |

Population, which is the point of the whole exercise:

```json
{
  "tables_total": 174,
  "secdef_total": 120,
  "reachable_by_authenticated": 60,
  "exempt_reachable": 3,
  "unexempt_reachable": 57,
  "exemption_rows": 3,
  "guard_helpers": 15
}
```

Both remaining gaps are understood and neither is reachable by a client role.

Companion checkers at the same instant:

- `tf_grant_tier_audit()` — `ok true`, `violation_total 0`, `missing_total 0`,
  `uncovered_total 0`, `drift_total 0`, `coverage_pct 100`, `declared_total 93`,
  `tf_covered_total 92`, `tf_population_total 92`
- `tf_function_safety_audit()->'totals'` — 92 functions, 31 reads, 61 writers,
  6 trigger writers, 7 transitive writers, 24 documented diagnostics
- `tf_controls_evaluate()` — 23 controls, 19 passing, 3 attention, 1 failing,
  6 manual and all 6 never attested

---

## Runbook

**Full read-out.**

```sql
select jsonb_pretty(public.tf_security_scan());
```

**Is the scan trustworthy right now.** Read `ok` first, always. `gap_total` is
meaningless when `ok` is false.

```sql
select (public.tf_security_scan())->'ok'              as trustworthy,
       (public.tf_security_scan())->'errors'          as why_not,
       (public.tf_security_scan())->'population'      as what_it_counted;
```

**Find stale exemptions before they become traps.**

```sql
select (public.tf_security_scan())->'stale_exemptions';
```

Anything listed there is an exemption over a function that is not currently
reachable-and-unguarded. Retire it. Do not leave it "just in case", that is
precisely the trap.

**Add an exemption properly.** The trigger will refuse anything careless. The
`reason` must be at least 40 characters and it must be a review, not a label.

```sql
insert into public.security_scan_exemptions (proname, reason)
values ('tf_example',
        'Deliberately public: returns only aggregate counts with no tenant identifiers, reviewed against studio_events on 2026-07-25.');
```

**Re-harden and re-check after a bulk table creation.** Run the re-harden block
in `LEAST_PRIVILEGE_TABLE_GRANTS.md`, then confirm the axis reads zero:

```sql
select (public.tf_security_scan())->'tables_truncatable_by_client',
       (public.tf_security_scan())->'tables_truncatable_by_client_tables';
```

---

## Governing principles this batch established

1. **A checker must publish its denominator.** Zero gaps over an unknown
   population is not evidence of anything. `population` is now a first-class key
   and the empty case is a hard `raise`.
2. **An exemption that suppresses nothing is a trap, not a redundancy.** It
   hides the finding the day the guard is removed. Detect them, retire them,
   and refuse new ones at the register.
3. **The creation exposure window.** A `SECURITY DEFINER` function is reachable
   by `anon` and `authenticated` from `CREATE FUNCTION` until
   `tf_apply_grant_tier`. Apply the tier in the same migration, never a
   follow-up.
4. **Decompose, never narrow.** `rls_enabled_no_policy` kept its meaning and
   gained a reachable subset alongside it. Every consumer of the old key still
   reads the old number.
5. **The same-transaction measurement trap.** If a migration's `CREATE FUNCTION`
   precedes its `DO` block, both the before and after measurements inside that
   block already include the new function. Assert that the register write moves
   no catalog population, not that the population grows.
6. **When an assertion fails, ask whether it found something before assuming it
   is wrong.** Migration 282's failure was the most valuable output of this
   batch.

---

## Open items

- ~~**`tf_controls_evaluate` has no control on the new axes.**~~ **Closed by
  migrations 284 through 287.** `tables_truncatable_by_client` is now read by
  `CM-TRUNCGRANT-024`, the scan's `integrity_total` plus `stale_exemption_total`
  by `CM-SCANINTEG-025`, and the refusal flag itself now gates every scan-derived
  status. Migration 285 went further and built `tf_controls_signal_coverage()`,
  which detects the class rather than the instances: it compares the scan's
  declared axis list against the catalog definition of `tf_controls_evaluate` and
  names any axis nobody renders. Migration 287 wired that detector into
  `CM-SIGNALCOV-026` so the detector is not itself an unread signal. Live:
  `unread_total 0`, `refusal_flag_honoured true`, `gap_total 0` over 6 axes. Read
  `docs/CONTROL_SIGNAL_COVERAGE.md`.
- **`it_controls.status` is a cache with no freshness gate.** The board can
  render a stale evaluation as authoritative. Publish `evaluated_at` staleness
  and refuse to render past a threshold.
- **Six manual controls have never been attested.** Attestation is an owner
  action, not an engineering one.
- **The `supabase_admin` default-ACL residual remains open**, per
  `LEAST_PRIVILEGE_TABLE_GRANTS.md`. Migration 283 now monitors the symptom;
  the mechanism is untouched.
- **Two agents deploy to one production migration stream with no lock**, filed
  as ClickUp `86bb3etah` recommending an advisory lock plus a deploy log plus a
  `CM-DEPLOY` control.

---

## Related

- `docs/GUARD_DETECTION.md` — the guard predicate registry the axis matches
  against, and the exemption lever this document closes
- `docs/LEAST_PRIVILEGE_TABLE_GRANTS.md` — migration 272, whose monitoring gap
  migration 283 closes
- `docs/REGISTER_INTEGRITY.md` — the seeded-register finding and the
  savepoint-probe technique reused here
- `docs/FUNCTION_GRANT_TIERS.md` — `tf_apply_grant_tier` and the PUBLIC twin
  gotcha that the creation exposure window depends on
- `docs/CONTROL_SIGNAL_COVERAGE.md` — migrations 284 through 287, which wire the
  axes this document declares into control rows and then detect the class of
  defect where an axis has no consumer at all
- `docs/CONTROL_BOARD_FRESHNESS.md` — migrations 288 through 290, which apply
  this document's undeclared-denominator lesson to the control register itself:
  a board of green statuses with no age on it cannot be told apart from an
  abandoned one, and a status branch that asserts a literal cannot be told apart
  from one that computes
- `docs/PLATFORM_KNOWLEDGE_BASE.md` — conventions, house rules and the Pass 10,
  Pass 11 and Pass 12 verification logs
