# CI Repository Fidelity

Status: implemented and green
Owner: Platform Engineering, Transit & Flow
Scope: `.github/workflows/ci.yml`, `supabase/migrations/`, `scripts/`

---

## 1. The failure, stated plainly

The GitHub Actions job named `CI / Validate Supabase migrations` failed on every
run, in about ninety-five seconds, with two annotations. It did not fail because
of a bad commit. It failed because it was structurally incapable of passing, and
had been since the day the workflow was added.

The job ran this:

```
supabase db start || true
supabase db reset --debug
```

`supabase db reset` drops the local database, recreates it empty, and replays
every `.sql` file in `supabase/migrations/` in filename order. The replay is only
meaningful if the repository contains the complete, ordered history.

It does not. Production has applied **320** migrations. The repository holds
**9** of the corresponding files, all of them from the last two days of work.
The first file the reset replays, `20260725113932_sweep_tenant_scoping_and_ai_booking_guard.sql`,
is ordinal 249. It references tables, functions, policies and enums created by
migrations 1 through 248, none of which exist in the repository. The first
statement fails, the reset aborts, and the job goes red.

There is a second, independent reason the replay could not work even after a
complete backfill. Seven of the nine committed migrations assert against live
production data: the production company UUID `ff000000-0000-4000-b000-000000000001`,
the legacy company UUID `dd000000-0000-4000-a000-000000000001`, and absolute
control-register counts (`expected 13` five times, `expected 30` once). Those
assertions are correct and valuable against production. Against a freshly reset,
seedless local database they are false by construction.

The other job, `CI / Type-check edge functions`, succeeded in seven seconds. It
succeeded because `supabase/functions/*/index.ts` matched nothing, the loop body
never ran, and the job exited zero. A green light that means "there was nothing
to look at" is not a green light. It has been corrected to say so out loud.

## 2. The finding underneath the failure

Diagnosing the job surfaced something more serious than a broken workflow.

**Roughly two megabytes of this platform's definition exists in exactly one
place: the production Postgres instance.** There is no second copy of migrations
1 through 248 anywhere. Not in the repository, not in a dump, not in a backup
this team controls. The entire schema, the RLS policy set, the GRC control
register, the `cygeus_*` tenancy and identity subsystem, the Studio module, all
of it, is one bad afternoon away from being unrecoverable.

**And the small part that is committed is partly wrong.** Comparing every
committed file against the applied text, byte for byte, produced this:

| Migration | File | Verdict |
|---|---|---|
| 249 | `sweep_tenant_scoping_and_ai_booking_guard` | Comment drift |
| 250 | `automation_blast_radius_transcription_and_bounding_model` | Comment drift |
| 251 | `automation_registry_note_drift_checker` | Exact |
| 252 | `note_drift_control_and_register_reconciliation` | Exact |
| 316 | `declaration_pending_residue_is_unmet_only` | Exact |
| 317 | `signal_roster_single_home_and_orphan_axis` | Exact |
| 318 | `require_signal_wiring_at_commit` | Exact |
| 319 | `prove_signal_wiring_refusal` | Exact |
| 320 | `signal_wiring_checker_and_control` | **Code drift** |

Migrations 249 and 250 differ in comment prose only. Their executable SQL is
identical to what ran. That is tolerable and now reported as a warning.

Migration 320 is different. Its repository file contains executable SQL that
production never executed. The divergence turns out to be deliberate and correct,
and it is worth understanding, because it is the exact case a naive gate would
either miss or misjudge.

The applied text of migration 320 carries the `coaleske_placeholder` defect: an
undefined identifier in the argument list of a `raise exception` sitting on the
failure path of the `enforcement_gap_total` assertion. The assertion passed, so
PL/pgSQL never resolved the identifier, and the migration committed clean. This
is the defect that produced **house rule twenty-three**: an assertion's failure
path is code, and untested code. The migration history row is immutable and
cannot be corrected. So the repository file carries the repair, plus a comment
block explaining exactly why it differs, so that a replay onto a fresh database
one day raises the intended diagnostic instead of `42703 column
"coaleske_placeholder" does not exist`.

Production is unaffected. The branch is unreachable while the assertion holds.
But the file is not what ran, and a governance system that cannot tell the
difference between "deliberately repaired" and "quietly edited" is not a
governance system.

## 3. What replaced it

`CI / Verify migration fidelity`. No database, no credentials, no replay. It
verifies what the repository honestly is, which is a partial and growing mirror
of one live database plus an authoritative manifest of everything that database
has executed.

