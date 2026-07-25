# Function Grant Tiers

How `EXECUTE` privilege is decided, applied, checked and enforced on every
function in `public`.

State captured 2026-07-25 at migration 248. Introduced by migration 247
(`grant_tier_remediation`) and made permanent by migration 248
(`grant_tier_drift_control`).

---

## The problem this exists to solve

Supabase installs the following on every project, before any application code
exists:

```sql
alter default privileges in schema public
  grant execute on functions to anon, authenticated;
```

That is a **named-role** grant. It applies to every function created in `public`
from then on, automatically, with no author and no migration attributing it.

For years this repo used the idiom:

```sql
revoke all on function public.some_fn() from public;
```

`public` there is the PUBLIC pseudo-role. Revoking it does **not** touch grants
held by `anon` or `authenticated` by name. The revoke succeeds, the migration
applies cleanly, the author reasonably believes the function is locked down, and
an unauthenticated caller can still execute it.

Nobody did anything wrong. The hole is real anyway. That combination, a defect
with no author, is exactly the class this platform handles by making the
convention data and checking it continuously rather than by asking people to
remember.

The correct form is:

```sql
revoke all on function public.some_fn() from public, anon, authenticated;
grant execute on function public.some_fn() to postgres, service_role;
```

In practice, never write that by hand. See *Applying a tier* below.

---

## The three tiers

| Tier | Roles granted EXECUTE | In-body authorization predicate | Use when |
| --- | --- | --- | --- |
| `admin` | `postgres`, `service_role` | not required, the grant **is** the control | cron-driven work, anything that writes to a third party, anything that changes platform behaviour |
| `staff` | `postgres`, `service_role`, `authenticated` | **required, always** | operator read models and staff actions performed from the Hub |
| `anon` | `postgres`, `service_role`, `authenticated`, `anon` | required | a function an unauthenticated caller may safely run, referenced by a PUBLIC-role RLS policy |

Two rules follow from the table and neither is optional.

**A `staff` grant is not an authorization decision.** It only says an
authenticated session may reach the body. Who that session is, and whether they
belong to the company, is decided inside the body by
`public.user_is_internal_staff(cid uuid)`. A `staff`-tier function without that
predicate is an open door for any signed-up user in any tenant. This is why
`tf_security_scan()` carries the `secdef_authenticated_no_guard` axis.

**An `admin` grant is a complete control on its own.** `authenticated` cannot
reach the body at all, so there is nothing for a body predicate to protect
against. Admin-tier functions still commonly carry the cron-tolerant form
(`if auth.uid() is not null and not user_is_internal_staff(...) then raise`) as
defence in depth, but the grant is what actually holds.

---

## Current tier assignments

Twelve functions carry a declared tier as of migration 248.

### `admin`

| Function | Why |
| --- | --- |
| `tf_automation_arm(p_key text, p_enable boolean)` | Flips customer-reaching automation flags. The only sanctioned arming path. Backend only. |
| `tf_apply_grant_tier(p_proname text, p_ident_args text, p_tier text, p_rationale text)` | Executes GRANT and REVOKE. Security invoker, so it lends no privilege, but it has no business being reachable from the app. |
| `tf_safety_autoticket()` | Opens and closes ClickUp tickets over HTTP. Driven by pg_cron every fifteen minutes. |
| `tf_grant_tier_autoticket()` | Writes to ClickUp. Reached by cron through `tf_safety_autoticket` as `postgres`. No authenticated caller has any reason to invoke it directly. |

### `staff`

| Function | Why |
| --- | --- |
| `tf_grant_tier_audit()` | Read-only ACL conformance check. Staff guarded in body, refuses by return value. |
| `tf_automation_readiness()` | Per-automation arming readiness. Read only, staff guarded. |
| `tf_automation_blast_radius(p_key text)` | Counts the rows an automation would touch. Read only, staff guarded. |
| `tf_automation_out_of_band()` | Compares live automation flags against `automation_arm_log`. Read only, staff guarded. |
| `tf_boolean_default_hazards()` | Boolean parameter default hazards. Read only, staff guarded. |
| `tf_function_safety_audit()` | Function safety register versus catalog. Read only, staff guarded. |
| `tf_control_attest(p_control_key text, p_status text, p_note text)` | A human attesting a manual control. Writes, but it is a staff act performed from the app, and the body guards on `user_is_internal_staff`. |

### `anon`

| Function | Why |
| --- | --- |
| `studio_is_staff()` | **The one deliberate exception.** Referenced by RLS policies whose role is PUBLIC, covering public reads on `studio_plans`, `studio_products`, `studio_product_categories` and `studio_conversion_credit_rules`. Revoking `anon` EXECUTE breaks the public storefront. |

`studio_is_staff` is in the table specifically so the checker treats it as
*declared* rather than reporting it as an undeclared anon-executable definer
function every fifteen minutes. A documented exception in a data table is a
decision. The same exception left undeclared is indistinguishable from a defect,
and it trains operators to ignore the alert.

---

## Applying a tier

```sql
select public.tf_apply_grant_tier(
  'tf_some_function',                    -- proname
  'p_key text, p_enable boolean',        -- identity arguments, '' for none
  'staff',                               -- admin | staff | anon
  'Why this tier and not a tighter one.' -- rationale, stored
);
```

