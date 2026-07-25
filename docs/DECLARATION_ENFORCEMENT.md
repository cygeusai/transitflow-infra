# Declaration Enforcement

**Migrations 307 through 309.** How Transit & Flow made it *impossible* to create a
`public.tf_*` function without declaring it in `tf_function_registry`, rather than
merely detectable after the fact.

---

## The thesis

Convention 33 says that creating a `tf_*` function carries three obligations in
the same migration:

1. apply a grant tier,
2. declare the function in `tf_function_registry`,
3. wire its signal into a control.

Until migration 307, only the first was structurally enforced. A function created
without a grant tier is reachable by `anon` at the instant it exists, which is a
security defect the platform refuses to leave to discipline, so
`tf_apply_grant_tier` and the `CM-GRANT-021` chain make it impossible to ship one
quietly. Obligations two and three were **detected**, not enforced.
`tf_function_safety_audit` publishes `undeclared_total`, a control reads it, and a
human eventually notices.

Detection and enforcement are not the same guarantee, and the difference is not
academic. A detected obligation is satisfied on the auditor's schedule. An
enforced one is satisfied on the author's, because the author cannot proceed
until it is. The window between "a migration created an undeclared function" and
"the monthly evaluation noticed" is up to a month wide, and everything the
registry is used for, the read/write classification, the safety audit, the
function inventory, is wrong for the whole width of that window.

This batch closes obligation two. It is now structurally impossible. The
mechanism is a `ddl_command_end` event trigger plus a deferred constraint
trigger, and the reason it takes two triggers rather than one is the most
interesting thing in the batch.

---

## The design that the catalog killed

The obvious design is the one everybody writes first: refuse at
`CREATE FUNCTION` time. Put an event trigger on `ddl_command_end`, and if the new
function is `public.tf_*` and has no `tf_function_registry` row, raise. The author
is then forced to write the registry insert **before** the `CREATE FUNCTION`
statement, and the ordering is self-documenting.

That design is impossible on this platform, and the catalog says so before a line
of it is written. `tf_function_registry_validate`, the validating trigger attached
by migration 276, contains this:

```sql
if not exists (
  select 1 from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = new.proname and p.prokind = 'f'
) then
  raise exception '...' using errcode = 'check_violation';
end if;
```

A registry row **cannot precede its function**. Migration 276 made that true
deliberately, to stop the register drifting into a wish list of functions that
were never built, and it is a good rule. It also means declare-then-create is not
available, so enforcement cannot live at `CREATE FUNCTION` time. There is no
instant during the migration at which both the declaration requirement and the
existence requirement can be satisfied by ordering alone.

This is the same shape as the write-timestamp trap from migration 288, where the
first freshness detector was disproved by reading `tf_controls_evaluate`'s single
`UPDATE` rather than by shipping it and watching it report zero forever. The
lesson repeats: **read the catalog before writing the detector.** In both cases
the disproof cost one query and saved a migration that would have looked correct
and measured nothing.

The same validator also refuses `declared_kind = 'read'` for any function that
`RETURNS trigger`, which is the migration 275 finding, and it is why both new
event-trigger functions in this batch are declared `write`.

---

## The transaction is the enforcement point

If enforcement cannot happen at `CREATE FUNCTION`, the next question is what
"in the same migration" actually means. It means **in the same transaction**.
Migration 307 opens by proving that claim rather than assuming it, because the
whole design rests on it.

A probe migration created `public.tf_txn_probe` and then raised. Afterwards the
table did not exist and `supabase_migrations.schema_migrations` still read 306, so
`apply_migration` is transactional: a failed migration writes no version row and
can be re-submitted unchanged. That is worth recording on its own, separate from
this batch, because it means every migration in this repository has always been
all-or-nothing and assertion blocks at the end of a migration are genuinely
pre-commit gates rather than post-hoc complaints.

A second probe confirmed the lever exists at all. The `postgres` role on this
project has `rolsuper = false`, and event-trigger creation is normally reserved to
superusers. The probe created an event trigger and then raised a deliberate
message; it returned the message rather than a permission error, so the capability
is present. The pre-existing `ensure_rls` event trigger, function
`rls_auto_enable`, is also `postgres`-owned, which corroborates it.

Given a transaction boundary that is real and reachable, the enforcement point is
`COMMIT`. Any order of statements inside the migration is acceptable. What is not
acceptable is committing with the obligation unmet.

