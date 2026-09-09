create function mapping.get_ticket_trend_by_production_line(p_until timestamp with time zone, p_weeks integer, p_production_line_id integer) returns TABLE(r_week_start date, r_year integer, r_week integer, r_ticket_count bigint, r_orderline_count bigint, r_ticket_percentage numeric, r_trend_direction text, r_trend_block jsonb)
	language sql
as $$
    WITH params AS (
        SELECT COALESCE(p_until, now()) AS until_ts
    ),
    week_series AS (
        SELECT date_trunc('week', generate_series(
            (SELECT until_ts FROM params) - (p_weeks - 1) * interval '1 week',
            (SELECT until_ts FROM params),
            '1 week'::interval
        ))::date AS week_start
    ),
    ticket_counts AS (
        SELECT
            date_trunc('week', t.created_at)::date AS week_start,
            COUNT(*) AS ticket_count
        FROM mapping.ticket t, params p
        WHERE t.created_at >= p.until_ts - (p_weeks - 1) * interval '1 week'
          AND t.created_at < p.until_ts + interval '1 day'
          AND t.production_line_id = p_production_line_id
          AND t.deleted_at IS NULL
        GROUP BY date_trunc('week', t.created_at)::date
    ),
    orderline_counts AS (
        SELECT
            date_trunc('week', cs.production_date)::date AS week_start,
            -- one row per orderline (uq_component_specs_orderline_id), so no distinct;
            -- the scan is index-only on (resolved_production_line_id, production_date)
            COUNT(*) AS orderline_count
        FROM mapping.component_specs cs, params p
        WHERE cs.production_date >= p.until_ts - (p_weeks - 1) * interval '1 week'
          AND cs.production_date < p.until_ts + interval '1 day'
          AND cs.resolved_production_line_id = p_production_line_id
        GROUP BY date_trunc('week', cs.production_date)::date
    ),
    weekly AS (
        SELECT
            ws.week_start,
            EXTRACT(isoyear FROM ws.week_start)::integer AS year,
            EXTRACT(week FROM ws.week_start)::integer AS week,
            COALESCE(tc.ticket_count, 0) AS ticket_count,
            COALESCE(oc.orderline_count, 0) AS orderline_count,
            CASE
                WHEN COALESCE(oc.orderline_count, 0) = 0 THEN NULL
                ELSE ROUND(COALESCE(tc.ticket_count, 0)::numeric * 100.0 / oc.orderline_count, 3)
            END AS ticket_percentage,
            row_number() OVER (ORDER BY ws.week_start) - 1 AS x_index
        FROM week_series ws
        LEFT JOIN ticket_counts tc ON tc.week_start = ws.week_start
        LEFT JOIN orderline_counts oc ON oc.week_start = ws.week_start
    ),
    trend AS (
        SELECT
            COUNT(*) FILTER (WHERE ticket_percentage IS NOT NULL) AS valid_points,
            CASE
                WHEN COUNT(*) FILTER (WHERE ticket_percentage IS NOT NULL) < 2 THEN 0
                ELSE regr_slope(ticket_percentage, x_index)
            END AS slope
        FROM weekly
    ),
    trend_resolved AS (
        SELECT
            CASE
                WHEN t.valid_points < 2 THEN 'insufficient-data'
                WHEN t.slope <= -0.01 THEN 'falling'
                WHEN t.slope >=  0.01 THEN 'rising'
                ELSE 'stable'
            END AS direction
        FROM trend t
    ),
    trend_lookup AS (
        SELECT
            tr.direction,
            entry AS block
        FROM trend_resolved tr
        LEFT JOIN legacy.lookup l ON l.lookup = 'lookup_trend'
        LEFT JOIN LATERAL jsonb_array_elements(l.lookup_json) AS entry ON entry->>'code' = tr.direction
    )
    SELECT
        w.week_start,
        w.year,
        w.week,
        w.ticket_count,
        w.orderline_count,
        w.ticket_percentage,
        tl.direction AS r_trend_direction,
        tl.block AS r_trend_block
    FROM weekly w, trend_lookup tl
    ORDER BY w.week_start;
$$;

alter function mapping.get_ticket_trend_by_production_line(timestamp with time zone, integer, integer) owner to xfw3;

