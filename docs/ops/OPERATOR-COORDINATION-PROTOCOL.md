# Operator coordination protocol

**Status** active from 19 August 2026 · **Owner** Director of IT

## Why this exists

Four times in three days, another operator applied migrations to this
production database within seconds or minutes of mine:

| When (UTC) | Their migration | What happened |
|---|---|---|
| 16 Aug 17:06 | `onsite_scope_verification_gate` | Shipped a SECURITY DEFINER trigger with default anon/authenticated grants. A1 and A15 went red seven minutes later. Closed by m342. |
| 16 Aug 22:37 | `register_acorn_finance_partner_record` | Clean, no residue. |
| 19 Aug 09:34 | `pin_search_path_trigger_guards` | Landed four seconds after m346. Clean. |
| 19 Aug 10:42 to 11:11 | (my own operator session died mid-import) | Left the pricebook import 774 of 1,026 complete with no record of where it stopped. Found only by counting rows. |

Three of four were harmless. The ratchets caught the one that was not. That
is the system working, but it is luck plus assertions covering for an absent
process, and the fourth case shows the failure mode does not require a second
operator at all: a session that dies mid-sequence leaves the same ambiguity.

## The protocol

**1. Announce before you apply.** Post to `#information-technology` before a
migration sequence: what you are changing, roughly how many migrations, and
expected duration. One line is enough. This is the whole protocol's value;
everything else is detail.

**2. Multi-part sequences declare their shape up front.** If you are applying
`x of n`, say so before the first one. Anyone reading the ledger later, or
picking up after you, then knows whether it finished.

**3. Never leave a partial sequence silent.** If a sequence stops early, for
any reason, post the stopping point immediately. The pricebook import cost an
hour of forensic counting purely because nobody could tell 774 from 1,026
without querying.

**4. Prefer idempotent migrations for data loads.** Every slice of the
pricebook import used an existence check, which is the only reason a partial
sequence was safely resumable rather than a restore-from-backup conversation.

**5. Watch the board after you apply.** The regression suite runs hourly.
If your change trips A1, A15, or A19, you will know within the hour, but only
if someone is looking. The person who applied is the person who watches.

**6. Grants are part of the change, not an afterthought.** Supabase grants
EXECUTE to `anon` and `authenticated` by default. `revoke ... from public` does
not undo it. Use `tf_apply_grant_tier` in the same migration that creates the
function. A15 will catch you, but catching is worse than not needing to.

## What is deliberately not in this protocol

No change freeze, no approval queue, no ticket. The assertions are the real
control and they work. This is about making concurrent work legible, not
about slowing it down.
