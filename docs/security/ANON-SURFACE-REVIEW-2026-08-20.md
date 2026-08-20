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

---

# Addendum: what the red board exposed about the watcher (m359, m360)

Closing the board surfaced a worse problem than the board itself. The hourly
regression watcher paged `#information-technology` every time the suite was
red and said **nothing at all** when it went green.

Between 19:09 and 00:09 the team received seven "2 critical assertion(s)
failing" pages. On recovery they would have received zero. The ticket closes
itself in the ticket system, which nobody was watching, while the last thing
Slack ever said was that the platform was broken. An alarm that fires but
never stands down trains people to ignore the alarm.

Three defects, all in `tf_regression_autoticket`:

1. **No recovery signal.** Fixed by paging once on the red-to-green
   transition. The edge is `tickets_resolved > 0`, which is true exactly once
   per crossing and false on every steady-state green tick, so the recovery
   message never becomes an hourly heartbeat.
2. **`exception when others then null` around `tf_request_ticket`.** A ticket
   that failed to open produced no error, no warning, and `ok:true` with
   `tickets_opened: 0`. Now warns and lands in an `errors` array that drives
   the `ok` flag.
3. **The same swallow around `tf_resolve_ticket`.** Same fix.

`m360` then closed two follow-ons found by running the thing rather than
trusting it:

- `tf_page_staff_sev` reported `scope_recognized: false` for `internal_ops`.
  It worked only because the function seeds an owner + system_administrator
  floor before adding scope roles, so an unknown scope degrades to that floor.
  For a platform regression that floor is the right audience, but happening to
  be right is not a design. The scope is now declared. Nobody's paging
  changed.
- `tf_page_staff_sev` absorbs its own exceptions and returns them in the
  payload rather than raising, so m359's error capture would have missed a
  failed page entirely. The watcher now reads the returned payload too.

## End-to-end proof

Not a structural check. The real path ran:

| time (UTC) | event |
|---|---|
| 00:09 | watcher pages `#information-technology`, 2 critical failing |
| 00:51 / 00:53 | m357 and m358 applied, board returns to 21/21 |
| 01:01 | watcher run: ticket resolved 1, recovery page enqueued |
| 01:02:00 | recovery notification **delivered**, `delivered_channel = slack` |
| 01:03 | steady-state run: `tickets_resolved 0`, `recovery_paged null` |

The last row is the one that matters as much as the delivery: the recovery
message fires on the transition and stays quiet afterwards.
