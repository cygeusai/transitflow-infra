-- Migration 318: commit-time refusal for unwired checkers.
--
-- WHAT THIS CLOSES
-- Convention 33 obligation three: "wire its signal into a control". Six
-- verification passes recorded this as unclosable, on the stated ground that
-- there is no single catalog fact testable at commit time. That ground was
-- wrong, and migration 317 stated the fact:
--
--   A checker is a public.tf_* function of prokind='f' whose pg_get_functiondef
--   text contains the literal 'axes',.
--
-- That is convention 37 read literally. The axis is the consumption surface, so
-- publishing an axes key IS what makes a function a checker. It is a property of
-- the function's own text, not an author's declared intent, which is why it can
-- never become an exemption lever of the kind migration 265 closed. An author
-- who wants out has to stop publishing axes, and a function that publishes no
-- axes is not a checker.
--
-- WIRED means three catalog facts, all re-tested at COMMIT:
--   1. the proname is a key in public.tf_controls_signal_roster()
--   2. pg_get_functiondef(public.tf_controls_evaluate) contains public.<proname>()
--   3. at least one public.it_controls row has signal containing <proname>
-- All three are exact substring tests, not LIKE, because underscore is a LIKE
-- wildcard and every name in this platform contains one.
--
-- SHAPE
-- Same commit-time enforcement pattern as tf_require_function_declaration:
-- an event trigger on ddl_command_end enqueues, and a DEFERRABLE INITIALLY
-- DEFERRED constraint trigger on the queue fires at COMMIT to enforce and sweep.
-- The obligation therefore holds at COMMIT, not at statement time (convention
-- 42), so a migration may create the checker and wire it in any internal order.
--
-- KILL SWITCH
-- Per convention 43, the enforcement has a kill switch, so the kill switch is a
-- monitored axis: evtenabled on tf_require_signal_wiring. Migration 320 monitors
-- it. An enforcement nobody watches being disabled is an enforcement that is
-- already off.
--
-- WHAT COMES NEXT, AND WHY THE ORDER IS FORCED
-- The next migration provokes this refusal with the roll-back diagnostic idiom
-- and captures the verbatim error, retained in history per the migration 311
-- precedent. The migration after that creates tf_signal_wiring_enforcement_audit
-- AND wires it in one transaction, because that function will itself publish
-- axes and this enforcement makes any other order impossible. That is the
-- enforcement working, not a limitation of it.
--
-- QUEUE TABLE PRECEDENT
-- tf_signal_wiring_pending mirrors tf_declaration_pending exactly: RLS enabled
-- by ensure_rls, no policy, and ALL revoked from anon and authenticated so the
-- policy-less state is not reachable and tf_security_scan stays quiet. That
-- exact configuration is live and green on tf_declaration_pending today.
--
-- ONE GOTCHA RECORDED HERE BECAUSE IT COST AN ATTEMPT
-- public.tf_controls_board() has no 'summary' key. The register summary is the
-- return value of public.tf_controls_evaluate() itself. The first attempt at
-- this migration read board->'summary', got NULL, and the coalesce default of
-- -1 turned a clean register into a loud false red. That is the correct
-- outcome and the reason the default is -1: in an assertion, the safe default
-- for a coalesce is the FAILING value, never the passing one. Had it defaulted
-- to 0 this migration would have committed on a reading it never actually took.

create table if not exists public.tf_signal_wiring_pending (
  proname          text primary key,
  object_identity  text,
  command_tag      text,
  created_by       text default current_user,
  queued_at        timestamptz default now()
);

revoke all on public.tf_signal_wiring_pending from public;
revoke all on public.tf_signal_wiring_pending from anon;
revoke all on public.tf_signal_wiring_pending from authenticated;
grant all on public.tf_signal_wiring_pending to postgres;
grant all on public.tf_signal_wiring_pending to service_role;

comment on table public.tf_signal_wiring_pending is
  'Transit & Flow: transient queue for convention 33 obligation three. A row appears when a tf_* function publishing an axes key is created or altered without being wired to a control, and is swept at COMMIT by tf_signal_wiring_pending_check. A row surviving a commit means the deferred check was bypassed and is a defect.';

-- The enqueue half. Fires on ddl_command_end.
create or replace function public.tf_signal_wiring_required()
returns event_trigger
language plpgsql
set search_path = public, pg_catalog
as $fn$
declare
  r          record;
  v_proname  text;
  v_src      text;
  v_eval     text;
  v_wired    boolean;
