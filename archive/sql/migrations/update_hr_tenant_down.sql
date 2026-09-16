-- Rollback of sql/update_hr_tenant.sql: the unique keys without the tenant, the
-- column nullable without default, and both crud functions as they were live on
-- 15 Sep 2026 (the loop versions without tenant).
BEGIN;

ALTER TABLE log.hr_data
    DROP CONSTRAINT uq_hr_data_log,
    ADD  CONSTRAINT uq_hr_data_log UNIQUE (employee_id, business_date, shift);
ALTER TABLE log.hr_shift_planning
    DROP CONSTRAINT uq_shift_planning,
    ADD  CONSTRAINT uq_shift_planning UNIQUE (department_group_id, business_date);

ALTER TABLE log.hr_data
    ALTER COLUMN tenant_id DROP NOT NULL,
    ALTER COLUMN tenant_id DROP DEFAULT;
ALTER TABLE log.hr_shift_planning
    ALTER COLUMN tenant_id DROP NOT NULL,
    ALTER COLUMN tenant_id DROP DEFAULT;

-- ============ log.crud_hr_data_log, the version before ============
CREATE OR REPLACE FUNCTION log.crud_hr_data_log(p_param_json jsonb, p_no_results boolean DEFAULT false)
 RETURNS TABLE(track_by integer, crud text, hr_data_log_id integer, employee_id integer, department_id integer, department_group_id integer, business_date date, shift text, start_at timestamp with time zone, end_at timestamp with time zone, source text, source_ref text, ingested_at timestamp with time zone, updated_at timestamp with time zone)
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
declare
  rec jsonb;
  v_data jsonb;
begin

  for rec in
    select value from jsonb_array_elements(p_param_json) as e(value)
  loop

    v_data := rec -> 'data';

    return query
    insert into log.hr_data as h (
      employee_id, department_id, department_group_id,
      business_date, shift,
      start_at, end_at,
      source, source_ref
    )
    values (
      (v_data ->> 'employee_id')::int,
      (v_data ->> 'department_id')::int,
      (v_data ->> 'department_group_id')::int,
      (v_data ->> 'business_date')::date,
      v_data ->> 'shift',
      (v_data ->> 'start_at')::timestamptz,
      (v_data ->> 'end_at')::timestamptz,
      coalesce(v_data ->> 'source', 'dyflexis'),
      v_data ->> 'source_ref'
    )
--     on conflict (employee_id, business_date, shift) do update set
--       department_id = excluded.department_id,
--       department_group_id = excluded.department_group_id,
--       start_at = excluded.start_at,
--       end_at = coalesce(excluded.end_at, h.end_at),
--       source = excluded.source,
--       source_ref = coalesce(excluded.source_ref, h.source_ref),
--       updated_at = now()
    on conflict (employee_id, business_date, shift) do update set
      department_id       = coalesce(excluded.department_id,       h.department_id),
      department_group_id = coalesce(excluded.department_group_id, h.department_group_id),
      start_at            = coalesce(excluded.start_at,            h.start_at),
      end_at              = coalesce(excluded.end_at,              h.end_at),
      source              = excluded.source,
      source_ref          = coalesce(excluded.source_ref,          h.source_ref),
      updated_at          = now()  
    returning
      (rec ->> 'track_by')::integer,
      rec ->> 'crud',
      h.hr_data_log_id,
      h.employee_id,
      h.department_id,
      h.department_group_id,
      h.business_date,
      h.shift,
      h.start_at,
      h.end_at,
      h.source,
      h.source_ref,
      h.ingested_at,
      h.updated_at;

  end loop;

  if p_no_results then return; end if;

end;
$function$;

-- ============ log.crud_hr_shift_planning_log, the version before ============
CREATE OR REPLACE FUNCTION log.crud_hr_shift_planning_log(p_param_json jsonb, p_no_results boolean DEFAULT false)
 RETURNS TABLE(track_by integer, crud text, shift_planning_id integer, department_group_id integer, business_date date, shift_json jsonb, updated_at timestamp with time zone)
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
declare
  rec jsonb;
  v_data jsonb;
begin

  for rec in
    select value from jsonb_array_elements(p_param_json) as e(value)
  loop

    v_data := rec -> 'data';

    return query
    insert into log.hr_shift_planning as s (
      department_group_id, business_date, shift_json
    )
    values (
      (v_data ->> 'department_group_id')::int,
      (v_data ->> 'business_date')::date,
      coalesce(v_data -> 'shift_json', '{}'::jsonb)
    )
    on conflict (department_group_id, business_date) do update set
      shift_json = excluded.shift_json,
      updated_at = now()
    returning
      (rec ->> 'track_by')::integer,
      rec ->> 'crud',
      s.shift_planning_id,
      s.department_group_id,
      s.business_date,
      s.shift_json,
      s.updated_at;

  end loop;

  if p_no_results then return; end if;

end;
$function$;

COMMIT;
