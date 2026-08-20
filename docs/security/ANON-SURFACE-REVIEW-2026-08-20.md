# Anon SECURITY DEFINER surface review, 20 August 2026

**Reviewer:** platform operator (autonomous)
**Trigger:** A1 and A15 both red, critical, after ordinals 503-510
**Outcome:** 21 passed, 0 failed, 0 critical failures. Function safety board 0/0/0/0.

## What went red and why

Another operator shipped a deliberate pre-authentication studio signup funnel.
Three new SECURITY DEFINER functions became reachable by `anon`:

| function | anon | authenticated | disposition |
|---|---|---|---|
| `tf_studio_current_agreement(p_agreement_key text)` | yes | yes | keep, allowlisted `catalog_read` |
| `tf_studio_submit_founding_application(...)` | yes | yes | keep, allowlisted `ui_action` |
| `tf_studio_accept_agreement(...)` | yes | yes | keep, hardened first, allowlisted `ui_action` |

They carried correct `tf_function_grant_tiers` declarations and
`tf_function_registry` rows. What they did not carry was a review recorded in
the two closed-allowlist assertions. That is the assertions working, not
failing: a closed allowlist that nobody reviews is not an allowlist.

## Disposition and why it is not the m342 precedent

m342 demoted `tf_guard_onsite_verification` to admin because nothing outside
the database had any business calling it. That reasoning does not transfer
here. A professional signing a founding agreement has no account by
definition, so `anon` is the intended reach and not drift. Blind demotion
would have broken another team's funnel to make a board go green, which is
the wrong trade every time.

Each definition was read in full before disposition:

- **`tf_studio_current_agreement`** is `sql stable`. It returns six named
  fields of the current *published* version only, or a refusal object when
  nothing is published. It selects named columns rather than the row, so a
  column added later cannot leak. No write path, no tenant data, no PII.
- **`tf_studio_submit_founding_application`** validates presence of company,
  contact and email, enforces an email pattern, caps field lengths, clamps
  seats to 1-25, deduplicates the same lowercased email inside 24 hours, and
  writes `status = 'pending'` only. It is a function rather than a table grant
  precisely so applicant PII is never selectable.
- **`tf_studio_accept_agreement`** was the one that needed work before it could
  be blessed. See below.

## What was hardened before blessing (m357, m358)

`tf_studio_accept_agreement` writes into a legal evidence ledger from an
unauthenticated caller. As shipped it had no idempotence, no ceiling, and an
`exception when others` that retried the insert. Three defects, three fixes:

1. **Idempotence.** One signer signs one version once. A double-clicked
   button, a retried request or a replayed payload now returns the signature
   already on file instead of minting a second one. Two live rows for one
   signature is not a duplicate record, it is an ambiguous one.
2. **A ceiling that does not need a session.** 25 acceptances per origin
   address per 24 hours. A null address is not counted, because it cannot be
   attributed and refusing every caller behind a stripped header would refuse
   real signers.
3. **No more silent swallow.** The blanket retry could report a failed insert
   to a signer as success. The header parse is now guarded where it happens
   and raises a warning; everything else propagates. A signature that did not
   record must never return `ok`.

m358 then backed the idempotence with a partial unique index on
`(agreement_key, agreement_version, lower(signer_email)) where revoked_at is
null`, closing the check-then-act race, and taught the function to return the
committed row when it loses that race. The guarantee now lives in the
database, where concurrency cannot route around it.

## The structural fix: A1 no longer hardcodes its own allowlist

A1 checked the anon surface against a name list written into the assertion
body. That list went stale twice, and each time it went stale the board
reported a critical failure against functions that were correctly declared. A
bare name list would also have silently exempted a future `public.auth_org`.

A1 now reads `tf_function_grant_tiers`, which every anon grant already passes
through: a function is acceptable on the anon surface only if it has a row
with `tier = 'anon'` and a rationale of at least 60 characters. A correctly
declared function passes. An undeclared one, or one declared with a token
rationale, still fails critical. The three legacy `cygeus` functions predate
the tier table and are excepted by name **and** schema, not by name alone.

Arithmetic at the time of writing: 8 anon-reachable SECURITY DEFINER
functions, 3 legacy exceptions, 5 passing on declarations. Remove any one
declaration and A1 goes red. The check is real.

## Verification performed

- Guard paths exercised live: missing fields, invalid email, and no published
  version all refuse. `studio_agreement_acceptances` row count unchanged at 0.
  No fake data was written to a production table to manufacture a test.
- Grants confirmed intact after both `create or replace` calls.
- Suite re-run against `Transit & Flow`: 21 / 0 / 0.
- Both migration files mirrored into the repository and verified byte-exact
  against the statements production actually ran
  (`1e1b5e09d4d7429073f4213efd607078`, `80bb59fbce6f06f5be34a40fc0d288a1`).

## Note on the sandbox company

Running the suite against `DEMO - Transit & Flow Sandbox` reports A7 and A18
failing. That company has no outbound SMS sender and no Slack channel mapping,
which is what a sandbox should look like. The suite is company-scoped; run it
against `ff000000-0000-4000-b000-000000000001` for the production board.
