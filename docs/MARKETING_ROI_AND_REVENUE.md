# Revenue Recognition and the Channel P&L

Two read models on this platform were reporting revenue. They disagreed by
seventeen percent, and nothing anywhere said which one was right.

That is the finding. The marketing ROI function that follows is the thing the
platform was missing entirely. Both shipped in migration 219.

## E1 — the Executive Dashboard was understating collected revenue by 17%

`tf_owner_dashboard` computed revenue as:

```sql
select sum(total_amount) from invoices where is_paid = true
```

`tf_customer_index`, `tf_customer_360` and `tf_ops_report` all computed it as:

```sql
select sum(total_amount - balance) from invoices
```

These are not two roundings of the same number. They are two different
definitions of the word revenue, and the difference is every partially paid
invoice on the platform.

An invoice billed at $2,000 with $1,600 collected and $400 still open carries
`is_paid = false`. The dashboard therefore dropped it whole, including the
$1,600 the customer actually paid, while the Customers page counted the $1,600
correctly. Live, on the production tenant:

| Basis | Trailing 365 days |
|-------|-------------------|
| `sum(total_amount) where is_paid` (shipped) | **$10,648.75** |
| `sum(total_amount - balance)` (everywhere else) | **$12,834.05** |
| Understatement | **$2,185.30 · 17.0%** |

Three partially paid invoices out of thirty-one. The owner opened one screen and
saw one number, opened another and saw a number seventeen percent larger, and
the platform offered no way to tell which was the business truth.

**Collected revenue is the convention.** Cash the customer has actually parted
with, on the invoice it was billed against. A customer billed $12,000 who has
paid $400 has produced $400 of revenue, which is the same reasoning that puts
the Customer 360 segment ladder on collected rather than invoiced dollars. The
dashboard now returns `revenue_basis: 'collected'` in its payload so the
convention is asserted in the response, not just in a document.

Three preconditions were proven before unifying, because the fix is only safe if
`balance` is trustworthy: **`paid_with_balance = 0`** (no invoice is marked paid
while carrying an open balance), **`null_is_paid = 0`**, and **`overbalance = 0`**
(no balance exceeds its total). With those three at zero, `total_amount - balance`
is exactly the collected amount and the `is_paid` filter on outstanding balance
is redundant, since a paid invoice carries balance zero by definition.

**A second defect fell out of the same rewrite.** The daily revenue trend ran a
correlated subquery per day of the window, so a 365 day dashboard executed 365
separate aggregate scans of the invoice table. It is now one grouped pass left
joined onto the date spine. Same output, one scan, and it stops being an O(days x
invoices) problem before the invoice table gets large enough to make it one.

### Coverage is now stated rather than implied

Unifying the basis exposed something more useful than the bug: the three read
models see three different slices of the same money, and each slice is now
explainable rather than mysterious.

| Invoice population | Count | Collected | Which read model can see it |
|--------------------|-------|-----------|------------------------------|
| Job **and** customer linked | 19 | $6,843.77 | Dashboard, Customer 360, **Marketing ROI** |
| Customer linked, no job | 10 | $4,586.15 | Dashboard, Customer 360 |
| Neither linked | 2 | $1,404.13 | Dashboard only |
| **Total** | **31** | **$12,834.05** | |

`tf_owner_dashboard` reports $12,834.05. `tf_customer_index` sums to
$11,429.92, which is exactly the first two rows. They no longer disagree about
revenue; they disagree about *reachability*, which is a data-quality fact, not a
convention conflict. Two invoices carrying $1,404.13 have no customer at all,
and that is now a visible number instead of a silent gap between two screens.

## E2 — `tf_marketing_roi`, the channel P&L

No function on this platform closed the loop from marketing spend to collected
revenue. `lead_spend`, `leads.lead_cost`, `tf_log_lead_cost` and
`tf_log_lead_spend` all existed as fragments with no consumer, and
`tf_owner_dashboard` had no marketing block at all. An owner could see what came
in and could not see what it cost to make it come in.

`tf_marketing_roi(p_days integer default 90)` closes it:
**spend → lead → job → invoice → collected revenue, by source.**

### The model, stated explicitly

**Cohort: jobs created in the window**, and all revenue collected against those
jobs whenever it lands. Not invoices dated in the window. A job booked in March
that pays in May belongs to March's marketing, because March's marketing is what
bought it. Attributing by invoice date would credit the channel that was running
when the check cleared.

**Attribution: first touch, lead source then job source.** If the job carries a
`leads` row with a `source_id`, that source wins. Otherwise the `jobs.source`
enum is used. This ordering matters because the lead row is the richer record and
the enum is the fallback of last resort.

**Spend: prorated period buys plus per-lead costs.** A monthly `lead_spend` row
overlapping a seven day window contributes seven thirty-firsts of its amount, not
the whole thing. Home-services marketing bills both ways, a flat Google Ads buy
and a per-lead Angi or Thumbtack charge, so both `lead_spend.amount` and
`leads.lead_cost` roll into one `spend` figure per channel.

### One channel, one name

The enum value `housecall_pro` and the `lead_sources.key` `housecall_pro`
describe the same channel, and a naive implementation reports it twice. Proven
before the fix: `src:housecall_pro` at 57 jobs / $6,843.77 sitting alongside
`housecall_pro` at 20 jobs / $0.00, the same channel split into a profitable half
and a worthless half by nothing but which table the row came from.

The normaliser maps `web → website` and `repeat_customer → repeat`, and the
lead-source key is preferred whenever present. Verified live: Housecall Pro now
appears **once**, at 77 booked jobs and $6,843.77 collected.

