# Deploy Coordination

**Migrations 310 through 315.** Concurrent DDL against the Transit & Flow
production schema is now refused rather than discouraged, every DDL command is
recorded with its transaction, backend and clock timestamp, and `CM-DEPLOY-029`
reads a checker whose decisive axis measures whether the lock *worked* rather
than whether it is *installed*.

This closes the item that six consecutive verification passes named as the
largest unmitigated governance risk in the backend. ClickUp `86bb3etah` carried
the recommendation in three parts: an advisory lock, a deploy log, and a
`CM-DEPLOY` control. All three are built.

---

## The thesis

More than one channel can write DDL to this schema, and until migration 310
none of them knew about the others.

A human in the Supabase dashboard SQL editor, a CI job holding the service role,
an agent working over MCP, a second agent, a `psql` session on a laptop. Each of
these is a legitimate deploy path and each was, before this batch, completely
blind to the rest. Two of them running at once could interleave DDL against the
same objects. Postgres would take both, catalog locks would keep the individual
statements consistent, and the *result* would be a schema that neither author
intended and that no artifact recorded.

The second half of that sentence is the important half. Interleaving is a real
hazard, but the governance failure is that it would have been **invisible**. A
migration history is a list of what was submitted, not a record of when each
statement actually executed or by whom. Reconstructing an interleave after the
fact, from a migration list alone, is not possible.

So the batch does two separate things, and it is worth keeping them separate in
your head:

1. **Prevention.** An advisory lock makes an interleave impossible while the
   lock is honoured.
2. **Measurement.** A deploy log makes an interleave *detectable*, from recorded
   evidence, independently of whether the lock is believed to be working.

A control that only did the first would be a control that certifies its own
configuration. The fifth axis of the checker exists so that this one does not.

---

## Structural, not voluntary

The obvious design is a convention: "acquire `pg_advisory_xact_lock(8410310)` at
the top of every migration." That design fails for the same reason every
convention in this platform has eventually failed. It works exactly as well as
the discipline of the author who is in a hurry, and the author in a hurry is the
one you built the control for.

Migration 307 set the precedent when it made function declaration structural: an
event trigger does the work, so an author cannot forget to do it. Deploy
coordination follows the same shape.

```
create event trigger tf_serialize_deploy_ddl
  on ddl_command_start
  execute function public.tf_ddl_serialize();
```

`ddl_command_start` had no trigger on this project before migration 310. Only
`ddl_command_end` and `sql_drop` were in use. Firing on `start` is the whole
point: the lock has to be taken before the command does anything, not after.

Because the lock is transaction scoped and advisory xact locks are re-entrant
within a transaction, a twenty-statement migration acquires it on its first DDL
command and holds it until `COMMIT`. There is no unlock call to forget and no
unlock path to leak. The transaction boundary releases it, including on
rollback, including on a crashed backend.

---

## The refusal

The function waits, and then it refuses. It does not wait forever.

```sql
create or replace function public.tf_ddl_serialize()
returns event_trigger
language plpgsql
security definer
set search_path = public, pg_catalog
as $fn$
declare
  v_key    constant bigint := 8410310;
  v_i      int;
  v_detail text;
begin
  -- Bounded polite wait, then a refusal that names the holder. Never blocks
  -- indefinitely, so a wedged deploy cannot freeze every other session.
  for v_i in 1..50 loop
    if pg_try_advisory_xact_lock(v_key) then
      return;
    end if;
    perform pg_sleep(0.1);
  end loop;

  select format(
           'holder backend pid %s, user %s, application %s, transaction started %s, state %s',
           a.pid,
           coalesce(a.usename, 'unknown'),
           coalesce(nullif(a.application_name, ''), 'unset'),
           coalesce(to_char(a.xact_start at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'), 'unknown'),
           coalesce(a.state, 'unknown'))
    into v_detail
    from pg_locks l
    join pg_stat_activity a on a.pid = l.pid
   where l.locktype = 'advisory'
     and l.classid  = 0
     and l.objid    = v_key::int
     and l.objsubid = 1
     and l.granted
     and l.pid <> pg_backend_pid()
   limit 1;

  raise exception using
    errcode = '55P03',
    message = 'migration 310: refusing concurrent DDL, the Transit & Flow deploy lock is held by another session',
    detail  = coalesce(v_detail, 'holder session could not be identified in pg_locks at the moment of refusal'),
    hint    = 'Wait for the in-flight deploy to commit or roll back, then re-run this migration. ...';
end;
$fn$;
```

