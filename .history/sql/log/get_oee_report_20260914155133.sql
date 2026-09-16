-- The OEE report (docs/plan-oee-report.md): per resource and day in view the
-- measured seconds and areas, and the results of the rule list of
-- production.formula 'oee-report' (formula_json) evaluated on them
-- (public.evaluate_many_nas), together in param_json: the inputs below plus
-- every name a rule assigns. One row per resource and day, plus
-- one aggregated row per resource over every day in view: the params summed,
-- the formulas evaluated on the sums, so every percentage is weighted.
--
-- the inputs in param_json (seconds unless said otherwise; the standard units, no unit in a key):
--   shift_duration, break_times      the shifts of the day that name the tenant of
--                                    the resource's line (action.dates.shift_json),
--                                    summed; a shift without tenants counts for all
--   has_break_times                  relation.resource.resource_json, 1 or 0; the
--                                    formula makes availability of the three
--   technical_failure                log.state_shift_agg state breakdown
--   planned, producing, plan_calibrated
--                                    log.state_shift_agg, the state of that name
--   actual_output_sqm                the producing row, sqm
--   planned_output_sqm               the planned row, sqm
--   planned_print_operator_duration  log.hr_shift_planning of the labor resource of
--                                    the resource's line (step labor): the
--                                    employees of the groups lookup_teams lists
--                                    under print-operators, their duration
--                                    (minutes) x 60
--   planned_operators                the same planning: the employee_count of the
--                                    shifts of those groups, summed (the count is
--                                    already without the absent employees)
--   operator_working_time            the working time of one operator a day, a
--                                    variable below
--   operator_cost_per_second         the cost of one print operator a second,
--                                    from the variables below
-- The last four are line values, repeated on every resource of the line: do
-- not sum them across resources. The two constants are in param_json so the
-- board can evaluate the rules itself when planned_operators is edited.
--
-- set is the kind of row: 'resource' (one per resource and day, plus its
-- aggregated row) or 'summary' (one per tenant and day, plus its aggregated
-- row: the measured params of the tenant's resources summed, the operators
-- once per line, the break time already multiplied by the flag). The summary
-- row is the card that carries the operators and their cost; its
-- resource_uid is 'tenant-<tenant_id>', its resource_path null.
-- report_key is the day as text, 'aggregated' on the aggregated row; the board
-- groups its columns on it, i18n.title (the day, or the translated word) is
-- the column title. report_date is null on the aggregated row.
--
-- The days in view: p_date and the p_workdays workdays before it (action.dates,
-- no weekends): 4 gives five day columns. p_dates, when given, replaces that
-- (the filter's multi-date-picker, later). p_steps keeps to the resources of
-- those steps (relation.resource.step), print for now.
drop function if exists log.get_oee_report(date, date, text, integer[], ltree[]);
drop function if exists log.get_oee_report(date, date, text, integer[], ltree[], datemultirange);
drop function if exists log.get_oee_report(timestamp with time zone, timestamp with time zone, text, integer[], ltree[], datemultirange);
drop function if exists log.get_oee_report(timestamp with time zone, text, integer[], ltree[], datemultirange, text[], integer);
drop function if exists log.get_oee_report(date, text, integer[], ltree[], datemultirange, text[], integer);

create function log.get_oee_report(p_date date DEFAULT (now() AT TIME ZONE 'Europe/Amsterdam')::date, p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_resource_paths ltree[] DEFAULT NULL::ltree[], p_dates datemultirange DEFAULT NULL::datemultirange, p_steps text[] DEFAULT ARRAY['print'::text], p_workdays integer DEFAULT 4)
    returns TABLE(report_date date, report_key text, i18n jsonb, tenant_id integer, tenant_name text, resource_uid text, resource_path ltree, resource_name text, set text, param_json jsonb, formula_json jsonb, sort_order integer)
    stable
    language plpgsql
as $$
#variable_conflict use_column
DECLARE
    -- the cost of a print operator: to be tuned, later a lookup
    v_operator_monthly_cost    numeric := 3500;      -- euro a month, one operator
    v_workdays_per_month       numeric := 21;
    v_operator_working_time    numeric := 8 * 3600;  -- seconds a day, one operator
    v_operator_cost_per_second numeric := round(v_operator_monthly_cost / v_workdays_per_month / v_operator_working_time, 6);
    v_dates   datemultirange := coalesce(p_dates, (
                  -- p_date and the p_workdays workdays before it
                  SELECT datemultirange(daterange(min(w.date), max(w.date), '[]'))
                  FROM (SELECT d.date
                        FROM action.dates d
                        WHERE d.date <= p_date
                          AND d.is_weekend = false
                        ORDER BY d.date DESC
                        LIMIT greatest(p_workdays, 0) + 1) w));
    v_formula jsonb;
    v_langs   text[] := array['nl', 'en', 'de', 'fr', 'es', 'uk'];
    v_aggregated_i18n jsonb := jsonb_build_object(
        'nl', jsonb_build_object('title', 'totaal'),
        'en', jsonb_build_object('title', 'aggregated'),
        'de', jsonb_build_object('title', 'gesamt'),
        'fr', jsonb_build_object('title', 'total'),
        'es', jsonb_build_object('title', 'total'),
        'uk', jsonb_build_object('title', 'разом'));
BEGIN
    SELECT gf.formula_json INTO v_formula
    FROM production.get_formula(array['oee-report']) gf;
    v_formula := coalesce(v_formula, '[]'::jsonb);

    RETURN QUERY
    WITH day AS (
        -- the workdays in view (a weekend day only through p_dates)
        SELECT d.date
        FROM action.dates d
        WHERE d.date <@ v_dates
          AND (p_dates IS NOT NULL OR d.is_weekend = false)
    ),
    res AS (
        -- the resources in view: a path, a line, and the tenant of that line
        SELECT r.resource_uid, r.resource_path, r.resource_name, r.line_id,
               pl.tenant_id,
               coalesce((r.resource_json ->> 'has_break_times')::numeric, 0) AS has_break_times
        FROM relation.resource r
        JOIN relation.production_line pl ON pl.line_id = r.line_id
        WHERE r.resource_path IS NOT NULL
          AND nlevel(r.resource_path) >= 3
          AND (p_steps IS NULL OR r.step = any (p_steps))
          AND (p_line_type IS NULL OR pl.line_type = p_line_type)
          AND (p_tenant_ids IS NULL OR pl.tenant_id = any (p_tenant_ids))
          AND (p_resource_paths IS NULL OR r.resource_path <@ any (p_resource_paths))
    ),
    tenant AS (
        SELECT (t.value ->> 'tenant_id')::integer AS tenant_id, t.value ->> 'name' AS tenant_name
        FROM relation.lookup lk
        CROSS JOIN LATERAL jsonb_array_elements(lk.lookup_json) AS t(value)
        WHERE lk.lookup = 'lookup_tenants'
    ),
    -- the shifts of a day that a resource works: the ones naming its tenant,
    -- or every shift when the shift names no tenant
    shifts AS (
        SELECT d.date, r.resource_uid,
               sum((sh.value ->> 'shift_duration')::numeric)             AS shift_duration,
               sum(coalesce((sh.value ->> 'break_times')::numeric, 0)) AS break_times
        FROM day d
        JOIN action.dates ad ON ad.date = d.date
        CROSS JOIN LATERAL jsonb_array_elements(coalesce(ad.shift_json, '[]'::jsonb)) AS sh(value)
        JOIN res r ON (jsonb_array_length(coalesce(sh.value -> 'tenants', '[]'::jsonb)) = 0
                    OR sh.value -> 'tenants' @> to_jsonb(r.tenant_id))
        GROUP BY d.date, r.resource_uid
    ),
    -- the measured seconds and areas of the day, from the shift aggregate
    measured AS (
        SELECT a.shift_date AS date, a.resource_uid,
               sum(a.duration_seconds)     FILTER (WHERE a.state = 'breakdown')       AS technical_failure,
               sum(a.duration_seconds)     FILTER (WHERE a.state = 'planned')         AS planned,
               sum(a.duration_seconds)     FILTER (WHERE a.state = 'producing')       AS producing,
               sum(a.duration_seconds)     FILTER (WHERE a.state = 'plan_calibrated') AS plan_calibrated,
               sum(a.actual_output_sqm)    FILTER (WHERE a.state = 'producing')       AS actual_output_sqm,
               sum(a.planned_output_sqm)   FILTER (WHERE a.state = 'planned')         AS planned_output_sqm
        FROM log.state_shift_agg a
        JOIN res r ON r.resource_uid = a.resource_uid
        WHERE a.shift_date <@ v_dates
        GROUP BY a.shift_date, a.resource_uid
    ),
    -- the print operators planned on a line per day: the HR planning of the
    -- labor resource of the line, the groups of the print-operators team
    operator_group AS (
        SELECT c.value #>> '{}' AS group_code
        FROM relation.lookup lk
        CROSS JOIN LATERAL jsonb_array_elements(lk.lookup_json) AS t(value)
        CROSS JOIN LATERAL jsonb_array_elements(t.value -> 'codes') AS c(value)
        WHERE lk.lookup = 'lookup_teams' AND t.value ->> 'code' = 'print-operators'
    ),
    labor AS (
        SELECT lr.line_id, lr.resource_uid
        FROM relation.resource lr
        WHERE lr.step = 'labor'
          AND lr.line_id IN (SELECT DISTINCT line_id FROM res)
    ),
    operators AS (
        SELECT sp.business_date AS date, l.line_id,
               -- the planned minutes of the employees x 60, and the headcount of
               -- the shifts (employee_count is already without the absent ones)
               sum((SELECT sum((e.value ->> 'duration')::numeric)
                    FROM jsonb_array_elements(coalesce(g.value -> 'employees', '[]'::jsonb)) AS e(value))) * 60 AS planned_print_operator_duration,
               sum((SELECT sum((s.value ->> 'employee_count')::numeric)
                    FROM jsonb_array_elements(coalesce(g.value -> 'shifts', '[]'::jsonb)) AS s(value)))         AS planned_operators
        FROM log.hr_shift_planning sp
        JOIN labor l ON l.resource_uid = sp.shift_json ->> 'resource_uid'
        CROSS JOIN LATERAL jsonb_array_elements(coalesce(sp.shift_json -> 'plan' -> 'groups', '[]'::jsonb)) AS g(value)
        WHERE sp.business_date <@ v_dates
          AND public.to_kebab(g.value ->> 'group') IN (SELECT group_code FROM operator_group)
        GROUP BY sp.business_date, l.line_id
    ),
    -- one row per resource and day, every input present (the evaluator
    -- raises on a missing variable)
    per_day AS (
        SELECT d.date, r.resource_uid,
               jsonb_build_object(
                   'shift_duration',                  coalesce(sh.shift_duration, 0),
                   'break_times',                     coalesce(sh.break_times, 0),
                   'has_break_times',                 r.has_break_times,
                   'technical_failure',               coalesce(m.technical_failure, 0),
                   'planned',                         coalesce(m.planned, 0),
                   'producing',                       coalesce(m.producing, 0),
                   'plan_calibrated',                 coalesce(m.plan_calibrated, 0),
                   'actual_output_sqm',               coalesce(m.actual_output_sqm, 0),
                   'planned_output_sqm',              coalesce(m.planned_output_sqm, 0),
                   'planned_print_operator_duration', coalesce(o.planned_print_operator_duration, 0),
                   'planned_operators',               coalesce(o.planned_operators, 0),
                   'operator_working_time',           v_operator_working_time,
                   'operator_cost_per_second',        v_operator_cost_per_second) AS param_json
        FROM day d
        CROSS JOIN res r
        LEFT JOIN shifts sh       ON sh.date = d.date AND sh.resource_uid = r.resource_uid
        LEFT JOIN measured m      ON m.date = d.date  AND m.resource_uid = r.resource_uid
        LEFT JOIN operators o     ON o.date = d.date  AND o.line_id = r.line_id
    ),
    -- the aggregated row per resource: every param summed over the days
    -- (planned_operators becomes operator-days), the flag and the constants
    -- as they are
    aggregated AS (
        SELECT p.resource_uid,
               jsonb_build_object(
                   'shift_duration',                  sum((p.param_json ->> 'shift_duration')::numeric),
                   'break_times',                     sum((p.param_json ->> 'break_times')::numeric),
                   'has_break_times',                 max((p.param_json ->> 'has_break_times')::numeric),
                   'technical_failure',               sum((p.param_json ->> 'technical_failure')::numeric),
                   'planned',                         sum((p.param_json ->> 'planned')::numeric),
                   'producing',                       sum((p.param_json ->> 'producing')::numeric),
                   'plan_calibrated',                 sum((p.param_json ->> 'plan_calibrated')::numeric),
                   'actual_output_sqm',               sum((p.param_json ->> 'actual_output_sqm')::numeric),
                   'planned_output_sqm',              sum((p.param_json ->> 'planned_output_sqm')::numeric),
                   'planned_print_operator_duration', sum((p.param_json ->> 'planned_print_operator_duration')::numeric),
                   'planned_operators',               sum((p.param_json ->> 'planned_operators')::numeric),
                   'operator_working_time',           v_operator_working_time,
                   'operator_cost_per_second',        v_operator_cost_per_second) AS param_json
        FROM per_day p
        GROUP BY p.resource_uid
    ),
    -- the operators once per line, summed per tenant and day
    tenant_operators AS (
        SELECT o.date, l.tenant_id,
               sum(o.planned_print_operator_duration) AS planned_print_operator_duration,
               sum(o.planned_operators)               AS planned_operators
        FROM operators o
        JOIN (SELECT DISTINCT line_id, tenant_id FROM res) l ON l.line_id = o.line_id
        GROUP BY o.date, l.tenant_id
    ),
    -- the summary per tenant and day: the measured params of its resources
    -- summed; the break time is multiplied by the flag here, so the flag is 1
    tenant_day AS (
        SELECT p.date, r.tenant_id,
               jsonb_build_object(
                   'shift_duration',                  sum((p.param_json ->> 'shift_duration')::numeric),
                   'break_times',                     sum((p.param_json ->> 'has_break_times')::numeric * (p.param_json ->> 'break_times')::numeric),
                   'has_break_times',                 1,
                   'technical_failure',               sum((p.param_json ->> 'technical_failure')::numeric),
                   'planned',                         sum((p.param_json ->> 'planned')::numeric),
                   'producing',                       sum((p.param_json ->> 'producing')::numeric),
                   'plan_calibrated',                 sum((p.param_json ->> 'plan_calibrated')::numeric),
                   'actual_output_sqm',               sum((p.param_json ->> 'actual_output_sqm')::numeric),
                   'planned_output_sqm',              sum((p.param_json ->> 'planned_output_sqm')::numeric),
                   'planned_print_operator_duration', coalesce(max(o.planned_print_operator_duration), 0),
                   'planned_operators',               coalesce(max(o.planned_operators), 0),
                   'operator_working_time',           v_operator_working_time,
                   'operator_cost_per_second',        v_operator_cost_per_second) AS param_json
        FROM per_day p
        JOIN res r ON r.resource_uid = p.resource_uid
        LEFT JOIN tenant_operators o ON o.date = p.date AND o.tenant_id = r.tenant_id
        GROUP BY p.date, r.tenant_id
    ),
    -- the summary per tenant over the days
    tenant_aggregated AS (
        SELECT td.tenant_id,
               jsonb_build_object(
                   'shift_duration',                  sum((td.param_json ->> 'shift_duration')::numeric),
                   'break_times',                     sum((td.param_json ->> 'break_times')::numeric),
                   'has_break_times',                 1,
                   'technical_failure',               sum((td.param_json ->> 'technical_failure')::numeric),
                   'planned',                         sum((td.param_json ->> 'planned')::numeric),
                   'producing',                       sum((td.param_json ->> 'producing')::numeric),
                   'plan_calibrated',                 sum((td.param_json ->> 'plan_calibrated')::numeric),
                   'actual_output_sqm',               sum((td.param_json ->> 'actual_output_sqm')::numeric),
                   'planned_output_sqm',              sum((td.param_json ->> 'planned_output_sqm')::numeric),
                   'planned_print_operator_duration', sum((td.param_json ->> 'planned_print_operator_duration')::numeric),
                   'planned_operators',               sum((td.param_json ->> 'planned_operators')::numeric),
                   'operator_working_time',           v_operator_working_time,
                   'operator_cost_per_second',        v_operator_cost_per_second) AS param_json
        FROM tenant_day td
        GROUP BY td.tenant_id
    ),
    day_i18n AS (
        SELECT d.date, (SELECT jsonb_object_agg(l, jsonb_build_object('title', d.date::text)) FROM unnest(v_langs) l) AS i18n
        FROM day d
    ),
    -- the rows: a resource per day and aggregated, a tenant summary per day and aggregated
    rows_out AS (
        SELECT p.date, p.date::text AS report_key, di.i18n, r.tenant_id,
               r.resource_uid, r.resource_path, r.resource_name, 'resource' AS set, p.param_json, 0 AS sort_order
        FROM per_day p
        JOIN res r ON r.resource_uid = p.resource_uid
        JOIN day_i18n di ON di.date = p.date
        UNION ALL
        SELECT NULL, 'aggregated', v_aggregated_i18n, r.tenant_id,
               r.resource_uid, r.resource_path, r.resource_name, 'resource', a.param_json, 1
        FROM aggregated a
        JOIN res r ON r.resource_uid = a.resource_uid
        UNION ALL
        SELECT td.date, td.date::text, di.i18n, td.tenant_id,
               'tenant-' || td.tenant_id, NULL, t.tenant_name, 'summary', td.param_json, 0
        FROM tenant_day td
        JOIN day_i18n di ON di.date = td.date
        LEFT JOIN tenant t ON t.tenant_id = td.tenant_id
        UNION ALL
        SELECT NULL, 'aggregated', v_aggregated_i18n, ta.tenant_id,
               'tenant-' || ta.tenant_id, NULL, t.tenant_name, 'summary', ta.param_json, 1
        FROM tenant_aggregated ta
        LEFT JOIN tenant t ON t.tenant_id = ta.tenant_id
    )
    SELECT o.date, o.report_key, o.i18n,
           o.tenant_id, t.tenant_name,
           o.resource_uid, o.resource_path, o.resource_name, o.set,
           public.evaluate_many_nas(v_formula, o.param_json),
           v_formula,
           o.sort_order
    FROM rows_out o
    LEFT JOIN tenant t ON t.tenant_id = o.tenant_id
    ORDER BY o.tenant_id, (o.set = 'summary'), o.resource_path, o.sort_order, o.date;
END;
$$;

alter function log.get_oee_report(date, text, integer[], ltree[], datemultirange, text[], integer) owner to xfw3;
