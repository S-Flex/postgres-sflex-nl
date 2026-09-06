-- the output column follows the renamed table, so the old signature goes first
drop function if exists mock.generate_plan(date, text, text);

create function mock.generate_plan(p_date date, p_step text, p_line_type text) returns TABLE(plan_id bigint, lane_id bigint, material_impose_plan_id bigint)
	language sql
as $$
    WITH pattern AS (
        SELECT DISTINCT ON (m.sort_order)
               m.material_impose_plan_id, m.sort_order, m.material_id,
               m.start_offset_in_seconds, m.is_pinned
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
    new_lane AS (
        INSERT INTO action.lane (lane_date)
        SELECT p_date FROM pattern
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
    -- one slot per lane, stamped from the pattern row: the planned moment
    -- the client moves, pins and copies. The pattern stays the template.
    new_lane_item AS (
        INSERT INTO action.lane_item
            (lane_id, sort_order, start_offset_in_seconds, is_pinned,
             no_split, type, source, source_ref)
        SELECT nl.lane_id, p.sort_order, p.start_offset_in_seconds,
               coalesce(p.is_pinned, false), true, 'plan',
               'material-plan', p.material_impose_plan_id || ':' || p_date
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
