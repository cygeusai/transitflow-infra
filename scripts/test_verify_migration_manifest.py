#!/usr/bin/env python3
"""
Transit & Flow - refusal proof for the migration fidelity gate.

House rule twenty-three: an assertion's failure path is code, and untested code.
A gate that has only ever been observed to pass has not been observed to do
anything. This script builds a disposable copy of the repository, breaks it in
one specific way at a time, and requires the gate to refuse each time. Then it
restores the copy and requires the gate to pass, which proves the refusals came
from the mutation rather than from the harness.

Every case below corresponds to a real way this repository could be corrupted:
a hand-edited migration, a file renamed to look like a different migration, a
fabricated migration that was never applied, a deleted file, an exception left
in place after the file it covers was edited again, and a manifest with a hole
punched in its ordinals.

Usage:  python3 scripts/test_verify_migration_manifest.py
Exit 0 if every case behaves as required.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
MIGDIR = "supabase/migrations"
MANIFEST = f"{MIGDIR}/MIGRATION_MANIFEST.tsv"
EXCEPTIONS = f"{MIGDIR}/MANIFEST_EXCEPTIONS.tsv"
FLOORS = f"{MIGDIR}/.ci-floors.json"
TARGET = "20260725181758_require_signal_wiring_at_commit.sql"  # classified EXACT
EXCEPTED = "20260725183125_signal_wiring_checker_and_control.sql"


def run(root: Path) -> tuple[int, str]:
    proc = subprocess.run(
        [sys.executable, str(root / "scripts/verify_migration_manifest.py"),
         "--repo-root", str(root)],
        capture_output=True, text=True,
    )
    return proc.returncode, proc.stdout + proc.stderr


def stage(tmp: Path) -> Path:
    root = tmp / "repo"
    root.mkdir()
    (root / "scripts").mkdir()
    (root / MIGDIR).mkdir(parents=True)
    shutil.copy(REPO / "scripts/verify_migration_manifest.py", root / "scripts")
    for p in (REPO / MIGDIR).iterdir():
        if p.is_file():
            shutil.copy(p, root / MIGDIR / p.name)
    return root


# ------------------------------------------------------------------ mutations


def mut_code_drift(root: Path) -> None:
    """Change executable SQL in a file that currently matches production exactly."""
    p = root / MIGDIR / TARGET
    t = p.read_text()
    assert "raise" in t
    p.write_text(t.replace("raise", "raise ", 1) + "\nselect 1;\n")


def mut_comment_only(root: Path) -> None:
    """Change a comment only. Must NOT fail. Proves the gate is not merely strict."""
    p = root / MIGDIR / TARGET
    p.write_text("-- a comment that production never saw\n" + p.read_text())


def mut_renamed(root: Path) -> None:
    """Rename a file so its declared name no longer matches the applied name."""
    src = root / MIGDIR / TARGET
    src.rename(root / MIGDIR / "20260725181758_a_name_production_never_used.sql")


def mut_fabricated(root: Path) -> None:
    """Add a migration file for a version production has never applied."""
    (root / MIGDIR / "20991231235959_never_applied.sql").write_text("select 1;\n")


def mut_deleted(root: Path) -> None:
    """Delete a migration file, dropping coverage below the floor."""
    (root / MIGDIR / TARGET).unlink()


def mut_stale_exception(root: Path) -> None:
    """Edit a file that has a registered exception. The pin must stop matching."""
    p = root / MIGDIR / EXCEPTED
    p.write_text(p.read_text() + "\nselect 1;\n")


def mut_manifest_hole(root: Path) -> None:
    """Remove a manifest row, breaking ordinal contiguity."""
    p = root / MANIFEST
    lines = p.read_text().split("\n")
    out, dropped = [], False
    for line in lines:
        if not dropped and line.startswith("100\t"):
            dropped = True
            continue
        out.append(line)
    assert dropped, "expected ordinal 100 in the manifest"
    p.write_text("\n".join(out))


def mut_unparseable(root: Path) -> None:
    """Corrupt the SQL so it cannot parse."""
    p = root / MIGDIR / TARGET
    p.write_text("create table (((;\n")


def mut_bad_checksum(root: Path) -> None:
    """Corrupt a checksum field in the manifest."""
    p = root / MANIFEST
    p.write_text(p.read_text().replace(
        "\tc91db1d62b6f96c434ce159dbba4e6d4\t", "\tnot-a-checksum\t", 1))


def mut_short_rationale(root: Path) -> None:
    """An exception whose rationale explains nothing must be rejected."""
    p = root / EXCEPTIONS
    lines = [l for l in p.read_text().split("\n") if not l.startswith("20260725183125\t")]
    lines.append("20260725183125\ta672d7c47e25e8831c2ea88ad2e1ff8c\tREPLAY_REPAIR\tbecause")
    p.write_text("\n".join(lines) + "\n")


CASES = [
    ("code drift in an exact file", mut_code_drift, "FAIL"),
    ("comment-only edit", mut_comment_only, "PASS"),
    ("file renamed away from applied name", mut_renamed, "FAIL"),
    ("fabricated migration file", mut_fabricated, "FAIL"),
    ("migration file deleted below floor", mut_deleted, "FAIL"),
    ("registered exception gone stale", mut_stale_exception, "FAIL"),
    ("hole punched in manifest ordinals", mut_manifest_hole, "FAIL"),
    ("unparseable SQL", mut_unparseable, "FAIL"),
    ("malformed checksum in manifest", mut_bad_checksum, "FAIL"),
    ("exception with a rationale that explains nothing", mut_short_rationale, "FAIL"),
]


def main() -> int:
    problems: list[str] = []
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)

        baseline = stage(tmp)
        rc, out = run(baseline)
        if rc != 0:
            print("Baseline copy does not pass. The harness is wrong, not the gate.")
            print(out)
            return 1
        print("baseline                                              PASS as required")
        shutil.rmtree(baseline)

        for label, mutate, expect in CASES:
            root = stage(tmp)
            mutate(root)
            rc, out = run(root)
            got = "PASS" if rc == 0 else "FAIL"
            ok = got == expect
            print(f"{label:<54s}{got} {'as required' if ok else 'BUT EXPECTED ' + expect}")
            if not ok:
                problems.append(label)
                print("    " + "\n    ".join(out.strip().split("\n")[-12:]))
            shutil.rmtree(root)

    print()
    if problems:
        print(f"{len(problems)} case(s) behaved wrongly: {', '.join(problems)}")
        return 1
    print(f"All {len(CASES)} cases behaved as required. The gate refuses when it should "
          f"and permits when it should.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
