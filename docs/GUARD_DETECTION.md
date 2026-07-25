# Guard Detection

**Migrations 253 through 257. Control `AC-GUARDREG-023`. Ticket key `safety:guard_detection`.**

This note explains how Transit & Flow decides whether a `SECURITY DEFINER`
function is guarded, why that decision was wrong until migration 254, and what
an operator does when the control fails.

---

## 1. Why this matters more than it looks

`SECURITY DEFINER` functions execute with the privileges of their owner, which
on this platform is `postgres`. That means they bypass row-level security
entirely. RLS is the platform's primary tenant-isolation mechanism, so a definer
function granted to `authenticated` with no authorization predicate in its body
is reachable by every signed-in identity of every role: staff, technician,
property owner, tenant portal user, and any future role nobody has invented yet.

Control `AC-DEFN-017` exists to make that impossible. It reads a single number
out of `tf_security_scan()`: how many definer functions are executable by
`authenticated` and carry no authorization predicate. If that number is anything
other than zero, the control fails.

The control is therefore only as trustworthy as the detection behind it. The
detection is what this note is about.

---

## 2. What was wrong

Before migration 254, `tf_security_scan()` decided the question with this
predicate, compiled into its own body:

```sql
and pg_get_functiondef(p.oid) !~* '(user_is_internal_staff|user_is_internal_writer|studio_is_staff|has_permission|user_has_role|is_company_member|user_company_id|current_company|current_owner_|current_tenant_|current_user_role|is_privileged_role|user_is_assigned_to_|current_supabase_user_id|auth\.uid)'
```

Two defects, and they are different in kind.

**The rules were code, not data.** Fifteen guard-helper names lived inside the
function that enforced them. Adding a sixteenth helper meant rewriting the
scanner. The platform already has a house rule against exactly this shape,
stated as *conventions live in tables, checkers read the tables*, and applied in
`tf_function_safety_patterns`, `tf_boolean_param_conventions`,
`tf_automation_registry` and `tf_function_grant_tiers`. The security scanner was
the one checker that had not been brought into line, which is a poor place to
leave the exception.

**The match ran against raw source.** `pg_get_functiondef` returns the whole
function text including comments and string literals. So this function passed:

```sql
create function public.some_report()
returns int language sql stable security definer
as $$
  -- authorization: protected by auth.uid() and user_is_internal_staff
  select count(*) from public.invoices;
$$;
```

There is no guard in that function. There is a sentence describing one. The
scanner could not tell the difference, `AC-DEFN-017` read `passing`, and the
dashboard was green.

**How this was found.** While writing an ad-hoc query to find callers of
`current_owner_unit_ids`, `tf_owner_approve_maintenance` came back as apparently
unguarded. Reading the body showed it is guarded, by a helper the ad-hoc regex
had omitted. Chasing that false positive into `tf_security_scan` produced the
real finding. The lesson is one the knowledge base already carries: measure, do
not estimate, and when a measurement surprises you, read the source before
believing either the measurement or your prior.

**Measured exposure at the time of discovery.** This was a latent hazard, not a
realized breach:

| Measurement | Value |
| --- | --- |
| Definer functions granted to `authenticated`, not exempt | 54 |
| Passed the raw regex | 54 |
| Passed once comments and literals were stripped | 54 |
| **Passed only because of a comment or a literal** | **0** |

Zero today. The defect is that nothing prevented it from being non-zero
tomorrow, and nothing would have reported it if it had been.

---

## 3. The shape of the fix

Guard detection now follows the platform's standard five-part convention shape.

| Part | Object |
| --- | --- |
| A table of rules | `tf_guard_predicate_registry` |
| A function that applies them | `tf_guard_pattern()` |
| A checker comparing live state to the table | `tf_guard_detection_audit()` |
| A GRC control that fails on disagreement | `AC-GUARDREG-023` |
| An auto-ticket key | `safety:guard_detection` |

### 3.1 `tf_guard_predicate_registry`

Fifteen rows, one per guard helper, each carrying the regex fragment, a guard
class, and a written rationale. Classes are `staff_role`, `permission`,
`tenant_scope`, `owner_scope`, `assignment` and `session_identity`.

