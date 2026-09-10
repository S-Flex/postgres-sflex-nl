-- the return column follows the schedule, so the old signature goes first
drop function if exists mock.generate_plan(date, text, text);

-- Stamps the day plan of a step from mock.material_print_schedule: the plan
-- (type material-resource-plan), one material lane per schedule row of the
-- line whose interval (interval_start_date, interval_days through
-- action.get_interval_dates) says p_date is a production day and that names
-- an impose path, with one item per nest moment code of the row
-- (lane_item.nest_moment_code; instance 0, 1, 2 in moment order,
-- production.get_nest_moment_instances), and one resource lane per impose
-- machine the rows name (resource_path), so the resource board reads the same
-- items per machine (get_resource_plan). The material items stay on their
-- material lanes; the resource lane carries no items of its own. A row
-- without an impose path has no lane yet. The plan is made even when the line
-- has no rows, so the daily refresh (site.refresh_derived_data) does not make
-- it again. A stamped day is the truth from then on: a move on the board
-- changes the item, not the schedule.
create function mock.generate_plan(p_date date, p_step text, p_line_type text) returns TABLE(plan_id bigint, lane_id bigint, material_print_schedule_id bigint)
	language sql
as $$
    WITH schedule AS (
        SELECT mps.material_print_schedule_id, mps.material_id, mps.production_line_id,
               mps.tenant_id, mps.resource_path, mps.nest_moment_codes,
               coalesce(mps.sort_order, 1000000 + mps.material_print_schedule_id) AS sort_order,
               row_number() OVER (ORDER BY coalesce(mps.sort_order, 1000000 + mps.material_print_schedule_id),
                                           mps.material_print_schedule_id) AS rn
        FROM mock.material_print_schedule mps
        WHERE mps.line = p_line_type
          AND mps.resource_path IS NOT NULL
          AND coalesce(cardinality(mps.nest_moment_codes), 0) > 0
          -- p_date is a production day of the row: the anchor is the first
          -- workday of its tenant at or after interval_start_date (the same
          -- rule as the lanes read)
          AND EXISTS (
                SELECT 1
                FROM action.get_interval_dates(
                         (SELECT min(d.date)
                          FROM action.dates d
                          WHERE d.date >= coalesce(mps.interval_start_date, p_date)
                            AND d.is_weekend = false
                            AND NOT (array[mps.tenant_id] <@ d.tenants_mandatory_day_off
                                     AND d.tenants_mandatory_day_off <> '{}')),
                         p_date, coalesce(nullif(mps.interval_days, 0), 1), 1,
                         false, false, 0, array[mps.tenant_id]) AS i(interval_date)
                WHERE i.interval_date = p_date)
    ),
    -- the machines the rows name: one resource lane each. One lane per
    -- machine per day (resource_lane): a lane that already exists for the
    -- date is reused, the others are made below
    resource AS (
        SELECT r.resource_path, rl.lane_id AS existing_lane_id
        FROM (SELECT DISTINCT s.resource_path FROM schedule s) r
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
    -- group lanes: one fresh lane per schedule row, with the imposition group
    -- of the row on it (imposition_group_lane; the group ids were seeded 1:1
    -- from the material ids). The lane carries its step and its impose path
    -- (site.line.impose.width)
    new_lane AS (
        INSERT INTO action.lane (lane_date, step, resource_path)
        SELECT p_date, p_step, subpath(s.resource_path, 0, 4)
        FROM schedule s
        ORDER BY s.rn
        RETURNING lane_id
    ),
    numbered_lane AS (
        SELECT nl.lane_id, row_number() OVER (ORDER BY nl.lane_id) AS rn FROM new_lane nl
    ),
    new_group_lane AS (
        INSERT INTO action.imposition_group_lane (lane_id, imposition_group_id)
        SELECT nl.lane_id, s.material_id
        FROM numbered_lane nl
        JOIN schedule s USING (rn)
        WHERE s.material_id IS NOT NULL
        RETURNING lane_id
    ),
    new_plan_lane AS (
        INSERT INTO action.plan_lane (plan_id, lane_id, sort_order)
        SELECT np.plan_id, nl.lane_id, s.sort_order
        FROM numbered_lane nl
        JOIN schedule s USING (rn)
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
               coalesce((SELECT max(s.sort_order) FROM schedule s), 0) + 1000 + row_number() OVER (ORDER BY x.resource_path)
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
    -- the items: one per nest moment of the row, in moment order. No time of
    -- its own yet (the lanes read serves the moment of its class), not pinned;
    -- the ref names the schedule row, the day and the instance, so the item is
    -- found again (unique (source, source_ref))
    new_lane_item AS (
        INSERT INTO action.lane_item
            (lane_id, sort_order, start_offset_in_seconds, is_pinned,
             no_split, type, source, source_ref, instance, nest_moment_code)
        SELECT nl.lane_id, s.sort_order + m.instance, NULL, false, true, 'plan',
               'material-plan', s.material_print_schedule_id || ':' || p_date || ':' || m.instance,
               m.instance, m.nest_moment_code
        FROM numbered_lane nl
        JOIN schedule s USING (rn)
        CROSS JOIN LATERAL production.get_nest_moment_instances(s.nest_moment_codes) AS m
        RETURNING lane_item_id, lane_id
    ),
    -- the imposition group of the item (the group ids were seeded 1:1 from
    -- the material ids)
    new_imposition_group_lane_item AS (
        INSERT INTO action.imposition_group_lane_item (imposition_group_id, lane_item_id)
        SELECT s.material_id, nli.lane_item_id
        FROM new_lane_item nli
        JOIN numbered_lane nl ON nl.lane_id = nli.lane_id
        JOIN schedule s USING (rn)
        WHERE s.material_id IS NOT NULL
        RETURNING lane_item_id
    )
    -- The inserts above always run: a data-modifying CTE executes,
    -- referenced or not.
    SELECT (SELECT plan_id FROM new_plan), nl.lane_id, s.material_print_schedule_id
    FROM numbered_lane nl
    JOIN schedule s USING (rn);
$$;

alter function mock.generate_plan(date, text, text) owner to xfw3;