---

## The mechanism

Three objects, in one migration.

**A transient queue.** `public.tf_declaration_pending` holds one row per `tf_*`
function created or renamed in the current transaction that does not yet have a
registry row.

```sql
create table if not exists public.tf_declaration_pending (
  proname          text primary key,
  object_identity  text not null,
  command_tag      text not null,
  created_by       text not null default current_user,
  queued_at        timestamptz not null default now()
);
revoke all on table public.tf_declaration_pending from public, anon, authenticated;
```

Its table comment states the invariant that makes it auditable:

> Transient queue. A row exists only between the moment a `public.tf_*` function is
> created or renamed and the commit of the transaction that did it. Outside a
> transaction this table is empty by construction. A row that outlives a commit
> means the deferred check did not run, and that is itself a finding.

**An event trigger that only ever enqueues.** `tf_registry_declaration_required()`
fires on `ddl_command_end`, filters to `CREATE FUNCTION` and `ALTER FUNCTION` in
`public` on `prokind = 'f'` names matching `tf\_%`, skips anything already
declared, and inserts. It raises nothing. It is not `SECURITY DEFINER`.

```sql
for r in select * from pg_event_trigger_ddl_commands() loop
  if r.command_tag not in ('CREATE FUNCTION', 'ALTER FUNCTION') then continue; end if;
  if r.schema_name is distinct from 'public' then continue; end if;
  select p.proname into v_proname from pg_proc p where p.oid = r.objid and p.prokind = 'f';
  if v_proname is null or v_proname not like 'tf\_%' then continue; end if;
  if exists (select 1 from public.tf_function_registry g where g.proname = v_proname) then continue; end if;
  insert into public.tf_declaration_pending (proname, object_identity, command_tag)
  values (v_proname, r.object_identity, r.command_tag)
  on conflict (proname) do nothing;
end loop;
```

**A deferred constraint trigger that refuses at commit.**

```sql
create constraint trigger tf_declaration_pending_deferred_check
  after insert on public.tf_declaration_pending
  deferrable initially deferred
  for each row execute function public.tf_declaration_pending_check();
```

`DEFERRABLE INITIALLY DEFERRED` moves the firing to `COMMIT`. The function
re-reads the authoritative condition rather than trusting the queue:

```sql
if exists (select 1 from public.tf_function_registry g where g.proname = new.proname) then
  delete from public.tf_declaration_pending p where p.proname = new.proname;
  return null;
end if;
raise exception 'Refused at commit: public.% was created or renamed in this transaction with no row in public.tf_function_registry. Convention 33 obligation two requires the declaration in the same migration as the creation.', new.proname
  using errcode = 'check_violation',
        hint = 'The declaration cannot precede the creation, because tf_function_registry_validate refuses a row for a function that does not exist yet. Create the function first, then insert into public.tf_function_registry (proname, declared_kind, rationale), both inside one transaction. This check runs at COMMIT, so any order inside the transaction is accepted.';
```

Two properties are worth naming.

**It is fail-closed against tampering with the queue.** Deleting the pending row
does not bypass the check, because the check is already scheduled against that row
and re-evaluates the registry, not the queue. The queue is a *scheduling
mechanism*, never the source of truth.

**The hint teaches the correct ordering.** A refusal that only says "no" costs the
next author a debugging session. This one states the constraint that makes the
naive fix impossible and gives the working sequence, because the failure mode it
guards against is precisely one an author will try to fix in the wrong direction.

---

## The evidence

Three probes, each written to abort so nothing persisted.

**Negative test.** A migration created `public.tf_zzz_negative_probe` with no
registry row and attempted to commit. It returned, verbatim:

> `ERROR: 23514: Refused at commit: public.tf_zzz_negative_probe was created or
> renamed in this transaction with no row in public.tf_function_registry.
> Convention 33 obligation two requires the declaration in the same migration as
> the creation.`

plus the full hint. `23514` is `check_violation`, which is the code the raise
declares, so the refusal came from this mechanism and not from something else
failing coincidentally.

**Positive test.** A migration created a function *and* declared it, then raised
its own message rather than committing. It returned "positive probe: declaration
accepted, pending queue holds 1 row(s) mid-transaction, rolling back", which
establishes both that the guard does not over-fire on the compliant path and that
the queue does hold a row mid-transaction, exactly as the table comment says.

