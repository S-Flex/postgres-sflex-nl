-- OEE report (docs/plan-oee-report.md, 13 Sep 2026), step 1 of the plan:
--   0. relation.resource.resource_json.has_break_times: true/false becomes 1/0,
--      so the flag can be a variable in the formula (88 resources carry it).
--   1. production.formula 'oee-report': the rule list the report evaluates
--      per resource and day and on the aggregated row (evaluate_many_nas);
--      the results land in param_json next to the inputs, no separate result column.
--      Inputs are the keys of param_json; every ratio is guarded against a
--      zero denominator; percentages end in _percentage and are x 100.
--   2. log.get_oee_report: the params, the formulas and the result per print
--      machine, for p_date and the 4 workdays before, plus one aggregated row
--      per machine. Since 14 Sep: planned_operators (the headcount of the
--      print-operator shifts of the line), operator_working_time and
--      operator_cost_per_second (variables in the function) in param_json.
--   3. site.data_table get_oee_report.
-- Needs production.formula (update_schedule_01c_schedule_formula.sql) and
-- the plan_calibrated rows (update_plan_calibrated.sql).
-- Rollback: sql/update_oee_report_down.sql.
BEGIN;

-- ============ relation.resource: has_break_times as 1 / 0 ============
UPDATE relation.resource r
SET resource_json = jsonb_set(r.resource_json, '{has_break_times}',
                              CASE WHEN (r.resource_json ->> 'has_break_times')::boolean THEN '1'::jsonb ELSE '0'::jsonb END)
WHERE r.resource_json ? 'has_break_times'
  AND jsonb_typeof(r.resource_json -> 'has_break_times') = 'boolean';

-- ============ production.formula: oee-report ============
INSERT INTO production.formula (formula_code, formula_json, formula_level, version, version_status)
VALUES ('oee-report', $json$[
  "availability = shift_duration - has_break_times * break_times",
  "technical_failure_percentage = availability > 0 ? technical_failure / availability * 100 : 0",
  "technical_availability = availability - technical_failure",
  "technical_availability_percentage = availability > 0 ? technical_availability / availability * 100 : 0",
  "not_planned = technical_availability - planned",
  "not_planned_percentage = technical_availability > 0 ? not_planned / technical_availability * 100 : 0",
  "not_planned_calibrated = technical_availability - plan_calibrated",
  "producing_oee_planned_percentage = planned > 0 ? producing / planned * 100 : 0",
  "producing_oee_plan_calibrated_percentage = plan_calibrated > 0 ? producing / plan_calibrated * 100 : 0",
  "output_per_planned_hour = planned > 0 ? actual_output_sqm / (planned / 3600) : 0",
  "actual_output_per_hour = producing > 0 ? actual_output_sqm / (producing / 3600) : 0",
  "overcapacity = not_planned / 3600 * period_output_per_planned_hour",
  "planned_operator_duration = planned_operators * operator_working_time",
  "planned_operator_cost = planned_operator_duration * operator_cost_per_second",
  "operator_cost_per_sqm = actual_output_sqm > 0 ? planned_operator_cost / actual_output_sqm : 0",
  "output_per_operator = planned_operators > 0 ? actual_output_sqm / planned_operators : 0",
  "planned_printers_per_operator = planned_operators > 0 ? planned / (operator_working_time * planned_operators) : 0"
]$json$::jsonb, 0, 1, 'active')
ON CONFLICT (formula_code, version) DO UPDATE
    SET formula_json   = EXCLUDED.formula_json,
        formula_level  = EXCLUDED.formula_level,
        version_status = EXCLUDED.version_status;

