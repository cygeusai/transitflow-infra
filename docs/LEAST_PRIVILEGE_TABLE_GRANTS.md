# Least-Privilege Table Grants — the privilege RLS does not gate

Row Level Security is the backbone of tenant isolation on this platform. 173 of
173 base tables in `public` have it enabled, with 582 policies across them. That
is the control everyone looks at.

`TRUNCATE` is not subject to it.

State captured 2026-07-25 against Supabase project `kjooyhvynkzuvsixsutt` after
migration 272 (`least_privilege_revoke_truncate_trigger_references_from_client_roles`).

---

## The finding

Postgres evaluates RLS policies per row. `TRUNCATE` does not visit rows; it
unlinks the table's storage. There is therefore **no policy that can constrain
it**, and a role holding the `TRUNCATE` privilege on a table can empty that table
completely regardless of how carefully its RLS is written.

At discovery, in a database whose entire tenant isolation story rests on RLS:

| Privilege | Held by `authenticated` on | Held by `anon` on |
| --- | --- | --- |
| `TRUNCATE` | 172 of 173 tables | 0 |
| `TRIGGER` | 173 of 173 | varies |
| `REFERENCES` | 173 of 173 | varies |
| `MAINTAIN` | 173 of 173 | varies |

This was never exploited and could not have been through the normal front door.
**No HTTP verb in PostgREST maps to `TRUNCATE`**, which is exactly why nothing
ever broke and exactly why nobody looked. The exposure is real anywhere a client
role reaches SQL by another path: a `SECURITY INVOKER` definer chain, a future
RPC written without care, a connection string that escapes, a Supabase feature
that adds a new execution surface later.

The other three privileges are lower severity but belong to the same class:

- **`TRIGGER`** lets a role attach a trigger to a table it does not own. The
  trigger function runs with that function's own privileges, so this is a lever
  for arranging code execution on somebody else's write.
- **`REFERENCES`** lets a role create a foreign key against a table, which is a
  read oracle: existence of a row can be probed through constraint violations
  even where `SELECT` is denied by policy.
- **`MAINTAIN`** is new in Postgres 17 (this project runs 17.0.6, `server_version_num`
  170006) and permits `VACUUM`, `ANALYZE`, `REINDEX`, `CLUSTER` and
  `REFRESH MATERIALIZED VIEW`. It is a denial-of-service and a statistics-poisoning
  surface, not a data-disclosure one.

None of these four is required by any legitimate client-role operation. PostgREST
needs `SELECT`, `INSERT`, `UPDATE`, `DELETE`, and nothing else.

---

## Why it was there

The same reason as the function-grant finding in `FUNCTION_GRANT_TIERS.md`, and
it is worth stating plainly because it will keep producing findings:

> Supabase installs broad default privileges. For tables owned by `postgres` the
> historical default ACL grants the full `arwdDxtm` set to `anon` and
> `authenticated`, not the four verbs PostgREST actually uses.

Nobody granted `TRUNCATE` to `authenticated` on 172 tables. Everybody who created
a table inherited it. That is the signature of a default-privilege defect: the
exposure scales perfectly with how much you build, and no individual migration
looks wrong in review.

---

## The fix

Migration 272 revoked `TRUNCATE`, `TRIGGER`, `REFERENCES` and `MAINTAIN` from
`anon` and `authenticated` across every base table in `public`, leaving
`SELECT`, `INSERT`, `UPDATE` and `DELETE` intact so no application path changed.

It was written under the house rule proven three times in this sweep:

> **Assert deltas measured inside the transaction, never absolute counts pinned
> from an earlier query.**

A concurrent agent was deploying to production during this session. Table count
moved 171 to 173 and `tf_*` function count moved 84 to 91 while these migrations
were being written. Any assertion of the form "afterwards this number is zero"
is a race against whatever else is landing. Migration 272 measured its own
before-state inside its own transaction and asserted the movement, not the
endpoint.

### Live state after

```sql
select
  (select count(*) from pg_class c
    where c.relnamespace='public'::regnamespace and c.relkind='r'
      and has_table_privilege('anon', c.oid, 'TRUNCATE'))          as anon_truncatable,
  (select count(*) from pg_class c
    where c.relnamespace='public'::regnamespace and c.relkind='r'
      and has_table_privilege('authenticated', c.oid, 'TRUNCATE')) as auth_truncatable,
  (select count(*) from pg_class c
    where c.relnamespace='public'::regnamespace and c.relkind='r') as tables_total;
```

reads `0 / 0 / 173`.

---

## The residual, stated so it is not forgotten

Revoking the current grants does not change the **default** privileges that will
be applied to tables created in future. There are two owners in play:

