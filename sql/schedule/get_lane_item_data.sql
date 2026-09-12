-- The effective data_json of a lane item (docs/plan-planning-schema.md §3.3).
-- An item with its own data_json is its own source. An item without one (a
-- step item made from the nest manifest) walks lane_item_dependency from to
-- to from, predecessor by predecessor, and stops at the first item on each
-- branch that has a data_json. One source: that data_json. Several sources (a
-- merge): the nearest one is the base, its batches and production_orderlines
-- become the union over all sources, and the stored summary is dropped, since
-- it belongs to one source only (the read computes it anyway). Helper of
-- schedule.get_schedule_lane_items; not a board read of its own.
drop function if exists schedule.get_lane_item_data(bigint);

create function schedule.get_lane_item_data(p_lane_item_id bigint) returns jsonb
    stable
    language sql
as $$
    WITH RECURSIVE walk AS (
        SELECT li.lane_item_id, li.data_json, 0 AS depth, array[li.lane_item_id] AS path
        FROM schedule.lane_item li
        WHERE li.lane_item_id = p_lane_item_id

        UNION ALL

        -- only an item without data_json looks further back
        SELECT p.lane_item_id, p.data_json, w.depth + 1, w.path || p.lane_item_id
        FROM walk w
        JOIN schedule.lane_item_dependency d ON d.to_lane_item_id = w.lane_item_id
        JOIN schedule.lane_item p ON p.lane_item_id = d.from_lane_item_id
        WHERE w.data_json IS NULL
          AND NOT (p.lane_item_id = ANY (w.path))
    ),
    source AS (
        SELECT DISTINCT ON (w.lane_item_id) w.lane_item_id, w.data_json, w.depth
        FROM walk w
        WHERE w.data_json IS NOT NULL
        ORDER BY w.lane_item_id, w.depth
    ),
    base AS (
        SELECT s.data_json, (SELECT count(*) FROM source) AS source_count
        FROM source s
        ORDER BY s.depth, s.lane_item_id
        LIMIT 1
    ),
    merged AS (
        SELECT (SELECT jsonb_agg(DISTINCT b) FROM source s
                CROSS JOIN LATERAL jsonb_array_elements(coalesce(s.data_json -> 'batches', '[]'::jsonb)) AS b) AS batches,
               (SELECT jsonb_agg(DISTINCT o) FROM source s
                CROSS JOIN LATERAL jsonb_array_elements(coalesce(s.data_json -> 'production_orderlines', '[]'::jsonb)) AS o) AS production_orderlines
    )
    SELECT CASE
               WHEN b.source_count = 1 THEN b.data_json
               ELSE (b.data_json - 'summary')
                    || jsonb_build_object('batches',               coalesce(m.batches, '[]'::jsonb),
                                          'production_orderlines', coalesce(m.production_orderlines, '[]'::jsonb))
           END
    FROM base b
    CROSS JOIN merged m;
$$;

alter function schedule.get_lane_item_data(bigint) owner to xfw3;