The function revokes from `public, anon, authenticated` first, then grants the
tier's role set, then upserts the row into `tf_function_grant_tiers` so the
declaration and the live ACL are written in the same statement. Doing those two
things separately is how they drift.

The `ident_args` argument is `pg_get_function_identity_arguments(oid)`. Get it
right or the checker will report the declaration as pointing at a function that
does not exist:

```sql
select p.proname, pg_get_function_identity_arguments(p.oid) as ident_args
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname = 'public' and p.proname = 'tf_some_function';
```

Every migration that creates a `tf_*` function should end with a
`tf_apply_grant_tier` call. A function created without one is
anon-executable by default, which is the whole point of this document.

---

## Checking

```sql
select public.tf_grant_tier_audit();
```

Returns three violation classes, and the sum as `violation_total`:

- **`drift_total`** — a declared tier whose live ACL no longer matches. Something
  granted or revoked outside `tf_apply_grant_tier`.
- **`missing_total`** — a declared tier naming a function identity that no longer
  exists. Usually a signature change that did not update the declaration.
- **`undeclared_anon_total`** — a `tf_*` SECURITY DEFINER function that `anon` can
  execute and that has no declared tier. This is the class Supabase's default
  privileges create on their own.

Each violation carries a `remedy` string containing the exact
`tf_apply_grant_tier` call that fixes it. Copy it, run it, re-run the audit.

Live today: `declared_total: 12`, `violation_total: 0`.

### A PostgreSQL gotcha, documented because it cost time

`has_function_privilege(role, text, 'execute')` parses its second argument as a
**type list**. `pg_get_function_identity_arguments(oid)` returns parameter
*names* as well as types, for example `p_key text, p_enable boolean`. GRANT and
REVOKE accept that string happily. `has_function_privilege` raises
`invalid type name`.

The checker therefore resolves `pg_proc.oid` first and calls
`has_function_privilege(role, oid, 'execute')`. Never pass the identity-argument
string to a privilege function.

---

## Enforcement

Three layers, each of which fails independently of the others.

**Control `CM-GRANT-021`**, domain Change Management, owner CISO, automated.
Signal `tf_grant_tier_audit violation_total`. Mapped to SOC 2 `CC6.1`, `CC6.3`,
`CC8.1`; CIS v8 `3.3`, `6.8`; NIST CSF `PR.AC-4`, `PR.DS-5`. Evaluated on every
`tf_controls_evaluate()` run and wired into both the status CASE and the evidence
CASE, per convention 12.

**Ticket key `safety:grant_tier`**, produced by `tf_grant_tier_autoticket()`,
reached by `tf_safety_autoticket()` as section 4, driven by pg_cron job 46 at
minutes 7, 22, 37 and 52 of every hour. The ticket body carries the full finding
list, each with its remedy, plus the explanation of why grants drift on their
own. It closes itself automatically once the audit is clean.

**The `anon_secdef_nonpublic` axis of `tf_security_scan()`**, which catches the
same hole from the opposite direction and predates this work.

---

## How migration 248 proved the checker works

A checker that returns zero on a clean database is indistinguishable from a
checker that returns zero always. Migration 248 therefore does this inside its
own transaction, and the migration only commits if every assertion holds:

1. Assert baseline `ok: true` and `violation_total = 0`.
2. Deliberately open a hole:
   `grant execute on function public.tf_automation_arm(text, boolean) to authenticated;`
3. Assert `drift_total = 1`. The checker caught it.
4. Run `tf_controls_evaluate()`, assert `CM-GRANT-021` now reads `failing`. The
   control is genuinely wired, not merely seeded.
5. Revert: `revoke all on function public.tf_automation_arm(text, boolean) from authenticated;`
6. Assert `violation_total = 0` again, `CM-GRANT-021` back to `passing`, control
   board `total = 21` with `failing = 0`.
7. Impersonate non-staff user `dddddddd-0000-4000-a000-0000000000d1` by setting
   `request.jwt.claims`, call `tf_grant_tier_audit()`, assert it returns
   `{"ok": false, "error": "forbidden"}`. Clear the claims.
8. Same impersonation against `tf_grant_tier_autoticket()`, assert it **raises**.
   Clear the claims.
9. Last, call `tf_safety_autoticket()` and assert the new `grant_tiers` key is
   present in its return shape.

Step 9 is last on purpose. It reaches ClickUp over HTTP, and nothing after it may
fail and roll back a transaction that has already created a ticket in a system
the rollback cannot reach.

Steps 7 and 8 are the ones people get wrong. `set local role authenticated` alone
does **not** make `auth.uid()` non-null. `auth.uid()` reads
`request.jwt.claims`. A guard test that sets only the role passes trivially and
proves nothing. The claims must be cleared afterwards with
`set_config('request.jwt.claims', '', true)` or every later call in the same
transaction runs as that non-staff user.

---

## Related

- `PLATFORM_KNOWLEDGE_BASE.md` — the guard model, conventions register (#11),
  defect-pattern library
- `SECURITY_GUARDS_AND_QUEUE_LANES.md` — the definer-guard axis and `AC-DEFN-017`
- `IT_GOVERNANCE_GRC.md` — the control register and attestation model
