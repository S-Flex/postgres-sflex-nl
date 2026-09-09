-- the output column follows the renamed table, so the old signature goes first
drop function if exists mock.generate_plan(date, text, text);

-- Stamps the day plan of a step from the weekly pattern (mock.material_impose_plan):
-- the plan (type material-resource-plan), one material lane per pattern row
-- with its pattern item, and one resource lane per machine the pattern rows
-- name (resource_path), so the resource board reads the same items per
-- machine (get_resource_plan, stap 7c). The material items stay on their
-- material lanes; the resource lane carries no items of its own.
create function mock.generate_plan(p_date date, p_step text, p_line_type text) returns TABLE(plan_id bigint, lane_id bigint, material_impose_plan_id bigint)
	language sql
as $$
    WITH pattern AS (
        SELECT DISTINCT ON (m.sort_order)
               m.material_impose_plan_id, m.sort_order, m.material_id,
               m.start_offset_in_seconds, m.is_pinned, m.resource_path, m.instance
        FROM mock.material_impose_plan m
        WHERE m.weekday = extract(dow FROM p_date)::smallint + 1
          AND m.step = p_step
          AND m.production_line_id IN (
                SELECT DISTINCT production_line_id
                FROM mock.material_print_schedule
                WHERE line = p_line_type)
        ORDER BY m.sort_order, m.moved_at DESC, m.material_impose_plan_id DESC
    ),
    numbered_pattern AS (
        SELECT p.*, row_number() OVER (ORDER BY p.sort_order) AS rn FROM pattern p
    ),
    -- the machines the pattern names: one resource lane each. One lane per
    -- machine per day (resource_lane): a lane that already exists for the
    -- date is reused, the others are made below
    resource AS (
        SELECT r.resource_path, rl.lane_id AS existing_lane_id
        FROM (SELECT DISTINCT p.resource_path FROM pattern p WHERE p.resource_path IS NOT NULL) r
        LEFT JOIN LATERAL (
            SELECT rl.lane_id
            FROM action.resource_lane rl
            JOIN action.lane l ON l.lane_id = rl.lane_id
            WHERE rl.resource_path = r.resource_path AND l.lane_date = p_date
            ORDER BY rl.lane_id LIMIT 1
        ) rl ON true
    ),
    numbered_resource AS (
        SELECT r.resource_path, row_number() OVER (ORDER BY r.resource_path) AS rn
        FROM resource r
        WHERE r.existing_lane_id IS NULL
    ),
    new_plan AS (
        -- tenant_ids: the tenants that run this line_type
        INSERT INTO action.plan (plan_date, steps, type, line_type, tenant_ids)
        SELECT p_date, array[p_step], 'material-resource-plan', p_line_type,
               (SELECT array_agg(DISTINCT pl.tenant_id ORDER BY pl.tenant_id)
                       FILTER (WHERE pl.tenant_id IS NOT NULL)
                FROM relation.production_line pl
                WHERE pl.line_type = p_line_type)
        RETURNING plan_id
    ),
    -- group lanes: one fresh lane per pattern row, with the imposition group
    -- of the row on it (imposition_group_lane); the group ids were seeded 1:1
    -- from the material ids
    -- the lane carries its step and its impose path (site.line.impose.width)
    new_lane AS (
        INSERT INTO action.lane (lane_date, step, resource_path)
        SELECT p_date, p_step, subpath(p.resource_path, 0, 4)
        FROM numbered_pattern p
        ORDER BY p.rn
        RETURNING lane_id
    ),
    numbered_lane AS (
        SELECT nl.lane_id, row_number() OVER (ORDER BY nl.lane_id) AS rn FROM new_lane nl
    ),
    new_group_lane AS (
        INSERT INTO action.imposition_group_lane (lane_id, imposition_group_id)
        SELECT nl.lane_id, p.material_id
        FROM numbered_lane nl
        JOIN numbered_pattern p USING (rn)
        WHERE p.material_id IS NOT NULL
        RETURNING lane_id
    ),
    new_plan_lane AS (
        INSERT INTO action.plan_lane (plan_id, lane_id, sort_order)
        SELECT np.plan_id, nl.lane_id, p.sort_order
        FROM numbered_lane nl
        JOIN numbered_pattern p USING (rn)
        CROSS JOIN new_plan np
        RETURNING plan_id, lane_id, sort_order
    ),
    -- resource lanes: one fresh lane per machine without one; in the plan's
    -- order they follow the material lanes (plan_lane.sort_order is unique
    -- per plan)
    new_resource_lane_row AS (
        INSERT INTO action.lane (lane_date, step, resource_path)
        SELECT p_date, p_step, r.resource_path
        FROM numbered_resource r
        ORDER BY r.rn
        RETURNING lane_id
    ),
    numbered_resource_lane AS (
        SELECT nl.lane_id, row_number() OVER (ORDER BY nl.lane_id) AS rn FROM new_resource_lane_row nl
    ),
    new_resource_lane AS (
        INSERT INTO action.resource_lane (lane_id, resource_path)
        SELECT nl.lane_id, r.resource_path
        FROM numbered_resource_lane nl
        JOIN numbered_resource r USING (rn)
        RETURNING lane_id
    ),
    new_resource_plan_lane AS (
        INSERT INTO action.plan_lane (plan_id, lane_id, sort_order)
        SELECT np.plan_id, x.lane_id,
               coalesce((SELECT max(p.sort_order) FROM pattern p), 0) + 1000 + row_number() OVER (ORDER BY x.resource_path)
        FROM (SELECT nl.lane_id, r.resource_path
              FROM numbered_resource_lane nl
              JOIN numbered_resource r USING (rn)
              UNION ALL
              SELECT r.existing_lane_id, r.resource_path
              FROM resource r
              WHERE r.existing_lane_id IS NOT NULL) x
        CROSS JOIN new_plan np
        RETURNING lane_id
    ),
    -- one slot per lane, stamped from the pattern row: the planned moment
    -- the client moves, pins and copies. The pattern stays the template.
    new_lane_item AS (
        INSERT INTO action.lane_item
            (lane_id, sort_order, start_offset_in_seconds, is_pinned,
             no_split, type, source, source_ref, instance)
        SELECT nl.lane_id, p.sort_order, p.start_offset_in_seconds,
               coalesce(p.is_pinned, false), true, 'plan',
               'material-plan', p.material_impose_plan_id || ':' || p_date,
               p.instance
        FROM numbered_lane nl
        JOIN numbered_pattern p USING (rn)
        RETURNING lane_item_id, lane_id
    ),
    -- the imposition group of the slot, on the item (the group ids were
    -- seeded 1:1 from the material ids)
    new_imposition_group_lane_item AS (
        INSERT INTO action.imposition_group_lane_item (imposition_group_id, lane_item_id)
        SELECT p.material_id, nli.lane_item_id
        FROM new_lane_item nli
        JOIN numbered_lane nl ON nl.lane_id = nli.lane_id
        JOIN numbered_pattern p USING (rn)
        WHERE p.material_id IS NOT NULL
        RETURNING lane_item_id
    )
    -- No lane-to-pattern table any more: action.lane_item.source_ref carries
    -- <material_impose_plan_id>:<date>, so the link is on the item itself.
    -- The inserts above still run — a data-modifying CTE always executes,
    -- referenced or not.
    SELECT (SELECT plan_id FROM new_plan), npl.lane_id, p.material_impose_plan_id
    FROM new_plan_lane npl
    JOIN numbered_pattern p ON p.sort_order = npl.sort_order;
$$;

alter function mock.generate_plan(date, text, text) owner to xfw3;
