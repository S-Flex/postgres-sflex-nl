create function mock.get_print_schedule_test(p_until timestamp with time zone DEFAULT now(), p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_only_starting_today boolean DEFAULT false) returns TABLE(material_id integer, tenant_id integer, production_line_id integer, date date, start_offset_in_seconds integer, duration_in_seconds integer, class_names text[], actual_sqm numeric, forecast_sqm numeric, param_json jsonb)
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
    v_formula constant jsonb := jsonb_build_array(
        'panel_area_m2 = width * height / 10000',
        'net_area_m2 = panel_area_m2 * (1 - waste_perc)',
        'forecast_panels = forecast_sqm / net_area_m2',
        'actual_panels = actual_sqm / net_area_m2',
        'forecast_gross_sqm = forecast_sqm / (1 - waste_perc)',
        'standard_production_impact_in_seconds = forecast_gross_sqm * standard_speed_print_time_sqm_in_seconds',
        'fast_production_impact_in_seconds = forecast_gross_sqm * high_speed_print_time_sqm_in_seconds');
    v_look_ahead integer;
    v_from       date;
    v_last       date;
BEGIN
    -- the axis starts on the first workday on or after p_until
    SELECT min(d.date)
    INTO v_from
    FROM action.dates d
    WHERE d.date >= (p_until AT TIME ZONE current_setting('TimeZone'))::date
      AND d.is_weekend = false
      AND NOT (coalesce(p_tenant_ids, d.tenants_mandatory_day_off) <@ d.tenants_mandatory_day_off and d.tenants_mandatory_day_off <> '{}');

    IF v_from IS NULL THEN
        RETURN;
    END IF;

    -- a day offset carries a date past the last column, so the workdays and the
    -- forecast have to reach that far even though the axis does not
    SELECT coalesce(max((v.value ->> 'day_offset')::integer), 0)
    INTO v_look_ahead
    FROM production.lookup l
             CROSS JOIN LATERAL jsonb_array_elements(l.lookup_json) AS v(value)
    WHERE l.lookup = 'lookup_nest_moments';

    SELECT max(d.date)
    INTO v_last
    FROM (SELECT d.date
          FROM action.dates d
          WHERE d.date >= v_from
            AND d.is_weekend = false
            AND NOT (coalesce(p_tenant_ids, d.tenants_mandatory_day_off) <@ d.tenants_mandatory_day_off and d.tenants_mandatory_day_off <> '{}')
          ORDER BY d.date
          LIMIT v_days + v_look_ahead) d;

    RETURN QUERY
        WITH workday AS (
            SELECT d.date,
                   (row_number() OVER (ORDER BY d.date) - 1)::integer AS day_index
            FROM action.dates d
            WHERE d.date >= v_from
              AND d.date <= v_last
              AND d.is_weekend = false
              AND NOT (coalesce(p_tenant_ids, d.tenants_mandatory_day_off) <@ d.tenants_mandatory_day_off and d.tenants_mandatory_day_off <> '{}')
        ),
        tenant AS (
            -- only the company id is needed here, the name lives in the row data
            SELECT (v.value ->> 'tenant_id')::integer             AS tenant_id,
                   (v.value ->> 'production_company_id')::integer AS production_company_id
            FROM relation.lookup l
                     CROSS JOIN LATERAL jsonb_array_elements(l.lookup_json) AS v(value)
            WHERE l.lookup = 'lookup_tenants'
        ),
        nest_moment AS (
            SELECT v.value ->> 'code'                               AS nest_moment_code,
                   coalesce((v.value ->> 'day_offset')::integer, 0) AS day_offset
            FROM production.lookup l
                     CROSS JOIN LATERAL jsonb_array_elements(l.lookup_json) AS v(value)
            WHERE l.lookup = 'lookup_nest_moments'
        ),
        forecast AS (
            SELECT f.production_company_id,
                   f.material_id,
                   f.date,
                   f.actual_sqm,
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
                   mps.production_line_id,
                   mps.tenant_id,
                   mps.nest_moment_codes,
                   coalesce(nullif(mps.interval_days, 0), 1) AS interval_days,
                   (SELECT min(d.date)
                    FROM action.dates d
                    WHERE d.date >= coalesce(mps.interval_start_date, v_from)
                      AND d.is_weekend = false
                      AND NOT (coalesce(p_tenant_ids, d.tenants_mandatory_day_off) <@ d.tenants_mandatory_day_off and d.tenants_mandatory_day_off <> '{}')) AS interval_start_date
            FROM mock.material_print_schedule mps
            WHERE mps.line = p_line_type
              AND (p_tenant_ids IS NULL OR mps.tenant_id = ANY (p_tenant_ids))
        ),
        production_day AS (
            -- step one: the production days of every material and the column
            -- each one occupies
            SELECT m.material_id,
                   m.production_line_id,
                   m.tenant_id,
                   m.interval_days,
                   m.nest_moment_codes,
                   i.interval_date AS production_date,
                   w.day_index     AS production_day_index,
                   min(i.interval_date) OVER (
                       PARTITION BY m.tenant_id, m.material_id, m.production_line_id
                       ) AS first_date
            FROM material m
                     CROSS JOIN LATERAL action.get_interval_dates(
                         m.interval_start_date,
                         v_from,
                         m.interval_days,
                         v_days,
                         false,
                         false,
                         0) AS i(interval_date)
                     JOIN workday w ON w.date = i.interval_date
        ),
        card AS (
            -- step two: every day offset of the material's nest moments turns
            -- the production day into a row that keeps the column and moves the
            -- date that many workdays forward
            SELECT (row_number() OVER ())::integer AS row_id,
                   c.*
            FROM (SELECT DISTINCT
                         p.tenant_id,
                         p.material_id,
                         p.production_line_id,
                         p.interval_days,
                         p.production_date,
                         p.production_day_index,
                         nm.day_offset,
                         w.date
                  FROM production_day p
                           JOIN nest_moment nm ON nm.nest_moment_code = ANY (p.nest_moment_codes)
                           JOIN workday w ON w.day_index = p.production_day_index + nm.day_offset
                  WHERE NOT p_only_starting_today
                     OR p.first_date = v_from) c
        ),
        row_base AS (
            SELECT c.*,
                   f.actual_sqm,
                   f.forecast_sqm,
                   coalesce(mpl.line_json -> 'specs', '[]'::jsonb) AS specs,
                   -- everything the formulas need except the panel size itself
                   v_params
                       || coalesce(mpl.line_json - 'specs', '{}'::jsonb)
                       || jsonb_build_object(
                              'forecast_sqm', coalesce(f.forecast_sqm, 0),
                              'actual_sqm', coalesce(f.actual_sqm, 0)) AS vars
            FROM card c
                     LEFT JOIN tenant t ON t.tenant_id = c.tenant_id
                     LEFT JOIN mapping.material_production_line mpl
                               ON mpl.material_id = c.material_id
                                   AND mpl.production_line_id = c.production_line_id
                     LEFT JOIN forecast f
                               ON f.production_company_id = t.production_company_id
                                   AND f.material_id = c.material_id
                                   AND f.date = c.date
        ),
        calc AS (
            -- panel numbers only: width and height already live in the row data,
            -- the arrays align by position because both read the same specs
            SELECT r.row_id,
                   jsonb_agg(jsonb_build_object(
                           'forecast_panels', round((c.result ->> 'forecast_panels')::numeric),
                           'actual_panels', round((c.result ->> 'actual_panels')::numeric)
                             ) ORDER BY spec.ord)                                              AS specs,
                   min(round((c.result ->> 'standard_production_impact_in_seconds')::numeric)) AS standard_impact,
                   min(round((c.result ->> 'fast_production_impact_in_seconds')::numeric))     AS fast_impact
            FROM row_base r
                     CROSS JOIN LATERAL jsonb_array_elements(r.specs)
                         WITH ORDINALITY AS spec(value, ord)
                     CROSS JOIN LATERAL (
                         SELECT coalesce(jsonb_object_agg(e.key, to_jsonb(n.num)), '{}'::jsonb) AS vars
                         FROM jsonb_each(r.vars || spec.value) AS e
                                  CROSS JOIN LATERAL (
                             SELECT CASE
                                        WHEN jsonb_typeof(e.value) = 'number'
                                            THEN (e.value #>> '{}')::numeric
                                        WHEN jsonb_typeof(e.value) = 'string'
                                            AND (e.value #>> '{}') ~ '^\s*-?\d+(\.\d+)?\s*$'
                                            THEN (e.value #>> '{}')::numeric
                                        END AS num
                             ) n
                         WHERE n.num IS NOT NULL
                         ) v
                     CROSS JOIN LATERAL (
                         SELECT evaluate_many_nas(v_formula, v.vars) AS result
                         ) c
            GROUP BY r.row_id
        )
        SELECT r.material_id,
               r.tenant_id,
               r.production_line_id,
               r.date,
               r.production_day_index * 86400,
               86400,
               -- plan-na marks a date that is not the production day itself,
               -- plan-initiated a slot beyond the material's own interval
               array_remove(array [
                   CASE WHEN r.day_offset > 0 THEN 'plan-na' END,
                   CASE
                       WHEN r.production_day_index > 2
                           AND r.production_day_index > r.interval_days
                           THEN 'plan-initiated'
                       END
                   ], null),
               r.actual_sqm,
               r.forecast_sqm,
               jsonb_build_object(
                       'specs', coalesce(c.specs, '[]'::jsonb),
                       'standard_production_impact_in_seconds', c.standard_impact,
                       'fast_production_impact_in_seconds', c.fast_impact)
        FROM row_base r
                 LEFT JOIN calc c ON c.row_id = r.row_id
        ORDER BY r.tenant_id, r.material_id, r.production_day_index, r.date;
END;
$$;

alter function mock.get_print_schedule_test(unknown, unknown, unknown, unknown) owner to xfw3;

