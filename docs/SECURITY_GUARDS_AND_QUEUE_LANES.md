# Security Guards and Queue Lanes

Two questions the platform could not answer honestly, and the eight migrations
that made it able to.

Migrations 224 through 231.

## The problem this solves

The security scan reported zero gaps across four axes and the queue reported
`operational` with zero pending. Both were true. Neither was sufficient.

The scan was silent about the single largest source of privilege on this
platform: `security definer` functions granted to `authenticated`. A definer
function runs with the privileges of its owner, which means RLS does not apply
to it. Its authorization *is* whatever predicate the author wrote inside the
body. If the author wrote none, any signed-in user of any tenant can call it and
read or write whatever it touches. There were 254 functions in `public` and the
scan was not looking at a single one of them from that angle.

The queue had a subtler problem. It reported healthy because nothing was
pending. But a lane with a producer and no consumer also reports nothing
pending, right up until the moment work starts arriving into it and sits there
forever. Zero pending is indistinguishable from zero flowing. The queue could
not tell the difference between "drained" and "dead", and it was reporting both
as green.

## What the investigation actually found

Three findings, in ascending order of how much they cost.

**Definer functions reachable by `authenticated` with no authorization
predicate.** A catalog sweep across `pg_proc` filtered to `prosecdef` and
`has_function_privilege('authenticated', oid, 'EXECUTE')` returned 48 functions.
Most carried a real guard. A minority carried none, and those were business
functions, not helpers, meaning a signed-in demo-tenant user could have invoked
production business logic directly over PostgREST. The RLS layer was never going
to catch this, because definer functions are precisely the construct that exists
to bypass RLS.

**Every non-ClickUp provider in the queue was a lane with no consumer, and the
platform did not know it.** The `integration_events` table is keyed by
`integration_provider`, an enum with ten values. Exactly one of those ten,
`clickup`, has a drain worker. The other nine are architecturally not
queue-driven: QuickBooks is pull-based, Housecall Pro writes through a webhook
and reconciles hourly, Slack and OpenPhone send inline, Stripe processes on
receipt, WordPress is a read-only weekly ingest, Twilio is provisioned but
inactive, Notion is operator-mirrored, and `other` is a sentinel. That is a
defensible architecture. What was not defensible is that nothing wrote it down,
so an event enqueued under, say, `quickbooks` would have sat pending forever
while the health board read `queue clear`.

**Convention drift, for the seventh time, and this one bit inside the fix
itself.** The first version of the lane registry declared its provider column as
`text`. `integration_events.provider` is the `integration_provider` enum. The
join between them raised `42883: operator does not exist: text =
integration_provider`, and it raised it *at read time inside the health
function*, not at migration time. The migration applied cleanly. The registry
looked correct. The health function that depended on it was broken and the
breakage was invisible until something drove it.

That is the whole argument for the house rule this work produced.

## What shipped

### The fifth security axis

`tf_security_scan()` gained an axis and a total. The axis counts definer
functions granted to `authenticated` whose definition matches no authorization
identifier. The scan now also returns `gap_total`, a single integer across all
five axes, so a caller does not have to know the axis names to know whether the
platform is clean.

The detection itself:

```sql
unguarded as (
  select p.proname
  from pg_proc p
  where p.pronamespace = 'public'::regnamespace
    and p.prosecdef and p.prokind = 'f'
    and has_function_privilege('authenticated', p.oid, 'EXECUTE')
    and pg_get_functiondef(p.oid) !~* '(user_is_internal_staff|user_is_internal_writer|studio_is_staff|has_permission|user_has_role|is_company_member|user_company_id|current_company|current_owner_|current_tenant_|current_user_role|is_privileged_role|user_is_assigned_to_|current_supabase_user_id|auth\.uid)'
    and not exists (select 1 from public.security_scan_exemptions e where e.proname = p.proname)
)
```

**Read this before you trust the zero.** The fifth axis is a *textual* test. It
scans `pg_get_functiondef` for any of a fixed list of authorization identifiers.
A function that merely *mentions* one of those tokens passes, even if it never
acts on the result. That does not make the axis useless, because the realistic
failure mode is a function with no guard at all rather than a function with a
decorative one. But it means **a green fifth axis is evidence, not proof**. When
a new definer function is granted to `authenticated`, read its guard yourself.
Do not let the scan read it for you.

The exemption table is the escape hatch and it is deliberately tiny. Two
functions sit on it: `tf_rent_payments_enabled`, which returns a single boolean
feature flag and is safe by construction, and `tf_security_scan` itself, which
would otherwise flag its own regex literal.

