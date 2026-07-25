# Revenue Linkage

How collected revenue gets attached to the job that earned it, why that link
kept decaying, and what now holds it in place.

Migrations 220 through 223.

## The problem this solves

`docs/MARKETING_ROI_AND_REVENUE.md` ends by naming the single highest-value
data-quality fix on the platform: close the `job_id` gap. Marketing ROI is
computed by walking invoice to job to lead to channel. An invoice with a null
`job_id` is revenue that can never reach a channel, so every unlinked dollar is
a dollar of spend that cannot be judged. At the start of this work, 46.7% of
collected revenue was in that state.

The tempting fix is a backfill. That would have been wrong, and the reason it
would have been wrong is the most important thing in this document.

## What the investigation actually found

Three findings, in ascending order of how much they cost.

**The linker was a one-shot backfill, not a process.** All 19 linked invoices
shared an exact signature, `customer_id` matched and invoice amount equalled job
amount to the cent, and every one of them had `txn_date` on or before
2026-07-16. All 12 unlinked invoices had `txn_date` on or after 2026-07-18.
Somebody ran a linker once, by hand, and nothing had linked since. The invoice
writer is the `qbo-sync` edge function on the `qbo-sync-2h` schedule, and it
never sets `job_id` at all.

This is a decay defect, and decay defects are worse than they look. Every new
invoice lands unlinked, so `revenue_traceable_pct` falls a little further every
sync. The metric gets worse precisely as the business gets bigger. A backfill
would have shown a triumphant number on the day it ran and then bled out. The
fix has to be a recurring sweep or it is not a fix.

**Convention drift on the QuickBooks natural key, with a date attached.** The
uniqueness constraint was `(company_id, source, external_id)`. Twenty-nine rows
carried `<realm>:<qbId>`. Two rows carried a bare `<qbId>`, `80` and `82`, and
those same two rows were the only invoices in the tenant with a null
`customer_id`, which is the fingerprint of a second, less complete writer having
touched the table at some point.

The realm-qualified suffix space was running 2 through 75 and marching upward.
When QuickBooks entity 80 came around to sync, it would have landed as
`realm:80`, which does not collide with the existing bare `80`. The same
invoice inserts twice. $1,145.38 plus $258.75, so **$1,404.13 of collected
revenue would have silently double-counted** on the owner dashboard and in the
channel P&L, permanently, with nothing anywhere to indicate it had happened.

**Genuine ambiguity that must not be auto-resolved.** Invoice doc 63, Steve
Mitchell, $827.99, matches two jobs: TF-100056 and TF-100057, both created
2026-07-19, both $827.99. A naive amount-matcher picks one and is wrong half the
time. Being wrong half the time about which job earned the money is worse than
admitting you do not know, because a wrong link looks exactly like a right one.

## What shipped

### `tf_link_revenue(p_dry_run boolean default true, p_days integer default 180)`

A three-stage idempotent sweep. `security definer`, pinned `search_path`.

Stage one resolves a missing `customer_id` from `customer_name`, but only when
exactly one live customer matches the composed display name. The customers table
has no `name` column, so the comparison builds it as first plus last, falling
back to `company_name`.

Stage two links invoice to job on customer plus exact amount, inside a date
window running 90 days before the invoice date to 7 days after, skipping any job
that already has an invoice. Then the part that matters: a candidate pair is
only accepted when the invoice has exactly one candidate job **and** that job has
exactly one candidate invoice. Uniqueness in both directions. One invoice with
two candidate jobs is a question for a human, not a match.

Stage three reports what it refused, with the customer name and amount, so the
refusals are actionable rather than merely counted.

Dry run is the default, following the house precedent set by
`tf_merge_duplicate_customers(p_dry_run boolean default true)`. Cron passes
`false` explicitly. A bare call can look but cannot touch.

### `tf_revenue_linkage_audit(p_days integer default 90)`

The scoreboard. `stable`, staff-guarded, read-only. Returns the traceability
figures plus a reason code for every invoice still unlinked, so the residual is
never an unexplained number. The reason codes are `zero_amount`, `no_customer`,
`no_candidate_job`, `ambiguous_candidates`, and `linkable_next_sweep`. It also
returns `external_id_shapes` and a `duplicate_key_risk` block, which is how the
second finding above got surfaced in the first place and how a regression would
get surfaced again.

### The normalised natural key

```sql
create unique index invoices_qb_norm_ext_uq
  on public.invoices (company_id, (regexp_replace(external_id, '^.*:', '')))
  where deleted_at is null and source = 'quickbooks';
```

The index is on the *normalised* expression, so `realm:80` and bare `80` occupy
the same slot and cannot both exist. It created cleanly, because today there is
no collision, only a future one.

This is a deliberate trade. A convention-violating sync now fails loudly and
stalls a batch, where before it would have quietly corrupted the financials. A
stalled batch is visible within the hour, because the existing watchdog and
autoticket infrastructure raise it. Corrupted revenue is not visible at all, and
by the time anyone notices, the P&L has been wrong for months and nobody can say
since when. Loud failure wins. It will not always be convenient, and that is
the point.

## The guard ladder

| Caller | `auth.uid()` | `tf_link_revenue` | `tf_revenue_linkage_audit` |
| --- | --- | --- | --- |
| pg_cron (`postgres`, no JWT) | null | runs | refused |
| Internal staff | set, staff | runs | runs |
| Authenticated non-staff | set, not staff | `forbidden` | `forbidden` |
| `anon` | n/a | execute revoked | execute revoked |

