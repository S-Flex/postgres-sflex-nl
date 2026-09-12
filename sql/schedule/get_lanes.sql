-- The lanes (labels) of the schedule boards (docs/plan-planning-schema.md §4):
-- one row per lane whose day is in view. A lane is one step on one machine on
-- one day; the material boards group its items, not its lanes. The formula and
-- constants of the machine come from production.resource_setting, so the board
-- evaluates durations the same way on every board.
--
-- p_from and p_until are the days in view, both included; inside they are one
-- datemultirange, so a p_dates datemultirange can replace the pair without a
-- change below once the frontend sends one. p_steps null = every step,
-- p_line_type null = every line type, p_tenant_ids null = every tenant (the
-- tenant of a lane is the first label of its path, site.tenant.abb).
drop function if exists schedule.get_lanes(date, date, text, integer[], text[]);

create function schedule.get_lanes(p_from date DEFAULT current_date, p_until date DEFAULT current_date, p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_steps text[] DEFAULT NULL::text[])
    returns TABLE(plan_id bigint, lane_id bigint, lane_date date, step text, resource_path ltree, resource_uid text, resource_name text, tenant_id integer, tenant_name text, sort_order numeric, param_json jsonb, formula jsonb)
    stable
    language plpgsql
as $$
#variable_conflict use_column
DECLARE
    v_dates datemultirange;
BEGIN
    v_dates := datemultirange(daterange(least(p_from, p_until), greatest(p_from, p_until), '[]'));

    RETURN QUERY
    SELECT p.plan_id, l.lane_id, l.lane_date, l.step, l.resource_path,
           r.resource_uid, r.resource_name,
           t.tenant_id, t.name,
           l.sort_order,
           -- the resource constants the board evaluates with, and its formula
           production.get_setting_numbers(rs.setting_json),
           coalesce(rs.setting_json -> 'formula', '[]'::jsonb)
    FROM schedule.lane l
    JOIN schedule.plan p ON p.plan_id = l.plan_id
    -- an impose lane carries a branch path (site.line.impose.width): no
    -- machine of its own, so no uid and no name
    LEFT JOIN relation.resource r ON r.resource_path = l.resource_path
    CROSS JOIN LATERAL (SELECT production.get_resource_setting(l.resource_path) AS setting_json) rs
    -- the site is the first label of the path
    LEFT JOIN site.tenant t ON t.abb = ltree2text(subpath(l.resource_path, 0, 1))
    WHERE l.lane_date <@ v_dates
      AND (p_line_type IS NULL OR p.line_type = p_line_type)
      AND (p_steps IS NULL OR l.step = ANY (p_steps))
      AND (p_tenant_ids IS NULL OR t.tenant_id = ANY (p_tenant_ids))
    ORDER BY l.lane_date, t.tenant_id, l.sort_order, l.resource_path;
END;
$$;

alter function schedule.get_lanes(date, date, text, integer[], text[]) owner to xfw3;
