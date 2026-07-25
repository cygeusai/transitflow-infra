-- Migration 316: pending_residue_total counts unmet obligations, not queue rows.
--
-- Found by house rule twenty-two, on its second outing, in the migration that
-- was about to close obligation three. A migration that creates a tf_* function
-- and then re-evaluates the register before it commits reads
-- CM-FNDECL-028 as failing every single time, because:
--
--   1. tf_require_function_declaration enqueues the new function at
--      ddl_command_end, when no registry row exists yet.
--   2. The migration inserts the registry row, meeting the obligation.
--   3. The pending row is only deleted by the deferred constraint trigger,
--      which fires at COMMIT.
--   4. Between 2 and 3 the obligation is met and the queue row still exists.
--
-- pending_residue_total counted queue rows, so it read 1 in that window and
-- enforcement_gap_total followed it. House rule twenty-two and the pending
-- queue were in direct contradiction: obeying the rule guaranteed a red.
--
-- The detector was measuring the wrong thing. Residue is an obligation nobody
-- met, not a bookkeeping row that has not been swept yet. Convention 21 is
-- decompose, never narrow, so the queue count is not deleted, it is published
-- as its own non-gating population counter. A standing queue row whose
-- obligation IS met still shows up in pending_queue_total, so the sweep is
-- still observable; it just no longer fails a control.

create or replace function public.tf_declaration_enforcement_audit()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_catalog
as $fn$
declare
  v_company uuid := 'ff000000-0000-4000-b000-000000000001';
  v_out           jsonb;
  v_key           text;
  v_enabled       "char";
  v_state         text;
  v_missing       int := 0;
  v_disabled      int := 0;
  v_residue       int := 0;
  v_queue         int := 0;
  v_unreg         int := 0;
  v_fn_total      int := 0;
  v_reg_total     int := 0;
  v_gap           int;
  v_unreg_names   text[] := '{}'::text[];
  v_pending_names text[] := '{}'::text[];
  v_queued_names  text[] := '{}'::text[];

  v_self_axes constant text[] := array['enforcement_gap_total'];

  -- enforcement_gap_total is a roll-up. The roll-up axis rule permits declaring
  -- it instead of its primitives only if this body asserts the identity.
  v_component_axes constant text[] := array[
    'enforcement_missing_total',
    'enforcement_disabled_total',
    'pending_residue_total',
    'unregistered_function_total'];

  v_non_gating constant jsonb := jsonb_build_object(
    'tf_function_total',
    'Population, not findings. Every public.tf_* function of prokind f. This is '
    || 'the denominator unregistered_function_total is drawn from, and publishing '
    || 'it is what lets a reader tell a clean result from a blind one.',
    'registry_row_total',
    'Population, not findings. Rows in tf_function_registry. It may legitimately '
    || 'exceed tf_function_total, and the excess is a stale declaration, which is '
    || 'tf_function_safety_audit territory rather than this checker.',
    'pending_queue_total',
    'Population, not findings. Every row currently in tf_declaration_pending, met '
    || 'or unmet. pending_residue_total is the unmet subset. The two differ only '
    || 'inside a transaction that has created a tf_* function, declared it, and '
    || 'not yet committed, which is exactly the window house rule twenty-two '
    || 'inspects. Publishing both is what keeps an unswept queue observable '
    || 'without failing a control for a row that is about to be swept.');