The asymmetry in the first row is intentional. The sweep uses a cron-tolerant
guard, `if auth.uid() is not null and not user_is_internal_staff(v_company)`,
because cron carries no JWT and a bare staff check would have turned the
scheduled sweep into a silent no-op that reported success forever. The audit
carries the full guard, because nothing but an operator ever needs to read it.

That distinction is now a platform rule. A cron-invoked mutating function needs
the tolerant form. Everything else takes the strict form.

## Verification

Driven against production data, not inspected. Verification found three defects
that code review had not, which is the entire argument for the discipline.

**Guard arity.** The functions called `user_is_internal_staff()` with no
argument. The platform's guard is `user_is_internal_staff(cid uuid)`. Every call
would have raised `42883`, and the nightly sweep would have failed every night
against a log nobody reads. Migration 221.

**`min(uuid)` does not exist.** Stage one used `min(c.id)` to pick the customer
from a unique match. Postgres has no `min` aggregate over `uuid`. Replaced with
`(array_agg(c.id))[1]`, which is exact here because the row is only retained when
the match count is 1. Migration 222.

**The sweep was not re-entrant.** The scratch tables were created `on commit
drop`, which only fires at COMMIT, so a second call inside the same transaction
hit `42P07`. Any wrapping transaction or retry would have broken it. Now dropped
defensively before creation. Migration 223.

Each of the three was repaired by reading the live definition out of
`pg_get_functiondef`, patching the one expression, and re-executing it, rather
than by retyping the body. `create or replace` preserves grants; the privilege
check afterwards confirmed all three rewrites left `anon` revoked and
`authenticated` plus `service_role` intact.

Then the behaviour:

- Dry run predicted 7 links and 2 customer resolutions. Live run wrote exactly
  7 and 2. An immediate third call in the same transaction found 0, which proves
  re-entrancy and idempotency together.
- Doc 63 stayed in `ambiguous` across every run, as designed.
- Clamps hold. `p_days` of 0 and -50 floor to 1, 999999 ceilings to 1095, null
  falls back to the declared default. A bare `tf_link_revenue()` returns
  `dry_run: true`.
- The demo non-staff user is refused on both functions. `anon` cannot execute
  either.
- With no JWT, the cron path runs the sweep and the audit refuses. Exactly the
  intended asymmetry.
- The duplicate-key guard was proved, not assumed. A probe insert of
  `realm:80` against the existing bare `80` raised `unique_violation`, inside a
  block written so that both branches raise and nothing can commit. Zero probe
  rows remain.
- `tf_security_scan()` returns 0 on all four axes.

## The numbers

| | Before | After |
| --- | --- | --- |
| Revenue traceable to a job | $6,843.77 | $10,721.31 |
| Collected revenue in window | $12,834.05 | $12,834.05 |
| `revenue_traceable_pct` | 53.3% | 83.5% |
| Invoices linked | 19 | 26 |
| Invoices unlinked | 12 | 5 |
| Revenue at risk of double-count | $1,404.13 | $0.00 |

The middle row is the one to check first. Collected revenue is identical before
and after. Linkage changes what revenue can be *attributed to*, never how much
revenue there is. If a linkage change ever moves the collected total, the
linkage is not what moved it and something else is wrong.

`tf_marketing_roi(90)` independently reports 83.5% and $10,721.31 from the same
convention, computed separately. Two read models agreeing is worth more than
either one asserting.

The five remaining unlinked invoices are fully explained: 2 zero-amount credit
memos, 2 with no candidate job, 1 genuinely ambiguous. The reason codes
`no_customer` and `linkable_next_sweep` both went to zero, which is what it
looks like when a sweep has finished its work rather than merely run.

## Operating it

`tf-revenue-linkage-hourly` runs `select public.tf_link_revenue(false, 180);` at
`55 * * * *`. Hourly rather than daily because the defect is decay, and every
hour of unswept invoices is revenue that cannot reach a channel. Minute 55 sits
well clear of the 2-hourly `qbo-sync-2h` on the hour and collides with no other
job. The sweep is indexed and no-ops cheaply when there is nothing to do.

To see the state of things, call `tf_revenue_linkage_audit(90)` and read
`unlinked_reasons` before `revenue_traceable_pct`. The percentage tells you
whether to care. The reason codes tell you what to do.

**Watch `ambiguous_candidates`.** These are the invoices where the platform
refused to guess. They need a human to say which job earned the money, and until
someone does, that revenue stays unattributed. If this count climbs, it is not a
bug in the sweep, it is a signal that jobs are being created in near-duplicate
pairs upstream and that is where the fix belongs.

**Watch `duplicate_key_risk.nonconforming_rows`.** It should trend to zero and
stay there. It sits at 2 today. Those two rows are now harmless, because the
index makes the collision impossible, but harmless is not the same as resolved.
Normalising them to the realm-qualified shape is tracked owner work. Until it is
done, the two QuickBooks entities 80 and 82 will fail to sync loudly rather than
corrupt quietly, which is the correct failure but still a failure.

**If `no_candidate_job` grows**, jobs are not being created for work that is
being invoiced, which is an operations problem wearing a data costume.

## The pattern, stated plainly

This is the fourth time convention drift has been the highest-yield defect class
on this platform. Phone identity, then revenue recognition, then the QuickBooks
external-id shape, now the linkage process itself. Every one followed the same
shape: two writers, one convention each, both correct in isolation, silently
disagreeing at the seam.

The countermeasure that keeps working is to enforce the convention in the
database on the normalised form of the value, so the disagreement becomes an
error at write time instead of a discrepancy at read time. Convention documented
in prose is a convention that will drift. Convention expressed as a unique index
is a convention that cannot.