Three design decisions in that body are worth stating explicitly.

**`pg_try_advisory_xact_lock` in a bounded loop, not `pg_advisory_xact_lock`.**
The blocking form would make a wedged deploy freeze every other DDL session
indefinitely, turning a coordination control into an availability incident. Five
seconds of polite polling absorbs the normal case, where two deploys arrive
seconds apart, and then the refusal is loud.

**The refusal names the holder.** `SQLSTATE 55P03` is `lock_not_available`, and
the `DETAIL` line carries the holding backend's pid, user, application name,
transaction start time and state, read out of `pg_locks` joined to
`pg_stat_activity` at the moment of refusal. An error that says "try again
later" wastes the reader's next ten minutes. An error that says "pid 917142,
user postgres, application pg_cron, started at 17:32:09, state active" ends the
investigation before it starts.

**The advisory lock catalog encoding.** For `pg_try_advisory_xact_lock(bigint)`
with a key below 2^31, `pg_locks` records `locktype='advisory'`, `classid=0`,
`objid=<key>`, `objsubid=1`. The lookup above depends on that encoding. A key at
or above 2^31 would split across `classid`/`objid` and this predicate would find
nothing, which is why the key is `8410310` and why this paragraph exists.

---

## The deploy log

```sql
create table public.tf_deploy_log (
  id                bigint generated always as identity primary key,
  logged_at         timestamptz not null default clock_timestamp(),
  xact_started_at   timestamptz,
  txid              bigint      not null,
  backend_pid       int         not null,
  session_user_name text        not null,
  application_name  text,
  command_tag       text        not null,
  object_type       text,
  schema_name       text,
  object_identity   text
);
create index tf_deploy_log_logged_at_idx on public.tf_deploy_log (logged_at desc);
create index tf_deploy_log_txid_idx      on public.tf_deploy_log (txid);
alter table public.tf_deploy_log enable row level security;
create policy tf_deploy_log_staff_read on public.tf_deploy_log
  for select to authenticated
  using (public.studio_is_staff());
```

A second event trigger on `ddl_command_end` writes one row per command reported
by `pg_event_trigger_ddl_commands()`.

### `clock_timestamp()`, not `now()`

Migration 310 created this column with `default now()`. Migration 313 changed it,
and the reason is the entire measurement.

`now()` is the *transaction* timestamp. It is identical for every statement in a
transaction. With `now()`, every row a migration writes carries the same instant,
so every transaction's span in the log is a single point rather than an interval.
Two point-spans overlap only if they are bit-identical. The overlap query would
have returned zero for every possible input, including a genuine interleave, and
it would have looked like a passing control.

`clock_timestamp()` advances within the transaction. Spans become real intervals
and overlap becomes measurable. This is the same class of defect as the
board-freshness write-timestamp trap in migration 288: a measurement taken with
the wrong clock reads clean no matter what happened.

### The RLS finding is deliberate

`ensure_rls` auto-enables row level security on every new table on this project.
A new table with no policy therefore becomes an `rls_enabled_no_policy` finding
in `tf_security_scan`. `tf_deploy_log` gets `tf_deploy_log_staff_read`, so it
does not add one. That policy is a real access decision, not scanner appeasement:
the deploy log is operational evidence and internal staff should be able to read
it.

---

## The install proves itself

Migration 310's first attempt failed, correctly, with:

```
ERROR: P0001: migration 310: the deploy log is empty at the end of a migration
that ran DDL after installing the logger, so the logger is not writing
```

The `comment on table public.tf_deploy_log` statement had been placed *before*
the `create event trigger` statements. No DDL ran after the logger was installed,
so there was nothing to log, so the assertion fired. The assertion was right and
the migration was wrong.

