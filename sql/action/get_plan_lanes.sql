-- One read for the lanes (labels) of every plan board: print_schedule,
-- impose_plan, resource_plan and whatever
-- follows. Moved from mock to action: the lane model lives here.
--
-- Two modes, switched by p_steps:
--   * p_steps null — material lanes: one row per planned moment of the
--     newest plan of the day (p_plan_type), reached through
--     lane_item.source_ref (<material_impose_plan_id>:<date>), plus the
--     tenant noop windows. Feeds print_schedule and impose_plan
--     (imposition_group_id is the material_id alias until the xbom groups
--     arrive).
--   * p_steps set, or p_plan_type 'production-plan' — resource lanes: one row
--     per resource whose step is in the list, line via path position 1,
--     tenant via path position 0 (the site abb). For a 'production-plan' the
--     day's plans are the source: per step the newest plan that covers it,
--     only resources with a lane in those plans, lane_id and
--     plan_lane.sort_order ride along; p_steps null = every step planned that
--     day (the resource board, get_resource_plan, reads the same). For other
--     plan types (impose: the material plan has no resource lanes) every
--     resource of the steps is a lane, lane_id null.
--
-- The offset rule: only a fixed group (coalesce(item, class moment from
-- lookup_nest_moments)) or a pinned item (its own offset) carries
-- start_offset_in_seconds. Every other item is a filler and serves null —
-- the client chains fillers itself (chain_scope), a moved-but-unpinned item
-- springs back on refresh.
--
-- Duration is not computed here. The row carries the formula of its resource
-- and the variables, and the board evaluates — otherwise a drag to another
-- resource could not change the duration. The chaining offset
-- (next_start_offset_in_seconds) belongs to the resource:
-- resource_json.next_start_lag_in_seconds; the connector mechanism replaces
-- this column later.
drop function if exists mock.get_plan_lanes(timestamp with time zone, text, text, integer[], boolean, text);
drop function if exists action.get_plan_lanes(timestamp with time zone, text, text, integer[], boolean, text);
drop function if exists action.get_plan_lanes(timestamp with time zone, text, text, integer[], boolean, text, text[]);

create function action.get_plan_lanes(p_until timestamp with time zone DEFAULT now(), p_step text DEFAULT 'print'::text, p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_only_starting_today boolean DEFAULT false, p_plan_type text DEFAULT 'material-resource-plan'::text, p_steps text[] DEFAULT NULL::text[]) returns TABLE(imposition_group_id integer, material_id integer, material_name text, production_line_id integer, tenant_id integer, tenant_name text, resource_path ltree, resource_uid text, resource_name text, delivery_hours integer, min_delivery_hours integer, sort_order numeric, param_json jsonb, formula jsonb, data jsonb, fixed_group text, is_pinned boolean, start_offset_in_seconds integer, next_start_offset_in_seconds integer, lane_item_id bigint, lane_id bigint)
	stable
	language plpgsql
as $$
#variable_conflict use_column
DECLARE
    v_date  date;
    v_fixed jsonb;
