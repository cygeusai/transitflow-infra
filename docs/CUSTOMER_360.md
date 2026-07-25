# Customer 360

The customer is the only revenue-bearing entity on this platform, and until
2026-07-25 it was the least instrumented one. Jobs had a board, invoices had a
sync, the queue had a health grade. The customer had a row in a table.

This layer makes the customer a first-class object: a list that reads as a book
of business rather than a phone directory, and a detail view that answers what
happened, what it is worth, and what to do next, in one round trip.

## Two functions, deliberately split

| Object | Powers | Shape |
|--------|--------|-------|
| `tf_customer_index(search, segment, risk, sort, limit, offset)` | The Customers list | Page slice plus lifetime revenue, open AR, segment tier, health and risk flags |
| `tf_customer_360(customer_id)` | The customer detail page | Profile, scorecard, AR aging, 11 related collections, merged timeline, next best actions |

The split exists because the two screens have opposite shapes. The list needs a
little about many customers with server-side filtering on values the client does
not have. The detail page needs everything about one customer. Forcing both
through one function would mean either over-fetching the list or under-serving
the page.

## Why the whole read model lives in the database

The alternative was a Lovable page firing twelve client-side queries: customers,
jobs, estimates, invoices, payments, communications, reviews, complaints,
warranty claims, leads, addresses, properties. That is twelve chances to leak a
tenant boundary and twelve round trips on a page an operator opens all day.

One RPC is one policy surface and one network hop. It also means the frontend
never encodes business rules. What counts as a completed job, what makes a
customer platinum, when a receivable is escalated, all of it lives in one place
and changes in one place.

## SECURITY INVOKER on purpose

Every other operational function on this platform is `SECURITY DEFINER`, because
platform operations legitimately need to read across tenants. These two are
`SECURITY INVOKER`, and the difference is not stylistic.

Every underlying table already enforces RLS. A `SECURITY DEFINER` read function
would bypass those policies and force the function body to re-implement tenancy
with its own `company_id` predicates. That is exactly how tenant leaks get
written: the policy and the hand-rolled filter drift, and nobody notices because
the function still returns rows. Invoker means the caller sees precisely what
their policies allow, no more, and the policy stays the single source of truth.

A consequence worth stating plainly: `tf_customer_360` returns
`{"found": false}` both when a customer does not exist and when it exists but is
not visible to the caller. That is not a limitation, it is the correct answer for
a tenant-scoped read. Distinguishing the two cases would itself be a leak.

## The index is a book of business

`tf_customer_index` computes four grouped rollups (jobs, invoices, open
complaints, review average), joins them onto the customer, then grades.

**Segment ladder**, on collected revenue rather than invoiced, because a customer
who was billed $12,000 and paid $400 is not platinum:

| Segment | Lifetime revenue |
|---------|------------------|
| platinum | >= $10,000 |
| gold | >= $5,000 |
| silver | >= $1,000 |
| bronze | > $0 |
| prospect | no collected revenue |

**Health** is `at_risk` on a do-not-service flag, an overdue balance, an open
complaint, or a detractor rating; `watch` on churn risk or any open balance;
otherwise `healthy`. **Risk flags** ship as an array (`do_not_service`,
`ar_overdue`, `open_complaint`, `detractor`, `churn_risk`) so the UI can render
chips without re-deriving anything.

Filtering by segment and risk is server-side because both are derived from
aggregates the client never sees. Search matches name and email by `ILIKE` and
phone by digits-only comparison, so `(614) 735-9278`, `614-735-9278` and
`6147359278` all find the same customer.

Internal grading booleans are stripped from the payload before return. The client
gets `risk_flags`, not the five flags that produced it.

## The detail page tells the operator what to do

`tf_customer_360` returns eleven collections, a scorecard, five-bucket AR aging,
a merged timeline, and `next_actions`.

`next_actions` is the point of the screen. A CRM that only records what happened
makes the operator do the thinking; this one ships the thinking with the record.
The ladder, evaluated in priority order:

