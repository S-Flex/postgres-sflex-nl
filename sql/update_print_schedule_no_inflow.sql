-- Board 75: a card is the work of one material on one day, per tenant: the
-- orderlines not yet nested (status up to file_in_gangrun, 450) whose nesting
-- deadline (nest_date) falls on that day; overdue work of the p_lookback_days
-- (2) workdays before joins the card of day 0 with the class state-delayed. The
-- urgency follows from the day: hours_to_production = (day index + 2) * 24, the
-- inverse of calculate_nest_date, and picks the row: the material's code with
-- the highest class at or below it, first in lookup order on a tie, else its
-- fastest moment. The forecast of the day rides on the card. No work, no card.
-- Return type and signature change: drop and create.
BEGIN;

-- ============ sql/mock/get_print_schedule.sql ============
-- The cards of the print schedule (75). A card is the work of one material on
-- one day, per tenant: the orderlines not yet nested (status up to
-- file_in_gangrun, mapping.component_specs) whose nest_date -- the nesting
-- deadline -- falls on that day; a deadline on a weekend lands on the next
-- workday. Overdue work, a deadline in the p_lookback_days workdays before
-- p_until, joins the card of day 0, which then carries the class
-- state-delayed; older deadlines are out.
--
-- The urgency of a card follows from its day: hours_to_production is (day
-- index + 2) * 24 -- day 0 is 48, day 1 is 72, day 2 is 96 -- the inverse of
-- mapping.calculate_nest_date, which nests a 48-hour order on its first working
-- day, a 72-hour order a day later, 96 two days later. It links the card to its
-- label row (the nest moments of the material, get_plan_lanes_imposition_group)
-- through nest_moment_code: of the codes of the material whose class
-- (lookup_nest_moments delivery_hours) is at or below the urgency the one with
-- the highest class, first in lookup order when two share it (48 before 48+);
-- a day faster than every moment of the material takes the fastest moment.
--
-- The forecast (get_production_forecast_material, per material and day) rides
-- on the card of its day. A card without work is no card; a card on a day that
-- is no production day of the material's interval carries the class plan-na.
--
-- Performance: the constants of a material are cleaned once (material_vars),
-- the formulas are evaluated once per distinct variable set (calc), and the
-- inflow is aggregated once (MATERIALIZED, bounded to the axis and the
-- look-back), never per card.
-- The return type and the signature changed over time (hours_to_production,
-- p_lookback_days), so the old ones go first.
drop function if exists mock.get_print_schedule(timestamp with time zone, text, integer[], boolean);
drop function if exists mock.get_print_schedule(timestamp with time zone, text, integer[], boolean, integer);

create function mock.get_print_schedule(p_until timestamp with time zone DEFAULT now(), p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_only_starting_today boolean DEFAULT false, p_lookback_days integer DEFAULT 2) returns TABLE(material_id integer, material_name text, production_line_id integer, tenant_id integer, tenant_name text, date date, nest_moment_code text, hours_to_production integer, day_offset integer, start_offset_in_seconds integer, duration_in_seconds integer, class_names text[], actual_sqm numeric, forecast_sqm numeric, param_json jsonb)
	language plpgsql
as $$
#variable_conflict use_column
DECLARE
    v_days constant integer := 10;
    -- board defaults, a key in line_json or in the spec overrides them
    v_params constant jsonb := jsonb_build_object(
        'waste_perc', 0.15,
        'standard_speed_print_time_sqm_in_seconds', 45,
        'high_speed_print_time_sqm_in_seconds', 15);
    -- width and height are in cm, the impacts follow the day's area and are
    -- therefore the same for every panel size
    v_formula constant jsonb := jsonb_build_array(
        'panel_area_m2 = width * height / 10000',
        'net_area_m2 = panel_area_m2 * (1 - waste_perc)',
        'forecast_panels = forecast_sqm / net_area_m2',
        'actual_panels = actual_sqm / net_area_m2',
        'forecast_gross_sqm = forecast_sqm / (1 - waste_perc)',
        'standard_production_impact_in_seconds = forecast_gross_sqm * standard_speed_print_time_sqm_in_seconds',
        'fast_production_impact_in_seconds = forecast_gross_sqm * high_speed_print_time_sqm_in_seconds');
    -- the work of a card is the orderlines not yet nested: status sequence up
    -- to file_in_gangrun (450), the boundary get_production_orderline_detail
    -- uses as well. is_open is no measure here: a printed line is still open
    v_nested_sequence constant integer := 450;
    v_from  date;   -- the day of p_until, day 0 of the axis
    v_start date;   -- p_lookback_days workdays before it: the oldest deadline still counted
    v_last  date;   -- the last day of the axis