BEGIN
    v_date := (p_until AT TIME ZONE current_setting('TimeZone'))::date;

    -- resource mode: one lane per resource of the steps
    IF p_steps IS NOT NULL OR p_plan_type = 'production-plan' THEN
        RETURN QUERY
        WITH tenant AS (
            SELECT (v.value ->> 'tenant_id')::integer AS tenant_id,
                   v.value ->> 'name'                 AS tenant_name,
                   v.value ->> 'abb'                  AS abb
            FROM relation.lookup lk
            CROSS JOIN LATERAL jsonb_array_elements(lk.lookup_json) AS v(value)
            WHERE lk.lookup = 'lookup_tenants'
        ),
        wanted_step AS (
            -- the steps asked, else every step a plan of the day carries
            SELECT DISTINCT s.step
            FROM action.plan p
            CROSS JOIN LATERAL unnest(p.steps) AS s(step)
            WHERE p.plan_date = v_date AND p.type = p_plan_type
              AND (p_line_type IS NULL OR p.line_type = p_line_type)
              AND (p_steps IS NULL OR s.step = ANY (p_steps))
        ),
        the_plan AS (
            -- per step the newest plan of this date, type and line type
            SELECT DISTINCT ON (ws.step) ws.step, p.plan_id
            FROM wanted_step ws
            JOIN action.plan p ON ws.step = ANY (p.steps)
            WHERE p.plan_date = v_date AND p.type = p_plan_type
              AND (p_line_type IS NULL OR p.line_type = p_line_type)
            ORDER BY ws.step, p.plan_id DESC
        ),
        plan_lane AS (
            -- the machine-day lanes of those plans; a group lane has no row here
            SELECT DISTINCT ON (rl.lane_id) rl.lane_id, pl.sort_order, rl.resource_path
            FROM the_plan tp
            JOIN action.plan_lane pl USING (plan_id)
            JOIN action.resource_lane rl ON rl.lane_id = pl.lane_id
            ORDER BY rl.lane_id, tp.plan_id DESC
        )
        SELECT NULL::integer, NULL::integer, NULL::text, NULL::integer,
               t.tenant_id, t.tenant_name,
               r.resource_path, r.resource_uid, r.resource_name,
               NULL::integer, NULL::integer,
               pl.sort_order,
               -- the resource constants the board evaluates with; numbers
               -- only — evaluate_many_nas rejects strings
               coalesce((SELECT jsonb_object_agg(e.key, e.value)
                         FROM jsonb_each(rs.setting_json) e
                         WHERE jsonb_typeof(e.value) = 'number'), '{}'::jsonb),
               coalesce(rs.setting_json -> 'formula', '[]'::jsonb),
               '{}'::jsonb,
               NULL::text, false,
               -- a lane has no time of its own; the items bring the times
               NULL::integer,
               (r.resource_json ->> 'next_start_lag_in_seconds')::integer,
               NULL::bigint, pl.lane_id
        FROM relation.resource r
        LEFT JOIN plan_lane pl ON pl.resource_path = r.resource_path
        LEFT JOIN LATERAL (
            SELECT s.setting_json FROM production.resource_setting s
            WHERE r.resource_path <@ s.resource_path
            ORDER BY nlevel(s.resource_path) DESC, s.moved_at DESC LIMIT 1
        ) rs ON true
        LEFT JOIN tenant t ON t.abb = ltree2text(subpath(r.resource_path, 0, 1))
        WHERE r.step = ANY (coalesce(p_steps, (SELECT array_agg(ws.step) FROM wanted_step ws)))
          AND (p_line_type IS NULL OR ltree2text(subpath(r.resource_path, 1, 1)) = p_line_type)
          -- a production plan names its lanes; other plan types have no
          -- resource lanes, so every resource of the steps is a lane
          AND (p_plan_type <> 'production-plan' OR pl.lane_id IS NOT NULL)
          AND (p_tenant_ids IS NULL OR t.tenant_id = ANY (p_tenant_ids))
        ORDER BY t.tenant_id, pl.sort_order NULLS LAST, r.resource_path;
        RETURN;
    END IF;

    -- The default schedule per delivery class: the group label and the moment
    -- the class starts at. A schedule is a template, so this is where a lane
    -- item gets its first time; once the planner moves the item, the item
    -- wins (see the coalesce below).
    SELECT coalesce(jsonb_object_agg(
               v.value ->> 'code',
               jsonb_build_object(
                   'group',  v.value ->> 'fixed_group',
                   'offset', v.value #> '{nest_moments,0,nest_time,start_offset_in_seconds}')),
           '{}'::jsonb)
    INTO v_fixed
    FROM production.lookup l
    CROSS JOIN LATERAL jsonb_array_elements(l.lookup_json) AS v(value)
    WHERE l.lookup = 'lookup_nest_moments'
      AND (v.value ->> 'fixed_group' IS NOT NULL
           OR v.value #>> '{nest_moments,0,nest_time,start_offset_in_seconds}' IS NOT NULL);

    RETURN QUERY
    WITH the_plan AS (
        -- the newest plan of this date, step, type and line type wins
        SELECT plan_id
        FROM action.plan
        WHERE plan_date = v_date AND p_step = ANY (steps)
          AND type = p_plan_type
          AND (p_line_type IS NULL OR line_type = p_line_type)
        ORDER BY plan_id DESC
        LIMIT 1
    ),
    tenant AS (
        SELECT (v.value ->> 'tenant_id')::integer AS tenant_id,
               v.value ->> 'name'                 AS tenant_name
        FROM relation.lookup lk
        CROSS JOIN LATERAL jsonb_array_elements(lk.lookup_json) AS v(value)
        WHERE lk.lookup = 'lookup_tenants'
    ),
    item AS (
        -- one row per planned moment; an extra moment is simply another item
        SELECT l.lane_id, li.lane_item_id, li.sort_order, li.is_pinned,
               li.start_offset_in_seconds,
               igli.imposition_group_id,
               -- the pattern row the item was stamped from: source_ref is
               -- <material_impose_plan_id>:<date>. A batch item (source
               -- 'nest', one per extra batch on the lane) has no pattern row
               -- of its own and borrows the one of the lane's pattern item,
               -- so material, line, tenant and resource come out the same
               CASE WHEN li.source = 'material-plan'
                    THEN nullif(split_part(li.source_ref, ':', 1), '')::bigint
                    ELSE (SELECT nullif(split_part(sib.source_ref, ':', 1), '')::bigint
                          FROM action.lane_item sib
                          WHERE sib.lane_id = li.lane_id AND sib.source = 'material-plan'
                          ORDER BY sib.sort_order LIMIT 1)
               END AS material_impose_plan_id
        FROM the_plan tp
        JOIN action.plan_lane l USING (plan_id)
        JOIN action.lane_item li ON li.lane_id = l.lane_id AND li.type = 'plan'
        LEFT JOIN action.imposition_group_lane_item igli ON igli.lane_item_id = li.lane_item_id
        WHERE li.source IN ('material-plan', 'nest')
    ),
    -- one interval check per distinct (start, days) pair of the plan's own
    -- materials instead of one per row: a check costs ~7 ms in
    -- get_interval_dates, so per row it was hundreds of milliseconds. The
    -- extra (null, 1) pair covers materials without a schedule row.
    --
    -- p_tenant_ids goes into get_interval_dates as well, not only into the
    -- anchor below: without it the day-off test there falls back to
    -- coalesce(null, tenants_mandatory_day_off) <@ tenants_mandatory_day_off,
    -- which is always true, so one tenant's day off dropped a working day for
    -- every tenant and shifted the interval for all of them.
    -- MATERIALIZED: referenced once, so the planner would inline it into the
    -- EXISTS below and run the interval check per material row (65 x 4000
    -- buffers) instead of once per pair (16 x)
    allowed_interval AS MATERIALIZED (
        SELECT s.interval_start_date, s.interval_days
        FROM (SELECT DISTINCT mps.interval_start_date,
                     coalesce(nullif(mps.interval_days, 0), 1) AS interval_days
              FROM item i
              JOIN mock.material_impose_plan m ON m.material_impose_plan_id = i.material_impose_plan_id
              JOIN mock.material_print_schedule mps
                   ON mps.material_id = m.material_id
                  AND mps.production_line_id = m.production_line_id
                  AND mps.tenant_id = m.tenant_id
              UNION
              SELECT NULL::date, 1) s
        WHERE NOT p_only_starting_today
           OR EXISTS (
                  SELECT 1
                  FROM action.get_interval_dates(
                           (SELECT min(d.date)
                            FROM action.dates d
                            WHERE d.date >= coalesce(s.interval_start_date, v_date)
                              AND d.is_weekend = false
                              AND NOT (coalesce(p_tenant_ids, d.tenants_mandatory_day_off) <@ d.tenants_mandatory_day_off and d.tenants_mandatory_day_off <> '{}')),
                           v_date, s.interval_days, 1, false, false, 0,
                           p_tenant_ids) AS i(interval_date)
                  WHERE i.interval_date = v_date)
    ),
    material_row AS (
        SELECT i.imposition_group_id,
               -- alias: the group id is the material id until the xbom groups arrive
               coalesce(m.material_id, i.imposition_group_id) AS material_id,
               mps.material_name, m.production_line_id,
               m.tenant_id, t.tenant_name,
               m.resource_path, r.resource_uid, r.resource_name,
               mps.delivery_hours, mps.min_delivery_hours, i.sort_order,
               -- the variables the board evaluates with: the resource
               -- constants, the format of the group, and the work itself.
               -- Numbers only — evaluate_many_nas rejects strings.
               coalesce((SELECT jsonb_object_agg(e.key, e.value)
                         FROM jsonb_each(rs.setting_json) e
                         WHERE jsonb_typeof(e.value) = 'number'), '{}'::jsonb)
               || coalesce(w.format_json, '{}'::jsonb)
               || jsonb_build_object('specs', coalesce(mpl.line_json -> 'specs', '[]'::jsonb))
                                                       AS param_json,
               coalesce(rs.setting_json -> 'formula', '[]'::jsonb) AS formula,
               -- every impose resource the item may be dragged to, with its
               -- own constants, so the duration follows the gesture
               jsonb_build_object('valid_resources', coalesce((
                   SELECT jsonb_agg(jsonb_build_object('resource_path', vr.resource_path::text,
                                                       'resource_name', vr.resource_name)
                                    || coalesce((SELECT jsonb_object_agg(e.key, e.value)
                                                 FROM jsonb_each(vrs.setting_json) e
                                                 WHERE jsonb_typeof(e.value) = 'number'), '{}'::jsonb)
                                    ORDER BY vr.resource_path)
                   FROM relation.resource vr
                   LEFT JOIN LATERAL (
                       SELECT s.setting_json FROM production.resource_setting s
                       WHERE vr.resource_path <@ s.resource_path
                       ORDER BY nlevel(s.resource_path) DESC, s.moved_at DESC LIMIT 1
                   ) vrs ON true
                   WHERE vr.resource_path ~ '*.impose.*'
                     AND subpath(vr.resource_path, 0, 2) = subpath(m.resource_path, 0, 2)
               ), '[]'::jsonb))                        AS data,
               v_fixed -> mps.delivery_hours::text ->> 'group' AS fixed_group,
               -- the mutable truth lives on the lane item
               i.is_pinned,
               -- only a fixed group (class moment as default) or a pinned
               -- item has a time of its own; every other item is a filler
               -- and serves null — the client chains fillers itself
               CASE WHEN v_fixed -> mps.delivery_hours::text ->> 'group' IS NOT NULL
                    THEN coalesce(i.start_offset_in_seconds,
                                  (v_fixed -> mps.delivery_hours::text ->> 'offset')::integer)
                    WHEN i.is_pinned THEN i.start_offset_in_seconds
               END                                     AS start_offset_in_seconds,
               -- the chaining offset belongs to the resource; the connector
               -- mechanism replaces this column later
               (r.resource_json ->> 'next_start_lag_in_seconds')::integer
                                                       AS next_start_offset_in_seconds,
               i.lane_item_id, i.lane_id
        FROM item i
        LEFT JOIN mock.material_impose_plan m ON m.material_impose_plan_id = i.material_impose_plan_id
        LEFT JOIN relation.resource r ON r.resource_path = m.resource_path
        -- the speed setting of that resource for that group
        LEFT JOIN LATERAL (
            SELECT s.setting_json FROM production.resource_setting s
            WHERE m.resource_path <@ s.resource_path
              AND (s.imposition_group_id IS NULL OR s.imposition_group_id = i.imposition_group_id)
            ORDER BY nlevel(s.resource_path) DESC,
                     (s.imposition_group_id IS NOT NULL) DESC,
                     s.moved_at DESC
            LIMIT 1
        ) rs ON true
        -- the format of the group: waste and imposition size, first entry that
        -- matches the material width of the resource path
        LEFT JOIN LATERAL (
            SELECT jsonb_build_object(
                       'waste_factor',   (f.value ->> 'waste_factor')::numeric,
                       'imposition_sqm', (f.value ->> 'imposition_sqm')::numeric) AS format_json
            FROM catalog.imposition_group g
            CROSS JOIN LATERAL jsonb_array_elements(coalesce(g.imposition_group_json -> 'waste', '[]'::jsonb)) f
            WHERE g.imposition_group_id = i.imposition_group_id
            ORDER BY (f.value ->> 'width')::numeric DESC
            LIMIT 1
        ) w ON true
        LEFT JOIN mock.material_print_schedule mps
               ON mps.material_id = m.material_id
              AND mps.production_line_id = m.production_line_id
              AND mps.tenant_id = m.tenant_id
        LEFT JOIN mapping.material_production_line mpl
               ON mpl.material_id = m.material_id
              AND mpl.production_line_id = m.production_line_id
        LEFT JOIN tenant t ON t.tenant_id = m.tenant_id
        WHERE (p_tenant_ids IS NULL OR m.tenant_id = ANY (p_tenant_ids))
          -- only materials whose interval says the plan date is a production day
          AND (NOT p_only_starting_today OR EXISTS (
                   SELECT 1 FROM allowed_interval ai
                   WHERE ai.interval_start_date IS NOT DISTINCT FROM mps.interval_start_date
                     AND ai.interval_days = coalesce(nullif(mps.interval_days, 0), 1)))
    )
    SELECT * FROM material_row
    UNION ALL
    -- one row per tenant noop window, newest per slot; removed time the client
    -- lays the timeline around (column names and types come from the first branch)
    SELECT NULL, NULL, NULL, NULL, s.tenant_id, t.tenant_name, NULL, NULL, NULL, NULL, NULL, NULL,
           -- a noop has no formula, so its duration is already in param_json:
           -- the board reads param_json.duration_in_seconds for every row
           jsonb_build_object('specs', '[]'::jsonb,
                              'duration_in_seconds', s.duration_in_seconds),
           '[]'::jsonb, '{}'::jsonb, 'noop', false,
           s.start_offset_in_seconds, s.duration_in_seconds, NULL::bigint, NULL::bigint
    FROM (
        SELECT DISTINCT ON (n.rule_path, n.weekday, n.start_offset_in_seconds)
               n.rule_path::integer AS tenant_id,
               n.start_offset_in_seconds, n.duration_in_seconds
        FROM action.non_working_times n
        WHERE n.type = 'noop'
          AND n.rule_path NOT LIKE '%.%'
          AND n.rule_path IN (SELECT DISTINCT mr.tenant_id::text FROM material_row mr)
          AND (n.weekday IS NULL OR n.weekday = extract(dow FROM v_date)::smallint + 1)
        ORDER BY n.rule_path, n.weekday, n.start_offset_in_seconds,
                 n.non_working_time_id DESC
    ) s
    LEFT JOIN tenant t ON t.tenant_id = s.tenant_id
    WHERE s.duration_in_seconds > 0
    ORDER BY tenant_id, sort_order;
END;
$$;

alter function action.get_plan_lanes(timestamp with time zone, text, text, integer[], boolean, text, text[]) owner to xfw3;
