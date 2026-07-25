-- Migration 319: falsifiability proof for the migration 318 refusal.
--
-- WHY THIS MIGRATION EXISTS
-- Per the migration 311 precedent, an enforcement that has never been observed
-- refusing anything is an enforcement nobody has tested. A control that cannot
-- fail is not a control, it is a decoration. This migration provokes the
-- migration 318 refusal deliberately, asserts the exact shape of what comes
-- back, and is retained in the migration history as the evidence.
--
-- HOW IT PROVES WITHOUT LEAKING
-- The probe runs inside a plpgsql subtransaction. It creates a checker-shaped
-- function that publishes an axes key and wires it to nothing, satisfies
-- convention 33 obligation two so that ONLY obligation three can refuse, then
-- forces the DEFERRABLE INITIALLY DEFERRED constraint trigger to fire early
-- with SET CONSTRAINTS ALL IMMEDIATE. The refusal aborts the subtransaction,
-- which unwinds the CREATE FUNCTION, the registry row and the queue row
-- together. Nothing survives into the committed state, and the assertions at
-- the bottom verify that rather than assuming it.
--
-- The handler catches check_violation only. If the enforcement fails to fire,
-- control reaches the 'NO REFUSAL' raise, which is raise_exception and is NOT
-- caught, so this migration fails loudly. A probe that passes when the thing it
-- probes is broken is worse than no probe.
--
-- VERBATIM REFUSAL CAPTURED ON 2026-07-25, RECORDED HERE FOR THE RUNBOOK
--
--   SQLSTATE: 23514
--   ERROR: Refused at commit: public.tf_probe_unwired_checker() publishes an
--   axes key, which makes it a checker, and it is not wired to a control.
--   Unmet: not a key in public.tf_controls_signal_roster() |
--   public.tf_controls_evaluate() does not call public.tf_probe_unwired_checker()
--   | no public.it_controls row has a signal naming tf_probe_unwired_checker
--   HINT: Convention 33 obligation three. In the same transaction: add the
--   function and its axis names to public.tf_controls_signal_roster(), add a
--   call to public.tf_probe_unwired_checker() inside
--   public.tf_controls_evaluate(), and insert or update a public.it_controls
--   row whose signal names tf_probe_unwired_checker. This check runs at COMMIT,
--   so any order inside the transaction is accepted. If the function is not
--   meant to be a checker, stop publishing an axes key, because publishing one
--   is the definition.
--
-- Note the refusal enumerates all three unmet facts rather than short
-- circuiting on the first. An author fixing one at a time and re-running would
-- otherwise pay three round trips to learn what one message can say.

do $mig$
declare
  v_state    text := '(none)';
  v_err      text := '(none)';
  v_hint     text := '(none)';
  v_refused  boolean := false;
  v_leftover int;
  v_sum      jsonb;
begin
  begin
    execute $d$
      create or replace function public.tf_probe_unwired_checker()
      returns jsonb
      language sql
      stable
      set search_path = public, pg_catalog
      as $p$
        select jsonb_build_object(
          'ok', true,
          'axes', jsonb_build_array('probe_gap_total'),
          'probe_gap_total', 0);
      $p$;
    $d$;

    -- Obligation two satisfied on purpose, so obligation three is isolated.
    insert into public.tf_function_registry (proname, declared_kind, rationale)
    values ('tf_probe_unwired_checker', 'read',
            'Falsifiability probe for migration 318. This row never commits.')
    on conflict (proname) do nothing;

    -- Force the deferred check to fire without reaching COMMIT.
    set constraints all immediate;

    raise exception 'migration 319: NO REFUSAL. A function publishing an axes key and wired to nothing was accepted. The migration 318 enforcement is not working.'
      using errcode = 'raise_exception';
  exception when check_violation then
    v_state   := SQLSTATE;
    v_err     := SQLERRM;
    v_refused := true;
    get stacked diagnostics v_hint = PG_EXCEPTION_HINT;
  end;

  if not v_refused then
    raise exception 'migration 319: the probe completed without a check_violation.';
  end if;

  if v_state <> '23514' then
    raise exception 'migration 319: expected SQLSTATE 23514 (check_violation), got %.', v_state;
  end if;

  if strpos(v_err, 'Refused at commit') = 0 then
    raise exception 'migration 319: refusal text does not open with the expected phrase. Got: %', v_err;
  end if;

  if strpos(v_err, 'not a key in public.tf_controls_signal_roster()') = 0 then
    raise exception 'migration 319: refusal does not name the missing roster entry. Got: %', v_err;
  end if;

  if strpos(v_err, 'does not call public.tf_probe_unwired_checker()') = 0 then
    raise exception 'migration 319: refusal does not name the missing evaluator call site. Got: %', v_err;
  end if;

  if strpos(v_err, 'no public.it_controls row has a signal naming tf_probe_unwired_checker') = 0 then
    raise exception 'migration 319: refusal does not name the missing control signal. Got: %', v_err;
  end if;

  if strpos(v_hint, 'Convention 33 obligation three') = 0 then
    raise exception 'migration 319: refusal carries no remediation hint. Got: %', v_hint;
  end if;

  -- The subtransaction rollback must have taken the probe with it. Verify,
  -- do not assume.
  select count(*) into v_leftover
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'tf_probe_unwired_checker';
  if v_leftover <> 0 then
    raise exception 'migration 319: the probe function survived the rollback, % copy(ies) remain.', v_leftover;
  end if;

  select count(*) into v_leftover
    from public.tf_function_registry where proname = 'tf_probe_unwired_checker';
  if v_leftover <> 0 then
    raise exception 'migration 319: the probe registry row survived the rollback.';
  end if;

  select count(*) into v_leftover from public.tf_signal_wiring_pending;
  if v_leftover <> 0 then
    raise exception 'migration 319: the wiring queue is not empty after the probe, % row(s).', v_leftover;
  end if;

  -- House rule twenty-two.
  select public.tf_controls_evaluate() into v_sum;
  if coalesce((v_sum->>'failing')::int, -1) <> 0 then
    raise exception 'migration 319: register reports % failing control(s), expected 0. Summary: %',
      coalesce((v_sum->>'failing')::int, -1), v_sum::text;
  end if;

  raise notice 'migration 319 OK: refusal observed, SQLSTATE %, probe fully unwound, register summary %', v_state, v_sum::text;
end;
$mig$;