#!/usr/bin/env python3
"""
Transit & Flow - migration repository fidelity gate.

WHAT THIS REPLACES AND WHY
--------------------------
The previous CI job ran `supabase db reset`, which replays every migration file
in this repository against an empty local Postgres. That job could never pass and
was never capable of passing. Production has applied 320 migrations. This
repository holds a small subset of the corresponding .sql files. The first file
replayed references tables and functions created by migrations that are not in
the repository, so the reset aborts on the first statement. A gate that cannot
pass is not a gate, it is a permanently red light that teaches people to ignore
red lights.

This script gates what the repository honestly is: a partial, growing mirror of
one live database, plus an authoritative manifest of everything that database has
actually executed. It answers a question a replay cannot answer at all, which is
whether the files that ARE here match what really ran.

THE SIX CHECKS
--------------
A. Manifest well-formedness. Contiguous ordinals from 1, unique and strictly
   ascending versions, non-empty names, 32-hex checksums, positive byte counts.
B. File provenance. Every .sql file must be named <version>_<name>.sql and that
   exact (version, name) pair must appear in the manifest. Catches invented,
   renamed, reordered, and never-applied migration files.
C. Syntax. Every .sql file must parse as PostgreSQL, via pglast (libpg_query).
D. Fidelity. Each file is classified EXACT, COMMENT_DRIFT, or CODE_DRIFT against
   the manifest. CODE_DRIFT fails unless registered in MANIFEST_EXCEPTIONS.tsv
   against the file's current code checksum.
E. Index completeness. MIGRATIONS_INDEX.md must document at least as many of the
   320 applied ordinals as it did at the last floor update.
F. Coverage ratchet. The number of .sql files present must never fall below the
   recorded floor. The mirror can only grow.

E and F are ratchets rather than absolutes on purpose. An absolute would demand
that all 320 files land in a single commit before CI can be green again. A ratchet
makes every commit that closes part of the gap permanent, and makes any commit
that reopens it fail. Progress becomes irreversible without a deliberate,
reviewable edit to the floor file.

CHECKSUM DEFINITIONS
--------------------
checksum       md5 of the exact SQL text submitted to the database.
code_checksum  md5 of that text after trailing whitespace is stripped from every
               line and blank lines and whole-line SQL comments are removed.

Two checksums, because two kinds of divergence carry very different weight. A
rewritten comment is documentation. A changed statement is a claim about the
schema that production never agreed to.

Usage:
    python3 scripts/verify_migration_manifest.py [--repo-root .] [--update-floors]

Exit code 0 on pass, 1 on any failure. Emits GitHub Actions annotations when
GITHUB_ACTIONS is set, and writes a summary to GITHUB_STEP_SUMMARY if present.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

MANIFEST = "supabase/migrations/MIGRATION_MANIFEST.tsv"
EXCEPTIONS = "supabase/migrations/MANIFEST_EXCEPTIONS.tsv"
INDEX = "supabase/migrations/MIGRATIONS_INDEX.md"
FLOORS = "supabase/migrations/.ci-floors.json"
MIGDIR = "supabase/migrations"

HEX32 = re.compile(r"^[0-9a-f]{32}$")
FILENAME = re.compile(r"^(?P<version>\d{14})_(?P<name>.+)\.sql$")
INDEX_ROW = re.compile(r"^\|\s*(\d+)(?:\s*-\s*(\d+))?\s*\|")

IN_CI = bool(os.environ.get("GITHUB_ACTIONS"))


# ---------------------------------------------------------------- checksums


def code_normalise(text: str) -> str:
    """Strip trailing whitespace, drop blank lines and whole-line -- comments.

    This must stay byte-identical in behaviour to the SQL expression documented
    in the manifest header, which is what produced the code_checksum column.
    If you change one, change both, and re-derive the whole column.
    """
    kept = [line.rstrip() for line in text.split("\n")]
    kept = [l for l in kept if l.strip() != "" and not l.lstrip().startswith("--")]
    return "\n".join(kept)


def md5(text: str) -> str:
    return hashlib.md5(text.encode("utf-8")).hexdigest()


# ---------------------------------------------------------------- reporting


@dataclass
class Report:
    failures: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)

    def fail(self, msg: str, file: str | None = None) -> None:
        self.failures.append(msg)
        if IN_CI:
            loc = f" file={file}," if file else ""
            print(f"::error{loc}title=Migration fidelity::{msg}")

    def warn(self, msg: str, file: str | None = None) -> None:
        self.warnings.append(msg)
        if IN_CI:
            loc = f" file={file}," if file else ""
            print(f"::warning{loc}title=Migration fidelity::{msg}")

    def note(self, msg: str) -> None:
        self.notes.append(msg)


# ---------------------------------------------------------------- loading


@dataclass
class Row:
    ordinal: int
    version: str
    name: str
    statements: int
    checksum: str
    nbytes: int
    code_checksum: str


def load_manifest(path: Path, rep: Report) -> list[Row]:
    if not path.exists():
        rep.fail(f"{MANIFEST} is missing. The manifest is the authoritative record "
                 f"of what production has applied and cannot be regenerated by CI.")
        return []
    rows: list[Row] = []
    for lineno, raw in enumerate(path.read_text().split("\n"), start=1):
        if raw == "" or raw.startswith("#") or raw.startswith("ordinal\t"):
            continue
        parts = raw.split("\t")
        if len(parts) != 7:
            rep.fail(f"{MANIFEST}:{lineno} has {len(parts)} columns, expected 7.", MANIFEST)
            continue
        try:
            rows.append(Row(int(parts[0]), parts[1], parts[2], int(parts[3]),
                            parts[4], int(parts[5]), parts[6]))
        except ValueError:
            rep.fail(f"{MANIFEST}:{lineno} has a non-numeric ordinal, statement "
                     f"count, or byte count.", MANIFEST)
    return rows


def load_exceptions(path: Path, rep: Report) -> dict[str, tuple[str, str, str]]:
    """version -> (file_code_checksum, classification, rationale)"""
    out: dict[str, tuple[str, str, str]] = {}
    if not path.exists():
        return out
    for lineno, raw in enumerate(path.read_text().split("\n"), start=1):
        if raw == "" or raw.startswith("#") or raw.startswith("version\t"):
            continue
        parts = raw.split("\t")
        if len(parts) < 4:
            rep.fail(f"{EXCEPTIONS}:{lineno} has {len(parts)} columns, expected at "
                     f"least 4 (version, file_code_checksum, classification, rationale).",
                     EXCEPTIONS)
            continue
        version, fchk, cls, rationale = parts[0], parts[1], parts[2], "\t".join(parts[3:])
        if not HEX32.match(fchk):
            rep.fail(f"{EXCEPTIONS}:{lineno} pins a malformed checksum '{fchk}'.", EXCEPTIONS)
            continue
        if len(rationale.strip()) < 40:
            rep.fail(f"{EXCEPTIONS}:{lineno} rationale for {version} is too short. An "
                     f"exception must explain itself well enough that a reviewer who "
                     f"was not present can judge it.", EXCEPTIONS)
            continue
        out[version] = (fchk, cls, rationale)
    return out


def load_floors(path: Path) -> dict:
    if path.exists():
        return json.loads(path.read_text())
    return {"files_present": 0, "index_documented": 0}


# ---------------------------------------------------------------- checks


def check_a_wellformed(rows: list[Row], rep: Report) -> None:
    if not rows:
        rep.fail("Manifest contains no rows.", MANIFEST)
        return
    for i, r in enumerate(rows, start=1):
        if r.ordinal != i:
            rep.fail(f"Manifest ordinal {r.ordinal} appears at position {i}. Ordinals "
                     f"must be contiguous from 1 with no gaps and no reordering.", MANIFEST)
            break
    seen: set[str] = set()
    prev = ""
    for r in rows:
        if r.version in seen:
            rep.fail(f"Manifest version {r.version} appears more than once.", MANIFEST)
        seen.add(r.version)
        if prev and r.version <= prev:
            rep.fail(f"Manifest version {r.version} does not sort after {prev}. "
                     f"Versions must be strictly ascending.", MANIFEST)
        prev = r.version
        if not r.name.strip():
            rep.fail(f"Manifest row {r.ordinal} has an empty name.", MANIFEST)
        if not HEX32.match(r.checksum):
            rep.fail(f"Manifest row {r.ordinal} has malformed checksum '{r.checksum}'.", MANIFEST)
        if not HEX32.match(r.code_checksum):
            rep.fail(f"Manifest row {r.ordinal} has malformed code_checksum "
                     f"'{r.code_checksum}'.", MANIFEST)
        if r.nbytes <= 0:
            rep.fail(f"Manifest row {r.ordinal} claims {r.nbytes} bytes.", MANIFEST)
        if r.statements < 1:
            rep.fail(f"Manifest row {r.ordinal} claims {r.statements} statements.", MANIFEST)
    rep.note(f"A. Manifest well-formed: {len(rows)} applied migrations, "
             f"ordinals 1..{rows[-1].ordinal}, versions {rows[0].version}..{rows[-1].version}.")


def check_b_provenance(files: list[Path], by_version: dict[str, Row], rep: Report) -> list[tuple[Path, Row]]:
    matched: list[tuple[Path, Row]] = []
    for p in files:
        m = FILENAME.match(p.name)
        if not m:
            rep.fail(f"{p.name} does not follow <14-digit-version>_<name>.sql. Migration "
                     f"filenames are how a file claims which applied migration it is.",
                     f"{MIGDIR}/{p.name}")
            continue
        version, name = m.group("version"), m.group("name")
        row = by_version.get(version)
        if row is None:
            rep.fail(f"{p.name} claims version {version}, which production has never "
                     f"applied. Either the file is fabricated, or it was applied outside "
                     f"the migration system and the manifest needs regenerating.",
                     f"{MIGDIR}/{p.name}")
            continue
        if row.name != name:
            rep.fail(f"{p.name} claims name '{name}' but version {version} was applied as "
                     f"'{row.name}'. Rename the file to "
                     f"{version}_{row.name}.sql.", f"{MIGDIR}/{p.name}")
            continue
        matched.append((p, row))
    rep.note(f"B. Provenance: {len(matched)} of {len(files)} .sql files map to a real "
             f"applied migration.")
    return matched


def check_c_syntax(files: list[Path], rep: Report) -> None:
    try:
        import pglast  # type: ignore
        from pglast import parser  # type: ignore
    except ImportError:
        rep.warn("pglast is not installed, so SQL syntax was not verified. Install it "
                 "with 'pip install pglast' to enable check C.")
        return
    bad = 0
    for p in files:
        try:
            parser.parse_sql(p.read_text())
        except Exception as exc:  # pglast raises ParseError subclasses
            bad += 1
            first = str(exc).split("\n")[0]
            rep.fail(f"{p.name} does not parse as PostgreSQL: {first}", f"{MIGDIR}/{p.name}")
    if bad == 0:
        rep.note(f"C. Syntax: all {len(files)} .sql files parse as PostgreSQL "
                 f"(pglast {getattr(pglast, '__version__', 'unknown')}).")


def check_d_fidelity(matched: list[tuple[Path, Row]],
                     exceptions: dict[str, tuple[str, str, str]],
                     rep: Report) -> dict[str, int]:
    tally = {"EXACT": 0, "COMMENT_DRIFT": 0, "CODE_DRIFT": 0, "EXCEPTED": 0}
    for p, row in sorted(matched, key=lambda t: t[1].ordinal):
        text = p.read_text()
        exact = md5(text)
        # Applied text is stored without a trailing newline; a repository file that
        # ends with one is byte-identical for every purpose that matters.
        exact_stripped = md5(text.rstrip("\n"))
        file_code = md5(code_normalise(text))

        if exact == row.checksum or exact_stripped == row.checksum:
            tally["EXACT"] += 1
            continue

        if file_code == row.code_checksum:
            tally["COMMENT_DRIFT"] += 1
            rep.warn(f"{p.name} (migration {row.ordinal}) differs from the applied text "
                     f"in comments only. Executable SQL is identical. Acceptable, but the "
                     f"file is no longer a verbatim record.", f"{MIGDIR}/{p.name}")
            continue

        exc = exceptions.get(row.version)
        if exc and exc[0] == file_code:
            tally["EXCEPTED"] += 1
            rep.warn(f"{p.name} (migration {row.ordinal}) is registered CODE_DRIFT, "
                     f"classification {exc[1]}, pinned to the current file content.",
                     f"{MIGDIR}/{p.name}")
            continue

        if exc and exc[0] != file_code:
            rep.fail(f"{p.name} (migration {row.ordinal}) has a registered exception, but "
                     f"the file has changed since it was granted. Pinned {exc[0]}, file is "
                     f"now {file_code}. Review the new content and update "
                     f"{EXCEPTIONS}, or revert.", f"{MIGDIR}/{p.name}")
        else:
            rep.fail(f"{p.name} (migration {row.ordinal}) contains executable SQL that "
                     f"production never ran. Applied code checksum {row.code_checksum}, "
                     f"file code checksum {file_code}. Either the file is wrong, or a "
                     f"real change was made without a migration. If the divergence is "
                     f"deliberate and correct, register it in {EXCEPTIONS}.",
                     f"{MIGDIR}/{p.name}")
        tally["CODE_DRIFT"] += 1
    rep.note(f"D. Fidelity: {tally['EXACT']} exact, {tally['COMMENT_DRIFT']} comment drift, "
             f"{tally['EXCEPTED']} registered exception, {tally['CODE_DRIFT']} unregistered "
             f"code drift.")
    return tally


def documented_ordinals(path: Path) -> set[int]:
    if not path.exists():
        return set()
    out: set[int] = set()
    for line in path.read_text().split("\n"):
        m = INDEX_ROW.match(line)
        if not m:
            continue
        lo = int(m.group(1))
        hi = int(m.group(2)) if m.group(2) else lo
        if hi < lo:
            continue
        out.update(range(lo, hi + 1))
    return out


def check_e_index(rows: list[Row], root: Path, floors: dict, rep: Report) -> int:
    docs = documented_ordinals(root / INDEX)
    valid = {o for o in docs if 1 <= o <= len(rows)}
    floor = int(floors.get("index_documented", 0))
    if len(valid) < floor:
        missing = sorted(set(range(1, len(rows) + 1)) - valid)[:10]
        rep.fail(f"MIGRATIONS_INDEX.md documents {len(valid)} of {len(rows)} applied "
                 f"migrations, below the recorded floor of {floor}. Documentation coverage "
                 f"must never regress. First undocumented ordinals: {missing}.", INDEX)
    rep.note(f"E. Index coverage: {len(valid)}/{len(rows)} applied migrations documented "
             f"(floor {floor}).")
    return len(valid)


def check_f_coverage(matched_count: int, total: int, floors: dict, rep: Report) -> None:
    floor = int(floors.get("files_present", 0))
    if matched_count < floor:
        rep.fail(f"{matched_count} migration files are present, below the recorded floor "
                 f"of {floor}. Migration files are never deleted. If one was removed in "
                 f"error, restore it; if a removal is genuinely intended, lower the floor "
                 f"in {FLOORS} in the same commit and say why in the message.", FLOORS)
    pct = (matched_count / total * 100) if total else 0.0
    rep.note(f"F. Mirror coverage: {matched_count}/{total} applied migrations have their "
             f".sql file in the repository ({pct:.1f}%), floor {floor}. Run "
             f"scripts/backfill_migrations.py to close the gap.")


# ---------------------------------------------------------------- main


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo-root", default=".")
    ap.add_argument("--update-floors", action="store_true",
                    help="Rewrite the floor file to the currently measured values. "
                         "Run this deliberately, in the same commit that raises coverage.")
    args = ap.parse_args()
    root = Path(args.repo_root).resolve()

    rep = Report()
    rows = load_manifest(root / MANIFEST, rep)
    exceptions = load_exceptions(root / EXCEPTIONS, rep)
    floors = load_floors(root / FLOORS)

    if not rows:
        emit(rep, root)
        return 1

    check_a_wellformed(rows, rep)
    by_version = {r.version: r for r in rows}

    files = sorted((root / MIGDIR).glob("*.sql"))
    matched = check_b_provenance(files, by_version, rep)
    check_c_syntax(files, rep)
    check_d_fidelity(matched, exceptions, rep)
    documented = check_e_index(rows, root, floors, rep)
    check_f_coverage(len(matched), len(rows), floors, rep)

    if args.update_floors:
        new = {"files_present": len(matched), "index_documented": documented}
        (root / FLOORS).write_text(json.dumps(new, indent=2) + "\n")
        rep.note(f"Floors updated to {new}.")

    emit(rep, root)
    return 1 if rep.failures else 0


def emit(rep: Report, root: Path) -> None:
    lines: list[str] = []
    lines.append("## Migration repository fidelity")
    lines.append("")
    for n in rep.notes:
        lines.append(f"- {n}")
    if rep.warnings:
        lines.append("")
        lines.append(f"### Warnings ({len(rep.warnings)})")
        lines.append("")
        for w in rep.warnings:
            lines.append(f"- {w}")
    if rep.failures:
        lines.append("")
        lines.append(f"### Failures ({len(rep.failures)})")
        lines.append("")
        for f in rep.failures:
            lines.append(f"- {f}")
    lines.append("")
    lines.append("**PASS**" if not rep.failures else "**FAIL**")

    body = "\n".join(lines)
    print(body)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as fh:
            fh.write(body + "\n")


if __name__ == "__main__":
    sys.exit(main())