Three of the fragments are prefixes rather than full names, deliberately.
`current_owner_` covers `current_owner_unit_ids` and
`current_owner_work_order_ids`; `current_tenant_` and `user_is_assigned_to_`
cover their families the same way. That is why the false positive on
`tf_owner_approve_maintenance` was a defect in the ad-hoc query and not in the
scanner.

The weakest row is `auth.uid`, and its rationale says so in the table: presence
of `auth.uid()` proves the function reads the caller's identity, not that it
refuses anyone. It stays in the registry because removing it would flag a
large number of functions that are in fact scoped, but it should be read as the
lowest-confidence signal in the set.

### 3.2 `tf_guard_pattern()`

Builds the alternation from the registry. It is `plpgsql` rather than `sql` for
exactly one reason:

```sql
if v_pat is null then
  raise exception 'tf_guard_pattern: tf_guard_predicate_registry is empty. Refusing to return a null pattern, because x !~* null is null and every SECURITY DEFINER function would silently read as guarded.';
end if;
```

An empty registry makes the pattern null. In SQL, `x !~* null` evaluates to
null, not true, so the `unguarded` CTE would return zero rows and `AC-DEFN-017`
would report `passing` while protecting nothing. Emptying a table would have
turned the control green. Loud failure over quiet corruption.

That raise has a consequence upstream, handled in migration 255:
`tf_controls_evaluate` called `tf_security_scan()` on its first line with no
exception handler, so a raise there would have aborted the entire control
evaluation and left all twenty-three controls holding their previous status.
The call is now wrapped, the five scan-derived signals propagate `null` rather
than `0`, and the three scan-backed controls read `attention` when the scan
cannot run. A control must never pass because its own evaluation crashed.

### 3.3 `tf_strip_sql_comments(p_src text)`

Block comments first, then line comments. The `unguarded` CTE now reads:

```sql
and public.tf_strip_sql_comments(pg_get_functiondef(p.oid)) !~* public.tf_guard_pattern()
```

`tf_security_scan` also gained two additive output keys, `guard_pattern_source`
and `guard_helpers`, so the scan describes its own rules to whoever reads the
payload. Every pre-existing key and the `gap_total` formula are unchanged.

### 3.4 Comments are gated, string literals are not

`tf_guard_detection_audit()` computes three matches per function: against raw
source, against comment-stripped source, and against comment-and-literal
stripped source. Only the comment-stripped result gates the control.

That is a deliberate line. A legitimate guard can live inside a string literal,
because a function that builds dynamic SQL puts its `where` clause in a literal
by construction. Gating on literal-stripped source would fail those functions
for doing the right thing. Literal-only matches are therefore reported as
`literal_only_total` and `literal_only_fns` for a human to look at, and are not
counted as violations. Both numbers are zero today.

### 3.5 `tf_guard_detection_audit()`

Returns the population size, the unguarded set, the comment-only subset, the
advisory literal-only subset, and an integrity block that checks four
conditions:

1. the registry is not empty
2. `tf_security_scan` still calls `tf_guard_pattern`
3. `tf_security_scan` still calls `tf_strip_sql_comments`
4. `tf_security_scan` no longer carries an inline `user_is_internal_staff|`
   alternation

Conditions two through four exist because the fix is only durable while the
scanner keeps reading the table. A future `create or replace` that reverts the
scanner to a hardcoded regex would otherwise be invisible.

It is a read path, so it refuses by return value, `{"ok": false, "error":
"forbidden"}`, and it uses the guard form that lets a definer-owned caller with
a null `auth.uid()` through:

```sql
if auth.uid() is not null and not public.user_is_internal_staff(v_company) then
  return jsonb_build_object('ok', false, 'error', 'forbidden');
end if;
```

---

## 4. The proof

Migration 257 does not assert that the new logic works. It demonstrates it, by
creating a function whose only guard is a comment.

