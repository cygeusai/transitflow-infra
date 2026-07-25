# Scheduler & Queue Reliability

Two blind spots existed in platform observability until 2026-07-25. The health
monitor scored connectors, data quality, security, and automations, but nothing
watched **the scheduler that runs all of it** or **the queue that carries work to
external systems**. A cron job could stop firing and a queue event could sit dead
forever while every health component stayed green.

This layer closes both, and closes them the same way everything else on this
platform is closed: detected automatically, ticketed automatically, resolved
automatically when the condition clears.

## Objects

| Object | Purpose |
|--------|---------|
| `tf_scheduler_health()` | Grades every `pg_cron` job for stall and failure, not just a raw failure count |
| `cron_job_registry` | First-seen clock per job. `cron.job` has no `created_at`, so without this a brand-new job is indistinguishable from one that silently stopped |
| `tf_queue_health()` | Grades `integration_events` across five states: dead, stranded, skipped, discarded, in-flight |
| `tf_queue_requeue(scope, …)` | Returns stuck work to `pending`, with a credential guard and partial apply |
| `tf_queue_discard(scope, reason)` | Terminal operator decision: retire work that should never run again |
| `tf_reliability_autoticket()` | Closed loop. Opens `reliability:scheduler` / `reliability:queue` tickets, resolves them when clear |
| `tf-reliability-autoticket-hourly` | pg_cron, `50 * * * *` |

`tf_system_health()` consumes both, taking the platform from 9 scored components
to 11 (`scheduler`, `queue`), and persists six new metrics on every check:
`cron_jobs`, `cron_failing`, `cron_stalled`, `queue_dead`, `queue_stranded`,
`queue_pending`.

## Scheduler grading

Cadence is inferred from the cron expression by anchored regex (`*/N * * * *`,
comma lists, `M */N * * *`). A job is **stalled** when it is active, has an
inferable sub-daily cadence, and has not run within `3 * cadence + 5` minutes.
Coarse schedules (daily and rarer) yield a null cadence and are exempt, since a
monthly job is not late until it is a month late.

Severity ladder: `3_stalled` > `2_failing` (2+ failures in 24h, or the last run
failed) > `1_flaky` (any failure in 24h) > `0_new` > `0_ok`.

Flaky is deliberately not escalated. Two jobs currently carry a single
`job startup timeout` each across ~100 runs; that is Postgres worker contention,
not a broken job, and paging on it would train the operator to ignore the signal.

## Queue failure classes

Counting `attempts >= max_attempts` and calling it "dead letters" was the
original design. Driving it against live data proved it misses most real
failures. Five states, each meaning something different:

| State | Definition | Why it needs its own class |
|-------|-----------|----------------------------|
| **dead** | `status = 'dead_letter'`, or failed with retries exhausted | Retry budget spent. Needs a human decision |
| **stranded** | Failed, retry budget **remaining**, untouched for 24h+ | Not a dead letter, yet just as permanently stuck. Nothing is retrying it |
| **skipped** | Worker deliberately dropped the work; no retry path exists | Invisible by construction. Two `ops_ticket` events vanished this way |
| **discarded** | Operator retired it on purpose | A decision, not a failure. Must not read back as a dead letter |
| **stuck in flight** | Claimed by a worker, never completed | The worker died mid-processing |

Thresholds: outage at `broken > 25`, backlog `> 24h`, or `> 10` stuck in flight;
degraded on any broken, any stuck, any skipped, or backlog `> 6h`.

## Requeue: credential guard with partial apply

Replaying queue work into a connector whose credential is currently rejected
does not recover anything. It burns the remaining retry budget and converts
stranded events into true dead letters. So `tf_queue_requeue` checks for open
`reauth_required` errors first.

The guard **excludes, it does not abort**. An early version blocked the entire
call when any provider had a bad credential, which meant a healthy Housecall Pro
event could not be requeued because ClickUp's token was expired. One dead
connector must never block requeue of unaffected providers. The call now returns
`action: 'partial'` with `requeued`, `held`, and `held_providers` so the operator
sees exactly what was withheld and why. `p_force := true` overrides.

## Four defects found by driving the code against live data

Each was caught because every version was run against the real queue before it
was accepted, and each is documented in a header comment inside its own
migration.

