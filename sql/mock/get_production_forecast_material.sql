-- The forecast per material and production day: budget, actual and forecast
-- sqm from log.production_forecast_material, the actual sqm of the day from
-- component_specs on top.
--
-- p_days counts workdays (action.dates, weekends skipped), so "the next 10
-- workdays" is p_days = 10 whatever the calendar says; the forecast table
-- holds no weekend rows anyway. p_line_type null is every line;
-- p_material_id narrows to one material (the material-forecast page), which
-- lists per production line, so the line name rides along.
-- The signature gained p_material_id, so the old one is dropped first.
drop function if exists mock.get_production_forecast_material(timestamp with time zone, integer, text);

create function mock.get_production_forecast_material(p_from timestamp with time zone, p_days integer, p_line_type text DEFAULT NULL::text, p_material_id integer DEFAULT NULL::integer) returns TABLE(date date, production_line_id integer, line text, production_company_id integer, material_id integer, material_name text, budget_sqm numeric, actual_sqm numeric, forecast_sqm numeric, param_json jsonb)
	stable
	language plpgsql
as $$
#variable_conflict use_column
DECLARE
    v_from date := p_from::date;
    -- the last of the p_days workdays from v_from on
    v_last date := (SELECT max(w.date)
                    FROM (SELECT d.date
                          FROM action.dates d
                          WHERE d.date >= p_from::date
                            AND d.is_weekend = false
                          ORDER BY d.date
                          LIMIT greatest(p_days, 1)) w);
BEGIN
    RETURN QUERY
    WITH actual AS (
        SELECT
            cs.first_production_line_id      AS production_line_id,
            cs.material_id,
            cs.production_date::date         AS date,
            sum(cs.sqm)                      AS actual_sqm
        FROM mapping.component_specs cs
        WHERE cs.production_date >= v_from
          AND cs.production_date < v_last + 1
          AND cs.internal_status_code <> 'cancelled'
          AND (p_material_id IS NULL OR cs.material_id = p_material_id)
        GROUP BY cs.first_production_line_id, cs.material_id, cs.production_date::date
    )
    SELECT
        pfm.date,
        pfm.production_line_id,
        pl.line,
        pfm.production_company_id,
        pfm.material_id,
        mpl.line_json ->> 'material_name' AS material_name,
        round(pfm.budget_sqm, 1) AS budget_sqm,
        round(COALESCE(a.actual_sqm, 0), 1) AS actual_sqm,
        round(pfm.forecast_sqm, 1) AS forecast_sqm,
        pfm.param_json
    FROM log.production_forecast_material pfm
    JOIN relation.production_line pl
      ON pl.line_id = pfm.production_line_id
     AND (p_line_type IS NULL OR pl.line_type = p_line_type)
    LEFT JOIN mapping.material_production_line mpl
      ON mpl.material_id = pfm.material_id
     AND mpl.production_line_id = pfm.production_line_id
    LEFT JOIN actual a
      ON a.production_line_id = pfm.production_line_id
     AND a.material_id = pfm.material_id
     AND a.date = pfm.date
    WHERE pfm.date BETWEEN v_from AND v_last
      AND (p_material_id IS NULL OR pfm.material_id = p_material_id)
    ORDER BY pfm.date, mpl.line_json ->> 'material_name';
END;
$$;

alter function mock.get_production_forecast_material(timestamp with time zone, integer, text, integer) owner to xfw3;