-- ============ sql/log/get_oee_report.sql ============
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
--   period_output_per_planned_hour   the resource's output per planned hour over
--                                    every day in view (the sheet's total column);
--                                    the overcapacity rule prices the not-planned
--                                    hours of every day at it. On a summary row
--                                    the resources' overcapacity over their
--                                    not-planned hours, so the tenant's
--                                    overcapacity is the sum of its resources'
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
    v_operator_cost_per_second numeric := v_operator_monthly_cost / v_workdays_per_month / v_operator_working_time;
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
        'nl', jsonb_build_object('title', 'Totaal'),
        'en', jsonb_build_object('title', 'Aggregated'),
        'de', jsonb_build_object('title', 'Gesamt'),
        'fr', jsonb_build_object('title', 'Total'),
        'es', jsonb_build_object('title', 'Total'),
        'uk', jsonb_build_object('title', 'Разом'));
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
    -- the inputs per resource and day as numbers, every input present; not
    -- planned as the rule defines it (technical availability minus planned),
    -- needed here only to weight the rate of the summary rows
    base AS (
        SELECT d.date, r.resource_uid, r.resource_path, r.resource_name, r.tenant_id,
               coalesce(sh.shift_duration, 0)                 AS shift_duration,
               coalesce(sh.break_times, 0)                    AS break_times,
               r.has_break_times,
               coalesce(m.technical_failure, 0)               AS technical_failure,
               coalesce(m.planned, 0)                         AS planned,
               coalesce(m.producing, 0)                       AS producing,
               coalesce(m.plan_calibrated, 0)                 AS plan_calibrated,
               coalesce(m.actual_output_sqm, 0)               AS actual_output_sqm,
               coalesce(m.planned_output_sqm, 0)              AS planned_output_sqm,
               coalesce(o.planned_print_operator_duration, 0) AS planned_print_operator_duration,
               coalesce(o.planned_operators, 0)               AS planned_operators,
               coalesce(sh.shift_duration, 0) - r.has_break_times * coalesce(sh.break_times, 0)
                 - coalesce(m.technical_failure, 0) - coalesce(m.planned, 0) AS not_planned
        FROM day d
        CROSS JOIN res r
        LEFT JOIN shifts sh   ON sh.date = d.date AND sh.resource_uid = r.resource_uid
        LEFT JOIN measured m  ON m.date = d.date  AND m.resource_uid = r.resource_uid
        LEFT JOIN operators o ON o.date = d.date  AND o.line_id = r.line_id
    ),
    -- the output per planned hour of a resource over the whole period (the
    -- sheet's total column): every day of that resource prices its not-planned
    -- hours at this rate
    period_rate AS (
        SELECT b.resource_uid,
               CASE WHEN sum(b.planned) > 0 THEN sum(b.actual_output_sqm) / (sum(b.planned) / 3600) ELSE 0 END AS rate
        FROM base b
        GROUP BY b.resource_uid
    ),
    per_day AS (
        SELECT b.*, pr.rate,
               b.not_planned / 3600 * pr.rate AS overcapacity
        FROM base b
        JOIN period_rate pr ON pr.resource_uid = b.resource_uid
    ),
    -- the operators once per line, summed per tenant and day, and over the period
    tenant_operators AS (
        SELECT o.date, l.tenant_id,
               sum(o.planned_print_operator_duration) AS planned_print_operator_duration,
               sum(o.planned_operators)               AS planned_operators
        FROM operators o
        JOIN (SELECT DISTINCT line_id, tenant_id FROM res) l ON l.line_id = o.line_id
        GROUP BY o.date, l.tenant_id
    ),
    tenant_operators_period AS (
        SELECT t.tenant_id,
               sum(t.planned_print_operator_duration) AS planned_print_operator_duration,
               sum(t.planned_operators)               AS planned_operators
        FROM tenant_operators t
        GROUP BY t.tenant_id
    ),
    -- the four kinds of row as numbers: a resource per day and over the period,
    -- a tenant summary per day and over the period. A summary sums the inputs
    -- of the tenant's resources, multiplies the break time by the flag (flag 1),
    -- takes the operators once per line, and prices its not-planned hours at
    -- the overcapacity of its resources over their not-planned hours, so the
    -- tenant's overcapacity is the sum of its resources' (the sheet's total block)
    numbers AS (
        SELECT p.date, p.date::text AS report_key, 0 AS sort_order, 'resource' AS set,
               p.tenant_id, p.resource_uid, p.resource_path, p.resource_name,
               p.shift_duration, p.break_times, p.has_break_times, p.technical_failure,
               p.planned, p.producing, p.plan_calibrated, p.actual_output_sqm, p.planned_output_sqm,
               p.planned_print_operator_duration, p.planned_operators, p.rate
        FROM per_day p
        UNION ALL
        SELECT NULL, 'aggregated', 1, 'resource',
               p.tenant_id, p.resource_uid, p.resource_path, p.resource_name,
               sum(p.shift_duration), sum(p.break_times), max(p.has_break_times), sum(p.technical_failure),
               sum(p.planned), sum(p.producing), sum(p.plan_calibrated), sum(p.actual_output_sqm), sum(p.planned_output_sqm),
               sum(p.planned_print_operator_duration), sum(p.planned_operators), max(p.rate)
        FROM per_day p
        GROUP BY p.tenant_id, p.resource_uid, p.resource_path, p.resource_name
        UNION ALL
        SELECT p.date, p.date::text, 0, 'summary',
               p.tenant_id, 'tenant-' || p.tenant_id, NULL, t.tenant_name,
               sum(p.shift_duration), sum(p.has_break_times * p.break_times), 1, sum(p.technical_failure),
               sum(p.planned), sum(p.producing), sum(p.plan_calibrated), sum(p.actual_output_sqm), sum(p.planned_output_sqm),
               coalesce(max(o.planned_print_operator_duration), 0), coalesce(max(o.planned_operators), 0),
               CASE WHEN sum(p.not_planned) <> 0 THEN sum(p.overcapacity) / (sum(p.not_planned) / 3600) ELSE 0 END
        FROM per_day p
        LEFT JOIN tenant_operators o ON o.date = p.date AND o.tenant_id = p.tenant_id
        LEFT JOIN tenant t ON t.tenant_id = p.tenant_id
        GROUP BY p.date, p.tenant_id, t.tenant_name
        UNION ALL
        SELECT NULL, 'aggregated', 1, 'summary',
               p.tenant_id, 'tenant-' || p.tenant_id, NULL, t.tenant_name,
               sum(p.shift_duration), sum(p.has_break_times * p.break_times), 1, sum(p.technical_failure),
               sum(p.planned), sum(p.producing), sum(p.plan_calibrated), sum(p.actual_output_sqm), sum(p.planned_output_sqm),
               coalesce(max(o.planned_print_operator_duration), 0), coalesce(max(o.planned_operators), 0),
               CASE WHEN sum(p.not_planned) <> 0 THEN sum(p.overcapacity) / (sum(p.not_planned) / 3600) ELSE 0 END
        FROM per_day p
        LEFT JOIN tenant_operators_period o ON o.tenant_id = p.tenant_id
        LEFT JOIN tenant t ON t.tenant_id = p.tenant_id
        GROUP BY p.tenant_id, t.tenant_name
    ),
    day_i18n AS (
        SELECT d.date, (SELECT jsonb_object_agg(l, jsonb_build_object('title', d.date::text)) FROM unnest(v_langs) l) AS i18n
        FROM day d
    )
    SELECT n.date, n.report_key,
           CASE WHEN n.sort_order = 1 THEN v_aggregated_i18n ELSE di.i18n END,
           n.tenant_id, t.tenant_name,
           n.resource_uid, n.resource_path, n.resource_name, n.set,
           public.evaluate_many_nas(v_formula, jsonb_build_object(
               'shift_duration',                  n.shift_duration,
               'break_times',                     n.break_times,
               'has_break_times',                 n.has_break_times,
               'technical_failure',               n.technical_failure,
               'planned',                         n.planned,
               'producing',                       n.producing,
               'plan_calibrated',                 n.plan_calibrated,
               'actual_output_sqm',               n.actual_output_sqm,
               'planned_output_sqm',              n.planned_output_sqm,
               'planned_print_operator_duration', n.planned_print_operator_duration,
               'planned_operators',               n.planned_operators,
               'operator_working_time',           v_operator_working_time,
               'operator_cost_per_second',        v_operator_cost_per_second,
               'period_output_per_planned_hour',  n.rate)),
           v_formula,
           n.sort_order
    FROM numbers n
    LEFT JOIN day_i18n di ON di.date = n.date
    LEFT JOIN tenant t ON t.tenant_id = n.tenant_id
    ORDER BY n.tenant_id, (n.set = 'summary'), n.resource_path, n.sort_order, n.date;
END;
$$;

alter function log.get_oee_report(date, text, integer[], ltree[], datemultirange, text[], integer) owner to xfw3;

-- ============ site.data_table ============
INSERT INTO site.data_table (data_table, query, stored_proc, description, data_table_json, do_cache)
VALUES ('get_oee_report', 'log.get_oee_report', '',
        'the OEE report: per resource and day in view the measured inputs and the evaluated rule results together (param_json), the rules (formula_json), plus one aggregated row per resource',
        '{"primary_keys": ["resource_uid", "report_key"]}'::jsonb, false)
ON CONFLICT (data_table) DO UPDATE
    SET query           = EXCLUDED.query,
        description     = EXCLUDED.description,
        data_table_json = EXCLUDED.data_table_json;

COMMIT;

-- ============ check ============
-- expected: one active oee-report row with 17 rules
SELECT formula_code, version, version_status, jsonb_array_length(formula_json) AS rules
FROM production.get_formula(array['oee-report']);

-- expected: the printers of dk.sheet, yesterday and the 4 workdays before, plus one aggregated row each;
-- planned_operators 8 on 2026-09-14 for the Plaat line (day 4 + evening 3 + night 1), operator_cost_per_sqm > 0 where output > 0;
-- one summary row per tenant and day (set summary, resource_uid tenant-<id>) with the sums of its resources;
-- the summary's overcapacity equals the sum of the overcapacity of its resources in that column;
-- availability > 0 on working days, technical_availability_percentage between 0 and 100
SELECT r.report_date, r.report_key, r.set, r.tenant_name, r.resource_path,
       r.param_json ->> 'availability' AS availability,
       r.param_json ->> 'producing'    AS producing,
       r.param_json ->> 'technical_availability_percentage' AS technical_availability_percentage,
       r.param_json ->> 'producing_oee_planned_percentage'  AS producing_oee_planned_percentage,
       r.param_json ->> 'not_planned' AS not_planned,
       round((r.param_json ->> 'output_per_planned_hour')::numeric, 1) AS output_per_planned_hour,
       round((r.param_json ->> 'overcapacity')::numeric, 0) AS overcapacity,
       r.param_json ->> 'planned_operators'  AS planned_operators,
       r.param_json ->> 'planned_operator_cost' AS planned_operator_cost,
       r.param_json ->> 'operator_cost_per_sqm' AS operator_cost_per_sqm
FROM log.get_oee_report(p_date := current_date - 1) r
WHERE (r.resource_path <@ 'dk.sheet.print'::ltree OR r.set = 'summary')
ORDER BY r.tenant_id, (r.set = 'summary'), r.resource_path, r.sort_order, r.report_date
LIMIT 40;
