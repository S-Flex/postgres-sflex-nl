-- Rollback of sql/update_shift_employees_line.sql: the three functions as before
-- (model and until), the lookup nav and the data_group params as before. The page
-- and menu rename in json/data are reverted by hand (git).
BEGIN;

DROP FUNCTION IF EXISTS legacy.get_resource_shift_employees(integer, date);
DROP FUNCTION IF EXISTS mapping.get_status_bar_teams(integer, date);

create function legacy.get_resource_shift_employees(p_model text, p_until timestamp with time zone) returns TABLE(shift_planning_id integer, shift_type text, content jsonb, department_group_id integer, start_at timestamp with time zone, group_name text, employee_id integer, personnel_number text, first_name text, infix text, last_name text, contract_type text)
	stable
	language sql
as $$
WITH matching_resources AS (
    -- Resources that belong to the requested production line model
    SELECT r.resource_uid
    FROM relation.resource r
    JOIN relation.production_line pl ON pl.line_id = r.line_id
    WHERE pl.model = p_model
),
plans AS (
    -- Shift planning for the business date of p_until (Amsterdam time)
    SELECT
        sp.shift_planning_id,
        sp.department_group_id,
        sp.business_date,
        (sp.shift_json->>'start_at')::timestamptz AS start_at,
        sp.shift_json
    FROM log.hr_shift_planning sp
    JOIN matching_resources mr ON mr.resource_uid = sp.shift_json->>'resource_uid'
    WHERE sp.business_date = (p_until AT TIME ZONE 'Europe/Amsterdam')::date
),
shift_lookup AS (
    SELECT item->>'code' AS code, item->'block'->'i18n' AS block
    FROM legacy.lookup lu
    CROSS JOIN LATERAL jsonb_array_elements(lu.lookup_json) AS item
    WHERE lu.lookup = 'lookup_shift'
)
SELECT DISTINCT
    p.shift_planning_id,
    hd.shift                        AS shift_type,
    sl.block                        AS content,
    p.department_group_id,
    p.start_at,
    grp->>'group'                   AS group_name,
    (emp->>'employee_id')::integer  AS employee_id,
    emp->>'personnel_number'        AS personnel_number,
    emp->>'first_name'              AS first_name,
    NULLIF(emp->>'infix', '')       AS infix,
    emp->>'last_name'               AS last_name,
    emp->>'contract_type'           AS contract_type
FROM plans p
CROSS JOIN LATERAL jsonb_array_elements(p.shift_json->'plan'->'groups') AS grp
CROSS JOIN LATERAL jsonb_array_elements(grp->'employees')               AS emp
-- Shift type (day/night) comes from the clock data, per employee per business date
LEFT JOIN LATERAL (
    SELECT h.shift
    FROM log.hr_data h
    WHERE h.employee_id = (emp->>'employee_id')::integer
      AND h.business_date = p.business_date
    ORDER BY h.start_at DESC
    LIMIT 1
) hd ON true
LEFT JOIN shift_lookup sl ON sl.code = hd.shift
ORDER BY p.department_group_id, group_name, last_name, first_name;
$$;

alter function legacy.get_resource_shift_employees(text, timestamp with time zone) owner to xfw3;

create function mapping.get_status_bar_teams(p_model text, p_until timestamp with time zone) returns jsonb
	stable
	language plpgsql
as $$
BEGIN
    RETURN (
        WITH shift AS (
            SELECT group_name, COUNT(employee_id)::integer AS amount, start_at
            FROM legacy.get_resource_shift_employees(p_model, COALESCE(p_until, now()))
            GROUP BY shift_type, start_at, group_name
        ),
        latest AS (
            SELECT DISTINCT ON (group_name) group_name, amount
            FROM shift
            ORDER BY group_name, start_at DESC
        ),
        teams AS (
            SELECT
                grp->>'code'  AS code,
                grp->'i18n'   AS i18n,
                grp->>'order' AS order_key,
                COALESCE(SUM(l.amount), 0)::integer AS value
            FROM relation.lookup rl
            CROSS JOIN jsonb_array_elements(rl.lookup_json) AS grp
            LEFT JOIN latest l
                ON grp->'codes' @> to_jsonb(public.to_kebab(l.group_name))
            WHERE rl.lookup = 'lookup_teams'
            GROUP BY grp->>'code', grp->'i18n', grp->>'order'
        )
        SELECT COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'code', code,
                    'i18n', i18n,
                    'value', value
                ) ORDER BY order_key
            ),
            '[]'::jsonb
        )
        FROM teams
    );
END;
$$;

alter function mapping.get_status_bar_teams(text, timestamp with time zone) owner to xfw3;

create or replace function mapping.get_status_bar(p_model text DEFAULT NULL::text, p_until timestamp with time zone DEFAULT (CURRENT_DATE)::timestamp with time zone, p_production_line_id integer DEFAULT NULL::integer) returns TABLE(status_json jsonb)
	language plpgsql
as $$
#variable_conflict use_column
DECLARE
    v_line       record;
    v_teams      jsonb;
    v_bar_config jsonb;
BEGIN
    SELECT rl.lookup_json INTO v_bar_config
    FROM legacy.lookup rl
    WHERE rl.lookup = 'status_bar';

    v_teams := mapping.get_status_bar_teams(p_model, p_until);

    FOR v_line IN
        SELECT pl.line_id, pl.line AS line_name
        FROM relation.production_line pl
        WHERE (p_production_line_id IS NOT NULL AND pl.line_id = p_production_line_id)
           OR (p_production_line_id IS NULL AND p_model IS NOT NULL AND pl.model = p_model)
        ORDER BY pl.line
    LOOP
        status_json := jsonb_build_object(
            'production_line_id',   v_line.line_id,
            'production_line_name', v_line.line_name,
            'items', (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'code', grp->>'code',
                        'i18n', grp->'i18n',
                        'nav',  grp->'nav',
                        'data', CASE grp->>'src'
                            WHEN 'teams'          THEN v_teams
                            WHEN 'time_on_status' THEN mapping.get_status_bar_time_on_status(p_model, p_until, v_line.line_id)
                            WHEN 'capacity'       THEN mapping.get_status_bar_capacity(p_model, p_until, v_line.line_id, grp->'steps')
                            WHEN 'rework'         THEN mapping.get_status_bar_rework(v_line.line_id)
                            WHEN 'file_inflow'    THEN mapping.get_status_bar_file_inflow(v_line.line_id)
                            WHEN 'nests'          THEN mapping.get_status_bar_nests(v_line.line_id)
                            WHEN 'oee'            THEN mapping.get_status_bar_oee(p_model, p_until, v_line.line_id, grp->'items')
                        END
                    )
                )
                FROM jsonb_array_elements(v_bar_config) AS grp
            )
        );
        RETURN NEXT;
    END LOOP;
END;
$$;

alter function mapping.get_status_bar(text, timestamp with time zone, integer) owner to xfw3;

UPDATE site.data_group
SET data_group_json = replace(data_group_json::text, '(sidebar:production-planning-info)', '(sidebar:oee)')::jsonb
WHERE data_group_json::text LIKE '%(sidebar:production-planning-info)%';

COMMIT;
-- the lookup nav (model, until) and the data_group params (model, until): restore
-- json/lookup/legacy/status_bar.json and json/data_group/resource_shift_employees.json
-- from git and rerun the two UPDATE statements of the up script with those files.
