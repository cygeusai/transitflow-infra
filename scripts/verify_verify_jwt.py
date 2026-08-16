#!/usr/bin/env python3
"""
Transit & Flow - edge function verify_jwt posture gate.

WHAT THIS IS, AND WHAT IT REPLACES
----------------------------------
The original gate was lost when a sandbox container was reclaimed on
2026-08-16. This is a RE-AUTHORED replacement, not a recovery of that file.
It is written against the same idea, which is worth restating because it is
the reason the gate exists at all:

verify_jwt is a GATEWAY control, not a function control. When it is true,
Supabase refuses a request carrying no Authorization header before the
function's own code ever runs. When it is false, the gateway is open and the
FUNCTION is solely responsible for authenticating its caller.

So "false" is not a weaker setting than "true". It is a different setting, and
it is the CORRECT one for every inbound webhook, because Twilio, Quo, Housecall
Pro, Meta, Slack, Stripe and Shopify do not send a Supabase JWT. Flipping a
webhook to true does not harden it, it breaks it silently: the provider gets a
401 from the gateway, the function never runs, and nothing in the platform logs
an error because from Supabase's point of view nothing went wrong.

That is the failure this gate exists to catch, in both directions: a webhook
quietly closed, or an authenticated endpoint quietly opened.

THE ONE THING WORTH KNOWING ABOUT MEASUREMENT
---------------------------------------------
Do not trust the config readback to tell you what the gateway does. The
authoritative test is a request with NO Authorization header at all:

  verify_jwt = true   -> {"code":"UNAUTHORIZED_NO_AUTH_HEADER", ...} from the gateway
  verify_jwt = false  -> the isolate's own JSON, whatever that function returns

That probe is free, needs no credentials, and has caught a disagreement between
config and behaviour on this platform before.

MODES
  (default)        credential-free. Validates the baseline is well-formed and
                   internally consistent. This is what CI runs.
  --live           compares the baseline against the live platform. Needs
                   SUPABASE_ACCESS_TOKEN. Read-only.
  --plan           prints the baseline-vs-live table and never exits non-zero.
  --require-live   fail rather than skip if live measurement is unavailable.

Exit 0 on pass, 1 on any failure.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.request
from pathlib import Path

BASELINE = "supabase/functions/VERIFY_JWT_BASELINE.tsv"
PROJECT_REF = os.environ.get("PROJECT_REF", "kjooyhvynkzuvsixsutt")
SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")


def load_baseline(root: Path):
    path = root / BASELINE
    if not path.exists():
        return None, [f"{BASELINE} is missing. The gate cannot run without a recorded posture."]
    rows, errors, seen = [], [], set()
    header_seen = False
    for n, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.rstrip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if not header_seen:
            if parts != ["slug", "verify_jwt", "version", "gate"]:
                errors.append(f"line {n}: header must be slug/verify_jwt/version/gate, got {parts}")
            header_seen = True
            continue
        if len(parts) != 4:
            errors.append(f"line {n}: expected 4 tab-separated columns, got {len(parts)}")
            continue
        slug, vj, ver, gate = parts
        if not SLUG_RE.match(slug):
            errors.append(f"line {n}: implausible slug {slug!r}")
        if slug in seen:
            errors.append(f"line {n}: duplicate slug {slug!r}")
        seen.add(slug)
        if vj not in ("true", "false"):
            errors.append(f"line {n}: verify_jwt must be true or false, got {vj!r}")
        if not ver.isdigit() or int(ver) < 1:
            errors.append(f"line {n}: version must be a positive integer, got {ver!r}")
        if gate not in ("open", "jwt"):
            errors.append(f"line {n}: gate must be open or jwt, got {gate!r}")
        # The coupling that makes the file self-checking: gate is a restatement
        # of verify_jwt in words. If they disagree, one of them is a typo and we
        # do not know which, so refuse rather than pick.
        if vj == "true" and gate != "jwt":
            errors.append(f"line {n}: {slug} has verify_jwt=true but gate={gate}")
        if vj == "false" and gate != "open":
            errors.append(f"line {n}: {slug} has verify_jwt=false but gate={gate}")
        rows.append({"slug": slug, "verify_jwt": vj == "true", "version": int(ver), "gate": gate})
    if not header_seen:
        errors.append(f"{BASELINE} has no header line")
    if not rows:
        errors.append(f"{BASELINE} records zero functions. An empty baseline is not a pass.")
    return rows, errors


def fetch_live(token: str):
    url = f"https://api.supabase.com/v1/projects/{PROJECT_REF}/functions"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode())


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo-root", default=".")
    ap.add_argument("--live", action="store_true")
    ap.add_argument("--plan", action="store_true")
    ap.add_argument("--require-live", action="store_true")
    args = ap.parse_args()
    root = Path(args.repo_root).resolve()

    rows, errors = load_baseline(root)
    print("## Edge function verify_jwt posture")
    if rows is not None:
        n_open = sum(1 for r in rows if r["gate"] == "open")
        print(f"\n- A. Baseline well-formed: {len(rows)} functions recorded, "
              f"{n_open} gateway-open, {len(rows) - n_open} jwt-required.")

    failures = list(errors)

    want_live = args.live or args.plan or args.require_live
    if want_live:
        token = os.environ.get("SUPABASE_ACCESS_TOKEN", "")
        if not token:
            msg = "live measurement requested but SUPABASE_ACCESS_TOKEN is not set"
            if args.require_live:
                failures.append(msg)
            else:
                print(f"\n- B. Live comparison SKIPPED: {msg}.")
        else:
            try:
                live = {f["slug"]: f for f in fetch_live(token)}
            except Exception as exc:  # noqa: BLE001
                failures.append(f"live fetch failed: {type(exc).__name__}: {exc}")
                live = None
            if live is not None:
                base = {r["slug"]: r for r in (rows or [])}
                drift, missing, extra = [], [], []
                for slug, r in sorted(base.items()):
                    if slug not in live:
                        missing.append(slug)
                    elif bool(live[slug].get("verify_jwt")) != r["verify_jwt"]:
                        drift.append((slug, r["verify_jwt"], bool(live[slug].get("verify_jwt"))))
                for slug in sorted(live):
                    if slug not in base:
                        extra.append(slug)
                print(f"\n- B. Live comparison: {len(live)} live, {len(base)} recorded, "
                      f"{len(drift)} drifted, {len(missing)} recorded-but-absent, "
                      f"{len(extra)} live-but-unrecorded.")
                for slug, was, now in drift:
                    print(f"    DRIFT {slug}: baseline verify_jwt={was}, live={now}")
                for slug in missing:
                    print(f"    MISSING {slug}: recorded here, not deployed")
                for slug in extra:
                    print(f"    UNRECORDED {slug}: deployed, absent from the baseline")
                if not args.plan:
                    failures += [f"{s}: baseline {w}, live {n}" for s, w, n in drift]
                    failures += [f"{s}: recorded but not deployed" for s in missing]
                    failures += [f"{s}: deployed but not recorded" for s in extra]

    if args.plan:
        print("\n**PLAN ONLY, never blocks**")
        return 0
    if failures:
        print(f"\n### Failures ({len(failures)})\n")
        for f in failures:
            print(f"- {f}")
        print("\n**FAIL**")
        return 1
    print("\n**PASS**")
    return 0


if __name__ == "__main__":
    sys.exit(main())
