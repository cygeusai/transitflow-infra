#!/usr/bin/env python3
"""
Transit & Flow - materialise the full migration history into this repository.

WHY THIS EXISTS
---------------
Production has applied 320 migrations. This repository holds a fraction of the
corresponding .sql files. The rest of the platform's definition, roughly two
megabytes of it, exists only inside the production Postgres instance. That is a
single point of failure with no second copy, and it is the reason the migration
CI job could never pass.

Supabase stores the complete text of every applied migration in
supabase_migrations.schema_migrations.statements. This script reads that table
and writes each migration back out as a file, byte for byte as it was submitted.
It is not a reconstruction and not a schema dump. It is the original text.

WHY YOU HAVE TO RUN IT AND NOT CI
---------------------------------
It needs a direct database connection. Production credentials are deliberately
absent from this repository (.env.example carries names, never values), so this
is an owner-run, one-time operation. Once the files are committed, CI verifies
them forever afterwards without needing any credential at all.

HOW TO RUN IT
-------------
1. Supabase dashboard, Project Settings, Database, Connection string, URI.
   Use the session pooler or direct connection. Copy it.

2. Export it. Do not paste it into a file, do not commit it:

       export TF_DB_URL='postgresql://postgres:...@...pooler.supabase.com:5432/postgres'

3. Dry run first. This writes nothing and tells you exactly what it would do:

       python3 scripts/backfill_migrations.py --dry-run

4. Write the files and regenerate the manifest:

       python3 scripts/backfill_migrations.py --write

5. Verify, raise the floors, and commit:

       python3 scripts/verify_migration_manifest.py
       python3 scripts/verify_migration_manifest.py --update-floors
       git add supabase/migrations && git commit -m "chore(db): materialise full migration history"

6. Unset the variable:

       unset TF_DB_URL

EXISTING FILES ARE NEVER OVERWRITTEN unless you pass --overwrite. Two of the nine
files currently committed differ from the applied text in comments only, and one
carries a deliberate replay repair registered in MANIFEST_EXCEPTIONS.tsv. Those
edits are intentional and this script will leave them alone by default.

Requires: pip install "psycopg[binary]"   (or psycopg2-binary)
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import sys
from pathlib import Path

MIGDIR = Path("supabase/migrations")
MANIFEST = MIGDIR / "MIGRATION_MANIFEST.tsv"

QUERY = """
select
  row_number() over (order by version) as ordinal,
  version,
  coalesce(name, '') as name,
  cardinality(statements) as statement_count,
  array_to_string(statements, E'\\n') as sql_text
