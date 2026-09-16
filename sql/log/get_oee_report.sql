-- The OEE report (docs/plan-oee-report.md): per resource and day in view the
-- measured inputs and the results of the rule list of production.formula
-- 'oee-report' (formula_json) evaluated on them (public.evaluate_many_nas),
-- together in param_json: the inputs below plus every name a rule assigns.
-- One row per resource and day, plus one aggregated row per resource over
-- every day in view (the inputs summed, the rules evaluated on the sums, so
-- every percentage is weighted), plus a summary row per tenant per day and
-- over the period.
--
-- the inputs in param_json (seconds unless said otherwise; the standard units, no unit in a key):
--   shift_duration, break_times      the shifts of the day that name the tenant of
--                                    the resource's line (action.dates.shift_json),
--                                    summed; a shift without tenants counts for all
--   has_break_times                  relation.resource.resource_json, 1 or 0; the
--                                    formula makes availability of shift time,
--                                    offline and the breaks
--   offline                          log.state_shift_agg state offline
--   technical_failure                log.state_shift_agg state breakdown
--   planned, producing, plan_calibrated
--                                    log.state_shift_agg, the state of that name
--   actual_gross_output_sqm            the producing row: the sheet area produced, sqm
--   actual_net_output_sqm             the producing row: that area less the waste of the
--                                    nests, the area of the customer orders, sqm
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
--   shifts                           the same figures per shift of the day, one
--                                    element per shift code (the code of the shift
--                                    in shift_json and of log.state_shift_agg,
--                                    the order and titles of log.lookup lookup_shift):
--                                    {shift, i18n, the inputs above, the rule
--                                    results}, every element evaluated here. The
--                                    flat keys are the totals; the board shows a
--                                    column per element and the percentages of
--                                    the totals
-- The operator values are line values, repeated on every resource of the
-- line: do not sum them across resources. The two constants are in
-- param_json so the board can evaluate the rules itself when
-- planned_operators is edited.
--
-- set is the kind of row: 'resource' (one per resource and day, plus its
-- aggregated row) or 'summary' (one per tenant and day, plus its aggregated
-- row: the measured params of the tenant's resources summed, the operators
-- once per line, the break time already multiplied by the flag). The summary
-- row is the card that carries the operators and their cost; its
-- resource_uid is 'tenant-<tenant_id>', its resource_path null.
-- report_key is the day as text, 'aggregated' on the aggregated row; the board
-- groups its columns on it, i18n.title (the day in the notation of the
-- language, dd-mm-yyyy in Dutch, or the translated word for aggregated) is
-- the column title. business_date is the day as text (YYYY-MM-DD; a date column
-- reaches the board as a timestamp), null on the aggregated row; until is the
-- end of that day (null there too), production_line_id the line of the resource (on a
-- summary row the line of its resources), resource_uids the resource (on a
-- summary row every resource of the tenant): the values the navs of the board
-- hand to the sidebars (nest waste, planning, shift employees).
--
-- The days in view: p_date and the p_workdays workdays before it (action.dates,
-- no weekends): 4 gives five day columns. p_dates, when given, replaces that
-- (the filter's multi-date-picker, later). p_step keeps to the resources of
-- that step (relation.resource.step), print by default. The rows come per
-- tenant, the resources by name, the tenant's summary last.
drop function if exists log.get_oee_report(date, date, text, integer[], ltree[]);
drop function if exists log.get_oee_report(date, date, text, integer[], ltree[], datemultirange);
drop function if exists log.get_oee_report(timestamp with time zone, timestamp with time zone, text, integer[], ltree[], datemultirange);
drop function if exists log.get_oee_report(timestamp with time zone, text, integer[], ltree[], datemultirange, text[], integer);
drop function if exists log.get_oee_report(date, text, integer[], ltree[], datemultirange, text[], integer);
drop function if exists log.get_oee_report(date, text, integer[], ltree[], datemultirange, text, integer);

create function log.get_oee_report(p_date date DEFAULT (now() AT TIME ZONE 'Europe/Amsterdam')::date, p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_resource_paths ltree[] DEFAULT NULL::ltree[], p_dates datemultirange DEFAULT NULL::datemultirange, p_step text DEFAULT 'print'::text, p_workdays integer DEFAULT 4)
    returns TABLE(business_date text, until timestamp with time zone, report_key text, i18n jsonb, tenant_id integer, tenant_name text, resource_uid text, resource_path ltree, resource_name text, set text, production_line_id integer, resource_uids text[], param_json jsonb, formula_json jsonb, sort_order integer)
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
          AND (p_step IS NULL OR r.step = p_step)
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
    -- the shift codes in their order, with their titles (log.lookup lookup_shift)
    shift_code AS (
        SELECT c.value ->> 'code' AS shift, c.ordinality::integer AS shift_order, c.value -> 'i18n' AS i18n
        FROM log.lookup lk
        CROSS JOIN LATERAL jsonb_array_elements(lk.lookup_json) WITH ORDINALITY AS c(value, ordinality)
        WHERE lk.lookup = 'lookup_shift'
    ),
    -- the shifts of a day that a resource works, per shift code: the ones
    -- naming its tenant, or every shift when the shift names no tenant
    shifts AS (
        SELECT d.date, r.resource_uid, sh.value ->> 'code' AS shift,
               sum((sh.value ->> 'shift_duration')::numeric)             AS shift_duration,
               sum(coalesce((sh.value ->> 'break_times')::numeric, 0)) AS break_times
        FROM day d
        JOIN action.dates ad ON ad.date = d.date
        CROSS JOIN LATERAL jsonb_array_elements(coalesce(ad.shift_json, '[]'::jsonb)) AS sh(value)
        JOIN res r ON (jsonb_array_length(coalesce(sh.value -> 'tenants', '[]'::jsonb)) = 0
                    OR sh.value -> 'tenants' @> to_jsonb(r.tenant_id))
        GROUP BY d.date, r.resource_uid, sh.value ->> 'code'
    ),
    -- the measured seconds and areas per shift code, from the shift aggregate
    measured AS (
        SELECT a.shift_date AS date, a.resource_uid, a.shift_code AS shift,
               sum(a.duration_seconds)     FILTER (WHERE a.state = 'offline')         AS offline,
               sum(a.duration_seconds)     FILTER (WHERE a.state = 'breakdown')       AS technical_failure,
               sum(a.duration_seconds)     FILTER (WHERE a.state = 'planned')         AS planned,
               sum(a.duration_seconds)     FILTER (WHERE a.state = 'producing')       AS producing,
               sum(a.duration_seconds)     FILTER (WHERE a.state = 'plan_calibrated') AS plan_calibrated,
               sum(a.actual_gross_output_sqm) FILTER (WHERE a.state = 'producing')      AS actual_gross_output_sqm,
               sum(a.actual_net_output_sqm) FILTER (WHERE a.state = 'producing')       AS actual_net_output_sqm,
               sum(a.planned_output_sqm)   FILTER (WHERE a.state = 'planned')         AS planned_output_sqm
        FROM log.state_shift_agg a
        JOIN res r ON r.resource_uid = a.resource_uid
        WHERE a.shift_date <@ v_dates
        GROUP BY a.shift_date, a.resource_uid, a.shift_code
    ),
    -- the print operators planned on a line per day in view (the days only, so
    -- the period total takes no weekend planning): the HR planning of the labor
    -- resource of the line, the groups of the print-operators team
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
        FROM day d
        JOIN log.hr_shift_planning sp ON sp.business_date = d.date
        JOIN labor l ON l.resource_uid = sp.shift_json ->> 'resource_uid'
        CROSS JOIN LATERAL jsonb_array_elements(coalesce(sp.shift_json -> 'plan' -> 'groups', '[]'::jsonb)) AS g(value)
        WHERE public.to_kebab(g.value ->> 'group') IN (SELECT group_code FROM operator_group)
        GROUP BY sp.business_date, l.line_id
    ),
    -- the measured inputs per resource, day and shift code: every shift the
    -- resource works or has measurements in
    shift_rows AS (
        SELECT k.date, k.resource_uid, k.shift,
               coalesce(sh.shift_duration, 0)    AS shift_duration,
               coalesce(sh.break_times, 0)       AS break_times,
               coalesce(m.offline, 0)            AS offline,
               coalesce(m.technical_failure, 0)  AS technical_failure,
               coalesce(m.planned, 0)            AS planned,
               coalesce(m.producing, 0)          AS producing,
               coalesce(m.plan_calibrated, 0)    AS plan_calibrated,
               coalesce(m.actual_gross_output_sqm, 0) AS actual_gross_output_sqm,
               coalesce(m.actual_net_output_sqm, 0)  AS actual_net_output_sqm,
               coalesce(m.planned_output_sqm, 0) AS planned_output_sqm
        FROM (SELECT sh.date, sh.resource_uid, sh.shift FROM shifts sh
              UNION
              SELECT m.date, m.resource_uid, m.shift FROM measured m) k
        LEFT JOIN shifts sh  ON sh.date = k.date AND sh.resource_uid = k.resource_uid AND sh.shift IS NOT DISTINCT FROM k.shift
        LEFT JOIN measured m ON m.date = k.date  AND m.resource_uid = k.resource_uid  AND m.shift  IS NOT DISTINCT FROM k.shift
    ),
    -- the day per resource: every resource on every day in view, the shifts
    -- summed, every input present; not planned as the rule defines it
    -- (technical availability minus planned), needed here only to weight the
    -- rate of the summary rows
    base AS (
        SELECT d.date, r.resource_uid, r.resource_path, r.resource_name, r.tenant_id, r.line_id,
               coalesce(s.shift_duration, 0)                  AS shift_duration,
               coalesce(s.break_times, 0)                     AS break_times,
               r.has_break_times,
               coalesce(s.offline, 0)                         AS offline,
               coalesce(s.technical_failure, 0)               AS technical_failure,
               coalesce(s.planned, 0)                         AS planned,
               coalesce(s.producing, 0)                       AS producing,
               coalesce(s.plan_calibrated, 0)                 AS plan_calibrated,
               coalesce(s.actual_gross_output_sqm, 0)           AS actual_gross_output_sqm,
               coalesce(s.actual_net_output_sqm, 0)            AS actual_net_output_sqm,
               coalesce(s.planned_output_sqm, 0)              AS planned_output_sqm,
               coalesce(o.planned_print_operator_duration, 0) AS planned_print_operator_duration,
               coalesce(o.planned_operators, 0)               AS planned_operators,
               coalesce(s.shift_duration, 0) - r.has_break_times * coalesce(s.break_times, 0) - coalesce(s.offline, 0)
                 - coalesce(s.technical_failure, 0) - coalesce(s.planned, 0) AS not_planned
        FROM day d
        CROSS JOIN res r
        LEFT JOIN (SELECT sr.date, sr.resource_uid,
                          sum(sr.shift_duration) AS shift_duration, sum(sr.break_times) AS break_times,
                          sum(sr.offline) AS offline, sum(sr.technical_failure) AS technical_failure,
                          sum(sr.planned) AS planned, sum(sr.producing) AS producing, sum(sr.plan_calibrated) AS plan_calibrated,
                          sum(sr.actual_gross_output_sqm) AS actual_gross_output_sqm, sum(sr.actual_net_output_sqm) AS actual_net_output_sqm,
                          sum(sr.planned_output_sqm) AS planned_output_sqm
                   FROM shift_rows sr
                   GROUP BY sr.date, sr.resource_uid) s ON s.date = d.date AND s.resource_uid = r.resource_uid
        LEFT JOIN operators o ON o.date = d.date AND o.line_id = r.line_id
    ),
    -- the output per planned hour of a resource over the whole period (the
    -- sheet's total column): every day of that resource prices its not-planned
    -- hours at this rate
    period_rate AS (
        SELECT b.resource_uid,
               CASE WHEN sum(b.planned) > 0 THEN sum(b.actual_gross_output_sqm) / (sum(b.planned) / 3600) ELSE 0 END AS rate
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
               p.line_id AS production_line_id, ARRAY[p.resource_uid] AS resource_uids,
               p.shift_duration, p.break_times, p.has_break_times, p.offline, p.technical_failure,
               p.planned, p.producing, p.plan_calibrated, p.actual_gross_output_sqm, p.actual_net_output_sqm, p.planned_output_sqm,
               p.planned_print_operator_duration, p.planned_operators, p.rate
        FROM per_day p
        UNION ALL
        SELECT NULL, 'aggregated', 1, 'resource',
               p.tenant_id, p.resource_uid, p.resource_path, p.resource_name,
               p.line_id, ARRAY[p.resource_uid],
               sum(p.shift_duration), sum(p.break_times), max(p.has_break_times), sum(p.offline), sum(p.technical_failure),
               sum(p.planned), sum(p.producing), sum(p.plan_calibrated), sum(p.actual_gross_output_sqm), sum(p.actual_net_output_sqm), sum(p.planned_output_sqm),
               sum(p.planned_print_operator_duration), sum(p.planned_operators), max(p.rate)
        FROM per_day p
        GROUP BY p.tenant_id, p.resource_uid, p.resource_path, p.resource_name, p.line_id
        UNION ALL
        SELECT p.date, p.date::text, 0, 'summary',
               p.tenant_id, 'tenant-' || p.tenant_id, NULL, t.tenant_name,
               min(p.line_id), array_agg(DISTINCT p.resource_uid ORDER BY p.resource_uid),
               sum(p.shift_duration), sum(p.has_break_times * p.break_times), 1, sum(p.offline), sum(p.technical_failure),
               sum(p.planned), sum(p.producing), sum(p.plan_calibrated), sum(p.actual_gross_output_sqm), sum(p.actual_net_output_sqm), sum(p.planned_output_sqm),
               coalesce(max(o.planned_print_operator_duration), 0), coalesce(max(o.planned_operators), 0),
               CASE WHEN sum(p.not_planned) <> 0 THEN sum(p.overcapacity) / (sum(p.not_planned) / 3600) ELSE 0 END
        FROM per_day p
        LEFT JOIN tenant_operators o ON o.date = p.date AND o.tenant_id = p.tenant_id
        LEFT JOIN tenant t ON t.tenant_id = p.tenant_id
        GROUP BY p.date, p.tenant_id, t.tenant_name
        UNION ALL
        SELECT NULL, 'aggregated', 1, 'summary',
               p.tenant_id, 'tenant-' || p.tenant_id, NULL, t.tenant_name,
               min(p.line_id), array_agg(DISTINCT p.resource_uid ORDER BY p.resource_uid),
               sum(p.shift_duration), sum(p.has_break_times * p.break_times), 1, sum(p.offline), sum(p.technical_failure),
               sum(p.planned), sum(p.producing), sum(p.plan_calibrated), sum(p.actual_gross_output_sqm), sum(p.actual_net_output_sqm), sum(p.planned_output_sqm),
               coalesce(max(o.planned_print_operator_duration), 0), coalesce(max(o.planned_operators), 0),
               CASE WHEN sum(p.not_planned) <> 0 THEN sum(p.overcapacity) / (sum(p.not_planned) / 3600) ELSE 0 END
        FROM per_day p
        LEFT JOIN tenant_operators_period o ON o.tenant_id = p.tenant_id
        LEFT JOIN tenant t ON t.tenant_id = p.tenant_id
        GROUP BY p.tenant_id, t.tenant_name
    ),
    -- the same four kinds per shift code: the inputs of the shift, the day's
    -- operators and the rate of the row they belong to
    shift_numbers AS (
        SELECT n.report_key, n.set, n.resource_uid, sr.shift,
               sum(sr.shift_duration) AS shift_duration,
               sum(CASE WHEN n.set = 'summary' THEN r.has_break_times * sr.break_times ELSE sr.break_times END) AS break_times,
               max(n.has_break_times) AS has_break_times,
               sum(sr.offline) AS offline, sum(sr.technical_failure) AS technical_failure,
               sum(sr.planned) AS planned, sum(sr.producing) AS producing, sum(sr.plan_calibrated) AS plan_calibrated,
               sum(sr.actual_gross_output_sqm) AS actual_gross_output_sqm, sum(sr.actual_net_output_sqm) AS actual_net_output_sqm,
               sum(sr.planned_output_sqm) AS planned_output_sqm,
               max(n.planned_print_operator_duration) AS planned_print_operator_duration,
               max(n.planned_operators) AS planned_operators,
               max(n.rate) AS rate
        FROM shift_rows sr
        JOIN res r ON r.resource_uid = sr.resource_uid
        JOIN numbers n
          ON (n.report_key = sr.date::text OR n.report_key = 'aggregated')
         AND (   (n.set = 'resource' AND n.resource_uid = sr.resource_uid)
              OR (n.set = 'summary'  AND n.tenant_id = r.tenant_id))
        GROUP BY n.report_key, n.set, n.resource_uid, sr.shift
    ),
    shift_json AS (
        SELECT s.report_key, s.set, s.resource_uid,
               jsonb_agg(
                   jsonb_build_object('shift', s.shift, 'i18n', sc.i18n)
                   || public.evaluate_many_nas(v_formula, jsonb_build_object(
                          'shift_duration',                  s.shift_duration,
                          'break_times',                     s.break_times,
                          'has_break_times',                 s.has_break_times,
                          'offline',                         s.offline,
                          'technical_failure',               s.technical_failure,
                          'planned',                         s.planned,
                          'producing',                       s.producing,
                          'plan_calibrated',                 s.plan_calibrated,
                          'actual_gross_output_sqm',           s.actual_gross_output_sqm,
                          'actual_net_output_sqm',            s.actual_net_output_sqm,
                          'planned_output_sqm',              s.planned_output_sqm,
                          'planned_print_operator_duration', s.planned_print_operator_duration,
                          'planned_operators',               s.planned_operators,
                          'operator_working_time',           v_operator_working_time,
                          'operator_cost_per_second',        v_operator_cost_per_second,
                          'period_output_per_planned_hour',  s.rate))
                   ORDER BY sc.shift_order NULLS LAST, s.shift) AS shifts
        FROM shift_numbers s
        LEFT JOIN shift_code sc ON sc.shift = s.shift
        GROUP BY s.report_key, s.set, s.resource_uid
    ),
    -- the column title per language: the day in the notation of the language
    day_i18n AS (
        SELECT d.date,
               jsonb_build_object(
                   'nl', jsonb_build_object('title', to_char(d.date, 'DD-MM-YYYY')),
                   'en', jsonb_build_object('title', to_char(d.date, 'YYYY-MM-DD')),
                   'de', jsonb_build_object('title', to_char(d.date, 'DD.MM.YYYY')),
                   'fr', jsonb_build_object('title', to_char(d.date, 'DD/MM/YYYY')),
                   'es', jsonb_build_object('title', to_char(d.date, 'DD/MM/YYYY')),
                   'uk', jsonb_build_object('title', to_char(d.date, 'DD.MM.YYYY'))) AS i18n
        FROM day d
    )
    SELECT n.date::text,
           (n.date + 1)::timestamp AT TIME ZONE 'Europe/Amsterdam',
           n.report_key,
           CASE WHEN n.sort_order = 1 THEN v_aggregated_i18n ELSE di.i18n END,
           n.tenant_id, t.tenant_name,
           n.resource_uid, n.resource_path, n.resource_name, n.set,
           n.production_line_id, n.resource_uids,
           public.evaluate_many_nas(v_formula, jsonb_build_object(
               'shift_duration',                  n.shift_duration,
               'break_times',                     n.break_times,
               'has_break_times',                 n.has_break_times,
               'offline',                         n.offline,
               'technical_failure',               n.technical_failure,
               'planned',                         n.planned,
               'producing',                       n.producing,
               'plan_calibrated',                 n.plan_calibrated,
               'actual_gross_output_sqm',           n.actual_gross_output_sqm,
               'actual_net_output_sqm',            n.actual_net_output_sqm,
               'planned_output_sqm',              n.planned_output_sqm,
               'planned_print_operator_duration', n.planned_print_operator_duration,
               'planned_operators',               n.planned_operators,
               'operator_working_time',           v_operator_working_time,
               'operator_cost_per_second',        v_operator_cost_per_second,
               'period_output_per_planned_hour',  n.rate))
           || jsonb_build_object('shifts', coalesce(sj.shifts, '[]'::jsonb)),
           v_formula,
           n.sort_order
    FROM numbers n
    LEFT JOIN shift_json sj ON sj.report_key = n.report_key AND sj.set = n.set AND sj.resource_uid = n.resource_uid
    LEFT JOIN day_i18n di ON di.date = n.date
    LEFT JOIN tenant t ON t.tenant_id = n.tenant_id
    ORDER BY n.tenant_id, (n.set = 'summary'), n.resource_name, n.sort_order, n.date;
END;
$$;

alter function log.get_oee_report(date, text, integer[], ltree[], datemultirange, text, integer) owner to xfw3;