| Priority | Trigger | Action |
|----------|---------|--------|
| critical | `do_not_service` flag set | Surface the flag and its reason before anything else |
| critical | Balance past 60 days | Escalate aged receivable to collections |
| critical | Open complaint | Resolve it. Service recovery is the single highest-leverage retention move |
| high | Balance 1 to 60 days past due | Send payment reminder |
| high | Estimate sent or viewed 3+ days ago, no decision | Follow up |
| normal | Completed work, no review on file | Request a review |
| normal | No activity in over 12 months | Reactivation outreach |
| normal | Customer record with zero jobs | Convert prospect |

The aged-receivable and past-due rules are mutually exclusive by construction, so
a 90-day balance escalates to collections rather than generating a polite
reminder.

**Timeline** is an eight-arm union (jobs created, jobs completed, estimates,
invoices, payments, messages, reviews, complaints) merged newest-first and capped
at 60 events. One chronological story instead of five tabs the operator has to
correlate in their head.

**AR aging** buckets open balances at current, 1-30, 31-60, 61-90, and 90+ days
from the due date, so the page shows collectability rather than a single
undifferentiated balance number.

## Three defects found by driving the code against live data

Every version was executed against real customers before it was accepted. Under
that discipline the reliability layer surfaced five defects; this one surfaced
three, all invisible at creation time.

**1. A column that does not exist, and the obvious fix that was worse.**
`tf_customer_360` v1 computed estimate value as
`sum(quantity * unit_price) from estimate_line_items where estimate_id = e.id`.
There is no `estimate_id` on `estimate_line_items`. PL/pgSQL does not resolve
column references in function bodies until execution, so the migration applied
cleanly and failed on the first real call.

The obvious repair, joining through `estimate_options` and summing every line
item, would have been the more dangerous bug. This platform sells tiered
good/better/best estimates. Estimate `TF-EST-300001` carries three options at
$1,850, $2,485 and $4,975. Summing the line items reports **$9,310** for an
estimate the customer approved at **$2,485**, a 3.75x inflation on every tiered
estimate in the pipeline, in a number an owner would use to forecast revenue.

An estimate is worth exactly one option. The amount is now the selected option if
the customer chose one, else the recommended option, else the highest tier, with
`option_tier`, `option_name` and `option_count` shipped alongside so the UI can
render "Better tier of 3" rather than a naked number. The ranking uses
`is not distinct from` against `selected_option_id`: a plain `=` against a null
selection yields null for every row and silently destroys the ordering.

**2. Sort was honored for pagination and discarded for presentation.**
`tf_customer_index` v1 ordered the page CTE by the requested sort, then rebuilt
the JSON with `jsonb_agg(... order by lifetime_revenue desc)`. The aggregate's
own ORDER BY wins. Sorting by balance returned the correct 50 customers in
revenue order: `1185.30, 0.00, 1000.00, 49.00, 362.25`.

This is the worst class of sort bug. It is invisible on the default sort, and
invisible on any tie-heavy column, because ties fall through to the same
secondary key and look sorted. Sorting by name appeared to work perfectly.

Ordering is now computed once as a `row_number()` window and carried through both
the page slice and the aggregate, which makes the two physically incapable of
disagreeing. The rank column is stripped from the payload.

**3. The two most-read child tables had no `customer_id` index.**
`qb_payments` and `reviews` were the only two of eleven child tables without one,
and `reviews` is touched four times per call: the list, the rating average, the
review count, and the has-any-review test behind the request-a-review action.
Two sequential scans on every open of the most-opened page on the platform is not
a scale problem later, it is a latency problem now.

## Performance

At current volume (3,443 customers, 2,993 live, 81 jobs, 31 invoices)
`tf_customer_index` returns a full unfiltered page in **44ms**. Rollups are
grouped CTEs, which is correct and fast at this size.