### Nothing is silently dropped

Only 20 of 78 live jobs carry a lead row with a source. A marketing report that
quietly computed ROI on 25.6% of the book while presenting itself as the channel
P&L would be worse than no report at all, because it would be confidently wrong.

Two coverage blocks ship in every response:

```json
"attribution":   { "jobs_in_window": 78, "via_lead": 20, "via_job_source": 58,
                   "unattributed": 0, "lead_coverage_pct": 25.6 },
"traceability":  { "invoice_revenue_in_window": 12834.05,
                   "traceable_to_job": 6843.77, "not_traceable": 5990.28,
                   "revenue_traceable_pct": 53.3 }
```

**$5,990.28 of $12,834.05 collected, 46.7%, cannot reach a channel**, because
twelve invoices carry no `job_id`. The report says so on every call. Closing that
gap is a data-quality workstream, and the number is the tracker for it.

### Null, never zero, never infinity

`lead_spend` currently has zero rows. Every spend-derived ratio therefore returns
**null**, and the payload carries `spend_tracked: false` and `spend_rows: 0`.
Cost per lead, cost per booked job, ROAS, net contribution: all null. Zero would
assert that marketing is free and infinite ROAS would assert that it is
infinitely profitable. Both are lies. Null is the honest answer, and the flag
tells the UI to render "not tracked" rather than a number.

The asymmetry is deliberate: `avg_ticket` for a source with one job and no
revenue returns **0.00**, because that is measured. A ratio is null only when its
denominator is undefined.

### Per-source payload

Each entry carries `src_key`, `source_name`, `category`, `leads`, `booked_jobs`,
`completed_jobs`, `jobs_via_lead`, `revenue_collected`, `revenue_open`, `spend`,
and the derived `avg_ticket`, `cost_per_lead`, `cost_per_booked_job`, `roas`,
`net_contribution`, `lead_to_job_pct`, `completion_pct`. Sources sort by
collected revenue descending, so the channel paying for the business is the first
thing the owner reads. A `totals` block carries blended ROAS and blended cost per
booked job on the same rules.

## Verified live

Driven against production data, not inspected:

| Check | Result |
|-------|--------|
| Dashboard revenue, 365 days | **$12,834.05** (was $10,648.75) |
| Matches `sum(total_amount - balance)` exactly | yes |
| Reconciles to `tf_customer_index` | $11,429.92 + $1,404.13 unlinked = $12,834.05 |
| Housecall Pro appears once | 77 jobs, $6,843.77 |
| `lead_coverage_pct` | 25.6 |
| `revenue_traceable_pct` | 53.3 |
| `spend_tracked` | false, every spend ratio null |
| ROI totals reconcile to traceability | $6,843.77 = $6,843.77 |
| Forbidden path, non-staff caller | `{"ok":false,"error":"forbidden"}` on both |

**Parameter hardening**, driven past intended range: `tf_marketing_roi` clamps
`-500 → 1`, `0 → 1`, `999999 → 730`, `null → 90`, default `90`.
`tf_owner_dashboard` clamps `-9 → 1`, `99999 → 365`, default `30`. The default of
30 was read off the live catalog and reproduced in the signature. Replacing the
function with `create or replace` while omitting the default fails outright with
`42P13`, and the tempting remedy, `DROP FUNCTION` first, would silently revoke
every grant and break the live Hub mid-flight. Preserve the signature.

Post-migration security scan: **0 gaps on all four axes**
(`rls_disabled_tables`, `secdef_no_searchpath`, `anon_secdef_nonpublic`,
`rls_enabled_no_policy`).

## Security

Both functions are `SECURITY DEFINER` with `search_path` pinned to
`public, extensions` and an explicit `user_is_internal_staff()` guard as the
first statement. Both are revoked from `public` and `anon`, executable by
`authenticated` and `service_role`. `tf_marketing_roi` is additionally `stable`,
since it only reads.

These are platform-operations functions reporting across the whole tenant, which
is why they are DEFINER with an explicit guard, rather than INVOKER like
`tf_customer_index` and `tf_customer_360`. The rule on this platform: if the
function answers a question about one tenant's own rows, use INVOKER and let RLS
be the boundary. If it answers a question about platform operations, use DEFINER
and make the guard the first line of the body.

## Indexes

| Index | Serves |
|-------|--------|
| `idx_leads_job_id_live (job_id) where deleted_at is null and job_id is not null` | The lead→job attribution join |
| `idx_invoices_job_id_live (job_id) where deleted_at is null and job_id is not null` | The job→revenue rollup |
| `idx_lead_spend_period (company_id, period_start, period_end) where deleted_at is null` | The overlapping-period spend scan |
| `idx_invoices_txn_date_live (company_id, txn_date desc) where deleted_at is null` | The revenue trend and window filters |

## Operating it

Marketing ROI is only as good as the spend that feeds it. Three actions turn this
from a correct-but-empty report into the number that decides where the next
dollar goes:

1. **Log spend.** `tf_log_lead_spend` writes period buys, `tf_log_lead_cost`
   writes per-lead charges. Until one of them runs, `spend_tracked` stays false
   and every ROI ratio stays null, by design.
2. **Close the job_id gap.** 46.7% of collected revenue has no job link and can
   never reach a channel. That is the single highest-value data-quality fix on
   the platform right now, and `revenue_traceable_pct` is its scoreboard.
3. **Raise lead coverage.** 25.6% of jobs carry a lead row. Every job created
   without one falls back to a coarse enum and loses campaign and channel detail
   permanently.

Migration 219.