### 3.1 The manifest

`supabase/migrations/MIGRATION_MANIFEST.tsv` holds one row per applied migration,
320 of them, generated directly from `supabase_migrations.schema_migrations`:

```
ordinal  version  name  statements  checksum  bytes  code_checksum
```

Every row currently has `statements = 1`, so `array_to_string(statements, E'\n')`
is byte-for-byte the SQL text submitted to the database, with no trailing
newline. That makes the stored checksum directly comparable to a file on disk.

### 3.2 Two checksums, because there are two kinds of divergence

`checksum` is the md5 of the exact applied text.

`code_checksum` is the md5 of the same text after normalisation: trailing
whitespace stripped from every line, then blank lines and whole-line SQL comments
removed, then the remainder rejoined with newlines.

The normalisation is defined identically in three places and all three must move
together if it ever changes: the SQL expression in the manifest header comment,
`code_normalise()` in `scripts/verify_migration_manifest.py`, and
`code_normalise()` in `scripts/backfill_migrations.py`.

The two checksums produce three verdicts:

| Condition | Verdict | Consequence |
|---|---|---|
| `checksum` matches | EXACT | Silent pass |
| `checksum` differs, `code_checksum` matches | COMMENT_DRIFT | Warning |
| Both differ | CODE_DRIFT | **Build fails** unless registered |

A rewritten comment is documentation. A changed statement is a claim about the
schema that production never agreed to. Collapsing those two into one verdict
would force a choice between tolerating real drift and blocking on prose edits,
and both of those choices are wrong.

### 3.3 Registered exceptions

`supabase/migrations/MANIFEST_EXCEPTIONS.tsv` is the only way to accept
CODE_DRIFT, and accepting one costs something. The row must name the version,
pin the file's current code checksum, give a classification, and carry a rationale
of at least forty characters.

The pin is the important part. It records the file content as it stood when the
exception was granted. Edit the file again and the pin no longer matches, the
exception stops applying, and the build fails until a human reviews the new
content. **An exception can never become a standing licence to diverge.** There
is exactly one today, migration 320, classified `REPLAY_REPAIR`.

### 3.4 The six checks

**A. Manifest well-formedness.** Ordinals contiguous from 1 with no gaps and no
reordering, versions unique and strictly ascending, names non-empty, both
checksums 32 hex characters, byte counts positive, statement counts at least one.

**B. File provenance.** Every `.sql` file must be named `<version>_<name>.sql`,
and that exact pair must appear in the manifest. This catches a fabricated
migration, a file renamed to impersonate a different one, and a file for a
version production has never applied.

**C. Syntax.** Every `.sql` file must parse as PostgreSQL, using `pglast`, which
wraps `libpg_query`. This is the server's own parser, not a regex approximation.

**D. Fidelity.** The three-way classification above.

**E. Index completeness.** `MIGRATIONS_INDEX.md` must document at least as many
of the 320 applied ordinals as it did at the last floor update. Collapsed range
rows such as `| 176-180 |` count for their whole span. Current coverage: 202 of
320.

**F. Coverage ratchet.** The count of `.sql` files present must never fall below
the recorded floor. Current floor: 9 of 320, which is 2.8 percent.

### 3.5 Why E and F are ratchets and not absolutes

An absolute would demand that all 320 files land in one commit before CI can be
green again. That is not a gate, it is a hostage situation, and the predictable
outcome is that someone disables the job.

A ratchet makes every commit that closes part of the gap permanent, and makes any
commit that reopens it fail. Progress becomes irreversible without a deliberate,
reviewable edit to `supabase/migrations/.ci-floors.json`, in the same commit,
with a reason in the message. Raise the floors with:

```
python3 scripts/verify_migration_manifest.py --update-floors
```

### 3.6 The gate proves it refuses before it reports

`scripts/test_verify_migration_manifest.py` runs first, in CI, before the gate is
allowed to say anything about the real tree. It builds a disposable copy of the
repository, breaks it one specific way at a time, and requires the correct
outcome each time:

| Case | Required |
|---|---|
| Executable SQL changed in a file that matched exactly | Refuse |
| Comment-only edit | Permit |
| File renamed away from its applied name | Refuse |
| Migration file for a version never applied | Refuse |
| Migration file deleted, dropping below the floor | Refuse |
| Registered exception left in place after the file changed again | Refuse |
| Hole punched in the manifest ordinals | Refuse |
| Unparseable SQL | Refuse |
| Malformed checksum in the manifest | Refuse |
| Exception whose rationale explains nothing | Refuse |