- Tables created by **`postgres`** now inherit the corrected defaults.
- The **`supabase_admin`**-owned default ACL for `public` tables still reads
  `anon=arwdDxtm`. A table created by `supabase_admin` rather than `postgres`
  would inherit the full set again.

This is a genuine open edge. It is not currently reachable by the deployment
paths in use, both this agent and the Lovable agent create tables as `postgres`,
but it is the mechanism by which this finding would silently return.

**The monitoring gap was the more important half, and it is now closed.**
Migration 272 hardened the grants and nothing watched them. A control that fixed
something once and never looks again is not a control, it is a changelog entry.

Migration 283, `security_scan_monitors_truncate_grants_and_separates_unreachable_tables_from_unpoliced_ones`,
added `tables_truncatable_by_client` as the sixth declared axis of
`tf_security_scan()`. It reads **0**, with an empty
`tables_truncatable_by_client_tables`, and it is summed into `gap_total` through
the declared-axis list rather than a hand-written total, so it cannot be added to
the declaration and forgotten in the sum. If a future table lands with the
historical broad ACL, whether through the `supabase_admin` residual below or a
hand-written grant, the scan counts it and names it.

The mechanism residual above is untouched. Migration 283 monitors the symptom.
Read `docs/SECURITY_SCAN_INTEGRITY.md` for the axis, the population declaration
it sits inside, and the `ok: false` refusal ladder that stops the scan reporting
clean when its own integrity fails.

**Still open:** no control row reads the new axis. `tf_controls_evaluate()` has
23 controls and none of them consumes `tables_truncatable_by_client` or the
scan's `integrity_total`. The scan refuses correctly and nothing is listening,
which is the same shape as the defect migration 269 closed on the control
consumers. That work is open.

---

## Evidence the hardening holds under concurrent deployment

This is the part worth reading, because it was not planned and it is the
strongest evidence in the document.

Four migrations after 272, the concurrent Lovable agent deployed migration 277,
`studio_founding_anon_insert_grant`, granting `anon` the ability to submit a
founding-cohort application. Under the pre-272 defaults, a fresh grant statement
written casually would very likely have restored the broad ACL.

It did not. The live ACL on that table now reads:

```
studio_founding_applications:
  {postgres=arwdDxtm/postgres,
   authenticated=arwd/postgres,
   service_role=arwdDxtm/postgres,
   anon=a/postgres}
```

`anon=a` is `INSERT` and nothing else, and it is further constrained by the
`sfa_anon_apply` policy, which pins `status` into `('pending','waitlist')` and
forces `cohort_seat_no`, `reviewed_by`, `reviewed_at`, `subscription_id` and
`user_id` to null. An anonymous applicant can lodge an application and cannot
grant themselves a seat, mark themselves reviewed, or attach a subscription.

That is a correctly-built public intake form landing on a correctly-hardened
table, written by a different agent that never read this document. Least
privilege is worth the effort precisely because it protects work that has not
been written yet.

---

## Runbook

**Audit current client-role table privileges.**

```sql
select p.privilege_type, count(*) as tables
  from information_schema.role_table_grants p
 where p.table_schema = 'public'
   and p.grantee in ('anon','authenticated')
 group by 1 order by 1;
```

Expect only `SELECT`, `INSERT`, `UPDATE`, `DELETE`.

**Re-harden after a bulk table creation.**

```sql
do $$
declare r record;
begin
  for r in select c.relname from pg_class c
            where c.relnamespace='public'::regnamespace and c.relkind='r'
              and (has_table_privilege('anon', c.oid, 'TRUNCATE')
                or has_table_privilege('authenticated', c.oid, 'TRUNCATE'))
  loop
    execute format('revoke truncate, trigger, references, maintain on public.%I from anon, authenticated', r.relname);
    raise notice 'rehardened %', r.relname;
  end loop;
end $$;
```

**Check the default-privilege residual.**

```sql
select pg_get_userbyid(defaclrole) as owner, defaclobjtype, defaclacl
  from pg_default_acl
 where defaclnamespace = 'public'::regnamespace;
```

---

## Related

- `docs/FUNCTION_GRANT_TIERS.md` — the same defect class on the function side,
  and the `PUBLIC` twin gotcha that makes revoking `anon` alone insufficient
- `docs/REGISTER_INTEGRITY.md` — the registers that record intent, and what
  happens when they are seeded from the checker that reads them
- `docs/SECURITY_SCAN_INTEGRITY.md` — the `tables_truncatable_by_client` axis
  that monitors this hardening, and the population declaration that makes a
  zero-gap report mean something
- `docs/PLATFORM_KNOWLEDGE_BASE.md` — conventions 27 and 28, house rule 14, and
  the Pass 9 verification log