begin
  if auth.uid() is not null and not public.user_is_internal_staff(v_company) then
    return jsonb_build_object('ok', false, 'error', 'forbidden');
  end if;

  select evtenabled into v_enabled
    from pg_event_trigger
   where evtname = 'tf_require_function_declaration';

  if v_enabled is null then
    v_missing := 1;
    v_state   := 'absent';
  elsif v_enabled = 'D' then
    v_disabled := 1;
    v_state    := 'disabled';
  else
    v_state := case v_enabled
                 when 'O' then 'origin'
                 when 'R' then 'replica'
                 when 'A' then 'always'
                 else 'unknown' end;
  end if;

  select count(*) into v_fn_total
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f' and p.proname like 'tf\_%';

  select count(*) into v_reg_total from public.tf_function_registry;

  select coalesce(array_agg(p.proname order by p.proname), '{}'::text[])
    into v_unreg_names
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.prokind = 'f' and p.proname like 'tf\_%'
     and not exists (select 1 from public.tf_function_registry g where g.proname = p.proname);
  v_unreg := coalesce(array_length(v_unreg_names, 1), 0);

  -- Every queue row, met or unmet. Population.
  select coalesce(array_agg(q.proname order by q.proname), '{}'::text[])
    into v_queued_names
    from public.tf_declaration_pending q;
  v_queue := coalesce(array_length(v_queued_names, 1), 0);

  -- Residue is an obligation nobody met. A queue row whose registry row already
  -- exists is met and will be swept by the deferred check at COMMIT.
  select coalesce(array_agg(q.proname order by q.proname), '{}'::text[])
    into v_pending_names
    from public.tf_declaration_pending q
   where not exists (select 1 from public.tf_function_registry g where g.proname = q.proname);
  v_residue := coalesce(array_length(v_pending_names, 1), 0);

  v_gap := v_missing + v_disabled + v_residue + v_unreg;

  v_out := jsonb_build_object(
    'ok', true,
    'checked_at', now(),
    'event_trigger', 'tf_require_function_declaration',
    'event_trigger_state', v_state,
    'enforcement_missing_total', v_missing,
    'enforcement_disabled_total', v_disabled,
    'pending_residue_total', v_residue,
    'pending_functions', to_jsonb(v_pending_names),
    'pending_queue_total', v_queue,
    'queued_functions', to_jsonb(v_queued_names),
    'unregistered_function_total', v_unreg,
    'unregistered_functions', to_jsonb(v_unreg_names),
    'tf_function_total', v_fn_total,
    'registry_row_total', v_reg_total,
    'enforcement_gap_total', v_gap,
    'residue_note', 'pending_residue_total counts queue rows whose obligation is '
      || 'still unmet, which is a function created and not declared. It reads '
      || 'non-zero only inside a transaction that has created a tf_* function and '
      || 'has not declared it yet. Outside a transaction the queue is empty by '
      || 'construction, so a standing non-zero here means a commit-time check did '
      || 'not run. pending_queue_total counts every queue row including met ones, '
      || 'and the gap between the two is the ordinary declare-then-commit window '
      || 'that migration 316 stopped failing a control for.');

  -- Roll-up identity, asserted here, in this body, before the roll-up is published.
  if v_gap <> coalesce((v_out->>'enforcement_missing_total')::int, 0)
            + coalesce((v_out->>'enforcement_disabled_total')::int, 0)
            + coalesce((v_out->>'pending_residue_total')::int, 0)
            + coalesce((v_out->>'unregistered_function_total')::int, 0) then
    raise exception 'tf_declaration_enforcement_audit roll-up identity broken: enforcement_gap_total % does not equal the sum of its four components', v_gap;
  end if;

  -- Coupling one. Declared axis resolves to a computed key.
  foreach v_key in array v_self_axes loop
    if not jsonb_exists(v_out, v_key) then
      raise exception 'tf_declaration_enforcement_audit declares axis % but publishes no such key.', v_key;
    end if;
  end loop;

  -- Coupling one, extended to the components the roll-up stands for.
  foreach v_key in array v_component_axes loop
    if not jsonb_exists(v_out, v_key) then
      raise exception 'tf_declaration_enforcement_audit declares component axis % but publishes no such key.', v_key;
    end if;
  end loop;

  -- Coupling two. Declared non-gating counters resolve to computed keys.
  for v_key in select k from jsonb_object_keys(v_non_gating) as t(k) loop
    if not jsonb_exists(v_out, v_key) then
      raise exception 'tf_declaration_enforcement_audit declares non-gating counter % but publishes no such key.', v_key;
    end if;
  end loop;

  -- Coupling three. Every published counter is classified.
  for v_key in
    select k from jsonb_object_keys(v_out) as t(k)
     where k like '%\_total' or k like '%\_count'
  loop
    if not (v_key = any(v_self_axes))
       and not (v_key = any(v_component_axes))
       and not jsonb_exists(v_non_gating, v_key) then
      raise exception 'tf_declaration_enforcement_audit publishes counter % that is neither a declared axis, a declared component of the roll-up, nor a declared non-gating counter. Classify it before this checker can certify.', v_key;
    end if;
  end loop;

  return v_out || jsonb_build_object(
    'axes', to_jsonb(v_self_axes),
    'component_axes', to_jsonb(v_component_axes),
    'non_gating', v_non_gating);
end;
$fn$;

do $mig$
declare
  v_decl    jsonb;
  v_summary jsonb;
begin
  v_decl := public.tf_declaration_enforcement_audit();

  if coalesce(v_decl->>'ok', 'false') <> 'true' then
    raise exception 'migration 316: declaration enforcement checker did not certify: %', v_decl;
  end if;

  if not (v_decl ? 'pending_queue_total') then
    raise exception 'migration 316: pending_queue_total was not published';
  end if;

  if coalesce((v_decl->>'enforcement_gap_total')::int, -1) <> 0 then
    raise exception 'migration 316: enforcement_gap_total is % after the fix, expected 0. Payload: %',
      v_decl->>'enforcement_gap_total', v_decl;
  end if;

  perform public.tf_controls_evaluate();

  select jsonb_build_object(
           'total',     count(*),
           'failing',   count(*) filter (where status = 'failing'),
           'passing',   count(*) filter (where status = 'passing'),
           'attention', count(*) filter (where status = 'attention'))
    into v_summary
    from public.it_controls;

  if coalesce((v_summary->>'failing')::int, -1) <> 0 then
    raise exception 'migration 316: register reports % failing control(s), expected 0. Summary: %',
      v_summary->>'failing', v_summary;
  end if;

  raise notice 'migration 316 ok: residue is unmet-only, register %', v_summary;
end
$mig$;