from supabase_migrations.schema_migrations
order by version
"""

MANIFEST_HEADER = """# Transit & Flow - applied migration manifest
# Generated from supabase_migrations.schema_migrations on project kjooyhvynkzuvsixsutt
# by scripts/backfill_migrations.py.
# This file is the authoritative record of what has been APPLIED to production.
# It is NOT a substitute for the migration SQL itself. See docs/CI_REPOSITORY_FIDELITY.md.
#
# checksum      = md5(array_to_string(statements, E'\\n'))
# code_checksum = md5 of the same text after normalisation: trailing whitespace
#                 stripped from every line, then blank lines and whole-line SQL
#                 comments (lines whose first two non-space characters are --)
#                 removed, then the remaining lines rejoined with \\n.
# bytes         = length(array_to_string(statements, E'\\n'))
#
# The two checksums separate two different kinds of divergence between a
# repository file and what production actually ran:
#   checksum matches                      -> EXACT
#   checksum differs, code_checksum equal -> COMMENT_DRIFT  (prose only)
#   both differ                           -> CODE_DRIFT     (executable text)
# CODE_DRIFT fails the build unless the pair is registered in MANIFEST_EXCEPTIONS.tsv.
#
# Columns: ordinal<TAB>version<TAB>name<TAB>statements<TAB>checksum<TAB>bytes<TAB>code_checksum
"""

SAFE_NAME = re.compile(r"[^A-Za-z0-9_]+")


def code_normalise(text: str) -> str:
    """Must stay behaviourally identical to the same function in
    scripts/verify_migration_manifest.py and to the SQL in the manifest header."""
    kept = [line.rstrip() for line in text.split("\n")]
    kept = [l for l in kept if l.strip() != "" and not l.lstrip().startswith("--")]
    return "\n".join(kept)


def md5(text: str) -> str:
    return hashlib.md5(text.encode("utf-8")).hexdigest()


def connect(url: str):
    try:
        import psycopg  # type: ignore
        return psycopg.connect(url), "psycopg3"
    except ImportError:
        pass
    try:
        import psycopg2  # type: ignore
        return psycopg2.connect(url), "psycopg2"
    except ImportError:
        sys.exit('No Postgres driver found. Install one:\n'
                 '    pip install "psycopg[binary]"\n'
                 '  or\n'
                 '    pip install psycopg2-binary')


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true",
                    help="Report what would happen. Writes nothing. This is the default.")
    ap.add_argument("--write", action="store_true",
                    help="Actually write the .sql files and regenerate the manifest.")
    ap.add_argument("--overwrite", action="store_true",
                    help="Also replace files that already exist. Discards deliberate "
                         "local edits, including registered replay repairs.")
    ap.add_argument("--repo-root", default=".")
    args = ap.parse_args()

    if args.write and args.dry_run:
        sys.exit("Pass --write or --dry-run, not both.")
    write = args.write

    url = os.environ.get("TF_DB_URL") or os.environ.get("DATABASE_URL")
    if not url:
        sys.exit("Set TF_DB_URL to the project's Postgres connection string first. "
                 "See the docstring at the top of this file.")

    root = Path(args.repo_root).resolve()
    outdir = root / MIGDIR
    if not outdir.is_dir():
        sys.exit(f"{outdir} does not exist. Run this from the repository root.")

    conn, driver = connect(url)
    print(f"Connected via {driver}.")
    with conn:
        with conn.cursor() as cur:
            cur.execute(QUERY)
            rows = cur.fetchall()
    conn.close()

    print(f"{len(rows)} applied migrations found.\n")

    manifest_lines: list[str] = []
    written = skipped = multi = 0
    total_bytes = 0

    for ordinal, version, name, statement_count, sql_text in rows:
        sql_text = sql_text or ""
        chk = md5(sql_text)
        code_chk = md5(code_normalise(sql_text))
        nbytes = len(sql_text)
        total_bytes += nbytes
        manifest_lines.append(
            f"{ordinal}\t{version}\t{name}\t{statement_count}\t{chk}\t{nbytes}\t{code_chk}")

        if statement_count != 1:
            multi += 1
            print(f"  ! {version} was applied as {statement_count} statements. The file "
                  f"joins them with a newline, so its checksum is still comparable, but "
                  f"note the join is this script's choice, not the database's.")

        safe = SAFE_NAME.sub("_", name).strip("_") or "unnamed"
        target = outdir / f"{version}_{safe}.sql"

        if target.exists() and not args.overwrite:
            existing = target.read_text()
            if md5(existing) == chk or md5(existing.rstrip("\n")) == chk:
                state = "exact"
            elif md5(code_normalise(existing)) == code_chk:
                state = "comment drift, left as is"
            else:
                state = "CODE DRIFT, left as is, review it"
            print(f"  = {target.name}  ({state})")
            skipped += 1
            continue

        if write:
            target.write_text(sql_text if sql_text.endswith("\n") else sql_text + "\n")
        written += 1
        if written <= 5 or written % 50 == 0:
            print(f"  {'+' if write else '~'} {target.name}  ({nbytes} bytes)")

    if write:
        (root / MANIFEST).write_text(
            MANIFEST_HEADER
            + "ordinal\tversion\tname\tstatements\tchecksum\tbytes\tcode_checksum\n"
            + "\n".join(manifest_lines) + "\n")

    verb = "Wrote" if write else "Would write"
    print()
    print(f"{verb} {written} file(s), left {skipped} existing file(s) untouched.")
    print(f"Total applied SQL: {total_bytes:,} bytes across {len(rows)} migrations.")
    if multi:
        print(f"{multi} migration(s) had more than one statement.")
    if write:
        print(f"Manifest regenerated: {MANIFEST}")
        print("\nNext:")
        print("  python3 scripts/verify_migration_manifest.py")
        print("  python3 scripts/verify_migration_manifest.py --update-floors")
        print("  git add supabase/migrations && git commit -m "
              "'chore(db): materialise full migration history'")
    else:
        print("\nNothing was written. Re-run with --write to materialise the history.")
    print("\nWhen you are done: unset TF_DB_URL")
    return 0


if __name__ == "__main__":
    sys.exit(main())