begin
  for r in select * from pg_event_trigger_ddl_commands() loop
    if r.command_tag not in ('CREATE FUNCTION', 'ALTER FUNCTION') then
      continue;
    end if;

    if r.schema_name is distinct from 'public' then
      continue;
    end if;

    select p.proname, pg_get_functiondef(p.oid)
      into v_proname, v_src
      from pg_proc p
     where p.oid = r.objid
       and p.prokind = 'f';

    if v_proname is null or v_proname not like 'tf\_%' then
      continue;
    end if;

    -- Convention 37 read literally: publishing an axes key is what makes a
    -- function a checker. No axes key, no obligation.
    if v_src is null or strpos(v_src, '''axes'',') = 0 then
      continue;
    end if;

    select pg_get_functiondef(p.oid)
      into v_eval
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname = 'tf_controls_evaluate'
       and p.prokind = 'f'
     limit 1;

    v_wired :=
         jsonb_exists(public.tf_controls_signal_roster(), v_proname)
     and v_eval is not null
     and strpos(v_eval, 'public.' || v_proname || '()') > 0
     and exists (select 1
                   from public.it_controls c
                  where c.signal is not null
                    and strpos(c.signal, v_proname) > 0);

    if v_wired then
      continue;
    end if;

    insert into public.tf_signal_wiring_pending (proname, object_identity, command_tag)
    values (v_proname, r.object_identity, r.command_tag)
    on conflict (proname) do nothing;
  end loop;
end;
$fn$;

-- The deferred half. Fires at COMMIT, once per queued row.
create or replace function public.tf_signal_wiring_pending_check()
returns trigger
language plpgsql
set search_path = public, pg_catalog
as $fn$
declare
  v_eval    text;
  v_missing text[] := '{}'::text[];
begin
  select pg_get_functiondef(p.oid)
    into v_eval
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public'
     and p.proname = 'tf_controls_evaluate'
     and p.prokind = 'f'
   limit 1;

  if not jsonb_exists(public.tf_controls_signal_roster(), new.proname) then
    v_missing := v_missing || 'not a key in public.tf_controls_signal_roster()'::text;
  end if;

  if v_eval is null or strpos(v_eval, 'public.' || new.proname || '()') = 0 then
    v_missing := v_missing || ('public.tf_controls_evaluate() does not call public.' || new.proname || '()')::text;
  end if;

  if not exists (select 1
                   from public.it_controls c
                  where c.signal is not null
                    and strpos(c.signal, new.proname) > 0) then
    v_missing := v_missing || ('no public.it_controls row has a signal naming ' || new.proname)::text;
  end if;

  if cardinality(v_missing) = 0 then
    delete from public.tf_signal_wiring_pending p where p.proname = new.proname;
    return null;
  end if;

  raise exception 'Refused at commit: public.%() publishes an axes key, which makes it a checker, and it is not wired to a control. Unmet: %', new.proname, array_to_string(v_missing, ' | ')
    using errcode = 'check_violation',
          hint = 'Convention 33 obligation three. In the same transaction: add the function and its axis names to public.tf_controls_signal_roster(), add a call to public.' || new.proname || '() inside public.tf_controls_evaluate(), and insert or update a public.it_controls row whose signal names ' || new.proname || '. This check runs at COMMIT, so any order inside the transaction is accepted. If the function is not meant to be a checker, stop publishing an axes key, because publishing one is the definition.';
end;
$fn$;

create constraint trigger tf_signal_wiring_pending_deferred_check
  after insert on public.tf_signal_wiring_pending
  deferrable initially deferred
  for each row
  execute function public.tf_signal_wiring_pending_check();

create event trigger tf_require_signal_wiring
  on ddl_command_end
  execute function public.tf_signal_wiring_required();

-- Convention 33 obligation two: declare in the same migration as the creation.
insert into public.tf_function_registry (proname, declared_kind, rationale)
values (
  'tf_signal_wiring_required',
  'write',
  'RETURNS event_trigger. Fires on ddl_command_end for CREATE FUNCTION and ALTER FUNCTION in schema public, and queues a row in tf_signal_wiring_pending for any tf_* function whose definition publishes an axes key and which is not wired to a control at that instant. Declared write because it performs an INSERT. The axes test is textual and deliberate: convention 37 says the axis is the consumption surface, so publishing an axes key is what makes a function a checker, and that is a property of the function text rather than declared intent, which is why it cannot become an exemption lever.'
),
(
  'tf_signal_wiring_pending_check',
  'write',
  'RETURNS trigger. The deferred half of convention 33 obligation three. Fires at COMMIT for each queued row, re-tests the three wiring facts (roster membership, a call site in tf_controls_evaluate, and an it_controls signal naming the function), deletes the row when all three hold, and raises otherwise. Declared write on the migration 272 rule that a trigger function is a write path by construction, and it genuinely deletes.'
)
on conflict (proname) do update
  set declared_kind = excluded.declared_kind,
      rationale     = excluded.rationale,
      updated_at    = now();

do $gt$
begin
  perform public.tf_apply_grant_tier(
    'tf_signal_wiring_required', '', 'admin',
    'Event trigger function. Never called directly by any client. Admin tier only.');
  perform public.tf_apply_grant_tier(
    'tf_signal_wiring_pending_check', '', 'admin',
    'Constraint trigger function. Never called directly by any client. Admin tier only.');
end;
$gt$;

-- Assertions. Everything below is verified against the live catalog before this
-- transaction is allowed to commit.
do $mig$
declare
  v_evt      "char";
  v_tgdeferr boolean;
  v_tginit   boolean;
  v_rls      boolean;
  v_queue    int;
  v_reg      int;
  v_gt       int;
  v_sum      jsonb;
begin
  select e.evtenabled into v_evt
    from pg_event_trigger e where e.evtname = 'tf_require_signal_wiring';
  if v_evt is null then
    raise exception 'migration 318: event trigger tf_require_signal_wiring was not created.';
  end if;
  if v_evt <> 'O' then
    raise exception 'migration 318: event trigger tf_require_signal_wiring is not enabled, evtenabled=%.', v_evt;
  end if;

  select t.tgdeferrable, t.tginitdeferred
    into v_tgdeferr, v_tginit
    from pg_trigger t
   where t.tgrelid = 'public.tf_signal_wiring_pending'::regclass
     and t.tgname = 'tf_signal_wiring_pending_deferred_check';
  if v_tgdeferr is null then
    raise exception 'migration 318: constraint trigger tf_signal_wiring_pending_deferred_check was not created.';
  end if;
  if not (v_tgdeferr and v_tginit) then
    raise exception 'migration 318: constraint trigger is not DEFERRABLE INITIALLY DEFERRED (deferrable=%, initdeferred=%). It would fire at statement time and convention 42 would be violated.', v_tgdeferr, v_tginit;
  end if;

  select c.relrowsecurity into v_rls
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relname = 'tf_signal_wiring_pending';
  if not coalesce(v_rls, false) then
    raise exception 'migration 318: RLS is not enabled on public.tf_signal_wiring_pending.';
  end if;

  if has_table_privilege('anon', 'public.tf_signal_wiring_pending', 'select')
     or has_table_privilege('authenticated', 'public.tf_signal_wiring_pending', 'select') then
    raise exception 'migration 318: tf_signal_wiring_pending is readable by anon or authenticated with no policy in place.';
  end if;

  select count(*) into v_queue from public.tf_signal_wiring_pending;
  if v_queue <> 0 then
    raise exception 'migration 318: the wiring queue is not empty at install, % row(s). Nothing created here publishes an axes key, so this is unexpected.', v_queue;
  end if;

  select count(*) into v_reg
    from public.tf_function_registry
   where proname in ('tf_signal_wiring_required', 'tf_signal_wiring_pending_check');
  if v_reg <> 2 then
    raise exception 'migration 318: expected 2 registry rows for the new functions, found %.', v_reg;
  end if;

  select count(*) into v_gt
    from public.tf_function_grant_tiers
   where proname in ('tf_signal_wiring_required', 'tf_signal_wiring_pending_check');
  if v_gt <> 2 then
    raise exception 'migration 318: expected 2 grant tier rows for the new functions, found %.', v_gt;
  end if;

  -- House rule twenty-two: re-evaluate the control register before commit.
  -- A stale green is worse than a red, because nobody investigates a green.
  -- tf_controls_evaluate() returns the summary. tf_controls_board() does not
  -- carry a 'summary' key, and reading one there yields NULL.
  select public.tf_controls_evaluate() into v_sum;
  if coalesce((v_sum->>'failing')::int, -1) <> 0 then
    raise exception 'migration 318: register reports % failing control(s) after wiring, expected 0. Summary: %',
      coalesce((v_sum->>'failing')::int, -1), v_sum::text;
  end if;

  raise notice 'migration 318 OK: tf_require_signal_wiring armed, deferred check installed, queue empty, register summary %', v_sum::text;
end;
$mig$;