BEGIN
    -- the axis starts on the first workday on or after p_until, get_interval_dates
    -- needs a current_date that exists in its own workday sequence
    SELECT min(d.date)
    INTO v_from
    FROM action.dates d
    WHERE d.date >= (p_until AT TIME ZONE current_setting('TimeZone'))::date
      AND d.is_weekend = false
      AND NOT (coalesce(p_tenant_ids, d.tenants_mandatory_day_off) <@ d.tenants_mandatory_day_off and d.tenants_mandatory_day_off <> '{}');

    IF v_from IS NULL THEN
        RETURN;
    END IF;

    SELECT max(d.date)
    INTO v_last
    FROM (SELECT d.date
          FROM action.dates d
          WHERE d.date >= v_from
            AND d.is_weekend = false
            AND NOT (coalesce(p_tenant_ids, d.tenants_mandatory_day_off) <@ d.tenants_mandatory_day_off and d.tenants_mandatory_day_off <> '{}')
          ORDER BY d.date
          LIMIT v_days) d;

    SELECT coalesce(min(d.date), v_from)
    INTO v_start
    FROM (SELECT d.date
          FROM action.dates d
          WHERE d.date < v_from
            AND d.is_weekend = false
            AND NOT (coalesce(p_tenant_ids, d.tenants_mandatory_day_off) <@ d.tenants_mandatory_day_off and d.tenants_mandatory_day_off <> '{}')
          ORDER BY d.date DESC
          LIMIT greatest(p_lookback_days, 0)) d;

    RETURN QUERY
        WITH workday AS (
            -- day_index 0 is v_from
            SELECT d.date,
                   (row_number() OVER (ORDER BY d.date) - 1)::integer AS day_index
            FROM action.dates d
            WHERE d.date >= v_from
              AND d.date <= v_last
              AND d.is_weekend = false
              AND NOT (coalesce(p_tenant_ids, d.tenants_mandatory_day_off) <@ d.tenants_mandatory_day_off and d.tenants_mandatory_day_off <> '{}')
        ),
        tenant AS (
            -- the company id joins the forecast and the inflow, the name is
            -- returned as well
            SELECT t.tenant_id, t.name AS tenant_name, t.production_company_id
            FROM site.tenant t
        ),
        nest_moment AS (
            -- the moments of the lookup: the delivery class a moment serves,
            -- its day offset, and its place in the lookup (the tie-break
            -- between two codes of one class)
            SELECT v.value ->> 'code'                               AS nest_moment_code,
                   (v.value ->> 'delivery_hours')::integer            AS delivery_hours,
                   coalesce((v.value ->> 'day_offset')::integer, 0) AS day_offset,
                   v.ord                                               AS moment_order
            FROM production.lookup l
                     CROSS JOIN LATERAL jsonb_array_elements(l.lookup_json) WITH ORDINALITY AS v(value, ord)
            WHERE l.lookup = 'lookup_nest_moments'
        ),
        -- the variables the formulas read: every identifier on a right-hand
        -- side. The evaluator's cost grows with the number of variables it is
        -- handed (19 keys cost four times 7), so nothing else goes in
        needed_key AS (
            SELECT DISTINCT m[1] AS key
            FROM jsonb_array_elements_text(v_formula) AS f(line)
                     CROSS JOIN LATERAL regexp_matches(split_part(f.line, '=', 2), '[A-Za-z_][A-Za-z0-9_]*', 'g') AS m
        ),
        forecast AS (
            SELECT f.production_company_id,
                   f.material_id,
                   f.date,
                   f.forecast_sqm
            FROM mock.get_production_forecast_material(
                     v_from,
                     (v_last - v_from) + 1,
                     p_line_type) f
        ),
        material AS (
            -- the effective interval and anchor are decided here, so nothing
            -- derived from them can disagree
            SELECT mps.material_id,
                   mps.material_name,
                   mps.production_line_id,
                   mps.tenant_id,
                   mps.nest_moment_codes,
                   coalesce(nullif(mps.interval_days, 0), 1) AS interval_days,
                   -- the anchor must exist in the workday sequence of
                   -- get_interval_dates, a weekend or day off yields no dates at all
                   (SELECT min(d.date)
                    FROM action.dates d
                    WHERE d.date >= coalesce(mps.interval_start_date, v_from)
                      AND d.is_weekend = false
                      AND NOT (coalesce(p_tenant_ids, d.tenants_mandatory_day_off) <@ d.tenants_mandatory_day_off and d.tenants_mandatory_day_off <> '{}')) AS interval_start_date
            FROM mock.material_print_schedule mps
            WHERE mps.line = p_line_type
              AND (p_tenant_ids IS NULL OR mps.tenant_id = ANY (p_tenant_ids))
        ),
        -- the constants of a material, once per material instead of once per
        -- row: the numeric keys of line_json the formulas read (a key here
        -- overrides the board default), and per panel size the raw spec plus
        -- its numeric keys. The evaluator takes numbers only, so numeric texts
        -- are cast and the rest is dropped.
        -- MATERIALIZED: referenced once, so the planner inlined it into
        -- row_base and rebuilt it for every card row (66 materials x 1.178
        -- rows, 5 s with only_starting_today); now it is built once
        material_vars AS MATERIALIZED (
            SELECT m.material_id, m.production_line_id,
                   coalesce((SELECT jsonb_object_agg(e.key, to_jsonb(n.num))
                             FROM jsonb_each(mpl.line_json - 'specs') AS e
                                      JOIN needed_key k ON k.key = e.key
                                      CROSS JOIN LATERAL (
                                 SELECT CASE
                                            WHEN jsonb_typeof(e.value) = 'number'
                                                THEN (e.value #>> '{}')::numeric
                                            WHEN jsonb_typeof(e.value) = 'string'
                                                AND (e.value #>> '{}') ~ '^\s*-?\d+(\.\d+)?\s*$'
                                                THEN (e.value #>> '{}')::numeric
                                            END AS num
                                 ) n
                             WHERE n.num IS NOT NULL), '{}'::jsonb) AS line_vars,
                   coalesce((SELECT jsonb_agg(jsonb_build_object(
                                                  'spec', spec.value,
                                                  'vars', coalesce((SELECT jsonb_object_agg(e.key, to_jsonb(n.num))
                                                                    FROM jsonb_each(spec.value) AS e
                                                                             JOIN needed_key k ON k.key = e.key
                                                                             CROSS JOIN LATERAL (
                                                                        SELECT CASE
                                                                                   WHEN jsonb_typeof(e.value) = 'number'
                                                                                       THEN (e.value #>> '{}')::numeric
                                                                                   WHEN jsonb_typeof(e.value) = 'string'
                                                                                       AND (e.value #>> '{}') ~ '^\s*-?\d+(\.\d+)?\s*$'
                                                                                       THEN (e.value #>> '{}')::numeric
                                                                                   END AS num
                                                                        ) n
                                                                    WHERE n.num IS NOT NULL), '{}'::jsonb))
                                              ORDER BY spec.ord)
                             FROM jsonb_array_elements(coalesce(mpl.line_json -> 'specs', '[]'::jsonb))
                                      WITH ORDINALITY AS spec(value, ord)), '[]'::jsonb) AS spec_vars
            FROM (SELECT DISTINCT material_id, production_line_id FROM material) m
                     LEFT JOIN mapping.material_production_line mpl
                               ON mpl.material_id = m.material_id
                                   AND mpl.production_line_id = m.production_line_id
        ),
        production_day AS (
            -- the production days of every material on the axis, from its own
            -- start date and interval: a card on another day is a plan-na card
            SELECT m.material_id,
                   m.production_line_id,
                   m.tenant_id,
                   i.interval_date AS production_date,
                   min(i.interval_date) OVER (
                       PARTITION BY m.tenant_id, m.material_id, m.production_line_id
                       ) AS first_date
            FROM material m
                     CROSS JOIN LATERAL action.get_interval_dates(
                         m.interval_start_date,
                         v_from,
                         m.interval_days,
                         v_days,
                         false, -- weekends are not part of the axis
                         false, -- mandatory days off are not part of the axis
                         0,
                         -- the same tenants as the axis and the anchor: without
                         -- them one tenant's day off shifts every interval
                         p_tenant_ids) AS i(interval_date)
        ),
        -- MATERIALIZED: computed once (1,3 s per pass over the whole table
        -- when unbounded, 70 ms bounded). Bounded to what a card can show: the
        -- deadlines on the axis, plus the look-back
        inflow AS MATERIALIZED (
            -- the m2 of the orderlines not yet nested of a material per card
            -- day: the nest deadline, an overdue deadline (within the
            -- look-back) on day 0, a weekend on the next workday
            SELECT cs.production_company_id,
                   cs.material_id,
                   cd.date                        AS card_date,
                   sum(cs.sqm)                    AS sqm,
                   bool_or(cs.nest_date < v_from) AS is_delayed
            FROM mapping.component_specs cs
                     JOIN mapping.internal_status ist
                          ON ist.code = cs.internal_status_code
                         AND ist.domain_id = cs.domain_id
                     CROSS JOIN LATERAL (
                         SELECT min(w.date) AS date
                         FROM workday w
                         WHERE w.date >= greatest((cs.nest_date AT TIME ZONE current_setting('TimeZone'))::date, v_from)
                     ) cd
            WHERE cs.is_open
              AND ist.sequence <= v_nested_sequence
              AND cs.nest_date >= v_start
              AND cs.nest_date < v_last + 1
              AND cs.material_id IN (SELECT m.material_id FROM material m)
              AND cd.date IS NOT NULL
            GROUP BY cs.production_company_id, cs.material_id, cd.date
        ),
        card AS (
            -- one card per material and day: the work of the day, its urgency
            -- from the day index, the moment that nests it, the forecast of
            -- the day
            SELECT m.tenant_id, m.material_id, m.material_name, m.production_line_id,
                   i.card_date AS date, w.day_index,
                   (w.day_index + 2) * 24 AS hours_to_production,
                   nm.nest_moment_code, nm.day_offset,
                   i.is_delayed,
                   i.sqm AS actual_sqm,
                   coalesce(f.forecast_sqm, 0) AS forecast_sqm
            FROM inflow i
                     JOIN tenant t ON t.production_company_id = i.production_company_id
                     JOIN material m ON m.material_id = i.material_id AND m.tenant_id = t.tenant_id
                     JOIN workday w ON w.date = i.card_date
                     LEFT JOIN forecast f ON f.production_company_id = i.production_company_id
                                         AND f.material_id = i.material_id
                                         AND f.date = i.card_date
                     -- the material's code with the highest class at or below
                     -- the urgency, else its fastest moment
                     LEFT JOIN LATERAL (
                         SELECT nm.nest_moment_code, nm.day_offset
                         FROM nest_moment nm
                         WHERE nm.nest_moment_code = ANY (m.nest_moment_codes)
                         ORDER BY (nm.delivery_hours <= (w.day_index + 2) * 24) DESC,
                                  CASE WHEN nm.delivery_hours <= (w.day_index + 2) * 24
                                       THEN -nm.delivery_hours ELSE nm.delivery_hours END,
                                  nm.moment_order
                         LIMIT 1
                     ) nm ON true
            WHERE NOT p_only_starting_today
               OR EXISTS (SELECT 1
                          FROM production_day p
                          WHERE p.material_id = m.material_id
                            AND p.tenant_id = m.tenant_id
                            AND p.production_line_id = m.production_line_id
                            AND p.first_date = v_from)
        ),
        row_base AS (
            SELECT c.*,
                   t.tenant_name,
                   mv.spec_vars,
                   -- everything the formulas need except the panel size itself
                   (SELECT coalesce(jsonb_object_agg(e.key, e.value), '{}'::jsonb)
                    FROM jsonb_each(v_params) e
                             JOIN needed_key k ON k.key = e.key)
                       || mv.line_vars
                       || jsonb_build_object(
                              'forecast_sqm', c.forecast_sqm,
                              'actual_sqm', c.actual_sqm) AS vars,
                   -- the key calc is joined back on: one text per distinct
                   -- variable set, so the join can hash instead of comparing
                   -- jsonb row by row
                   md5(coalesce(mv.line_vars::text, '') || '|' || coalesce(mv.spec_vars::text, '')
                       || '|' || c.forecast_sqm::text || '|' || c.actual_sqm::text) AS calc_key
            FROM card c
                     LEFT JOIN tenant t ON t.tenant_id = c.tenant_id
                     LEFT JOIN material_vars mv
                               ON mv.material_id = c.material_id
                                   AND mv.production_line_id = c.production_line_id
        ),
        -- one evaluation per distinct variable set, not per row: the cards
        -- that share their numbers share their evaluation. Only the keys the
        -- board reads are kept, every row carries this payload
        calc AS MATERIALIZED (
            SELECT v.calc_key,
                   jsonb_agg(jsonb_build_object(
                           'width', s.value -> 'spec' -> 'width',
                           'height', s.value -> 'spec' -> 'height',
                           'forecast_panels', round((c.result ->> 'forecast_panels')::numeric),
                           'actual_panels', round((c.result ->> 'actual_panels')::numeric)
                             ) ORDER BY s.ord)                                             AS specs,
                   -- the impacts follow the area, so every size returns the same
                   min(round((c.result ->> 'standard_production_impact_in_seconds')::numeric)) AS standard_impact,
                   min(round((c.result ->> 'fast_production_impact_in_seconds')::numeric))     AS fast_impact
            FROM (SELECT DISTINCT r.calc_key, r.vars, r.spec_vars FROM row_base r) v
                     CROSS JOIN LATERAL jsonb_array_elements(v.spec_vars)
                         WITH ORDINALITY AS s(value, ord)
                     CROSS JOIN LATERAL (
                         SELECT evaluate_many_nas(v_formula, v.vars || (s.value -> 'vars')) AS result
                         ) c
            GROUP BY v.calc_key
        )
        SELECT r.material_id,
               r.material_name,
               r.production_line_id,
               r.tenant_id,
               r.tenant_name,
               r.date,
               r.nest_moment_code,
               r.hours_to_production,
               r.day_offset,
               -- the column is the day of the card: the nest deadline of its work
               r.day_index * 86400,
               86400,
               -- state-delayed: overdue work joined the card; plan-na: the day
               -- is no production day of the material's interval
               array_remove(array [
                   CASE WHEN r.is_delayed THEN 'state-delayed' END,
                   CASE WHEN NOT EXISTS (SELECT 1
                                         FROM production_day p
                                         WHERE p.material_id = r.material_id
                                           AND p.tenant_id = r.tenant_id
                                           AND p.production_line_id = r.production_line_id
                                           AND p.production_date = r.date)
                        THEN 'plan-na' END
                   ], null),
               round(r.actual_sqm, 1),
               round(r.forecast_sqm, 1),
               jsonb_build_object(
                       'specs', coalesce(c.specs, '[]'::jsonb),
                       'standard_production_impact_in_seconds', c.standard_impact,
                       'fast_production_impact_in_seconds', c.fast_impact)
        FROM row_base r
                 LEFT JOIN calc c ON c.calc_key = r.calc_key
        ORDER BY r.tenant_id, r.material_name, r.date;
END;
$$;

alter function mock.get_print_schedule(timestamp with time zone, text, integer[], boolean, integer) owner to xfw3;

-- p_only_starting_today changes the shape of the query (the filter on
-- first_date folds away when it is false). After five calls in one session
-- plpgsql switches to a generic plan for both values, and that plan was
-- 4-9 s for the unfiltered call (pg_stat_statements: min 54 ms, max 9.351
-- ms for the same statement). A custom plan per call costs ~5 ms of
-- planning and keeps both shapes fast; same setting as
-- mapping.get_production_orderline_detail.
alter function mock.get_print_schedule(timestamp with time zone, text, integer[], boolean, integer) set plan_cache_mode = force_custom_plan;

COMMIT;

-- check: the cards of one material per day and urgency, with their row
SELECT tenant_name, material_name, date, hours_to_production, nest_moment_code, actual_sqm, forecast_sqm, class_names
FROM mock.get_print_schedule(p_line_type => 'sheet')
WHERE material_id = 26
ORDER BY date, tenant_id, hours_to_production;