**Falsifiability test.** The strongest of the three. A migration disabled the
event trigger, ran the checker and the evaluator, re-enabled it, ran both again,
then rolled back. It returned:

> disabled -> state=disabled, gap=1, `CM-FNDECL-028`=failing; re-enabled -> gap=0,
> `CM-FNDECL-028`=passing. Rolling back.

A control that cannot be made to fail on demand is decoration. This one was made
to fail, and made to pass again, inside a single self-aborting transaction.

There is a fourth piece of evidence that required no probe at all. Migration 308
creates `tf_declaration_enforcement_audit` and declares it. That migration
committed. Its commit **is** the proof the satisfied path works in production
conditions, since the mechanism was live and watching while it ran.

---

## The kill switch, and why its presence is monitored

The mechanism has exactly one off switch:

```sql
alter event trigger tf_require_function_declaration disable;
```

That requires ownership of the trigger, so it is not available to any client role,
and it is a DDL statement, so it is auditable. It cannot be removed by accident.

But a guard whose absence is undetectable is a guard with an expiry date nobody
reads. So the enforcement's own presence is a monitored signal.
`public.tf_declaration_enforcement_audit()` reports whether the event trigger is
**absent** and whether it is **disabled**, as two separate axes, and both feed the
gap total. Disabling the trigger does not quietly widen the platform's tolerance,
it turns a control red at the next evaluation.

`evtenabled` is a `"char"` column with four values, and the checker maps all four
rather than testing for one: `'O'` origin, `'D'` disabled, `'R'` replica, `'A'`
always. Only `'D'` counts as disabled. Treating `'R'` or `'A'` as unknown, or
testing `evtenabled = 'O'` and calling everything else disabled, would misreport a
replica-configured trigger, so the state is published as a word,
`event_trigger_state`, alongside the counters.

---

## The checker

`public.tf_declaration_enforcement_audit()`, added by migration 308.
`SECURITY DEFINER`, pinned `search_path`, `staff` grant tier with the
`user_is_internal_staff` predicate in the body as that tier requires.

It declares one roll-up axis and four components, per the roll-up axis rule of
convention 40, and asserts the identity in its own body:

| Axis | Kind | What it counts |
|------|------|----------------|
| `enforcement_gap_total` | roll-up, gating | the sum of the four below |
| `enforcement_missing_total` | component | the event trigger does not exist |
| `enforcement_disabled_total` | component | it exists with `evtenabled = 'D'` |
| `pending_residue_total` | component | queue rows that outlived a commit |
| `unregistered_function_total` | component | `public.tf_*` functions with no registry row |

Two non-gating populations are published and explicitly excused from gating:
`tf_function_total` (97) and `registry_row_total` (97). Gating on either would
make adding a function look like a defect, which is the mistake convention 37
exists to prevent. Each carries a written rationale in the payload, not in this
document, so an auditor reads it from the signal.

`pending_residue_total` carries its own note, because it is the one axis whose
meaning changes depending on who is asking:

> `pending_residue_total` reads non-zero only inside a transaction that has just
> created a `tf_*` function and has not committed yet. Outside a transaction the
> queue is empty by construction, so a standing non-zero here means a commit-time
> check did not run.

That subtlety forced a small piece of discipline in migration 308's own assertion
block. The migration is itself creating a function, so at assertion time the queue
legitimately holds exactly one row: its own. The block therefore tolerates exactly
one in-flight row and asserts `enforcement_gap_total - pending_residue_total = 0`
and `event_trigger_state = 'origin'`. Asserting the raw total would have been an
assertion the migration could never satisfy, and loosening it to "ignore residue"
would have been an assertion that could never fail.

Live:

```json
{"ok": true, "enforcement_gap_total": 0,
 "enforcement_missing_total": 0, "enforcement_disabled_total": 0,
 "pending_residue_total": 0, "unregistered_function_total": 0,
 "event_trigger": "tf_require_function_declaration",
 "event_trigger_state": "origin",
 "tf_function_total": 97, "registry_row_total": 97,
 "unregistered_functions": [], "pending_functions": []}
```

---

## The control

Migration 309 wired it. `CM-FNDECL-028`.