The fix moved the `COMMENT` to *after* both triggers, which makes it the logger's
own first record, and then strengthened the assertion to check four things rather
than one: both trigger states read `'O'`, at least one row is logged, the first
`command_tag` is `'COMMENT'`, and the transaction holds the advisory lock it just
installed.

This works because **`ddl_command_end` fires for `COMMENT`**. A comment is DDL.
That makes a trailing `COMMENT` the cheapest possible self-proving probe: it
changes nothing, it costs nothing, and it cannot succeed unless the logger is
genuinely writing.

The failure also re-proved that `apply_migration` is transactional. Attempt one
left no table, no function, no registry row and no `schema_migrations` version
behind.

---

## The falsifiability proof

An unexercised refusal branch is a claim, not a control. Two attempts to provoke
one through the MCP channel produced false negatives, and the reason turned out
to be a finding worth more than the proof.

### The MCP serialization finding

**Two `execute_sql` or `apply_migration` calls issued in the same tool block do
not run concurrently against Postgres.** They are serialized somewhere in the MCP
channel before they reach the database.

This was not assumed, it was measured. A holder session was instrumented to
return its exact lock window, and the supposedly concurrent DDL was checked
against it:

```
holder window   t0 = 17:30:15.913915
                t1 = 17:30:45.942967   (30 s held)
"concurrent" COMMENT logged at 17:30:46.582
inside_holder_window = false
```

The competing statement landed 0.64 seconds **after** the lock was released. It
was never concurrent. It committed, and a naive reading of that result would have
concluded the lock did not work.

The consequence is precise and worth carrying forward: **this agent cannot
produce a DDL interleave through the MCP channel.** Other clients can. The
dashboard SQL editor, `psql`, CI, and a second independent agent all can. The
control defends against a hazard that this particular tool path happens not to be
able to generate, which is exactly why the hazard needs measurement rather than
introspection.

`dblink` was investigated as an independent backend and abandoned:
`pg_available_extensions` lists it, `pg_extension` does not, and `postgres` has
`rolsuper = false` on this project, so a passwordless dblink connection is not
possible.

### pg_cron as the independent backend

pg_cron 1.6.4 is installed with interval syntax support. Scheduling a job gives a
genuinely separate backend, identifiable by `application_name = 'pg_cron'`:

```sql
select cron.schedule(
  'tf-deploy-lock-probe',
  '30 seconds',
  'select pg_advisory_xact_lock(8410310), pg_sleep(60)');
```

With that holder running, a DDL statement was submitted. The refusal branch, as
raised, verbatim:

```
ERROR: 55P03: migration 310: refusing concurrent DDL, the Transit & Flow deploy
lock is held by another session

DETAIL: holder backend pid 917142, user postgres, application pg_cron,
transaction started 2026-07-25T17:32:09Z, state active

HINT: Wait for the in-flight deploy to commit or roll back, then re-run this
migration. Concurrent DDL against this schema is refused by design, not by
accident. See docs/DEPLOY_COORDINATION.md. Emergency bypass for a wedged
trigger: set session_replication_role = replica; then alter event trigger
tf_serialize_deploy_ddl disable;

CONTEXT: PL/pgSQL function tf_ddl_serialize() line 34 at RAISE
```

Cleanup was verified rather than assumed: `cron.unschedule('tf-deploy-lock-probe')`
returned true, and a follow-up query confirmed `job_rows 0`, `lock_still_held 0`,
`probe_backends 0`.

One operational note from the same session: `execute_sql` has a 60-second MCP
timeout. `select pg_sleep(65)` returns
`MCP server "Supabase" tool "execute_sql" timed out after 60s`. Design proofs
around this control have to fit inside that window or run detached, as the cron
job did.

### Why migration 311 is still in the history

Migration 311 created a throwaway table, `tf_deploy_lock_probe`, purely as a DDL
statement to submit against the held lock. Migration 312 drops it.

311 could have been rewritten out of the chain to keep the ordinals tidy. It was
not, and the header comment on 312 records why:

> a probe that proved a control is evidence, and deleting evidence to keep the
> ordinal chain tidy is the habit this platform exists to prevent.

---

## The checker