The comment-only case is deliberately a permit. A suite in which every case
refuses proves only that the harness is broken, not that the gate discriminates.

This is house rule twenty-three applied to CI itself. A gate that has only ever
been observed to pass has not been observed to do anything.

## 4. The remaining exposure, and how to close it

The gate makes drift impossible to introduce silently. It does not create the
missing 311 files. **The single-copy exposure is still open and it is the most
serious open item on the platform.**

`scripts/backfill_migrations.py` closes it. Supabase stores the complete text of
every applied migration in `supabase_migrations.schema_migrations.statements`, so
this is not a reconstruction and not a schema dump. It is the original submitted
text, read back and written to disk.

It requires a direct database connection, and production credentials are
deliberately absent from this repository. `.env.example` carries secret *names*
and never values, which is correct and stays that way. So this is a one-time,
owner-run operation. Once the files are committed, CI verifies them forever after
with no credential at all.

```bash
# Supabase dashboard -> Project Settings -> Database -> Connection string -> URI
export TF_DB_URL='postgresql://postgres:...@...pooler.supabase.com:5432/postgres'

python3 scripts/backfill_migrations.py --dry-run     # writes nothing, reports everything
python3 scripts/backfill_migrations.py --write       # materialise all 320 files

python3 scripts/verify_migration_manifest.py
python3 scripts/verify_migration_manifest.py --update-floors

git add supabase/migrations
git commit -m "chore(db): materialise full migration history"
git push

unset TF_DB_URL
```

Existing files are never overwritten without `--overwrite`. The two comment-drift
files and the one registered replay repair are intentional local edits and the
script leaves them alone by default.

`scripts/pull-backend.sh` already existed for the same purpose, using the Supabase
CLI. It has evidently never been run to completion. The Python script is preferred
because it reads the migration history table directly, so what lands on disk is
the original text rather than the CLI's regenerated view of the schema, and
because it reports a per-file fidelity verdict as it goes.

## 5. Why this matters beyond a green light

Transit & Flow is being built to sell TalentFlow OS to external tenants. SOC 2
readiness is an explicit requirement of that product. Change management is a SOC 2
control family, and the control it asks about is not "do you have CI". It is
whether you can demonstrate that what runs in production is what was reviewed and
approved.

Before this change the honest answer was no. The repository held three percent of
the schema, some of that three percent did not match what ran, and the job that
was supposed to catch exactly this had been failing so consistently that its
failure carried no information.

After this change the honest answer is: every migration file in the repository is
verified against the immutable applied history on every push, drift in executable
SQL fails the build, drift in comments is reported, the one deliberate exception
is named, pinned, and justified in version control, coverage can only increase,
and the gate itself is tested against ten ways of being wrong before it is
trusted to report on anything.

That is a control that would survive an auditor asking a second question.

## 6. Files

| Path | Role |
|---|---|
| `.github/workflows/ci.yml` | Both jobs. Replay removed, fidelity gate added. |
| `supabase/migrations/MIGRATION_MANIFEST.tsv` | Authoritative record of all 320 applied migrations. |
| `supabase/migrations/MANIFEST_EXCEPTIONS.tsv` | Registered, pinned, justified CODE_DRIFT exceptions. |
| `supabase/migrations/.ci-floors.json` | Coverage ratchet floors. |
| `supabase/migrations/MIGRATIONS_INDEX.md` | Human-readable history and design commentary. |
| `scripts/verify_migration_manifest.py` | The gate. Six checks. No credentials. |
| `scripts/test_verify_migration_manifest.py` | Refusal proof. Ten cases. Runs first in CI. |
| `scripts/backfill_migrations.py` | Owner-run tool to materialise all 320 files. |
| `scripts/pull-backend.sh` | Pre-existing CLI mirror. Superseded for migrations. |

## 7. Open items this creates

1. **Run the backfill.** Highest priority. Until it runs, 311 migrations exist in
   exactly one place. Owner action, needs the database connection string.
2. **Mirror the edge functions.** `supabase/functions/` is empty in the
   repository. The deployed functions have the same single-copy exposure as the
   migrations. `scripts/pull-backend.sh` covers this half.
3. **Raise index coverage from 202 toward 320.** The ratchet permits incremental
   progress; every commit that documents more ordinals locks in the gain.
4. **Commit signing.** Separate from this work and still awaiting a decision. GPG
   or SSH signing is the correct forward fix for the Unverified-commit class.
   Rewriting published history is not.