### The guard sweep

Migration 225 closed every function the new axis found, using the catalog-patch
pattern rather than retyping bodies: read `pg_get_functiondef(oid)`, apply a
targeted `replace()` on the declaration boundary, `execute` the result. `create
or replace` preserves grants, which matters, because retyping a function is how
you silently hand `anon` an execute bit you never meant to hand it.

Guard form was chosen per function, not uniformly. A function that pg_cron
invokes takes the cron-tolerant form. Everything else takes the strict form.

### `AC-DEFN-017`

The axis became a control. `tf_controls_evaluate()` now reads
`tf_security_scan.secdef_authenticated_no_guard` and writes a `passing` or
`attention` verdict against control key `AC-DEFN-017`, "Authorization enforced
inside SECURITY DEFINER functions", in the Access Control domain. It reads
`passing` today with evidence "0 definer fn(s) granted to authenticated with no
authorization predicate".

This is the part that makes the axis durable. A scan that nobody reads decays
into a scan that nobody runs. A control is read by the GRC report, which is
scheduled, which posts to Slack, which a human sees. Detection that is not wired
to an escalation path is a diary entry.

### `public.integration_queue_lanes`

The registry. One row per `integration_provider` enum value, ten rows, no
exceptions, with `consumer`, `cadence`, `is_drained`, and a `notes` column that
states in prose why the lane is shaped the way it is.

| Provider | Consumer | Cadence | Drained |
| --- | --- | --- | --- |
| `clickup` | `tf-clickup-worker` edge function | `tf-clickup-worker-hourly` (`25 * * * *`) | yes |
| `housecall_pro` | none by design | `hcp-hourly-sync` (`0 * * * *`) reconciles | no |
| `quickbooks` | none by design | `qbo-sync-2h` (`0 */2 * * *`) pulls directly | no |
| `slack` | none by design | `tf-slack-sweep` (`*/2 * * * *`) | no |
| `openphone` | none by design | inline send and webhook receipt | no |
| `stripe` | none by design | inline on webhook receipt | no |
| `wordpress` | none by design | `tf-site-ingest-weekly` (`0 7 * * 1`) | no |
| `twilio` | none by design | n/a | no |
| `notion` | none by design | n/a | no |
| `other` | none by design | n/a | no |

`clickup` is the only true queue lane on the platform today. Everything else is
a declaration that enqueueing under that provider is a defect.

The registry is seeded from the enum, not from a hand-written list, so adding an
eleventh provider to `integration_provider` without registering its lane is
itself detectable.

### `tf_queue_health` v7

The health function now joins live event traffic against the registry and
returns two new arrays.

`orphan_lanes` carries a reason code per entry. `unregistered_provider` means
events exist under a provider with no registry row, which is a real gap and
someone must classify it. `no_consumer_by_design` means events exist under a
provider the registry explicitly marks as having no drain, which is a producer
bug upstream, not a queue bug.

`unregistered_providers` is the simpler, harder signal: an enum value with no
registry row at all. It should always be empty. If it is not, someone extended
the enum and skipped the registry, and the queue has a blind spot again.

The verdict is production-scoped. Demo-tenant traffic is surfaced under a
`non_production` key and never reaches the verdict, because a broken row in a
demo tenant is not an incident and a health board that cries wolf gets muted.

## The guard ladder

| Caller | `auth.uid()` | `tf_security_scan` | `tf_queue_health` | `tf_queue_discard` |
| --- | --- | --- | --- | --- |
| pg_cron (`postgres`, no JWT) | null | runs | runs | runs |
| Internal staff | set, staff | runs | runs | **`42501`** |
| Authenticated non-staff | set, not staff | `forbidden` | `forbidden` | `42501` |
| `anon` | n/a | execute revoked | execute revoked | execute revoked |

The `42501` in the staff row is not a bug and it is the single most confusing
thing in the security model. Queue operator functions carry a correct in-body
staff guard *and* are granted only to `postgres` and `service_role`. Grant tier
is checked before the body runs. An internal staff user impersonated in a SQL
session will therefore be refused at the grant layer with `42501: permission
denied for function` and will never reach the guard that would have let them in.
This is correct. Queue mutation is an operator action executed through the
service role, not a user action executed through PostgREST.

Read grants before you read guards. A function can be perfectly guarded and
still unreachable, and a function can be reachable through a grant you forgot
you issued.

## Verification

Driven, not inspected. That distinction produced the entire second half of this
document.