**1. Company-scoping hid orphaned rows.** `tf_queue_health` v1 was scoped to the
production tenant and reported "queue clear" while two 8-day-old failures sat in
a legacy tenant. A platform-operations function must be platform-wide with a
per-company breakdown. Scoping an operator view to one tenant does not filter
noise, it permanently hides work nobody will ever see again.

**2. Dead-letters-only missed both real failures.** Neither stuck event was a
dead letter: ClickUp had 3 of 5 attempts, Housecall Pro 2 of 5. Both had retry
budget and nothing was retrying them. That is what produced the `stranded` class,
and inspection of the same window produced `skipped`.

**3. Requeue produced a false platform outage.** Backlog age was measured from
`created_at`, but requeue resets `status` without touching `created_at`. One
legitimately requeued 7-day-old event read as a 7-day backlog, tripped the 24h
outage threshold, and took overall platform status to **down**. Backlog now
measures **eligibility**, `coalesce(next_retry_at, created_at)`, floored at zero
so a future-dated backoff cannot go negative. The reading dropped from 10,500
minutes to 10.3.

**4. Discard poisoned its own drain condition.** v1 wrote
`status = 'failed', attempts = max_attempts`, which is precisely the dead-letter
predicate. Every discard read back as a dead letter, so the queue could never
drain and the `reliability:queue` ticket could never close, defeating the entire
closed loop. Fixed by adding a real `discarded` terminal state to the
`integration_event_status` enum. Postgres forbids using a new enum value in the
transaction that adds it, so that shipped as its own migration.

**5. A brand-new cron job graded itself stalled.** Found four minutes after
scheduling `tf-reliability-autoticket-hourly`. With no run history and no
`created_at` on `cron.job`, "never fired because it is new" and "never fired
because it is broken" were the same signal, and the false stall propagated to
overall status **down**. `cron_job_registry` now stamps `first_seen_at` on every
health call and the stall clock runs from `coalesce(last_run, first_seen_at)`, so
a new job gets exactly one grace window and a genuinely dead job still trips
after it. In the same pass the outage threshold moved to 3+ stalled jobs: one
late job out of 35 is a degradation, not a platform outage, and it should not
reach the public status page or the availability SLO.

## Closed loop

`tf_reliability_autoticket()` runs hourly at `:50`.

- Scheduler stalled or failing → ticket `reliability:scheduler`, priority 1 if
  stalled, else 2. Body names each offending job with its severity and 24h
  failure count.
- Queue broken (dead + stranded + skipped + stuck) → ticket `reliability:queue`,
  priority 1 above 25 broken, else 2. Body embeds copy-paste remediation.
- Either condition clearing auto-resolves its ticket with a closing note.

```
Inspect:  select public.tf_queue_health();
Requeue:  select public.tf_queue_requeue('stranded');   -- also 'dead', 'skipped', 'all'
Discard:  select public.tf_queue_discard(p_scope := 'dead', p_reason := 'obsolete');
```

## Reconciled, not swept

The backlog found during the build was cleared by inspection, not by bulk
requeue. The two `skipped` `ops_ticket` events were duplicates of ClickUp tasks
that already existed (`86bb3ayzr` PITR, `86bb3az04` SSO), created through the
OAuth connection while the server-side Vault token was rejected; both were
discarded with reasons naming the surviving task. The legacy-tenant ClickUp event
was discarded as obsolete (workspace access revoked, non-production tenant). The
rate-limited Housecall Pro event was legitimately requeued and completed.

## Verified live

Ticket opened (queued, priority 2, list `901418420453`) → second run returned no
new ticket with exactly one registry row, proving dedup → queue drained → third
run auto-resolved it. Scheduler reports `35 jobs scheduled, all firing (1
awaiting first run)`; queue reports `queue clear, 3 pending`. Security scan after
all eleven migrations: **0 gaps on all four axes**.

## Security

Every function is SECURITY DEFINER with pinned `search_path`, revoked from
`public`, `anon`, and `authenticated`, and executable only by `service_role`.
`cron_job_registry` enforces RLS with internal-staff read. Cron is platform
infrastructure rather than tenant data, so the registry is not company-scoped;
visibility is granted to production-tenant internal staff.
