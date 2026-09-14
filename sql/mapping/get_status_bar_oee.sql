-- The OEE items of the status bar for one production line: the report of the
-- business day of p_until (log.get_oee_report), its params summed over the
-- machines of the line, the rules of production.formula 'oee-report' evaluated
-- on the sums. p_items is the items list of the status_bar lookup group
-- (code = a key of oee_json, i18n its title); the value is that key, rounded.
create function mapping.get_status_bar_oee(p_model text, p_until timestamp with time zone, p_line_id integer, p_items jsonb) returns jsonb
    stable
    language sql
as $$
    WITH day AS (
        SELECT (coalesce(p_until, now()) AT TIME ZONE 'Europe/Amsterdam')::date AS date
    ),
    params AS (
        -- the day rows of the machines of the line, every param summed
        SELECT jsonb_object_agg(kv.key, kv.total) AS param_json
        FROM (
            SELECT kv.key, sum(kv.value::numeric) AS total
            FROM day d
            CROSS JOIN LATERAL log.get_oee_report(d.date, d.date) r
            JOIN relation.resource res ON res.resource_uid = r.resource_uid
            CROSS JOIN LATERAL jsonb_each_text(r.param_json) AS kv(key, value)
            WHERE res.line_id = p_line_id
              AND r.report_date IS NOT NULL
            GROUP BY kv.key
        ) kv
    ),
    result AS (
        SELECT public.evaluate_many_nas(gf.formula_json, p.param_json) AS oee_json
        FROM params p
        CROSS JOIN production.get_formula(array['oee-report']) gf
        WHERE p.param_json IS NOT NULL
    )
    SELECT coalesce(jsonb_agg(
               jsonb_build_object(
                   'code',  i.value ->> 'code',
                   'i18n',  i.value -> 'i18n',
                   'value', round(coalesce((res.oee_json ->> (i.value ->> 'code'))::numeric, 0), 1))
               ORDER BY i.ordinality), '[]'::jsonb)
    FROM jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) WITH ORDINALITY AS i
    LEFT JOIN result res ON true;
$$;

alter function mapping.get_status_bar_oee(text, timestamp with time zone, integer, jsonb) owner to xfw3;