The lane registry migration applied cleanly and was wrong. The `text` versus
`integration_provider` mismatch did not surface at DDL time because the join
lived inside a function body, and Postgres does not resolve operators in a
function body until the function is called. A post-migration check that read
`information_schema.columns` and confirmed the table existed would have passed.
A post-migration check that *called* `tf_queue_health()` failed immediately with
`42883`.

So the house rule is now explicit and it is not negotiable:

> A migration that creates or replaces a function must include a `do $drive$`
> block that CALLS the function and asserts on its output. Inspecting the
> catalog to confirm the function exists is not verification. Confirming the
> definition contains the expected text is not verification. Only running it is.

Migration 230 retyped the column to the enum and reseeded all ten rows.
Migration 231 shipped v7 with the reason codes and the registry-gap array, and
carried a `do $drive$` post-check that called `tf_queue_health()` and asserted
on `orphan_lanes` and `unregistered_providers` being present and well-formed.

Behaviour confirmed against live state:

- `tf_security_scan()` returns 0 on all five axes with `gap_total: 0` and
  `secdef_authenticated_no_guard_fns: []`.
- The 48 definer functions reachable by `authenticated` were token-tested
  individually. Every one carries a real guard, except `tf_rent_payments_enabled`
  which is exempt by decision. The scan is honest.
- `tf_queue_health()` returns `operational`, `scope: production`, `pending: 0`,
  `stranded: 0`, `dead_letters: 0`, `orphan_lanes: []`,
  `unregistered_providers: []`, and a `lanes` array of exactly 10.
- `tf_controls_evaluate()` writes `AC-DEFN-017` as `passing`.
- The `42501` grant-tier behaviour was reproduced deliberately under staff
  impersonation, so it is documented behaviour rather than a surprise waiting in
  an incident.

## The numbers

| | Before | After |
| --- | --- | --- |
| Security axes scanned | 4 | 5 |
| Definer fns reachable by `authenticated`, unguarded | unknown | 0 |
| Single-integer gap summary | none | `gap_total: 0` |
| GRC controls | 16 | 17 |
| Queue lanes documented | 0 | 10 |
| Queue orphan detection | none | 2 reason codes |
| Enum values with no registry row | 10 | 0 |

The first row is the one that matters. "Unknown" is not a number, and a
dashboard that reports zero gaps while one of its axes does not exist is not
reporting zero gaps. It is reporting the gaps it happens to look for.

## Operating it

`tf-security-autoharden` runs the scan on its existing schedule and the GRC
evaluation carries `AC-DEFN-017` into the controls report. Queue health is read
by `tf_system_health` and surfaces as the `queue` component.

**Watch `unregistered_providers` first, not `orphan_lanes`.** An orphan lane
means work is arriving somewhere unexpected, which is bad. An unregistered
provider means the platform has gained a capability that the reliability layer
does not know exists, which is worse, because the next orphan under that
provider will not be detected at all. It should always be empty. If it is not,
seed the registry before you debug anything else.

**Watch `orphan_lanes[].reason`.** `no_consumer_by_design` is an upstream
producer bug. Find the code that enqueued and stop it enqueueing, because adding
a consumer to a lane the architecture says should not have one is solving the
wrong problem. `unregistered_provider` is a classification gap and the fix is a
registry row plus a decision about whether that lane needs draining.

**Watch `gap_total`, then read the axis.** The total tells you whether to care.
The axis names tell you what to do. Do not build alerting on the individual axes
without the total, because a fifth axis was added once and a sixth will be added
eventually, and alerting that enumerates axes by name goes stale the moment that
happens.

**When you add a definer function granted to `authenticated`, read its guard
yourself.** The scan will tell you it is fine if the body contains the string
`auth.uid`. That is not the same as the body acting on it.

## The pattern, stated plainly

This is the seventh time convention drift has been the highest-yield defect
class on this platform, and the first time it occurred inside the fix for the
previous one. A registry built to catch undeclared lanes was itself typed
against the wrong domain, and the mismatch hid inside a function body where DDL
validation could not reach it.

There are two countermeasures and this work needed both. The first is the one
already established: express the convention in the database, on the normalised
form of the value, so a violation becomes a write-time error rather than a
read-time discrepancy. The registry is now typed to the enum and seeded from it,
so a new provider without a lane is detectable by construction.

The second is newer and it is about verification rather than schema. A component
that is only inspected is a component that has not been tested. The catalog will
happily confirm that a broken function exists, that its definition contains the
words you expected, and that its grants are correct. It will not tell you that
it raises `42883` on the first line of its first join. Only calling it does
that.

Detection that is not wired to escalation is a diary entry. Verification that
does not execute the thing is a wish.