Indexes added in migration 215: `customer_id` on `qb_payments` and `reviews`,
`estimate_id` on `estimate_options`, and trigram GIN on the customer name, email
and digits-normalised phone expressions. The search box uses leading-wildcard
`ILIKE`, which no btree can serve; the phone index covers
`regexp_replace(phone, '[^0-9]', '', 'g')` because that is the expression the
function actually filters on, not the raw column.

Past roughly a million job rows the grouped rollups move to an incrementally
maintained `customer_rollup` table. The function signatures are designed so that
swap is invisible to the frontend.

## Frontend contract

Both routes call only these two RPCs. No client-side table queries against
customers, jobs, invoices, estimates, complaints, reviews, communications,
payments, leads or warranty claims. This is not a style preference: it is what
keeps the tenancy boundary to one surface and the business rules to one place.

- `/customers` — server-side search, segment filter, risk filter, four sorts,
  paginated on `limit`/`offset` against `total`. Never fetch all rows and filter
  in the browser.
- `/customers/:id` — next best actions above the fold, scorecard strip, AR aging
  bars, eleven count-badged tabs with the merged timeline as default.
- `{"found": false}` renders a clean not-found state, never a crash and never a
  spinner that resolves to nothing.

## Shipped

`src/routes/_authenticated/customers.index.tsx` and
`customers.$id.tsx`, commit `e73a5eae`, live on https://goqtf.lovable.app.

The index page runs one `tf_customer_index` call behind a 300ms debounce with
`keepPreviousData`, so typing does not blank the table between keystrokes, and a
30s `staleTime` so tab-switching does not re-hit the database. Filter changes
reset the page cursor to zero, which is the difference between a filter that
works and one that lands the operator on an empty page 4. The desktop table
collapses to cards below `md`. The detail page is one `tf_customer_360` call
rendering the do-not-service banner, an 8-tile scorecard, the actions panel, the
aging strip, and the eleven tabs, each with its own empty state rather than a
blank panel.

Contract verified by reading the shipped source: two `supabase.rpc` calls across
both files, zero `.from(` table queries. The segment, health and risk-chip
components are defined once on the index route and imported by the detail route,
so a grading vocabulary change cannot drift between the two screens.

## Hardening verified under abuse

The parameters are guarded, confirmed by driving them past their intended range:
`p_limit` clamps to 1 at the low end and **200** at the high end, so no
authenticated caller can pull all 2,993 customers in a single payload by asking
for `limit: 100000`. A negative `p_offset` clamps to 0 and returns page one
rather than an empty slice. An unrecognised `p_sort` falls back to `revenue`.

An unrecognised `p_segment` or `p_risk` returns zero rows rather than silently
dropping the filter. That asymmetry with `p_sort` is deliberate: a bad sort is
cosmetic, but a filter that quietly stops filtering shows an operator rows they
believe they excluded.

## Security

`SECURITY INVOKER`, `stable`, `search_path` pinned to `public, pg_temp`, revoked
from `public` and `anon`, executable by `authenticated` and `service_role`.
Tenancy is enforced entirely by the RLS policies on the underlying tables.
Security scan after all four migrations: **0 gaps on all four axes**
(`rls_disabled_tables`, `secdef_no_searchpath`, `anon_secdef_nonpublic`,
`rls_enabled_no_policy`).

## Verified live

Index: 2,993 live customers returned, `total` correct; all four sorts verified to
return their pages in the requested order; `ar_overdue` filter returned 4;
`platinum` returned 0, consistent with the current revenue distribution; a
digits-only phone search matched exactly 1. Pagination verified with a non-zero
offset returning the correct next slice.

360: run against a customer carrying 2 jobs, 2 invoices, 3 messages and a 7-event
timeline, returning `at_risk` health, `silver` segment, $1,185.30 in the 1-30 day
aging bucket, and two next actions (payment reminder at high, review request at
normal). Estimate block verified against the one tiered estimate on file,
returning the approved `better` tier at $2,485 with `option_count: 3`. Not-found
path verified with a zero UUID.

Migrations 212 to 215.
