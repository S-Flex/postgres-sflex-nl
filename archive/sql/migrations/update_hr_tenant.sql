-- Dyflexis multi-tenant: finishes the migration that started with the
-- tenant_id column on log.hr_data and log.hr_shift_planning.
--   1. every existing row is tenant 1 (Dutch); the column gets default 1, not null
--   2. the tenant joins the unique key of both tables (wider, never stricter:
--      checked live 15 Sep 2026, no group collides)
--   3. both crud functions write the tenant and conflict on the new key. They
--      are set-based now (the loop versions are replaced in kind): the batch is
--      one insert, the last element of a key in the batch wins, the returned
--      rows are matched back to their track_by on the key. RETURNS TABLE is
--      unchanged, so CREATE OR REPLACE keeps the function and its grants.
-- One transaction: the constraints and the functions never disagree.
-- Rollback: sql/update_hr_tenant_down.sql.
BEGIN;

-- ============ 1. existing rows are tenant 1 ============
UPDATE log.hr_data           SET tenant_id = 1 WHERE tenant_id IS NULL;
UPDATE log.hr_shift_planning SET tenant_id = 1 WHERE tenant_id IS NULL;

ALTER TABLE log.hr_data
    ALTER COLUMN tenant_id SET DEFAULT 1,
    ALTER COLUMN tenant_id SET NOT NULL;
ALTER TABLE log.hr_shift_planning
    ALTER COLUMN tenant_id SET DEFAULT 1,
    ALTER COLUMN tenant_id SET NOT NULL;

-- ============ 2. the tenant in the unique keys ============
ALTER TABLE log.hr_data
    DROP CONSTRAINT uq_hr_data_log,
    ADD  CONSTRAINT uq_hr_data_log UNIQUE (tenant_id, employee_id, business_date, shift);

ALTER TABLE log.hr_shift_planning
    DROP CONSTRAINT uq_shift_planning,
    ADD  CONSTRAINT uq_shift_planning UNIQUE (tenant_id, department_group_id, business_date);

-- ============ 3. sql/log/crud_hr_data_log.sql ============
CREATE OR REPLACE FUNCTION log.crud_hr_data_log(p_param_json jsonb, p_no_results boolean DEFAULT false)
    RETURNS TABLE(track_by integer, crud text, hr_data_log_id integer, employee_id integer, department_id integer, department_group_id integer, business_date date, shift text, start_at timestamp with time zone, end_at timestamp with time zone, source text, source_ref text, ingested_at timestamp with time zone, updated_at timestamp with time zone)
    LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
BEGIN
    RETURN QUERY
    WITH el AS (
        -- the elements of the batch; the last one of a key wins, so one
        -- statement never touches a row twice
        SELECT DISTINCT ON (tenant_id, employee_id, business_date, shift)
               (e.value ->> 'track_by')::integer                  AS track_by,
               e.value ->> 'crud'                                 AS crud,
               coalesce((e.value -> 'data' ->> 'tenant_id')::integer, 1) AS tenant_id,
               (e.value -> 'data' ->> 'employee_id')::integer     AS employee_id,
               (e.value -> 'data' ->> 'department_id')::integer   AS department_id,
               (e.value -> 'data' ->> 'department_group_id')::integer AS department_group_id,
               (e.value -> 'data' ->> 'business_date')::date      AS business_date,
               e.value -> 'data' ->> 'shift'                      AS shift,
               (e.value -> 'data' ->> 'start_at')::timestamptz    AS start_at,
               (e.value -> 'data' ->> 'end_at')::timestamptz      AS end_at,
               coalesce(e.value -> 'data' ->> 'source', 'dyflexis') AS source,
               e.value -> 'data' ->> 'source_ref'                 AS source_ref
        FROM jsonb_array_elements(p_param_json) WITH ORDINALITY AS e(value, ordinality)
        ORDER BY tenant_id, employee_id, business_date, shift, e.ordinality DESC
    ),
    up AS (
        INSERT INTO log.hr_data AS h (tenant_id, employee_id, department_id, department_group_id,
                                      business_date, shift, start_at, end_at, source, source_ref)
        SELECT el.tenant_id, el.employee_id, el.department_id, el.department_group_id,
               el.business_date, el.shift, el.start_at, el.end_at, el.source, el.source_ref
        FROM el
        ON CONFLICT (tenant_id, employee_id, business_date, shift) DO UPDATE SET
            department_id       = coalesce(EXCLUDED.department_id,       h.department_id),
            department_group_id = coalesce(EXCLUDED.department_group_id, h.department_group_id),
            start_at            = coalesce(EXCLUDED.start_at,            h.start_at),
            end_at              = coalesce(EXCLUDED.end_at,              h.end_at),
            source              = EXCLUDED.source,
            source_ref          = coalesce(EXCLUDED.source_ref,          h.source_ref),
            updated_at          = now()
        RETURNING h.*
    )
    SELECT el.track_by, el.crud,
           up.hr_data_log_id, up.employee_id, up.department_id, up.department_group_id,
           up.business_date, up.shift, up.start_at, up.end_at, up.source, up.source_ref,
           up.ingested_at, up.updated_at
    FROM up
    JOIN el ON el.tenant_id = up.tenant_id AND el.employee_id = up.employee_id
           AND el.business_date = up.business_date AND el.shift = up.shift
    WHERE NOT p_no_results;