```sql
create function public.tf__guardreg_fixture_comment_only()
returns int language sql stable security definer set search_path to 'public'
as $body$
  -- authorization: this function is protected by auth.uid() and
  -- user_is_internal_staff. That sentence is a lie. There is no guard
  -- here at all, only the words describing one.
  select 1;
$body$;
grant execute on function public.tf__guardreg_fixture_comment_only() to authenticated;
```

Five assertions run while the fixture is live:

1. the **old** logic, raw source against the pattern, reads it as **guarded**.
   If this assertion failed, the fixture would not be exercising the defect and
   nothing after it would mean anything.
2. `tf_security_scan()` reports exactly one unguarded function and names it.
3. `tf_guard_detection_audit()` reports `comment_only_total = 1` and names it.
4. `AC-DEFN-017` evaluates to `failing`.
5. `AC-GUARDREG-023` evaluates to `failing`.

The whole block sits inside `begin ... exception when others then v_err :=
SQLERRM; end`, and the `drop function` runs **after** that handler, so the
fixture is removed on every code path including every failure path. Only then
is `v_err` re-raised. Recovery is asserted afterwards: the fixture is gone from
`pg_proc`, the scan and the audit are back to zero, and both controls read
`passing` again.

All five assertions and the recovery block passed on first application.

---

## 5. Runbook

**Diagnose.**

```sql
select public.tf_guard_detection_audit();
select public.tf_security_scan();
select * from public.tf_guard_predicate_registry order by guard_class, helper_name;
select control_key, status, evidence from public.it_controls
 where control_key in ('AC-DEFN-017','AC-GUARDREG-023');
```

**If `comment_only_total` is non-zero.** A named function reads as guarded only
because of a comment. Read the body. Either add a real authorization predicate,
or, if the function genuinely discloses nothing tenant-specific, add a row to
`security_scan_exemptions` with a written reason and an `approved_by`. The
exemption table currently holds two rows, both with reasons, and that is the
standard it should be held to.

**If `integrity_violation_total` is non-zero.** Read
`integrity_violations`. An empty registry means somebody truncated the table;
reseed it from migration 253. A scanner that no longer calls `tf_guard_pattern`
or `tf_strip_sql_comments` means somebody replaced `tf_security_scan` with an
older definition; restore the migration 254 body.

**Adding a sixteenth guard helper.** Insert the row, nothing else. The scanner
picks it up on the next call because it reads the table.

```sql
insert into public.tf_guard_predicate_registry
  (helper_name, pattern_fragment, guard_class, rationale)
values ('my_new_guard','my_new_guard','tenant_scope','What it proves and why it counts.');
```

**Never** edit `tf_security_scan` to add a name. That is the defect this change
removed, and `AC-GUARDREG-023` will fail the moment an inline alternation
reappears.

---

## 6. State after migration 257

| Measurement | Value |
| --- | --- |
| Migrations | 257 |
| Registered guard helpers | 15 |
| Definer functions scanned | 55 |
| Unguarded | 0 |
| Comment-only guard matches | 0 |
| Literal-only guard matches (advisory) | 0 |
| Guard-detection integrity violations | 0 |
| GRC controls | 23 |
| Passing / attention / failing | 21 / 2 / 0 |
| `tf_*` functions | 84 |
| Declared in `tf_function_registry` | 84 |
| Declared grant tiers | 18 |
| Grant-tier violations | 0 |
| Automation flags enabled | 0 of 13 |

The two controls reading `attention` are `AC-MFA-003` and `DP-PITR-007`. Both
are owner actions, tracked in ClickUp, and neither is a code defect.

---

## 7. The lesson worth carrying

The three passes of verification that preceded this change each found a
different class of defect. Pass 1 and pass 2 found stale numbers in the
documentation. Pass 3 found unarmed hazards: code that was correct in its
current state and wrong the instant somebody changed a flag.

This finding is a fourth class, and it is the one that matters most. The
platform had twenty-two controls checking the system. It had nothing checking
the thing that decides whether a control can see a defect. A checker whose
detection rules are wrong does not report a problem, it reports success, and
success from a broken checker is indistinguishable from success from a working
one right up until an audit or an incident.

Verify the verifier. Then induce a failure and watch it get caught, because a
checker never observed catching anything is not a checker.