`public.tf_deploy_coordination_audit()`, added by migration 313, follows the
`tf_declaration_enforcement_audit` template exactly.

**Self axis (the roll-up):** `coordination_gap_total`

**Component axes:**

| Axis | Source | Answers |
|---|---|---|
| `lock_trigger_missing_total` | `pg_event_trigger` | is the lock trigger installed |
| `lock_trigger_disabled_total` | `pg_event_trigger.evtenabled` | is it enabled |
| `log_trigger_missing_total` | `pg_event_trigger` | is the logger installed |
| `log_trigger_disabled_total` | `pg_event_trigger.evtenabled` | is it enabled |
| `interleaved_deploy_total` | `tf_deploy_log` command spans | **did it work** |

**Non-gating population counters:** `deploy_event_total`,
`deploy_transaction_total`, `distinct_backend_total`. Each carries a stated
reason it is population rather than findings, per the undeclared-denominator rule
from migration 280.

### The axis that can contradict the others

Four axes read the trigger catalog. They answer whether enforcement is
*configured*. Only the fifth answers whether enforcement *held*:

```sql
with spans as (
  select l.txid, l.backend_pid, min(l.logged_at) as t0, max(l.logged_at) as t1
    from public.tf_deploy_log l
   group by l.txid, l.backend_pid
)
select coalesce(array_agg(
         format('txid %s on pid %s overlaps txid %s on pid %s',
                a.txid, a.backend_pid, b.txid, b.backend_pid)
         order by a.txid, b.txid), '{}'::text[])
  into v_pairs
  from spans a
  join spans b
    on a.txid < b.txid
   and a.backend_pid <> b.backend_pid
   and a.t0 <= b.t1
   and b.t0 <= a.t1;
```

The checker publishes a note saying so in its own payload, so a reader of the
JSON does not have to infer it:

> `interleaved_deploy_total` is computed from recorded command spans, not from
> the trigger catalog. It is the only axis here that can contradict the others: a
> lock reported present and enabled that nonetheless permitted two backends to
> interleave would read zero on four axes and non-zero on this one, and this one
> is the one that is measuring the claim.

`deploy_transaction_total` travels with it as the denominator. With fewer than two
recorded transactions, no overlap is arithmetically possible and a zero reading
carries no information. The population must be published for the finding to mean
anything.

### `evtenabled` handling

`pg_event_trigger.evtenabled` is type `"char"` with four values: `'O'` origin,
`'D'` disabled, `'R'` replica, `'A'` always. All four are mapped. `'R'` is counted
as disabled, because **the axis measures whether enforcement runs, not how the
catalog spells the reason it does not.**

---

## The control

`CM-DEPLOY-029`, Change Management, owner CISO, automated.

- **Signal:** `tf_deploy_coordination_audit coordination_gap_total`
- **Frameworks:** SOC 2 CC8.1, CC7.1, CC4.1; CIS v8 4.1, 16.11; NIST CSF PR.IP-1,
  PR.IP-3, DE.CM-7
- **Status branch:** `null` reads attention, `0` reads passing, anything else
  reads failing. House rule twenty: zero is the passing branch and null is the
  attention branch, so a check that could not run never reports clean.

Migration 315 wired it, using the asserted textual splice with four anchors
against `tf_controls_evaluate()`, each asserted to occur exactly once before it
is used. In the same transaction it added the checker to the
`tf_controls_signal_coverage` roster, which is hand-maintained and would have
turned `CM-SIGNALCOV-026` red on the next evaluation if the two had shipped
apart.

Live evidence string, read back out of `it_controls` rather than inferred:

> lock trigger `tf_serialize_deploy_ddl` is origin and log trigger
> `tf_deploy_ddl_log` is origin; 0 interleaved deploy pair(s) [] across a
> population of 12 DDL transaction(s) on 12 backend(s), 41 logged command(s)
> since 2026-07-25T17:27:59.960192+00:00. The interleave axis is measured from
> recorded command spans, not from the trigger catalog, so it is the axis that
> can contradict the other four.

Migration 315 also removed a hard-coded roster size from `CM-SIGNALCOV-026`'s
signal text. That string said "over a ten-checker roster" while the roster held
twelve. A denominator that travels with the payload cannot go stale; a copy of it
pasted into the register can, so the copy is gone.