END;
$function$;

ALTER FUNCTION log.crud_hr_data_log(jsonb, boolean) OWNER TO xfw3;

-- ============ sql/log/crud_hr_shift_planning_log.sql ============
CREATE OR REPLACE FUNCTION log.crud_hr_shift_planning_log(p_param_json jsonb, p_no_results boolean DEFAULT false)
    RETURNS TABLE(track_by integer, crud text, shift_planning_id integer, department_group_id integer, business_date date, shift_json jsonb, updated_at timestamp with time zone)
    LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
BEGIN
    RETURN QUERY
    WITH el AS (
        SELECT DISTINCT ON (tenant_id, department_group_id, business_date)
               (e.value ->> 'track_by')::integer                  AS track_by,
               e.value ->> 'crud'                                 AS crud,
               coalesce((e.value -> 'data' ->> 'tenant_id')::integer, 1) AS tenant_id,
               (e.value -> 'data' ->> 'department_group_id')::integer AS department_group_id,
               (e.value -> 'data' ->> 'business_date')::date      AS business_date,
               coalesce(e.value -> 'data' -> 'shift_json', '{}'::jsonb) AS shift_json
        FROM jsonb_array_elements(p_param_json) WITH ORDINALITY AS e(value, ordinality)
        ORDER BY tenant_id, department_group_id, business_date, e.ordinality DESC
    ),
    up AS (
        INSERT INTO log.hr_shift_planning AS s (tenant_id, department_group_id, business_date, shift_json)
        SELECT el.tenant_id, el.department_group_id, el.business_date, el.shift_json
        FROM el
        ON CONFLICT (tenant_id, department_group_id, business_date) DO UPDATE SET
            shift_json = EXCLUDED.shift_json,
            updated_at = now()
        RETURNING s.*
    )
    SELECT el.track_by, el.crud,
           up.shift_planning_id, up.department_group_id, up.business_date, up.shift_json, up.updated_at
    FROM up
    JOIN el ON el.tenant_id = up.tenant_id AND el.department_group_id = up.department_group_id
           AND el.business_date = up.business_date
    WHERE NOT p_no_results;
END;
$function$;

ALTER FUNCTION log.crud_hr_shift_planning_log(jsonb, boolean) OWNER TO xfw3;

COMMIT;

-- ============ check ============
-- expected: both keys start with tenant_id, tenant_id not null with default 1, no null tenant left
SELECT conrelid::regclass AS tbl, conname, pg_get_constraintdef(oid) AS def
FROM pg_constraint
WHERE conname IN ('uq_hr_data_log', 'uq_shift_planning');

SELECT table_name, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'log' AND table_name IN ('hr_data', 'hr_shift_planning') AND column_name = 'tenant_id';

SELECT 'hr_data' AS tbl, count(*) FILTER (WHERE tenant_id IS NULL) AS tenant_null FROM log.hr_data
UNION ALL
SELECT 'hr_shift_planning', count(*) FILTER (WHERE tenant_id IS NULL) FROM log.hr_shift_planning;