| Field | Value |
|-------|-------|
| Title | Creating a tf_ function without declaring it is impossible, not merely detectable |
| Domain | Change Management |
| Owner | `CISO` |
| Automated | true |
| Signal | `tf_declaration_enforcement_audit enforcement_gap_total` |
| Frameworks | SOC 2 `CC4.1` `CC7.1` `CC8.1`; CIS v8 `4.1` `16.11`; NIST CSF `PR.IP-1` `PR.IP-3` `DE.CM-7` |
| Status | passing |

Live evidence:

> event trigger `tf_require_function_declaration` is origin; 0 of 97
> `public.tf_*` function(s) undeclared []; queue residue 0, enforcement missing 0,
> disabled 0. Enforced at COMMIT by the deferred check, not at CREATE.

The last sentence is deliberate. An operator reading this control during an
incident needs to know that a migration which appears to create a function
successfully can still be rejected seconds later, and that the rejection is not a
mystery, it is this.

Wiring it took a five-anchor edit to `tf_controls_evaluate` and
`tf_controls_signal_coverage`, applied with the asserted textual splice: each
anchor is counted with

```sql
v_hits := (length(v_new) - length(replace(v_new, v_anchor, ''))) / length(v_anchor);
if v_hits <> 1 then
  raise exception 'migration 309: anchor % occurs % time(s), refusing to splice', v_i, v_hits;
end if;
```

and the migration refuses rather than splicing into an ambiguous position. The
roster in `tf_controls_signal_coverage` gained
`'tf_declaration_enforcement_audit', jsonb_build_array('v_decl')`; the evaluator
gained the declarations, the guarded call, the computed status branch and the
evidence branch. The status branch computes, it does not assert:

```sql
when 'CM-FNDECL-028' then case when v_declgap is null then 'attention'
                               when v_declgap = 0    then 'passing'
                               else 'failing' end
```

Null is the attention branch, per house rule twenty. A checker that could not run
must never render clean. Migration 309 also runs the standing pre-install regex
guard that refuses any handler of the shape
`exception when others then <var> := 0;` before installing the patched function.

---

## Side effect: one new scanner finding, deliberately not suppressed

`tf_declaration_pending` is a table, so the pre-existing `ensure_rls` event trigger
enabled RLS on it automatically. It has no policies, because no client role should
ever read it and its ACL grants nothing to `public`, `anon` or `authenticated`.

`tf_security_scan`'s `rls_enabled_no_policy` axis therefore moved from 1 to 2, and
its `gap_total` from 2 to 3. The decomposed axis
`rls_enabled_no_policy_reachable` remains **0**, and that is the number
`AC-RLS-001` weighs, so no control changed status.

This was left visible rather than exempted. A standing exemption over a table that
no role can reach suppresses nothing today and hides the finding on the day
somebody grants that table to `authenticated`, which is the retired-exemption rule
from migration 282. The correct treatment of a benign finding is to publish it
next to the number that explains it, not to make it disappear.

---

## Register state at close of batch

**309 migrations applied. 28 controls: 25 passing, 3 attention, 0 failing.**
(Migrations 310 through 315 subsequently took this to **315 migrations, 29
controls: 26 passing, 3 attention, 0 failing**. See
[`DEPLOY_COORDINATION.md`](./DEPLOY_COORDINATION.md).)

```json
{"total": 28, "passing": 25, "attention": 3, "failing": 0, "automated": 22}
```

Corroborating checkers, all clean:

- `tf_controls_signal_coverage`: `ok true`, `checkers_total 11`,
  `declaring_checker_total 11`, `axes_total 25`, `gap_total 0`, all five
  primitives zero and all five offender arrays empty.
- `tf_controls_board`: `ok true`, `authoritative true`, `unscored_total 0`,
  `tautological_total 0`, `controls_total 28`, `automated_total 22`.
- `tf_declaration_enforcement_audit`: `ok true`, `enforcement_gap_total 0`.
- `tf_security_scan`: `ok true`, `integrity_total 0`, `gap_total 3` over a
  declared population of 175 tables and 123 definer functions.

The three attention controls are unchanged and all are owner actions outside the
database: `AC-PRIV-002`, `AC-MFA-003`, `DP-PITR-007`.

---

## Runbook

**Prove enforcement is live and the registry is complete.**

```sql
select public.tf_declaration_enforcement_audit();
```

Expect `ok: true`, `enforcement_gap_total: 0`, `event_trigger_state: "origin"`,
and all four components zero. Read `tf_function_total` and `registry_row_total`
together: they should be equal, and a `registry_row_total` that exceeds
`tf_function_total` is a stale declaration, which is
`tf_function_safety_audit` territory rather than this checker's.