---

## The drift migration 310 introduced, and house rule twenty-two

Migration 315's first attempt failed its own assertion:

```
ERROR: P0001: register reports 1 failing control(s) after wiring, expected 0.
Summary: {"total": 29, "failing": 1, "passing": 25, "attention": 3, ...}
```

The failing control was `CM-FNDRIFT-018`, and the drift was not new. It had been
sitting in the catalog since migration 310:

```json
{"name": "tf_ddl_serialize", "computed": "read", "declared": "write",
 "transitive_only": false}
```

Migration 310 declared `tf_ddl_serialize` as `declared_kind='write'`, citing the
migration 272 rule that a trigger function is a write path by construction.
`tf_function_safety_audit` computes kind from the body, found no DML, computed
`read`, and reported drift.

**The detector was right.** The 272 rule was applied by analogy and the analogy
does not hold. `tf_ddl_serialize` acquires a lock and either returns or raises.
It executes no DML at all. Its sibling `tf_ddl_log` is the same shape of object,
genuinely inserts, computes `write`, and shows no drift, which is the control
case that settles it.

The wrong fix would have been to teach `tf_function_safety_audit` that a lock
acquisition counts as a write. That makes the declaration true by narrowing the
detector, and convention 21 is *decompose, never narrow*. Migration 314 changed
the declaration to `read` with a rationale that states what `read` does and does
not mean here: the function mutates no rows, and on the axis `declared_kind`
classifies it reads nothing and writes nothing. It is not passive, but it is not
a data writer.

### House rule twenty-two

> **A migration that writes a row into `tf_function_registry` must re-evaluate the
> control register before it commits.**

A declaration is a claim. `tf_function_safety_audit` is the thing that can refute
it and `CM-FNDRIFT-018` is the consumer that renders the refutation. Migrations
310 through 313 were inside the letter of house rule seventeen, because they did
not touch the register, and the consequence was that a real drift sat undetected
for fifteen minutes behind a register still displaying its pre-310 statuses.

**A stale green is worse than a red, because nobody investigates a green.**

---

## Register state at close of batch

Read from the live database after migration 315, not carried forward from the
migration assertions:

| Figure | Value |
|---|---|
| Controls | 29 |
| Passing | 26 |
| Attention | 3 |
| Failing | 0 |
| Roster checkers | 12 |
| Declared axes | 26 |
| Signal coverage gaps | 0 |
| Function drift | 0 |
| Scan integrity failures | 0 |
| Board | authoritative, 0 unscored, 0 tautological |

The three attention controls are unchanged and all three are owner actions, not
platform defects: `AC-MFA-003` (one privileged account without MFA),
`AC-PRIV-002` (one anon-exposed definer function), `DP-PITR-007` (point-in-time
recovery not yet enabled).

---

## Runbook

### Normal deploy

Nothing to do. The lock is taken for you on the first DDL command of your
transaction and released at `COMMIT` or `ROLLBACK`.

### You hit `55P03`

Read the `DETAIL` line. It names the pid, user, application and transaction start
time of the session holding the lock.

- **Application is `pg_cron`:** a scheduled job is running DDL. Wait; they are
  short.
- **Application names a CI runner:** a pipeline is deploying. Do not force it.
  Wait for the pipeline, then re-run.
- **Application is unset and the transaction started minutes ago:** likely an
  abandoned session. Confirm before acting:

```sql
select a.pid, a.usename, a.application_name, a.state,
       a.xact_start, a.query_start, left(a.query, 200) as query
  from pg_locks l
  join pg_stat_activity a on a.pid = l.pid
 where l.locktype = 'advisory' and l.classid = 0
   and l.objid = 8410310 and l.objsubid = 1 and l.granted;
```

If it is genuinely abandoned, `select pg_terminate_backend(<pid>);` releases the
lock by ending the transaction. Terminating a live deploy mid-migration is safe
in the sense that the migration rolls back, and unsafe in the sense that you have
just cancelled somebody's work. Ask first.

### The trigger itself is wedged

