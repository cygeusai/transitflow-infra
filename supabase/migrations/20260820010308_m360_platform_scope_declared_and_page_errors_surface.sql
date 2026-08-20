-- m360_platform_scope_declared_and_page_errors_surface
--
-- Two small truths found by actually running the recovery page end to end
-- rather than assuming it worked.
--
-- 1. tf_page_staff_sev reported scope_recognized:false for 'internal_ops'.
--    That is honest: there is no such branch. It works only because the
--    function seeds v_keys with the owner and system_administrator floor
--    before adding scope roles, so an unrecognized scope silently degrades to
--    that floor. For a platform regression that floor happens to be the right
--    audience, but "happens to be right" is not a design. Every page from
--    platform_regression_critical since m331 has carried a false-looking
--    diagnostic. Declare the scope, change nothing about who is paged.
--
-- 2. tf_page_staff_sev catches its own exceptions and returns them in the
--    payload instead of raising. m359 recorded errors only from raised
--    exceptions, so a page that failed this way would still have produced
--    ok:true from the watcher. Read the returned payload as well.

do $do$
declare
  v_def text;
  v_new text;
  v_a1 constant text := E'    else array[]::text[]\n  end;';
  v_a2 constant text := E'''scope_recognized'', v_scope in (''ops'',''dispatch'',''finance'',''compliance'',''field'',''sales'',''all_staff'')';
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'tf_page_staff_sev';

  if v_def is null then
    raise exception 'm360: public.tf_page_staff_sev not found';
  end if;
  if position('internal_ops' in v_def) > 0 then
    raise exception 'm360: tf_page_staff_sev already declares internal_ops';
  end if;
  if (length(v_def) - length(replace(v_def, v_a1, ''))) / length(v_a1) <> 1 then
    raise exception 'm360: expected exactly 1 case-else anchor in tf_page_staff_sev';
  end if;
  if (length(v_def) - length(replace(v_def, v_a2, ''))) / length(v_a2) <> 1 then
    raise exception 'm360: expected exactly 1 scope_recognized anchor in tf_page_staff_sev';
  end if;

  v_new := replace(v_def, v_a1,
       E'    when ''internal_ops'' then array[]::text[]\n'
    || E'    -- Deliberate. A platform regression is for the owner and the system\n'
    || E'    -- administrator only, which is exactly the floor seeded above, so this\n'
    || E'    -- branch adds nobody. Declared in m360 so the scope reports as\n'
    || E'    -- recognized and a reader can see the empty set was chosen, not defaulted.\n'
    || v_a1);

  v_new := replace(v_new, v_a2,
    E'''scope_recognized'', v_scope in (''ops'',''dispatch'',''finance'',''compliance'',''field'',''sales'',''all_staff'',''internal_ops'')');

  execute v_new;
end
$do$;

do $do$
declare
  v_def text;
  v_new text;
  v_anchor constant text := E'  return jsonb_build_object(\n    ''ok'', jsonb_array_length(v_errs) = 0,';
begin
  select pg_get_functiondef(p.oid) into v_def
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'tf_regression_autoticket';

  if v_def is null then
    raise exception 'm360: public.tf_regression_autoticket not found';
  end if;
  if (length(v_def) - length(replace(v_def, v_anchor, ''))) / length(v_anchor) <> 1 then
    raise exception 'm360: expected exactly 1 return anchor in tf_regression_autoticket';
  end if;

  v_new := replace(v_def, v_anchor,
       E'  -- tf_page_staff_sev absorbs its own exceptions and hands the error back in\n'
    || E'  -- the payload. A page that failed that way raised nothing, so without this\n'
    || E'  -- the watcher would still have reported ok:true having paged nobody.\n'
    || E'  if v_paged ? ''error'' then\n'
    || E'    raise warning ''tf_regression_autoticket: critical page returned an error: %'', v_paged->>''error'';\n'
    || E'    v_errs := v_errs || jsonb_build_object(''stage'',''page_critical_payload'',''message'',v_paged->>''error'');\n'
    || E'  end if;\n'
    || E'  if v_recov ? ''error'' then\n'
    || E'    raise warning ''tf_regression_autoticket: recovery page returned an error: %'', v_recov->>''error'';\n'
    || E'    v_errs := v_errs || jsonb_build_object(''stage'',''page_recovery_payload'',''message'',v_recov->>''error'');\n'
    || E'  end if;\n\n'
    || v_anchor);

  execute v_new;
end
$do$;

update public.tf_function_registry
   set rationale = 'Severity-aware staff pager. Seeds the owner and system_administrator floor, then adds roles for the named scope. m360 declared the internal_ops scope explicitly so platform pages stop reporting scope_recognized:false; the audience is unchanged.',
       updated_at = now()
 where proname = 'tf_page_staff_sev';