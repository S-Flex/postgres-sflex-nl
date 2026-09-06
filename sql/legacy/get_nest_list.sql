-- The nests in a status, for the intermediate stock board (intermediate_stock):
-- the nest's own status (nest_json.internal_status_code, kept current from the
-- machine log by legacy.sync_nest_status_from_log), on a batch of the line,
-- and — when machines are named — with a log row on one of them. A nest whose
-- orderlines are all past the nest's own status is no stock any more (cut on a
-- machine without a log, or handled by hand) and stays out; a nest whose
-- orderlines are not found stays in, the orderline is the source for that
-- conclusion, not its absence.
drop function if exists legacy.get_nest_list(integer, text[], text[], boolean);

create function legacy.get_nest_list(p_production_line_id integer DEFAULT NULL::integer, p_resource_uids text[] DEFAULT NULL::text[], p_internal_status text[] DEFAULT ARRAY['printed'::text], p_require_thumbnail boolean DEFAULT true) returns TABLE(nest_name text, nest_id bigint, nested_at timestamp with time zone, printed_at timestamp with time zone, nest_json jsonb, sqm numeric, material_name text)
	stable
	language sql
as $$
    WITH candidate AS (
        SELECT DISTINCT ON (n.nest_name)
            n.nest_name,
            n.nest_id,
            n.nested_at,
            rdl.start_at AS printed_at,
            n.nest_json,
            (n.nest_json->>'amount')::numeric
                * (n.nest_json->>'width')::numeric
                * (n.nest_json->>'height')::numeric / 10000 AS sqm,
            mpl.line_json->>'name' AS material_name,
            ist.sequence AS status_sequence
        FROM legacy.nest n
        JOIN legacy.batch b
          ON b.batch_uid = n.batch_uid
         AND (p_production_line_id IS NULL
              OR (b.batch_json->>'production_line_id')::int = p_production_line_id)
        LEFT JOIN mapping.material_production_line mpl
          ON mpl.material_id = (n.nest_json->>'material_id')::int
        LEFT JOIN mapping.internal_status ist
          ON ist.code = n.nest_json->>'internal_status_code' AND ist.domain_id = n.domain_id
        LEFT JOIN LATERAL (
            -- log.data replaced legacy.resource_data_log
            SELECT d.start_at
            FROM log.data d
            WHERE d.nest_name = n.nest_name
              AND (p_resource_uids IS NULL OR d.resource_uid = ANY (p_resource_uids))
            ORDER BY d.start_at DESC NULLS LAST
            LIMIT 1
        ) rdl ON true
        WHERE n.nest_json->>'internal_status_code' = ANY (p_internal_status)
          AND (p_resource_uids IS NULL OR rdl.start_at IS NOT NULL)
          AND (NOT p_require_thumbnail
            OR NULLIF(n.nest_json->>'job_thumbnail', '') IS NOT NULL)
        ORDER BY n.nest_name, n.nested_at DESC NULLS LAST
    ),
    -- the least advanced orderline part per candidate nest, one detail call for the set
    orderline_floor AS (
        SELECT x.nest_id, min(o.status_sequence) AS min_sequence
        FROM (SELECT array_agg(c.nest_id) AS nest_ids FROM candidate c) ids
        CROSS JOIN LATERAL mapping.get_production_orderline_detail(
                 p_date => now(), p_date_type => 'nest', p_nest_ids => ids.nest_ids,
                 p_status_sequences => NULL, p_is_open => NULL) o
        CROSS JOIN LATERAL unnest(o.nest_ids) AS x(nest_id)
        WHERE x.nest_id = ANY (ids.nest_ids)
        GROUP BY x.nest_id
    )
    SELECT c.nest_name, c.nest_id, c.nested_at, c.printed_at, c.nest_json, c.sqm, c.material_name
    FROM candidate c
    LEFT JOIN orderline_floor f ON f.nest_id = c.nest_id
    WHERE f.min_sequence IS NULL
       OR c.status_sequence IS NULL
       OR f.min_sequence <= c.status_sequence
    ORDER BY c.nest_name;
$$;

alter function legacy.get_nest_list(integer, text[], text[], boolean) owner to xfw3;
