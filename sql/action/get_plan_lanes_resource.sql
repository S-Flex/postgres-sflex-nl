-- One read for the resource lanes (labels) of the plan boards: resource_plan
-- (81) and whatever follows. One row per lane of a plan of the day, so one row
-- per machine that is planned: the lane names the resource
-- (action.resource_lane) and the step of that resource has to be a step planned
-- that day. A group lane has no row in resource_lane and is therefore no row
-- here.
--
-- p_steps null = every step planned that day, whatever the type of the plan:
-- the production plans and the impose plan (material-resource-plan) both name
-- their machines as resource lanes, so per step and type the newest plan of the
-- day wins.
--
-- The material lanes are action.get_plan_lanes_imposition_group. p_steps here
-- names the steps whose resources are lanes; p_step there names the step of the
-- plan to read — two different questions, so two reads.
--
-- A lane has no time of its own: the items bring the times (action.get_resource_plan).
create function action.get_plan_lanes_resource(p_until timestamp with time zone DEFAULT now(), p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_steps text[] DEFAULT NULL::text[]) returns TABLE(tenant_id integer, tenant_name text, step text, resource_path ltree, resource_uid text, resource_name text, sort_order numeric, param_json jsonb, formula jsonb, next_start_offset_in_seconds integer, lane_id bigint)
	stable
	language plpgsql
as $$
#variable_conflict use_column
DECLARE
    v_date date;
BEGIN
    v_date := (p_until AT TIME ZONE current_setting('TimeZone'))::date;

    RETURN QUERY
    WITH the_plan AS (
        -- per step and plan type the newest plan of this date and line type
        SELECT DISTINCT ON (s.step, p.type) s.step, p.plan_id
        FROM action.plan p
        CROSS JOIN LATERAL unnest(p.steps) AS s(step)
        WHERE p.plan_date = v_date
          AND (p_line_type IS NULL OR p.line_type = p_line_type)
          AND (p_steps IS NULL OR s.step = ANY (p_steps))
        ORDER BY s.step, p.type, p.plan_id DESC
    ),
    lane AS (
        -- the machine lanes of those plans; a lane two plans share counts once,
        -- with the sort order of the newest
        SELECT DISTINCT ON (rl.lane_id) rl.lane_id, rl.resource_path, pl.sort_order
        FROM the_plan tp
        JOIN action.plan_lane pl ON pl.plan_id = tp.plan_id
        JOIN action.resource_lane rl ON rl.lane_id = pl.lane_id
        ORDER BY rl.lane_id, tp.plan_id DESC
    )
    SELECT t.tenant_id, t.name, r.step,
           r.resource_path, r.resource_uid, r.resource_name,
           l.sort_order,
           -- the resource constants the board evaluates with
           production.get_setting_numbers(rs.setting_json),
           coalesce(rs.setting_json -> 'formula', '[]'::jsonb),
           -- the chaining offset belongs to the resource; the connector
           -- mechanism replaces this column later
           (r.resource_json ->> 'next_start_lag_in_seconds')::integer,
           l.lane_id
    FROM lane l
    JOIN relation.resource r ON r.resource_path = l.resource_path
    CROSS JOIN LATERAL (SELECT production.get_resource_setting(r.resource_path) AS setting_json) rs
    -- the site is position 0 of the path, the line type position 1
    LEFT JOIN site.tenant t ON t.abb = ltree2text(subpath(r.resource_path, 0, 1))
    -- the step of the resource itself has to be a step planned that day
    WHERE EXISTS (SELECT 1 FROM the_plan tp WHERE tp.step = r.step)
      AND (p_line_type IS NULL OR ltree2text(subpath(r.resource_path, 1, 1)) = p_line_type)
      AND (p_tenant_ids IS NULL OR t.tenant_id = ANY (p_tenant_ids))
    ORDER BY t.tenant_id, l.sort_order NULLS LAST, r.resource_path;
END;
$$;

alter function action.get_plan_lanes_resource(timestamp with time zone, text, integer[], text[]) owner to xfw3;
