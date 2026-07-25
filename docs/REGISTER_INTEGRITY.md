# Register Integrity — the checker that seeded its own oracle

Every checker on this platform compares live catalog reality against a **register**:
a table that states what each object is supposed to be. `tf_function_registry`
declares whether a function is a read or a write. `tf_function_grant_tiers`
declares which roles may execute it. `tf_guard_predicate_registry` declares what
counts as a guard. `tf_function_safety_patterns` declares what counts as a write
signal.

This is convention 7, "conventions live in tables, checkers read the tables," and
it has been the single highest-yield structural decision in the backend. Migrations
275 and 276 found the two ways it fails.

State captured 2026-07-25 against Supabase project `kjooyhvynkzuvsixsutt` after
migration 276 (`registers_validate_their_own_rows_against_the_catalog`). Every
number here was read out of the live database.

---

## The short version

A register is only as good as the two edges nobody looks at:

1. **Where the rows came from.** If a register was seeded from the output of the
   checker that reads it, the two agree by construction and will agree forever,
   including everywhere the checker was wrong on the day it seeded.
2. **What the table will accept.** If a register accepts any row a human can
   type, then a row that resolves to nothing is indistinguishable from a row that
   resolves correctly, and the ACL the row was supposed to apply never gets
   applied.

Migration 275 fixed a classifier blind spot. Migration 276 fixed the register
that had inherited it, and then made both registers refuse to hold a row they
cannot verify against the catalog.

---

## Migration 275: the trigger-function classifier blind spot

`tf_function_safety_audit()` decides whether each `tf_*` function is a read or a
write by matching its source text against `tf_function_safety_patterns`. The
`dml` signal class looks for `insert`, `update`, `delete`, `merge`, `truncate`.
A function whose body contains none of them, and which calls no function that
does, is classified `read`.

That is correct for ordinary functions and structurally wrong for one class:

> **A function that `RETURNS trigger` is a write path by construction.** It runs
> inside another statement's `INSERT`, `UPDATE` or `DELETE`, and its return value
> **is the row that statement writes**. Assigning to `new.*` is the mutation.
> There is no DML keyword anywhere in the body for a pattern sweep to find.

Three such functions were classified `read` by the pre-275 audit. The worst of
them was `public.tf_assign_job_number()`:

```sql
CREATE OR REPLACE FUNCTION public.tf_assign_job_number()
 RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $function$
begin
  if new.job_number is null or new.job_number !~ '^TF-[0-9]+$' then
    if new.job_number is not null and (new.legacy_job_number is null) then
      new.legacy_job_number := new.job_number;
    end if;
    new.job_number := 'TF-' || nextval('public.tf_job_number_seq')::text;
  end if;
  return new;
end $function$
```

It is attached as `tg_assign_job_number` on `public.jobs`. It rewrites the primary
human-facing identifier of every job the business creates, it consumes a sequence,
and it silently relocates a caller-supplied value into `legacy_job_number`. The
platform's own safety audit called it a read.

### The fix

Migration 275 patched the audit by the anchored catalog-patch idiom, six
replacements against `pg_get_functiondef` output, each asserted to have landed:

| Where | What was added |
| --- | --- |
| `raw` CTE | `(p.prorettype = 'pg_catalog.trigger'::regtype) as returns_trigger` |
| `base` CTE | carries `returns_trigger` forward |
| `writers` CTE | `... or cron_mutation or returns_trigger` |
| `joined` / `transitive_only` | `and not b.returns_trigger`, so a structural trigger writer is never mislabelled a transitive one |
| `totals` | new key `trigger_writers` |
| per-function payload | new key `returns_trigger` |

The classification is **structural, not textual**. It reads `pg_proc.prorettype`
against `pg_catalog.trigger`. There is no regex to defeat and no comment to hide
behind, which is the point: the previous three passes of this sweep all closed
defects in text matching, and the answer here was to stop matching text.

### The proof that made it worth trusting

Asserting "drift went down" would have proved nothing. Migration 275 asserted an
**exact partition**. Before patching, it computed the precise set of functions that
should flip, by catalog predicate rather than by expectation:

```sql
  select coalesce(array_agg(f->>'name' order by f->>'name'), '{}'::text[])
    into v_flip_names
    from jsonb_array_elements(v_base->'functions') f
    join pg_proc p on p.proname = f->>'name'
   where p.pronamespace = 'public'::regnamespace
     and p.prokind = 'f'
     and p.prorettype = 'pg_catalog.trigger'::regtype
     and f->>'computed_kind' = 'read';
  v_flip := coalesce(array_length(v_flip_names, 1), 0);
```

then, after patching, required the blast radius to match to the row:

```sql
  if a_reads <> b_reads - v_flip then
    raise exception 'blast radius wrong: reads moved % -> % but exactly % function(s) were reclassified, so reads should be %', b_reads, a_reads, v_flip, b_reads - v_flip;
  end if;
  if a_writers <> b_writers + v_flip then ... end if;
  if a_trans <> b_trans then
    raise exception 'transitive_writers moved % -> %. A structural trigger writer is not a transitive writer and must not be counted as one.', b_trans, a_trans;
  end if;
```

Every function that was not a trigger function is the control group. If the patch
had caught anything else, `reads` would have moved further than `v_flip` and the
migration would have rolled back. It did not.

---

## Migration 276: the seeded register

The classifier fix surfaced exactly one drift row: `tf_assign_job_number`,
declared `read` in `tf_function_registry`, now computed `write`. Reading the
declaration's own rationale is where this stops being a bug and becomes a lesson:

> `rationale: "Baseline classification seeded from tf_function_safety_audit() at
> migration 233."`

The register agreed with the checker **because the register was populated by the
checker.**

> **A register seeded from a checker inherits every blind spot that checker had on
> the day it was seeded, and from then on the two agree with each other forever.
> Agreement between a checker and a register it wrote is not corroboration.**

This is the quietest failure mode in the whole design, because it presents as
health. `drift_total` had read 0 for dozens of migrations. Three functions that
rewrite production rows were declared reads, the drift checker confirmed the
declaration matched, and both were reading from the same mistake.

Seeding a register from a checker is sometimes the only practical way to
bootstrap one, and it was the right call at migration 233 for 80-odd functions.
What was missing was the record that it happened. The rationale string is the only
reason this was diagnosable at all, and it is now the reason the corrected rows
say what corrected them.

### The related defect: the mis-keyed register row

`tf_function_grant_tiers` is keyed on `(proname, ident_args)` where `ident_args`
must be the output of `pg_get_function_identity_arguments`, for example
`'p_days integer'`. `tf_grant_tier_audit()` resolves each row back to a
`pg_proc.oid` through that exact key.

The concurrent Lovable agent, deploying the Studio Analytics feature during this
session, inserted rows directly into the table keyed on the bare **type list**,
`'integer'`. Those rows:

- resolved to no function at all,
- counted toward `missing_total` as violations,
- and, most importantly, **never applied the ACL they declared**, because
  `tf_apply_grant_tier` is what applies grants and it was never called.

> **A register row written by hand instead of through its applier is a
> declaration with no enforcement behind it and no key discipline in front of it.**

### The fix: registers that refuse

Migration 276 corrected the class rather than the instance. It did not update the
one bad row; it updated every row matching the defective predicate:

```sql
  update public.tf_function_registry r
     set declared_kind = 'write',
         rationale = coalesce(r.rationale,'') || ' Corrected at migration 276: RETURNS trigger. ...',
         updated_at = now()
   where r.declared_kind = 'read'
     and exists (select 1 from pg_proc p
                  where p.pronamespace = 'public'::regnamespace
                    and p.proname = r.proname and p.prokind = 'f'
                    and p.prorettype = 'pg_catalog.trigger'::regtype);
```

Then it attached a `BEFORE INSERT OR UPDATE` row trigger to each register.

**`tf_function_registry_validate`** refuses two classes of row:

- a `proname` that names no function in schema `public`
- `declared_kind = 'read'` on anything that `RETURNS trigger`

**`tf_grant_tier_registry_validate`** does something slightly different. It
**canonicalises** rather than refusing, where canonicalising is unambiguous:

- if `(proname, ident_args)` already resolves, pass it through
- if `proname` resolves to exactly one function, rewrite `ident_args` to the
  catalog's own `pg_get_function_identity_arguments` output and `raise notice`
  that it did
- if `proname` resolves to nothing, refuse
- if `proname` is overloaded more than one way, refuse, because there is no single
  correct answer to guess

Both validators are deliberately **`SECURITY INVOKER`**. They add nothing to the
reachable-definer population that `AC-DEFN-017` has to reason about. A validator
that hardens one control by widening another's surface is not a net gain.

The canonicaliser works against `tf_apply_grant_tier`'s upsert because of a
specific Postgres ordering rule:

> For `INSERT ... ON CONFLICT`, `BEFORE ROW INSERT` triggers fire **before**
> conflict detection. A BEFORE trigger that rewrites the conflict key therefore
> redirects the upsert onto the corrected key.

### The four inductions

Migration 276 proved each refusal live, and asserted not merely that a refusal
happened but that it happened **for the right reason**, by matching on marker
substrings of the message:

| # | Induced | Required marker |
| --- | --- | --- |
| 1 | insert a registry row for a function that does not exist | `no such function in schema public` |
| 2 | re-declare `tf_assign_job_number` as `read` | `cannot be declared read` |
| 3 | insert a grant-tier row for a phantom identity | `no such function identity` |
| 4 | **replay the exact defect**: hand-write `('tf_studio_funnel','integer')` | must land on `('tf_studio_funnel','p_days integer')` with zero rows left keyed `'integer'` |

Induction 4 is the one that matters. It is not a synthetic test, it is the
production incident from earlier the same day, replayed against the new control,
and required to come out differently.

All four ran inside a savepoint probe and were rolled back.

### The savepoint probe

Worth naming as a technique, because it is now used in three migrations. A
PL/pgSQL `BEGIN ... EXCEPTION` block is an implicit savepoint. Plain variables are
**not** transactional and survive the rollback. So:

```sql
  begin
    insert into public.studio_founding_applications
      (company_name, contact_name, email, status)
    values ('ZZ Probe', 'ZZ Probe', '  ZZ.Probe@Example.COM  ', 'pending')
    returning email, status into v_probe_mail, v_probe_stat;
    raise exception 'zz_probe_rollback';
  exception when others then
    if sqlerrm <> 'zz_probe_rollback' then raise; end if;
  end;
  if v_probe_mail <> 'zz.probe@example.com' then
    raise exception 'trigger probe failed: guard did not normalise the email, got "%"', v_probe_mail;
  end if;
```

This proves live behaviour against production tables with **zero residue**. Every
migration using it also asserts the row counts are unchanged and that no `zz\_%`
rows survive.

It is how migration 274 proved that `tf_founding_guard` still fires after its
`EXECUTE` privilege was revoked, which is a genuinely counter-intuitive result:

> **Postgres checks `EXECUTE` on a trigger function at `CREATE TRIGGER` time, not
> at fire time.** Revoking `EXECUTE` from client roles on a trigger function does
> not stop the trigger firing. It only stops someone calling it directly.

That is what makes `admin` the correct grant tier for every trigger function on
the platform. There is no functional cost to it.

---

## Live state after migration 276

```
tf_function_safety_audit()
  ok: true   functions: 91   reads: 31   writers: 60
  trigger_writers: 5   transitive_writers: 7   documented_diagnostics: 24
  drift_total: 0   undeclared_total: 0   stale_total: 0
  diagnostic_violation_total: 0   misleading_total: 7

tf_grant_tier_audit()
  ok: true   violation_total: 0   drift_total: 0   missing_total: 0
  uncovered_total: 0   coverage_pct: 100
  declared_total: 92   tf_covered_total: 91 of 91
```

`trigger_writers` is 5, not 3, because the two validators created by migration 276
are themselves trigger functions and were declared in both registers in the same
transaction that created them. That is house rule 8, and it is the reason the
number moved by exactly the amount it should have.

---

## Troubleshooting

| What you see | Most likely cause | First check |
| --- | --- | --- |
| `tf_function_grant_tiers` insert fails with `no such function identity` | the function was dropped, or `proname` is misspelt | `select proname, pg_get_function_identity_arguments(oid) from pg_proc where pronamespace='public'::regnamespace and proname like '%<fragment>%'` |
| Insert fails with `is overloaded N ways` | genuinely ambiguous; the canonicaliser will not guess | supply the exact `pg_get_function_identity_arguments` string for the overload you mean |
| `tf_function_registry` insert fails with `cannot be declared read` | you are declaring a `RETURNS trigger` function as a read | it is a write by construction; declare `write`. See migration 275 |
| A `notice` says `canonicalised ident_args` | a caller wrote a type list instead of an identity-argument string | harmless, the row was corrected, but find the caller and route it through `tf_apply_grant_tier` |
| `missing_total` is non-zero | a register row resolves to no function | `select * from public.tf_grant_tier_audit() -> 'violations'`; rows predating migration 276 are not validated retroactively |

Both validators can be inspected with
`select pg_get_functiondef(oid) from pg_proc where proname in ('tf_function_registry_validate','tf_grant_tier_registry_validate')`.

---

## Related

- `docs/FUNCTION_SAFETY_AUDIT.md` — the classifier itself, its five signal
  classes, and the two earlier refusal defects closed by migrations 268 and 269
- `docs/FUNCTION_GRANT_TIERS.md` — the three-tier grant convention,
  `tf_apply_grant_tier`, and why the coverage denominator had to be published
- `docs/LEAST_PRIVILEGE_TABLE_GRANTS.md` — the table-privilege counterpart, and
  the `TRUNCATE` finding
- `docs/PLATFORM_KNOWLEDGE_BASE.md` — conventions 27 and 28, house rule 14, the
  defect-pattern library and the Pass 9 verification log