**Confirm the event trigger's real state.**

```sql
select evtname, evtenabled, evtevent, pg_get_userbyid(evtowner) as owner
  from pg_event_trigger where evtname = 'tf_require_function_declaration';
```

Expect one row, `evtenabled = 'O'`, owner `postgres`.

**Confirm the queue is empty outside a transaction.**

```sql
select count(*) from public.tf_declaration_pending;
```

Expect `0`. Any standing row here means a commit-time check did not run, and that
is a finding regardless of what the counters say.

**Write a migration that creates a `tf_*` function.** Create the function first,
then declare it, both in the same migration:

```sql
create or replace function public.tf_my_new_function() returns jsonb ...;

insert into public.tf_function_registry (proname, declared_kind, rationale)
values ('tf_my_new_function', 'write', 'why this function exists and what it mutates')
on conflict (proname) do nothing;

select public.tf_apply_grant_tier('tf_my_new_function', '', 'admin', 'why this tier');
```

Order inside the transaction does not matter to this check, but the declaration
cannot come first in a *separate* transaction, because
`tf_function_registry_validate` will refuse a row for a function that does not
exist yet.

**If a migration is refused at commit.** Read the hint. The fix is never to move
the insert earlier into its own migration, it is to put both statements in one
migration. If the refusal names a function you did not expect to create, an
`ALTER FUNCTION ... RENAME` also enqueues, and a renamed function needs its
registry row renamed with it.

**Emergency disable.** There is one, and using it is visible:

```sql
alter event trigger tf_require_function_declaration disable;
```

`CM-FNDECL-028` turns `failing` at the next evaluation, and
`enforcement_disabled_total` reads 1 immediately. Re-enable with `ENABLE` and
re-run `tf_controls_evaluate()`. Do not leave it disabled across a deploy.

---

## What this batch did not close

**Obligation three of convention 33** remains detected rather than structural.
Nothing prevents a migration from creating a checker and never wiring its signal
into a control. `tf_controls_signal_coverage` finds it afterwards, across an
roster of eleven checkers with twenty-five axes at the close of this batch, since
grown to twelve and twenty-six by migration 315, and `CM-SIGNALCOV-026` renders it,
but the creation itself is not refused. That is now the oldest structural gap in
the governance chain.

The reason it is harder than obligation two is that "wire its signal into a
control" has no single catalog fact to test at commit time. A new function is not
necessarily a checker, and whether it is one is a property of whether a consumer
reads a counter out of it, which is house rule nineteen. Enforcing it at commit
would require the migration to declare its own intent, and a self-declared intent
that the author can set to "not a checker" is an exemption lever of exactly the
kind migration 265 spent a batch closing. The design work is real and is not
attempted here.

> **Superseded.** The paragraph below was accurate when this batch closed. It was
> closed shortly afterwards by migrations 310 through 315, which installed the
> advisory lock, the deploy log and control `CM-DEPLOY-029`. Read
> [`DEPLOY_COORDINATION.md`](./DEPLOY_COORDINATION.md) for what actually shipped.
> The paragraph is retained rather than deleted because it records what the
> governance chain looked like before the gap was closed.

**Deployment coordination** remains the largest unmitigated governance risk in the
backend, named by six consecutive verification passes. ClickUp `86bb3etah` carries
the recommendation: an advisory lock, a deploy log, and a `CM-DEPLOY` control.

---

## Related reading

- [`CHECKER_AXIS_DECLARATION.md`](./CHECKER_AXIS_DECLARATION.md) — the roster, the
  three couplings, the strict counter-read needle, house rules nineteen and twenty
- [`CONTROL_SIGNAL_COVERAGE.md`](./CONTROL_SIGNAL_COVERAGE.md) — the three
  obligations of creating a `tf_*` function, house rule seventeen
- [`CONTROL_BOARD_FRESHNESS.md`](./CONTROL_BOARD_FRESHNESS.md) — the asserted
  textual splice, the write-timestamp trap
- [`REGISTER_INTEGRITY.md`](./REGISTER_INTEGRITY.md) — `tf_function_registry`, its
  validating trigger, and why a declaration cannot precede its function
- [`FUNCTION_GRANT_TIERS.md`](./FUNCTION_GRANT_TIERS.md) — obligation one, the only
  one that was already structural
