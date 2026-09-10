drop function if exists action.crud_lane_item(jsonb, boolean);

create function action.crud_lane_item(p_param_json jsonb, p_no_results boolean DEFAULT false) returns TABLE(param_id integer, track_by integer, crud text, lane_item_id bigint, lane_id bigint, material_print_schedule_id bigint)
	language sql
as $$
    -- The client mutations of the planning boards, on lane_item level: the
    -- stored_proc of the data tables get_impose_plan and
    -- get_plan_lanes_imposition_group. One element per mutation:
    --   {"crud": "update", "track_by": 1,
    --    "data": {"lane_item_id": 8842, "start_offset_in_seconds": 43200,
    --             "sort_order": 20450, "is_pinned": true}}
    -- crud is create, update or delete; track_by is the order of the
    -- mutations in the batch and comes back on the result row; data carries
    -- the properties: lane_item_id (update, delete, the source of a copy),
    -- start_offset_in_seconds, sort_order, is_pinned, and for a create lane_id,
    -- plan_id, imposition_group_id and, for a copy that needs a fresh lane,
    -- resource_path (the impose path of the lane, site.line.impose.width; a
    -- copy on an existing lane takes the lane's). A property left out of
    -- data keeps its value. A copy is one more moment of the source item's
    -- nest moment (nest_moment_code), the next instance on its lane. The
    -- stamped day is the truth: nothing writes through to the schedule
    -- (mock.material_print_schedule), a move stays on the item.
    --   update — move/pin/sort the item
    --   create — an extra moment: the lane (a fresh one when asked) and the item
    --   delete — the moment; its batch rows, events and links cascade
    --
    -- Set-based throughout: ids are drawn from the sequences up front, so a
    -- created row can be paired back to its payload row without a temp table.
    WITH payload AS (
        SELECT row_number() OVER (ORDER BY coalesce((t.element ->> 'track_by')::integer, 0))::integer AS param_id,
               coalesce((t.element ->> 'track_by')::integer, 0) AS track_by,
               t.element ->> 'crud'                             AS crud,
               te.lane_item_id, te.lane_id, te.plan_id,
               te.start_offset_in_seconds, te.sort_order, te.is_pinned,
               te.imposition_group_id, te.resource_path
        FROM jsonb_array_elements(p_param_json) AS t(element)
        CROSS JOIN LATERAL jsonb_to_record(coalesce(t.element -> 'data', '{}'::jsonb)) AS te(
            lane_item_id bigint, lane_id bigint, plan_id bigint,
            start_offset_in_seconds integer, sort_order numeric,
            is_pinned boolean, imposition_group_id integer, resource_path ltree)
    ),
    -- what an update or a copy starts from: the item, its lane and the
    -- schedule row it was stamped from (source_ref is
    -- <material_print_schedule_id>:<date>:<instance>)
    source AS (
        SELECT p.param_id,
               li.lane_item_id, li.lane_id, li.sort_order, li.start_offset_in_seconds,
               li.is_pinned, li.duration_in_seconds, li.nest_moment_code,
               l.lane_date, l.resource_path,
               -- only a material item names a schedule row
               CASE WHEN li.source = 'material-plan'
                    THEN nullif(split_part(li.source_ref, ':', 1), '')::bigint END AS material_print_schedule_id,
               igli.imposition_group_id
        FROM payload p
        JOIN action.lane_item li ON li.lane_item_id = p.lane_item_id
        JOIN action.lane l       ON l.lane_id = li.lane_id
        LEFT JOIN action.imposition_group_lane_item igli ON igli.lane_item_id = li.lane_item_id
    ),
    -- ── update ────────────────────────────────────────────────────────────
    updated_item AS (
        UPDATE action.lane_item li
        SET sort_order              = coalesce(p.sort_order, li.sort_order),
            start_offset_in_seconds = coalesce(p.start_offset_in_seconds, li.start_offset_in_seconds),
            is_pinned               = coalesce(p.is_pinned, li.is_pinned)
        FROM payload p
        WHERE p.crud = 'update' AND li.lane_item_id = p.lane_item_id
        RETURNING li.lane_item_id, li.lane_id
    ),
    -- ── create ────────────────────────────────────────────────────────────
    -- ids up front: the lane (only for a copy that needs its own lane) and
    -- the item itself
    new_id AS (
        SELECT p.param_id, p.track_by, p.plan_id, p.sort_order, p.is_pinned,
               p.start_offset_in_seconds, p.lane_id AS given_lane_id,
               coalesce(p.imposition_group_id, s.imposition_group_id) AS imposition_group_id,
               coalesce(p.resource_path, s.resource_path)             AS resource_path,
               s.material_print_schedule_id, s.nest_moment_code,
               s.lane_id AS from_lane_id,
               nextval('action.lane_item_lane_item_id_seq') AS new_lane_item_id,
               CASE WHEN p.lane_id IS NULL AND s.lane_id IS NULL
                    THEN nextval('action.lane_lane_id_seq') END AS new_lane_id
        FROM payload p
        LEFT JOIN source s ON s.param_id = p.param_id
        WHERE p.crud = 'create'
    ),
    target AS (
        SELECT n.*,
               coalesce(n.given_lane_id, n.from_lane_id, n.new_lane_id) AS lane_id,
               coalesce(pl.plan_date, l.lane_date)                      AS lane_date
        FROM new_id n
        LEFT JOIN action.plan pl ON pl.plan_id = n.plan_id
        LEFT JOIN action.lane l  ON l.lane_id = coalesce(n.given_lane_id, n.from_lane_id)
    ),
    -- a fresh lane is an impose lane on the path given, else the source's
    new_lane AS (
        INSERT INTO action.lane (lane_id, lane_date, step, resource_path)
        OVERRIDING SYSTEM VALUE
        SELECT t.new_lane_id, t.lane_date, 'impose', t.resource_path
        FROM target t WHERE t.new_lane_id IS NOT NULL
        RETURNING lane_id
    ),
    -- a fresh lane on a material board is a group lane
    new_group_lane AS (
        INSERT INTO action.imposition_group_lane (lane_id, imposition_group_id)
        SELECT t.new_lane_id, t.imposition_group_id
        FROM target t WHERE t.new_lane_id IS NOT NULL AND t.imposition_group_id IS NOT NULL
        RETURNING lane_id
    ),
    new_plan_lane AS (
        INSERT INTO action.plan_lane (plan_id, lane_id, sort_order)
        SELECT t.plan_id, t.new_lane_id,
               coalesce(t.sort_order,
                        (SELECT coalesce(max(pl2.sort_order), 0) + 1000
                         FROM action.plan_lane pl2 WHERE pl2.plan_id = t.plan_id))
        FROM target t WHERE t.new_lane_id IS NOT NULL AND t.plan_id IS NOT NULL
        RETURNING lane_id
    ),
    -- the place of the new item on its lane: the next instance, and without a
    -- rank from the client a rank behind the lane, spread so a batch never
    -- collides on the unique (lane_id, sort_order)
    placed AS (
        SELECT t.*,
               ((SELECT coalesce(max(li3.instance), -1)
                 FROM action.lane_item li3 WHERE li3.lane_id = t.lane_id AND li3.type = 'plan')
                + row_number() OVER (PARTITION BY t.lane_id ORDER BY t.param_id))::integer AS instance,
               coalesce(t.sort_order,
                        (SELECT coalesce(max(li2.sort_order), 0)
                         FROM action.lane_item li2 WHERE li2.lane_id = t.lane_id)
                        + 1000 * row_number() OVER (ORDER BY t.param_id)) AS item_sort_order
        FROM target t
        WHERE t.lane_id IS NOT NULL
    ),
    new_item AS (
        INSERT INTO action.lane_item
            (lane_item_id, lane_id, sort_order, start_offset_in_seconds,
             duration_in_seconds, is_pinned, no_split, type, source, source_ref,
             instance, nest_moment_code)
        OVERRIDING SYSTEM VALUE
        SELECT pl.new_lane_item_id, pl.lane_id, pl.item_sort_order,
               coalesce(pl.start_offset_in_seconds, 0), 0,
               coalesce(pl.is_pinned, false), true, 'plan', 'material-plan',
               -- the shape generate_plan stamps; a create without a source
               -- item names no schedule row and gets no ref
               pl.material_print_schedule_id || ':' || pl.lane_date || ':' || pl.instance,
               pl.instance, pl.nest_moment_code
        FROM placed pl
        RETURNING lane_item_id, lane_id
    ),
    new_group_link AS (
        INSERT INTO action.imposition_group_lane_item (imposition_group_id, lane_item_id)
        SELECT t.imposition_group_id, t.new_lane_item_id
        FROM target t
        WHERE t.imposition_group_id IS NOT NULL AND t.lane_id IS NOT NULL
        ON CONFLICT DO NOTHING
        RETURNING lane_item_id
    ),
    -- ── delete ────────────────────────────────────────────────────────────
    deleted_item AS (
        DELETE FROM action.lane_item li
        USING payload p
        WHERE p.crud = 'delete' AND li.lane_item_id = p.lane_item_id
        RETURNING li.lane_item_id
    )
    SELECT p.param_id, p.track_by, p.crud,
           coalesce(t.new_lane_item_id, p.lane_item_id),
           coalesce(t.lane_id, p.lane_id),
           s.material_print_schedule_id
    FROM payload p
    LEFT JOIN target t ON t.param_id = p.param_id
    LEFT JOIN source s ON s.param_id = p.param_id
    WHERE NOT p_no_results
    ORDER BY p.param_id;
$$;

alter function action.crud_lane_item(jsonb, boolean) owner to xfw3;
