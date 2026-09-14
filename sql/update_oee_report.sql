-- OEE report (docs/plan-oee-report.md, 13 Sep 2026), step 1 of the plan:
--   0. relation.resource.resource_json.has_break_times: true/false becomes 1/0,
--      so the flag can be a variable in the formula (88 resources carry it).
--   1. production.formula 'oee-report': the rule list the report evaluates
--      per resource and day and on the aggregated row (evaluate_many_nas).
--      Inputs are the keys of param_json; every ratio is guarded against a
--      zero denominator; percentages end in _percentage and are x 100.
--   2. log.get_oee_report: the params, the formulas and the result per
--      resource and day in view, plus one aggregated row per resource.
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
  "not_planned = availability - planned",
  "not_planned_percentage = availability > 0 ? not_planned / availability * 100 : 0",
  "not_planned_calibrated = availability - plan_calibrated",
  "producing_oee_planned_percentage = planned > 0 ? producing / planned * 100 : 0",
  "producing_oee_plan_calibrated_percentage = plan_calibrated > 0 ? producing / plan_calibrated * 100 : 0",
  "actual_output_per_second = producing > 0 ? actual_output_sqm / producing : 0",
  "overcapacity = (technical_availability - producing) * actual_output_per_second"
]$json$::jsonb, 0, 1, 'active')
ON CONFLICT (formula_code, version) DO UPDATE
    SET formula_json   = EXCLUDED.formula_json,
        formula_level  = EXCLUDED.formula_level,
        version_status = EXCLUDED.version_status;

-- ============ sql/log/get_oee_report.sql ============
-- The OEE report (docs/plan-oee-report.md): per resource and day in view the
-- measured seconds and areas as param_json, the rule list of
-- production.formula 'oee-report' as formula_json, and the evaluated result
-- as oee_json (public.evaluate_many_nas). One row per resource and day, plus
-- one aggregated row per resource over every day in view: the params summed,
-- the formulas evaluated on the sums, so every percentage is weighted.
--
-- param_json (seconds unless said otherwise; the standard units, no unit in a key):
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
--   planned_print_operator_duration  log.hr_shift_planning of the department
--                                    resources of the resource's line: the
--                                    employees of the groups lookup_teams lists
--                                    under print-operators, their duration
--                                    (minutes) x 60. A line value, repeated on
--                                    every resource of the line: do not sum it
--                                    across resources
--
-- i18n.title is the day as text, 'aggregated' (translated) on the aggregated
-- row; the board groups its columns on it. report_date is null on that row.
--
-- p_from and p_until are the days in view, both included; inside they are one
-- datemultirange. p_dates, when given, replaces the pair (the filter's
-- multi-date-picker, once the frontend sends a datemultirange).
drop function if exists log.get_oee_report(date, date, text, integer[], ltree[]);
drop function if exists log.get_oee_report(date, date, text, integer[], ltree[], datemultirange);

create function log.get_oee_report(p_from date DEFAULT current_date - 7, p_until date DEFAULT current_date - 1, p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_resource_paths ltree[] DEFAULT NULL::ltree[], p_dates datemultirange DEFAULT NULL::datemultirange)
    returns TABLE(report_date date, i18n jsonb, tenant_id integer, tenant_name text, resource_uid text, resource_path ltree, resource_name text, param_json jsonb, formula_json jsonb, oee_json jsonb, sort_order integer)
    stable
    language plpgsql
as $$
#variable_conflict use_column
DECLARE
    v_dates   datemultirange := coalesce(p_dates, datemultirange(daterange(p_from, p_until, '[]')));
    v_formula jsonb;
    v_langs   text[] := array['nl', 'en', 'de', 'fr', 'es', 'uk'];