Emergency bypass, in the order the `HINT` gives it:

```sql
set session_replication_role = replica;
alter event trigger tf_serialize_deploy_ddl disable;
```

This is deliberately a two-step, deliberately session-scoped in its first step,
and deliberately monitored. `lock_trigger_disabled_total` goes non-zero the
moment you do it, `coordination_gap_total` follows, and `CM-DEPLOY-029` reads
failing on the next evaluation. Convention 43: enforcement has a kill switch, so
the kill switch is a monitored axis. Re-enable as soon as the incident closes:

```sql
alter event trigger tf_serialize_deploy_ddl enable;
```

### Reading the log

Recent deploy activity, one row per transaction:

```sql
select txid, backend_pid, session_user_name,
       coalesce(application_name, 'unset') as app,
       min(logged_at) as started, max(logged_at) as ended,
       count(*) as commands
  from public.tf_deploy_log
 group by txid, backend_pid, session_user_name, application_name
 order by started desc
 limit 20;
```

### Checking the control by hand

```sql
select public.tf_deploy_coordination_audit();
select status, evidence from public.it_controls where control_key = 'CM-DEPLOY-029';
```

Read the checker directly when you want the axes, read `it_controls` when you
want what the register is actually publishing. They can disagree, and when they
do the register is stale and `tf_controls_evaluate()` has not run since the
change.

### A note on the Supabase migration runner

The runner uses **more than one backend per migration** and issues its own
`ALTER TABLE supabase_migrations.schema_migrations` DDL, which the deploy logger
faithfully records. Observed during this batch: pids 917070 (bookkeeping) and
917071 (the actual migration body) for the same submission, on separate
transactions, milliseconds apart.

This is expected and is not an interleave. The two transactions do not overlap in
time, which is exactly what the span query tests, and it is a useful live
reminder that `distinct_backend_total` counts deploy *channels* observed, not
concurrent authors.

---

## What this batch did not close

**Obligation three of convention 33** remains the oldest structural gap.
Nothing prevents a migration from creating a checker and never wiring its signal
into a control. `tf_controls_signal_coverage` finds it afterwards, across a
twelve-checker roster with twenty-six axes, and `CM-SIGNALCOV-026` renders it,
but the creation itself is not refused. The design difficulty is unchanged and is
recorded in `DECLARATION_ENFORCEMENT.md`: "wire its signal into a control" has no
single catalog fact testable at commit time, and a self-declared intent flag
would be an exemption lever of exactly the kind migration 265 spent a batch
closing.

**The deploy log has no retention policy.** It grows one row per DDL command
forever. At current volume that is trivial, and a partition or a rolling delete
is premature. It becomes real work the day this platform has continuous
deployment rather than a build session, and the span query will need an index-
friendly window at that point rather than a full scan of history.

**The lock does not span projects or branches.** It is a single Postgres advisory
lock in one database. Supabase preview branches each get their own, which is
correct, and a cross-project deploy sequence has no coordination primitive. That
is not a gap worth closing until there is more than one production project.

---

## Related reading

- [`DECLARATION_ENFORCEMENT.md`](./DECLARATION_ENFORCEMENT.md) — migrations 307
  through 309, the precedent for making an obligation structural, house rule
  twenty-one
- [`CHECKER_AXIS_DECLARATION.md`](./CHECKER_AXIS_DECLARATION.md) — the roster, the
  three couplings, the strict counter-read needle, house rules nineteen and twenty
- [`CONTROL_SIGNAL_COVERAGE.md`](./CONTROL_SIGNAL_COVERAGE.md) — the three
  obligations of creating a `tf_*` function, house rule seventeen
- [`CONTROL_BOARD_FRESHNESS.md`](./CONTROL_BOARD_FRESHNESS.md) — the asserted
  textual splice, and the write-timestamp trap that `clock_timestamp()` avoids
  here
- [`FUNCTION_SAFETY_AUDIT.md`](./FUNCTION_SAFETY_AUDIT.md) — `declared_kind`,
  computed kind, and the drift detector that caught migration 310
- [`IT_GOVERNANCE_GRC.md`](./IT_GOVERNANCE_GRC.md) — the full control register