BEGIN
    SELECT gf.formula_json INTO v_formula
    FROM production.get_formula(array['oee-report']) gf;
    v_formula := coalesce(v_formula, '[]'::jsonb);

    RETURN QUERY
    WITH day AS (
        SELECT d.date
        FROM action.dates d
        WHERE d.date <@ v_dates
    ),
    res AS (
        -- the resources in view: a path, a line, and the tenant of that line
        SELECT r.resource_uid, r.resource_path, r.resource_name, r.line_id,
               pl.tenant_id,
               coalesce((r.resource_json ->> 'has_break_times')::numeric, 0) AS has_break_times
        FROM relation.resource r
        JOIN relation.production_line pl ON pl.line_id = r.line_id
        WHERE r.resource_path IS NOT NULL
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
    -- department resources of the line, the groups of the print-operators team
    operator_group AS (
        SELECT c.value #>> '{}' AS group_code
        FROM relation.lookup lk
        CROSS JOIN LATERAL jsonb_array_elements(lk.lookup_json) AS t(value)
        CROSS JOIN LATERAL jsonb_array_elements(t.value -> 'codes') AS c(value)
        WHERE lk.lookup = 'lookup_teams' AND t.value ->> 'code' = 'print-operators'
    ),
    operators AS (
        SELECT sp.business_date AS date, dr.line_id,
               sum((e.value ->> 'duration')::numeric) * 60 AS planned_print_operator_duration
        FROM log.hr_shift_planning sp
        JOIN relation.resource dr ON dr.resource_uid = sp.shift_json ->> 'resource_uid'
        CROSS JOIN LATERAL jsonb_array_elements(sp.shift_json -> 'plan' -> 'groups') AS g(value)
        CROSS JOIN LATERAL jsonb_array_elements(g.value -> 'employees') AS e(value)
        WHERE sp.business_date <@ v_dates
          AND dr.line_id IN (SELECT DISTINCT line_id FROM res)
          AND public.to_kebab(g.value ->> 'group') IN (SELECT group_code FROM operator_group)
        GROUP BY sp.business_date, dr.line_id
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
                   'planned_print_operator_duration', coalesce(o.planned_print_operator_duration, 0)) AS param_json
        FROM day d
        CROSS JOIN res r
        LEFT JOIN shifts sh       ON sh.date = d.date AND sh.resource_uid = r.resource_uid
        LEFT JOIN measured m      ON m.date = d.date  AND m.resource_uid = r.resource_uid
        LEFT JOIN operators o     ON o.date = d.date  AND o.line_id = r.line_id
    ),
    -- the aggregated row per resource: every param summed over the days,
    -- the flag of the resource as it is
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
                   'planned_print_operator_duration', sum((p.param_json ->> 'planned_print_operator_duration')::numeric)) AS param_json
        FROM per_day p
        GROUP BY p.resource_uid
    ),
    rows_out AS (
        SELECT p.date, p.resource_uid, p.param_json,
               (SELECT jsonb_object_agg(l, jsonb_build_object('title', p.date::text)) FROM unnest(v_langs) l) AS i18n,
               0 AS sort_order
        FROM per_day p
        UNION ALL
        SELECT NULL, a.resource_uid, a.param_json,
               jsonb_build_object('nl', jsonb_build_object('title', 'totaal'),
                                  'en', jsonb_build_object('title', 'aggregated'),
                                  'de', jsonb_build_object('title', 'gesamt'),
                                  'fr', jsonb_build_object('title', 'total'),
                                  'es', jsonb_build_object('title', 'total'),
                                  'uk', jsonb_build_object('title', 'разом')),
               1
        FROM aggregated a
    )
    SELECT o.date, o.i18n,
           r.tenant_id, t.tenant_name,
           r.resource_uid, r.resource_path, r.resource_name,
           o.param_json,
           v_formula,
           public.evaluate_many_nas(v_formula, o.param_json),
           o.sort_order
    FROM rows_out o
    JOIN res r ON r.resource_uid = o.resource_uid
    LEFT JOIN tenant t ON t.tenant_id = r.tenant_id
    ORDER BY r.resource_path, o.sort_order, o.date;
END;
$$;

alter function log.get_oee_report(date, date, text, integer[], ltree[], datemultirange) owner to xfw3;

-- ============ site.data_table ============
INSERT INTO site.data_table (data_table, query, stored_proc, description, data_table_json, do_cache)
VALUES ('get_oee_report', 'log.get_oee_report', '',
        'the OEE report: per resource and day in view the measured seconds and areas (param_json), the rules (formula_json) and the result (oee_json), plus one aggregated row per resource',
        '{"primary_keys": ["resource_uid", "i18n"]}'::jsonb, false)
ON CONFLICT (data_table) DO UPDATE
    SET query           = EXCLUDED.query,
        description     = EXCLUDED.description,
        data_table_json = EXCLUDED.data_table_json;

COMMIT;

-- ============ check ============
-- expected: one active oee-report row
SELECT formula_code, version, version_status, jsonb_array_length(formula_json) AS rules
FROM production.get_formula(array['oee-report']);

-- expected: rows for the last 7 days per resource with a path, plus one aggregated row each;
-- availability > 0 on working days, technical_availability_percentage between 0 and 100
SELECT r.report_date, r.i18n -> 'en' ->> 'title' AS title, r.tenant_name, r.resource_path,
       r.oee_json ->> 'availability' AS availability,
       r.param_json ->> 'producing'    AS producing,
       r.oee_json ->> 'technical_availability_percentage' AS technical_availability_percentage,
       r.oee_json ->> 'producing_oee_planned_percentage'  AS producing_oee_planned_percentage
FROM log.get_oee_report(current_date - 7, current_date - 1) r
WHERE r.resource_path <@ 'dk.sheet.print'::ltree
ORDER BY r.resource_path, r.sort_order, r.report_date
LIMIT 30;
