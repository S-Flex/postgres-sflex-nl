-- ============================================================
-- Stap 7c (docs/plan-lane-model.md): the impose lanes of the resource board
-- come from the material-resource-plan, and that plan is the impose plan.
--   1. The pattern rows (mock.material_impose_plan) carry step 'impose' since
--      8 aug; mock.generate_plan filters on the step it is called with and
--      site.refresh_derived_data called it with 'print' — every plan stamped
--      since 9 sep came out empty (0 lanes). refresh now calls 'impose', the
--      plan's steps say impose, and get_impose_plan / get_plan_lanes default
--      to that step. Existing plans: steps print -> impose.
--   2. generate_plan also makes one resource lane per impose machine the
--      pattern names (resource_lane, reusing a lane of that machine and day
--      when one exists), behind the material lanes in plan_lane.
--   3. get_plan_lanes (resource mode) and get_resource_plan read the resource
--      lanes of every plan type of the day, not only the production plans;
--      for an impose lane the items are the plan items of the material lanes
--      whose pattern names that machine: the pattern item with the fixed
--      group and class time of board 76 (through get_plan_lanes), the batch
--      items as fillers. Duration: the production impact of the nests, else
--      of the open work of the material (board 76's rule), never under 900.
--   4. Backfill (DO): existing material-resource-plans from today on get
--      their resource lanes; the empty plans are removed and stamped again.
-- Data_group 81: the label source no longer sends plan_type
-- (sql/update_data_group_partial.sql, 81). Run the check, the script, the
-- check again; then restart or recycle the hub (return types unchanged, but
-- get_plan_lanes' defaults changed).
-- ============================================================

-- check; expected before: plans from today with 0 lanes, 0 resource lanes;
-- after: no empty plan, 5 impose lanes per sheet plan, impose rows on 81
SELECT p.plan_date, p.line_type, p.steps,
       (SELECT count(*) FROM action.plan_lane pl JOIN action.imposition_group_lane g ON g.lane_id = pl.lane_id WHERE pl.plan_id = p.plan_id) AS material_lanes,
       (SELECT count(*) FROM action.plan_lane pl JOIN action.resource_lane rl ON rl.lane_id = pl.lane_id WHERE pl.plan_id = p.plan_id) AS resource_lanes
FROM action.plan p
WHERE p.type = 'material-resource-plan' AND p.plan_date >= current_date AND p.line_type = 'sheet'
ORDER BY 1;

BEGIN;

-- 1. the plan step
UPDATE action.plan
SET steps = array_replace(steps, 'print', 'impose')
WHERE type = 'material-resource-plan' AND 'print' = ANY (steps);

-- 2. the functions
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
               m.start_offset_in_seconds, m.is_pinned, m.resource_path
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
    -- resource lanes: one fresh lane per machine without one; in the plan's
    -- order they follow the material lanes (plan_lane.sort_order is unique
    -- per plan)
    new_resource_lane_row AS (
        INSERT INTO action.lane (lane_date)
        SELECT p_date FROM numbered_resource
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

-- One read for the lanes (labels) of every plan board: print_schedule,
-- impose_plan, resource_plan and whatever
-- follows. Moved from mock to action: the lane model lives here.
--
-- Two modes, switched by p_steps:
--   * p_steps null — material lanes: one row per lane (its pattern item) of
--     the newest plan of the day (p_plan_type), reached through
--     lane_item.source_ref (<material_impose_plan_id>:<date>), plus the
--     tenant noop windows. One row per material: the batch items of a lane
--     are not rows here. Feeds print_schedule and impose_plan
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

create function action.get_plan_lanes(p_until timestamp with time zone DEFAULT now(), p_step text DEFAULT 'impose'::text, p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_only_starting_today boolean DEFAULT false, p_plan_type text DEFAULT 'material-resource-plan'::text, p_steps text[] DEFAULT NULL::text[]) returns TABLE(imposition_group_id integer, material_id integer, material_name text, production_line_id integer, tenant_id integer, tenant_name text, resource_path ltree, resource_uid text, resource_name text, delivery_hours integer, min_delivery_hours integer, sort_order numeric, param_json jsonb, formula jsonb, data jsonb, fixed_group text, is_pinned boolean, start_offset_in_seconds integer, next_start_offset_in_seconds integer, lane_item_id bigint, lane_id bigint)
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
            -- the steps asked, else every step a plan of the day carries,
            -- whatever its type: the production plans and the impose plan
            -- (material-resource-plan) both name their machines as resource lanes
            SELECT DISTINCT s.step
            FROM action.plan p
            CROSS JOIN LATERAL unnest(p.steps) AS s(step)
            WHERE p.plan_date = v_date
              AND (p_line_type IS NULL OR p.line_type = p_line_type)
              AND (p_steps IS NULL OR s.step = ANY (p_steps))
        ),
        the_plan AS (
            -- per step and plan type the newest plan of this date and line type
            SELECT DISTINCT ON (ws.step, p.type) ws.step, p.plan_id
            FROM wanted_step ws
            JOIN action.plan p ON ws.step = ANY (p.steps)
            WHERE p.plan_date = v_date
              AND (p_line_type IS NULL OR p.line_type = p_line_type)
            ORDER BY ws.step, p.type, p.plan_id DESC
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
          -- every plan names its lanes: a resource without a lane that day is
          -- not on the board
          AND pl.lane_id IS NOT NULL
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
        -- one row per lane: its pattern item (source_ref is
        -- <material_impose_plan_id>:<date>). The batch items of the lane
        -- (source 'nest', one per extra batch) are not rows on the material
        -- boards: the boards aggregate the lane, the nests of all its items
        -- are read together (get_impose_plan). The batch items exist for the
        -- resource side, one batch per item.
        SELECT l.lane_id, li.lane_item_id, li.sort_order, li.is_pinned,
               li.start_offset_in_seconds,
               igli.imposition_group_id,
               nullif(split_part(li.source_ref, ':', 1), '')::bigint AS material_impose_plan_id
        FROM the_plan tp
        JOIN action.plan_lane l USING (plan_id)
        JOIN action.lane_item li ON li.lane_id = l.lane_id AND li.type = 'plan'
        LEFT JOIN action.imposition_group_lane_item igli ON igli.lane_item_id = li.lane_item_id
        WHERE li.source = 'material-plan'
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

-- renamed from mock.get_nest_schedule (via get_imposition_plan); impose is
-- the step, imposition the object it produces
drop function if exists mock.get_nest_schedule(timestamp with time zone, text, text, integer[], boolean, integer, integer, integer);
drop function if exists mock.get_nest_schedule(timestamp with time zone, text, text, integer[], integer, integer, integer);
drop function if exists mock.get_imposition_plan(timestamp with time zone, text, text, integer[], integer, integer, integer);
drop function if exists mock.get_impose_plan(timestamp with time zone, text, text, integer[], boolean, integer, integer, integer);
drop function if exists mock.get_impose_plan(timestamp with time zone, text, text, integer[], integer, integer, integer);

-- every item row is a plan row: type and type_json (the node of
-- lookup_lane_item_type, with sort_order, placement and formula) ride along as
-- on get_resource_plan, so the board reads the kind of row the same way. The
-- noop windows have no kind.
create function mock.get_impose_plan(p_until timestamp with time zone DEFAULT now(), p_step text DEFAULT 'impose'::text, p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_look_back_days integer DEFAULT 0, p_look_ahead_days integer DEFAULT 0, p_domain_id integer DEFAULT 1) returns TABLE(material_id integer, material_name text, production_line_id integer, tenant_id integer, tenant_name text, production_company_id integer, resource_uid text, resource_name text, resource_path ltree, delivery_hours integer, min_delivery_hours integer, sort_order numeric, param_json jsonb, formula jsonb, data jsonb, fixed_group text, is_pinned boolean, start_offset_in_seconds integer, next_start_offset_in_seconds integer, duration_in_seconds integer, nest_date date, orderline_count integer, product_amount numeric, part_amount integer, amount numeric, sqm numeric, forecast_sqm numeric, rework_count integer, rework_sqm numeric, impact_json jsonb, gross_sqm numeric, part_status_json jsonb, nest_ids bigint[], nest_count integer, seconds_to_logistics_date integer, class_names text[], unit_class_names text[], lane_item_id bigint, lane_id bigint, type text, type_json jsonb, start_at timestamp with time zone)
	stable
	language plpgsql
as $$
#variable_conflict use_column
declare
    v_date date := (p_until at time zone current_setting('TimeZone'))::date;
    -- at or below this sequence an orderline is not on a nest yet; only that
    -- work counts on a material row without planned nests
    v_max_status_sequence constant integer := 450;
    v_status_sequences integer[];
    -- a lane item is never shorter than this, whatever the sqm say
    v_min_duration_in_seconds  constant integer := 900;
    v_plan_type_json jsonb;
    v_plan_class_names text[];
begin
    -- the lookup node of the plan kind
    select t.value into v_plan_type_json
    from action.lookup lk
    cross join lateral jsonb_array_elements(lk.lookup_json) as t(value)
    where lk.lookup = 'lookup_lane_item_type' and t.value ->> 'type' = 'plan';
    -- its class names (timeline-plan) ride along in class_names, as on get_resource_plan
    v_plan_class_names := coalesce(
        (select array_agg(c) from jsonb_array_elements_text(coalesce(v_plan_type_json -> 'class_names', '[]'::jsonb)) c),
        '{}'::text[]);

    -- the statuses live in mapping.internal_status, not in code
    select array_agg(distinct s.sequence) into v_status_sequences
    from mapping.internal_status s
    where s.domain_id = p_domain_id and s.sequence <= v_max_status_sequence;

    return query
    with base as (
        select b.material_id, b.material_name, b.production_line_id,
               b.tenant_id, b.tenant_name, b.resource_uid, b.resource_name,
               -- the row's own resource: valid_resources.resource_field reads it
               b.resource_path,
               b.delivery_hours, b.min_delivery_hours, b.sort_order,
               b.param_json, b.formula, b.data, b.fixed_group, b.is_pinned,
               b.start_offset_in_seconds, b.next_start_offset_in_seconds,
               b.lane_item_id, b.lane_id
        -- only the materials whose interval (action.get_interval_dates on
        -- interval_start_date and interval_days) says the plan date is a
        -- production day; the rest of the plan stays out of the nest board
        from action.get_plan_lanes(
                 p_until, p_step, p_line_type, p_tenant_ids, p_only_starting_today => true) b
    ),
    tenant as (
        select (v.value ->> 'tenant_id')::integer             as tenant_id,
               (v.value ->> 'production_company_id')::integer as production_company_id
        from relation.lookup lk
        cross join lateral jsonb_array_elements(lk.lookup_json) as v(value)
        where lk.lookup = 'lookup_tenants'
    ),
    the_plan as (
        -- the newest plan of this date, step and line type wins
        select plan_id
        from action.plan
        where plan_date = v_date and p_step = any (steps)
          and type = 'material-resource-plan'
          and (p_line_type is null or line_type = p_line_type)
        order by plan_id desc
        limit 1
    ),
    lane_nest as (
        -- the nests hung on the lane of this row: the sets of all its plan
        -- items together (the pattern item and the batch items, one batch per
        -- item), keyed on the row's item. The reader gives the current set of
        -- every item, inherited or own
        select b2.lane_item_id, array_agg(distinct x.imposition_id) as nest_ids
        from (select distinct lane_item_id, lane_id from base where lane_item_id is not null) b2
        join action.lane_item li on li.lane_id = b2.lane_id and li.type = 'plan'
        cross join lateral action.get_lane_item_impositions(li.lane_item_id) x
        group by b2.lane_item_id
    ),
    -- One aggregate call for all rows without lane nests, and one per distinct
    -- nest set for the rest, instead of one call per row: the detail behind
    -- the aggregate is the expensive part and it costs the same for one
    -- material as for fifty. Window rows are matched back on material and
    -- line; nest rows on material alone (see row_data).
    window_agg as (
        select a.*
        from mapping.get_production_orderline_aggregate(
                 p_from             => p_until,
                 p_date_type        => 'nest',
                 p_look_back_days   => p_look_back_days,
                 p_look_ahead_days  => p_look_ahead_days,
                 -- empty, not null: null would mean every material
                 p_material_ids     => coalesce((select array_agg(distinct b.material_id)
                                                 from base b
                                                 left join lane_nest ln on ln.lane_item_id = b.lane_item_id
                                                 where b.material_id is not null and ln.nest_ids is null),
                                                '{}'::integer[]),
                 p_tenant_ids       => (select array_agg(distinct b.tenant_id) from base b),
                 p_status_sequences => v_status_sequences,
                 p_is_open          => true,
                 p_domain_id        => p_domain_id) a
    ),
    nest_agg as (
        -- the nests decide the scope here; the material of the owning item
        -- narrows the call — the rows are matched back on material anyway,
        -- and without the filter every call drags the forecast of every
        -- material along (hundreds of discarded rows per set)
        select ns.nest_ids as lane_nest_ids, a.*
        from (select ln.nest_ids, array_agg(distinct b.material_id) as material_ids
              from lane_nest ln
              join base b on b.lane_item_id = ln.lane_item_id
              where b.material_id is not null
              group by ln.nest_ids) ns
        cross join lateral mapping.get_production_orderline_aggregate(
                 p_from             => p_until,
                 p_date_type        => 'nest',
                 p_nest_ids         => ns.nest_ids,
                 p_material_ids     => ns.material_ids,
                 p_tenant_ids       => (select array_agg(distinct b.tenant_id) from base b),
                 -- a planned nest set counts all its work whatever the
                 -- status; the class names carry the state instead
                 p_status_sequences => null,
                 p_is_open          => null,
                 p_domain_id        => p_domain_id) a
    ),
    row_data as (
        select b.*, ln.nest_ids,
               o.orderline_count, o.product_amount, o.part_amount, o.amount,
               o.sqm, o.forecast_sqm, o.rework_count, o.rework_sqm, o.impact_json, o.gross_sqm,
               o.specs_json, o.part_status_json, o.seconds_to_logistics_date,
               o.class_names, o.unit_class_names, o.production_impact_in_seconds
        from base b
        left join lane_nest ln on ln.lane_item_id = b.lane_item_id
        -- the work of this material on this line, every delivery class summed:
        -- the moment collects all open work of its material. A past moment
        -- carries impositions and gets the real work of that nest set instead;
        -- a second moment of the same material shows the same numbers — a
        -- duplicate is a planning moment, not a split of the work.
        left join lateral (
            with agg as (
                select na.orderline_count, na.product_amount, na.part_amount, na.amount,
                       na.sqm, na.forecast_sqm, na.rework_count, na.rework_sqm, na.impact_json, na.gross_sqm,
                       na.specs_json, na.part_status_json, na.seconds_to_logistics_date,
                       na.class_names, na.unit_class_names, na.production_impact_in_seconds
                from nest_agg na
                where ln.nest_ids is not null
                  and na.lane_nest_ids = ln.nest_ids
                  -- the nests decide the work, not the line: an orderline
                  -- nested here can carry another line (rerouted work), and
                  -- the forecast-only rows of the material stay out
                  and na.material_id = b.material_id
                  and na.orderline_count > 0
                union all
                select wa.orderline_count, wa.product_amount, wa.part_amount, wa.amount,
                       wa.sqm, wa.forecast_sqm, wa.rework_count, wa.rework_sqm, wa.impact_json, wa.gross_sqm,
                       wa.specs_json, wa.part_status_json, wa.seconds_to_logistics_date,
                       wa.class_names, wa.unit_class_names, wa.production_impact_in_seconds
                from window_agg wa
                where ln.nest_ids is null
                  and wa.material_id = b.material_id
                  and wa.production_line_id = b.production_line_id
            )
            select sum(a.orderline_count)::integer as orderline_count,
                   sum(a.product_amount)           as product_amount,
                   sum(a.part_amount)::integer     as part_amount,
                   sum(a.amount)                   as amount,
                   sum(a.sqm)                      as sqm,
                   sum(a.forecast_sqm)             as forecast_sqm,
                   sum(a.rework_count)::integer    as rework_count,
                   sum(a.rework_sqm)               as rework_sqm,
                   jsonb_build_object(
                       'count',         sum((a.impact_json ->> 'count')::integer),
                       'amount',        sum((a.impact_json ->> 'amount')::numeric),
                       'sqm',           round(sum((a.impact_json ->> 'sqm')::numeric), 2),
                       'rework_count',  sum((a.impact_json ->> 'rework_count')::integer),
                       'rework_amount', sum((a.impact_json ->> 'rework_amount')::numeric),
                       'rework_sqm',    round(sum((a.impact_json ->> 'rework_sqm')::numeric), 2)) as impact_json,
                   sum(a.gross_sqm)                as gross_sqm,
                   -- the specs are a material property, identical on every class row
                   (array_agg(a.specs_json) filter (where a.specs_json is not null))[1] as specs_json,
                   -- the part statuses of all classes, summed per status
                   (select jsonb_agg(jsonb_build_object(
                               'sequence', x.sequence, 'internal_status_code', x.internal_status_code,
                               'class_names', x.class_names, 'i18n', x.i18n, 'amount', x.amount)
                            order by x.sequence)
                    from (select (e.value ->> 'sequence')::integer   as sequence,
                                 e.value ->> 'internal_status_code'  as internal_status_code,
                                 e.value -> 'class_names'            as class_names,
                                 e.value -> 'i18n'                   as i18n,
                                 sum((e.value ->> 'amount')::numeric) as amount
                          from agg a2
                          cross join lateral jsonb_array_elements(a2.part_status_json) as e(value)
                          group by 1, 2, 3, 4) x)  as part_status_json,
                   min(a.seconds_to_logistics_date) as seconds_to_logistics_date,
                   sum(a.production_impact_in_seconds)::integer as production_impact_in_seconds,
                   (select array_agg(distinct c order by c)
                    from agg a3 cross join lateral unnest(a3.class_names) as c)      as class_names,
                   (select array_agg(distinct c order by c)
                    from agg a4 cross join lateral unnest(a4.unit_class_names) as c) as unit_class_names
            from agg a
            having count(*) > 0
        ) o on true
    )
    select r.material_id, r.material_name, r.production_line_id,
           r.tenant_id, r.tenant_name, t.production_company_id, r.resource_uid, r.resource_name,
           r.resource_path,
           r.delivery_hours, r.min_delivery_hours, r.sort_order,
           -- the sizes with what the gross sqm needs of each, and the print
           -- time of the row at both speeds
           jsonb_set(r.param_json, '{specs}', coalesce(r.specs_json, r.param_json -> 'specs'))
           -- net_sqm is what the formula needs; the resource constants, the
           -- waste and the imposition size already ride along from
           -- get_plan_lanes, so the board can evaluate the duration itself
           || jsonb_build_object('net_sqm', coalesce(r.sqm, 0),
                                 -- the variables the formula of the plan kind (type_json.formula)
                                 -- runs over, the same names as on get_resource_plan
                                 'planned_start_offset_in_seconds', r.start_offset_in_seconds,
                                 'production_impact_in_seconds',
                                     case when r.material_id is null then r.next_start_offset_in_seconds
                                          else greatest(coalesce(r.production_impact_in_seconds, 0), v_min_duration_in_seconds) end) as param_json,
           r.formula, r.data,
           r.fixed_group, r.is_pinned,
           r.start_offset_in_seconds, r.next_start_offset_in_seconds,
           -- noop rows keep their window duration; a material row lasts the
           -- standard production impact of its orderlines (from the
           -- manifests), never shorter than the floor. The machine formula
           -- in param_json stays for the resource board (78).
           case when r.material_id is null then r.next_start_offset_in_seconds
                else greatest(coalesce(r.production_impact_in_seconds, 0),
                              v_min_duration_in_seconds)
           end as duration_in_seconds,
           -- the day the row's orderlines nest: the plan date of the board
           v_date as nest_date,
           r.orderline_count, r.product_amount, r.part_amount, r.amount,
           r.sqm, r.forecast_sqm, r.rework_count, r.rework_sqm, r.impact_json, r.gross_sqm,
           coalesce(r.part_status_json, '[]'::jsonb),
           -- the nests of the lane items, not the ones the orderlines sit on
           coalesce(r.nest_ids, '{}'::bigint[]),
           coalesce(cardinality(r.nest_ids), 0),
           r.seconds_to_logistics_date,
           -- the class names of the work plus, on an item row, those of the kind
           coalesce((select array_agg(distinct c order by c)
                     from unnest(coalesce(r.class_names, '{}'::text[])
                                 || case when r.lane_item_id is not null then v_plan_class_names else '{}'::text[] end) as c),
                    '{}'::text[]),
           coalesce(r.unit_class_names, '{}'::text[]),
           r.lane_item_id, r.lane_id,
           -- the kind of row: every item is a plan row, a noop window has none
           case when r.lane_item_id is not null then 'plan' end,
           case when r.lane_item_id is not null then v_plan_type_json end,
           -- the absolute start of the row: the plan date's midnight plus the offset
           -- (the board's formulas compare it with current_offset_in_seconds)
           case when r.start_offset_in_seconds is not null
                then (v_date::timestamp at time zone 'Europe/Amsterdam') + make_interval(secs => r.start_offset_in_seconds) end
    from row_data r
    left join tenant t on t.tenant_id = r.tenant_id
    order by r.tenant_id, r.sort_order;
end;
$$;

alter function mock.get_impose_plan(timestamp with time zone, text, text, integer[], integer, integer, integer) owner to xfw3;

-- the board query is planned per call and inlines the aggregate; JIT compiling
-- it costs seconds and never pays back
alter function mock.get_impose_plan(timestamp with time zone, text, text, integer[], integer, integer, integer) set jit = off;

-- The one item read of the resource board (docs/plan-lane-model.md, stap 7):
-- one row per lane item on the resource lanes of the day's plans — the
-- production plans, and the impose plan (material-resource-plan) whose
-- resource lanes are the impose machines and whose items are the material
-- items whose pattern names that machine (stap 7c) —
-- for the steps asked (p_steps null = every step planned that day), in three
-- kinds of rows, named by lane_item.type and action.lookup /
-- lookup_lane_item_type:
--   * plan     — the item as planned (stored); its nests via
--                get_lane_item_impositions, the work of the set from the
--                orderline aggregate, whatever the status of the orderlines,
--                with the forecast of its material (forecast_sqm next to sqm);
--   * progress — what of that plan is still to do for the lane's step: the
--                orderline amounts below the step's done status
--                (lookup_step_category.sequence), as a share of the plan's
--                duration. Same lane_item_id and start, shrinks as work moves
--                on, gone when everything is done. Derived here, never stored;
--   * actual   — what the machine did, as items that partition the lane's
--                day: a run = the produced items of one batch in a row
--                (log.get_resource_produced; a nest without a batch is its
--                own run, a batch interrupted by another batch or by a gap
--                longer than lookup_lane_item_type.actual.gap_split_in_seconds
--                becomes two runs), and the stretches between runs. The state
--                blocks (log.get_resource_state) are the sub level of every
--                actual item: states_json holds them clipped to the item,
--                the state that fills most of the item names it (state_json,
--                class_names). No lane_item_id.
-- The plan row carries progress_json (done and remaining amounts, share) for
-- its tooltip; its state (state_json, class_names) is the least advanced
-- status of its nests, its sub level the part statuses (part_status_json).
-- type_json is the lookup node of the row's type; its class_names ride along
-- in class_names as well, so the board styles the kinds without code, and its
-- formula computes start_offset_in_seconds and duration_in_seconds from the
-- row's param_json (planned_start_offset_in_seconds,
-- production_impact_in_seconds, remaining_impact_in_seconds,
-- actual_start_offset_in_seconds, actual_duration_in_seconds) — the same
-- evaluate mechanism as board 76 uses per resource. The columns
-- start_offset_in_seconds and duration_in_seconds carry the same result for
-- readers without an evaluator. p_types filters the kinds (null = all).
--
-- Replaces mock.get_production_plan (81) and the resource mode of
-- mock.get_impose_plan (78). The labels come from action.get_plan_lanes in
-- resource mode.
drop function if exists action.get_resource_plan(timestamp with time zone, text, integer[], text[], text[], integer);

create function action.get_resource_plan(p_until timestamp with time zone DEFAULT now(), p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_steps text[] DEFAULT NULL::text[], p_types text[] DEFAULT NULL::text[], p_domain_id integer DEFAULT 1)
    returns TABLE(tenant_id integer, tenant_name text, production_company_id integer, resource_uid text, resource_name text, resource_path ltree, lane_id bigint, step text, type text, type_json jsonb, lane_item_id bigint, sort_order numeric, is_pinned boolean, no_split boolean, fixed_group text, start_offset_in_seconds integer, duration_in_seconds integer, start_at timestamp with time zone, end_at timestamp with time zone, nest_ids bigint[], nest_count integer, batch_id integer, batch_name text, material_id integer, material_name text, impact_json jsonb, sqm numeric, forecast_sqm numeric, gross_sqm numeric, part_status_json jsonb, progress_json jsonb, state_json jsonb, group_state_json jsonb, states_json jsonb, class_names text[], param_json jsonb)
    stable
    language plpgsql
    set jit = off
as $$
#variable_conflict use_column
declare
    v_zone constant text := 'Europe/Amsterdam';
    -- the plan date is the day of the viewed moment; the axis of the board is
    -- that day's local midnight, offsets are seconds since then
    v_date       date := (p_until at time zone 'Europe/Amsterdam')::date;
    v_day_start  timestamp with time zone;
    v_day_end    timestamp with time zone;
    -- print seconds per gross sqm at standard speed, and the shortest item; a lookup later
    v_standard_seconds_per_sqm constant numeric := 45;
    v_min_duration_in_seconds  constant integer := 900;
    -- legacy.nest width/height are in cm; a lookup later
    v_nest_size_per_sqm        constant numeric := 10000;
    v_state_lookup             jsonb;
    v_type_lookup              jsonb;
    -- a gap longer than this inside a batch splits its run in two
    v_gap_split_in_seconds     integer;
    -- at or below this sequence an orderline is not on a nest yet: the open
    -- work of a material item without nests (the same rule as get_impose_plan)
    v_max_status_sequence constant integer := 450;
    v_status_sequences         integer[];
begin
    select array_agg(distinct s.sequence) into v_status_sequences
    from mapping.internal_status s
    where s.domain_id = p_domain_id and s.sequence <= v_max_status_sequence;

    select lk.lookup_json into v_state_lookup
    from relation.lookup lk where lk.lookup = 'lookup_resource_state';

    select lk.lookup_json into v_type_lookup
    from action.lookup lk where lk.lookup = 'lookup_lane_item_type';

    select coalesce((t.value ->> 'gap_split_in_seconds')::integer, 900) into v_gap_split_in_seconds
    from jsonb_array_elements(coalesce(v_type_lookup, '[]'::jsonb)) as t(value)
    where t.value ->> 'type' = 'actual';
    v_gap_split_in_seconds := coalesce(v_gap_split_in_seconds, 900);

    v_day_start := v_date::timestamp at time zone v_zone;
    v_day_end   := (v_date + 1)::timestamp at time zone v_zone;

    return query
    with kind as (
        -- the three kinds of rows, with their lookup node
        select t.value ->> 'type'                                    as type,
               (t.value ->> 'sort_order')::integer                   as sort_order,
               t.value                                               as type_json,
               coalesce((select array_agg(c) from jsonb_array_elements_text(coalesce(t.value -> 'class_names', '[]'::jsonb)) c),
                        '{}'::text[])                                as class_names
        from jsonb_array_elements(coalesce(v_type_lookup, '[]'::jsonb)) as t(value)
    ),
    step_done as (
        -- per step the status at which its work is done
        select s.value ->> 'step'                 as step,
               (s.value ->> 'sequence')::integer  as done_sequence
        from relation.lookup lk
        cross join lateral jsonb_array_elements(lk.lookup_json) as s(value)
        where lk.lookup = 'lookup_step_category'
    ),
    tenant as (
        select (v.value ->> 'tenant_id')::integer             as tenant_id,
               v.value ->> 'name'                             as tenant_name,
               v.value ->> 'abb'                              as abb,
               (v.value ->> 'production_company_id')::integer as production_company_id
        from relation.lookup lk
        cross join lateral jsonb_array_elements(lk.lookup_json) as v(value)
        where lk.lookup = 'lookup_tenants'
    ),
    -- the steps asked, else every step a plan of the day carries: the
    -- production plans (print, coat, cut, ...) and the impose plan (the
    -- material-resource-plan, whose resource lanes are the impose machines)
    wanted_step as (
        select distinct s.step
        from action.plan p
        cross join lateral unnest(p.steps) as s(step)
        where p.plan_date = v_date
          and (p_line_type is null or p.line_type = p_line_type)
          and (p_steps is null or s.step = any (p_steps))
    ),
    the_plan as (
        -- per step and plan type the newest plan of the day that covers it
        select distinct on (ws.step, p.type) ws.step, p.plan_id
        from wanted_step ws
        join action.plan p on ws.step = any (p.steps)
        where p.plan_date = v_date
          and (p_line_type is null or p.line_type = p_line_type)
        order by ws.step, p.type, p.plan_id desc
    ),
    -- one lane = one machine's day, the machine's step names the lane's step;
    -- the tenant through the first label of the path (the site abb)
    lane as (
        select distinct on (l.lane_id)
               l.lane_id, pl_l.sort_order, rl.resource_path,
               r.resource_uid, r.resource_name, r.step,
               t.tenant_id, t.tenant_name, t.production_company_id,
               sd.done_sequence
        from the_plan tp
        join action.plan_lane pl_l on pl_l.plan_id = tp.plan_id
        join action.lane l on l.lane_id = pl_l.lane_id
        join action.resource_lane rl on rl.lane_id = l.lane_id
        join relation.resource r on r.resource_path = rl.resource_path and r.step = tp.step
        left join step_done sd on sd.step = r.step
        left join tenant t on t.abb = ltree2text(subpath(rl.resource_path, 0, 1))
        where (p_tenant_ids is null or t.tenant_id = any (p_tenant_ids))
        order by l.lane_id, tp.plan_id desc
    ),
    -- the material lanes of the impose plan, with the resource their pattern
    -- names and what the material boards derive per lane: material, line,
    -- fixed group and class time — the same read board 76 uses, so both
    -- boards agree on every item
    material_lane as (
        select b.lane_id, b.lane_item_id as pattern_item_id,
               b.material_id, b.material_name, b.production_line_id,
               b.resource_path, b.fixed_group, b.start_offset_in_seconds
        from action.get_plan_lanes(p_until, p_line_type => p_line_type, p_tenant_ids => p_tenant_ids,
                                   p_only_starting_today => true) b
        where b.lane_id is not null
    ),
    -- planned items with the nests hung on them: the items on the lane itself
    -- (production plans), plus for an impose lane the items of every material
    -- lane whose pattern names its resource — the pattern item with the class
    -- time and fixed group of board 76, the batch items as fillers of the same
    -- material (one batch per item)
    item as (
        select li.lane_item_id, li.lane_id, li.sort_order, li.is_pinned, li.no_split,
               li.fixed_group, li.start_offset_in_seconds, li.duration_in_seconds,
               null::integer as material_id, null::text as material_name, null::integer as production_line_id,
               (select array_agg(distinct x.imposition_id)
                from action.get_lane_item_impositions(li.lane_item_id) x) as nest_ids
        from action.lane_item li
        join lane on lane.lane_id = li.lane_id
        where li.type = 'plan'
        union all
        select li.lane_item_id, lane.lane_id, li.sort_order, li.is_pinned, li.no_split,
               case when li.lane_item_id = ml.pattern_item_id then ml.fixed_group end,
               case when li.lane_item_id = ml.pattern_item_id then ml.start_offset_in_seconds
                    else li.start_offset_in_seconds end,
               li.duration_in_seconds,
               ml.material_id, ml.material_name, ml.production_line_id,
               (select array_agg(distinct x.imposition_id)
                from action.get_lane_item_impositions(li.lane_item_id) x)
        from lane
        join material_lane ml on ml.resource_path = lane.resource_path
        join action.lane_item li on li.lane_id = ml.lane_id and li.type = 'plan'
    ),
    -- what the nests of an item say: the batch, the run (amount x area), the
    -- materials, and the least advanced status, which names the item's state
    item_nest as (
        select i.lane_item_id,
               min(n.batch_id)                                                          as batch_id,
               min(b.batch_name)                                                        as batch_name,
               sum(coalesce(n.amount, 1) * coalesce(n.width, 0) * coalesce(n.height, 0)) / v_nest_size_per_sqm as run_sqm,
               array_agg(distinct (n.nest_json ->> 'material_id')::integer)
                   filter (where (n.nest_json ->> 'material_id') is not null)           as material_ids,
               (array_agg(n.nest_json ->> 'internal_status_code' order by ist.sequence nulls last))[1] as internal_status_code
        from item i
        cross join lateral action.get_lane_item_impositions(i.lane_item_id) nli
        join legacy.nest n on n.nest_id = nli.imposition_id
        left join legacy.batch b on b.batch_id = n.batch_id
        left join mapping.internal_status ist on ist.code = n.nest_json ->> 'internal_status_code' and ist.domain_id = p_domain_id
        group by i.lane_item_id
    ),
    -- one aggregate call per distinct nest set, narrowed to the materials of
    -- its nests (without that every call drags every material's forecast
    -- along). A planned set counts all its work whatever the status; the
    -- part statuses say what is done
    agg_rows as materialized (
        select ns.nest_ids as lane_nest_ids, a.*
        from (select i.nest_ids,
                     (select array_agg(distinct m) from item_nest nf
                      join item i2 on i2.lane_item_id = nf.lane_item_id
                      cross join lateral unnest(nf.material_ids) as m
                      where i2.nest_ids = i.nest_ids)              as material_ids
              from item i
              where i.nest_ids is not null
              group by i.nest_ids) ns
        cross join lateral mapping.get_production_orderline_aggregate(
                 p_from             => p_until,
                 p_date_type        => 'nest',
                 p_nest_ids         => ns.nest_ids,
                 p_material_ids     => ns.material_ids,
                 p_status_sequences => null,
                 p_is_open          => null,
                 p_domain_id        => p_domain_id) a
        where a.orderline_count > 0
    ),
    -- summed over the materials of the set; the material is named when the
    -- set has one, else null
    item_agg as (
        select r.lane_nest_ids as nest_ids,
               sum(r.orderline_count)::integer as orderline_count,
               sum(r.sqm)                      as sqm,
               -- the forecast of the set's materials on their lines for the day, the
               -- same number on every item of that material (like board 76)
               sum(r.forecast_sqm)             as forecast_sqm,
               sum(r.gross_sqm)                as gross_sqm,
               sum(r.production_impact_in_seconds)::integer as production_impact_in_seconds,
               jsonb_build_object(
                   'count',         sum((r.impact_json ->> 'count')::integer),
                   'amount',        sum((r.impact_json ->> 'amount')::numeric),
                   'sqm',           round(sum((r.impact_json ->> 'sqm')::numeric), 2),
                   'rework_count',  sum((r.impact_json ->> 'rework_count')::integer),
                   'rework_amount', sum((r.impact_json ->> 'rework_amount')::numeric),
                   'rework_sqm',    round(sum((r.impact_json ->> 'rework_sqm')::numeric), 2)) as impact_json,
               case when count(distinct r.material_id) = 1 then min(r.material_id) end   as material_id,
               case when count(distinct r.material_id) = 1 then min(r.material_name) end as material_name,
               -- the part statuses of the whole set, summed per status
               (select jsonb_agg(jsonb_build_object(
                           'sequence', x.sequence, 'internal_status_code', x.internal_status_code,
                           'class_names', x.class_names, 'i18n', x.i18n, 'amount', x.amount)
                        order by x.sequence)
                from (select (e.value ->> 'sequence')::integer   as sequence,
                             e.value ->> 'internal_status_code'  as internal_status_code,
                             e.value -> 'class_names'            as class_names,
                             e.value -> 'i18n'                   as i18n,
                             sum((e.value ->> 'amount')::numeric) as amount
                      from agg_rows b
                      cross join lateral jsonb_array_elements(b.part_status_json) as e(value)
                      where b.lane_nest_ids = r.lane_nest_ids
                      group by 1, 2, 3, 4) x)                                          as part_status_json,
               (select array_agg(distinct c order by c)
                from agg_rows b cross join lateral unnest(b.class_names) as c
                where b.lane_nest_ids = r.lane_nest_ids)                                as class_names
        from agg_rows r
        group by r.lane_nest_ids
    ),
    -- the open work of the materials whose item has no nests yet: one aggregate
    -- call for all of them (empty array, not null: null would mean every
    -- material), matched back on material and line — what board 76 shows on
    -- such a row, so an impose lane carries the same work
    open_work_row as (
        select a.*
        from mapping.get_production_orderline_aggregate(
                 p_from             => p_until,
                 p_date_type        => 'nest',
                 p_look_back_days   => 0,
                 p_look_ahead_days  => 0,
                 p_material_ids     => coalesce((select array_agg(distinct i.material_id) from item i
                                                 where i.material_id is not null and i.nest_ids is null),
                                                '{}'::integer[]),
                 p_tenant_ids       => p_tenant_ids,
                 p_status_sequences => v_status_sequences,
                 p_is_open          => true,
                 p_domain_id        => p_domain_id) a
        where a.orderline_count > 0
    ),
    open_work as (
        select r.material_id, r.production_line_id,
               sum(r.orderline_count)::integer as orderline_count,
               sum(r.sqm)                      as sqm,
               sum(r.forecast_sqm)             as forecast_sqm,
               sum(r.gross_sqm)                as gross_sqm,
               sum(r.production_impact_in_seconds)::integer as production_impact_in_seconds,
               jsonb_build_object(
                   'count',         sum((r.impact_json ->> 'count')::integer),
                   'amount',        sum((r.impact_json ->> 'amount')::numeric),
                   'sqm',           round(sum((r.impact_json ->> 'sqm')::numeric), 2),
                   'rework_count',  sum((r.impact_json ->> 'rework_count')::integer),
                   'rework_amount', sum((r.impact_json ->> 'rework_amount')::numeric),
                   'rework_sqm',    round(sum((r.impact_json ->> 'rework_sqm')::numeric), 2)) as impact_json,
               (select jsonb_agg(jsonb_build_object(
                           'sequence', x.sequence, 'internal_status_code', x.internal_status_code,
                           'class_names', x.class_names, 'i18n', x.i18n, 'amount', x.amount)
                        order by x.sequence)
                from (select (e.value ->> 'sequence')::integer   as sequence,
                             e.value ->> 'internal_status_code'  as internal_status_code,
                             e.value -> 'class_names'            as class_names,
                             e.value -> 'i18n'                   as i18n,
                             sum((e.value ->> 'amount')::numeric) as amount
                      from open_work_row b
                      cross join lateral jsonb_array_elements(b.part_status_json) as e(value)
                      where b.material_id = r.material_id and b.production_line_id = r.production_line_id
                      group by 1, 2, 3, 4) x)                                          as part_status_json,
               (select array_agg(distinct c order by c)
                from open_work_row b cross join lateral unnest(b.class_names) as c
                where b.material_id = r.material_id and b.production_line_id = r.production_line_id) as class_names
        from open_work_row r
        group by r.material_id, r.production_line_id
    ),
    -- the plan rows: the lane's resource names the row
    plan_row as (
        select l.tenant_id, l.tenant_name, l.production_company_id,
               l.resource_uid, l.resource_name, l.resource_path, l.lane_id, l.step,
               i.lane_item_id, i.sort_order, i.is_pinned, i.no_split, i.fixed_group,
               i.start_offset_in_seconds,
               -- pv2's duration when it sent one; a material item (impose) lasts
               -- the standard production impact of its work, from the nests or
               -- the open work, as on board 76; else the print time of the run
               -- (nest area x amount) at the resource's speed — never shorter
               -- than the minimum
               case when i.duration_in_seconds > 0 then i.duration_in_seconds
                    when i.material_id is not null
                         then greatest(coalesce(ag.production_impact_in_seconds, ow.production_impact_in_seconds, 0),
                                       v_min_duration_in_seconds)
                    else greatest(ceil(coalesce(nf.run_sqm, 0) * v_standard_seconds_per_sqm
                                       / coalesce(nullif(mock.get_resource_speed_factor(ag.material_id, l.resource_uid), 0), 1))::integer,
                                  v_min_duration_in_seconds) end                       as duration_in_seconds,
               coalesce(i.nest_ids, '{}'::bigint[])                                   as nest_ids,
               coalesce(cardinality(i.nest_ids), 0)                                    as nest_count,
               nf.batch_id, nf.batch_name,
               -- the material of the set, else of the material item itself; the
               -- work of the set, else the open work of the material
               coalesce(ag.material_id, i.material_id)                                 as material_id,
               coalesce(ag.material_name, i.material_name)                             as material_name,
               coalesce(ag.impact_json, ow.impact_json)                                as impact_json,
               coalesce(ag.sqm, ow.sqm)                                                as sqm,
               coalesce(ag.forecast_sqm, ow.forecast_sqm)                              as forecast_sqm,
               coalesce(ag.gross_sqm, ow.gross_sqm)                                    as gross_sqm,
               coalesce(ag.part_status_json, ow.part_status_json, '[]'::jsonb)         as part_status_json,
               -- the state of a planned item is the least advanced status of its
               -- nests, from the same lookup the actual rows use
               (select st.value from jsonb_array_elements(v_state_lookup) as ss(value)
                                     cross join lateral jsonb_array_elements(ss.value -> 'states') as st(value)
                 where st.value ->> 'code' = coalesce(nf.internal_status_code, 'batch') limit 1) as state_json,
               (select ss.value - 'states' from jsonb_array_elements(v_state_lookup) as ss(value)
                                           cross join lateral jsonb_array_elements(ss.value -> 'states') as st(value)
                 where st.value ->> 'code' = coalesce(nf.internal_status_code, 'batch') limit 1) as group_state_json,
               coalesce(ag.class_names, ow.class_names, '{}'::text[])                  as class_names,
               jsonb_build_object(
                   'standard_production_impact_in_seconds', ceil(coalesce(nf.run_sqm, 0) * v_standard_seconds_per_sqm)::integer,
                   'run_sqm',                                round(coalesce(nf.run_sqm, 0), 2),
                   'speed_factor',                           mock.get_resource_speed_factor(coalesce(ag.material_id, i.material_id), l.resource_uid),
                   'orderline_count',                        coalesce(ag.orderline_count, ow.orderline_count)) as param_json,
               -- what is done and what remains for the lane's step: the part
               -- amounts at or past the step's done status against the rest.
               -- Without orderline amounts nothing is known to be done
               coalesce(pr.done_amount, 0)                                             as done_amount,
               coalesce(pr.remaining_amount, 0)                                        as remaining_amount,
               case when coalesce(pr.done_amount, 0) + coalesce(pr.remaining_amount, 0) > 0
                    then coalesce(pr.remaining_amount, 0) / (coalesce(pr.done_amount, 0) + coalesce(pr.remaining_amount, 0))
                    else 1 end                                                         as remaining_share
        from item i
        join lane l on l.lane_id = i.lane_id
        left join item_nest nf on nf.lane_item_id = i.lane_item_id
        left join item_agg ag on ag.nest_ids = i.nest_ids
        -- the open work only counts for a material item without nests
        left join open_work ow on i.nest_ids is null
                              and ow.material_id = i.material_id
                              and ow.production_line_id = i.production_line_id
        left join lateral (
            select sum((e.value ->> 'amount')::numeric) filter (where (e.value ->> 'sequence')::integer >= l.done_sequence) as done_amount,
                   sum((e.value ->> 'amount')::numeric) filter (where (e.value ->> 'sequence')::integer <  l.done_sequence) as remaining_amount
            from jsonb_array_elements(coalesce(ag.part_status_json, ow.part_status_json, '[]'::jsonb)) as e(value)
            where l.done_sequence is not null
        ) pr on true
    ),
    -- actual: the state blocks and the produced items of the lanes'
    -- resources, up to the viewed moment (the log functions clip to now());
    -- skipped altogether when the actual rows are not asked for
    actual_state as (
        select s.resource_uid, s.state, s.group_state, s.start_at,
               s.start_at + make_interval(secs => coalesce(s.duration_seconds, 0)) as end_at
        from log.get_resource_state(
                 (select array_agg(l.resource_uid) from lane l), v_day_start, least(p_until, v_day_end), null) s
        where (p_types is null or 'actual' = any (p_types))
          and coalesce(s.duration_seconds, 0) > 0
    ),
    produced as (
        select r.resource_uid, r.start_at,
               r.start_at + make_interval(secs => coalesce(r.duration_seconds, 0)) as end_at,
               coalesce(r.duration_seconds, 0)                                    as producing_seconds,
               r.batch_id, r.batch_name, r.nest_name,
               (select sum((m.value ->> 'value')::numeric)
                from jsonb_array_elements(coalesce(r.data -> 'metrics_json', '[]'::jsonb)) as m(value)
                where m.value ->> 'code' = 'area')                                 as area_sqm,
               -- what a run is keyed on: the batch, else the nest, else the row itself
               coalesce(r.batch_id::text, r.nest_name, 'row:' || r.start_at::text) as run_key
        from log.get_resource_produced(
                 (select array_agg(l.resource_uid) from lane l), v_day_start, least(p_until, v_day_end), null) r
        where p_types is null or 'actual' = any (p_types)
    ),
    -- a new run starts where the key changes or the gap since the previous
    -- item is longer than the split
    produced_break as (
        select p.*,
               case when p.run_key is distinct from lag(p.run_key) over w
                      or p.start_at - lag(p.end_at) over w > make_interval(secs => v_gap_split_in_seconds)
                    then 1 else 0 end as is_break
        from produced p
        window w as (partition by p.resource_uid order by p.start_at, p.end_at)
    ),
    produced_run as (
        select pb.*,
               sum(pb.is_break) over (partition by pb.resource_uid order by pb.start_at, pb.end_at rows unbounded preceding) as run_no
        from produced_break pb
    ),
    run as (
        select pr.resource_uid, pr.run_no,
               min(pr.start_at) as start_at, max(pr.end_at) as end_at,
               min(pr.batch_id) as batch_id, min(pr.batch_name) as batch_name,
               count(*)::integer as produced_count,
               sum(pr.producing_seconds)::integer as producing_seconds,
               sum(pr.area_sqm) as area_sqm,
               array_agg(distinct pr.nest_name) filter (where pr.nest_name is not null) as nest_names
        from produced_run pr
        group by pr.resource_uid, pr.run_no
    ),
    -- the log can overlap: an item of the next batch starts before the last
    -- item of this one ends; a run ends where the next run begins
    run_clipped as (
        select r.resource_uid, r.run_no, r.start_at,
               least(r.end_at, lead(r.start_at) over (partition by r.resource_uid order by r.start_at, r.run_no)) as end_at,
               r.batch_id, r.batch_name, r.produced_count, r.producing_seconds, r.area_sqm, r.nest_names
        from run r
    ),
    -- the stretches between runs, from the day start and up to the viewed
    -- moment; a lane without runs is one stretch
    stretch as (
        select r.resource_uid, r.end_at as start_at,
               lead(r.start_at) over (partition by r.resource_uid order by r.start_at) as end_at
        from run_clipped r
        union all
        select l.resource_uid, v_day_start,
               (select min(r.start_at) from run_clipped r where r.resource_uid = l.resource_uid)
        from lane l
    ),
    actual_item as (
        select r.resource_uid, r.start_at, r.end_at, true as is_run,
               r.batch_id, r.batch_name, r.produced_count, r.producing_seconds, r.area_sqm, r.nest_names
        from run_clipped r
        union all
        select s.resource_uid, s.start_at, coalesce(s.end_at, least(p_until, v_day_end)), false,
               null, null, 0, 0, null, null
        from stretch s
        where coalesce(s.end_at, least(p_until, v_day_end)) > s.start_at
    ),
    -- the sub level: the state blocks clipped to the item
    actual_segment as (
        select i.resource_uid, i.start_at as item_start,
               greatest(st.start_at, i.start_at) as start_at,
               least(st.end_at, i.end_at)        as end_at,
               st.state, st.group_state
        from actual_item i
        join actual_state st
          on st.resource_uid = i.resource_uid
         and st.start_at < i.end_at and st.end_at > i.start_at
    ),
    actual_row as (
        select i.*,
               extract(epoch from (i.start_at - v_day_start))::integer as start_offset_in_seconds,
               extract(epoch from (i.end_at - i.start_at))::integer    as duration_in_seconds,
               (select jsonb_agg(jsonb_build_object(
                           'start_offset_in_seconds', extract(epoch from (sg.start_at - v_day_start))::integer,
                           'duration_in_seconds',     extract(epoch from (sg.end_at - sg.start_at))::integer,
                           'class_names',             array_remove(array[sg.state ->> 'class_name'], null),
                           'state_json',              sg.state)
                        order by sg.start_at)
                from actual_segment sg
                where sg.resource_uid = i.resource_uid and sg.item_start = i.start_at) as states_json,
               -- the state that fills most of the item names it
               d.state as state_json, d.group_state as group_state_json
        from actual_item i
        left join lateral (
            select sg.state, sg.group_state
            from actual_segment sg
            where sg.resource_uid = i.resource_uid and sg.item_start = i.start_at
            group by sg.state, sg.group_state
            order by sum(extract(epoch from (sg.end_at - sg.start_at))) desc
            limit 1
        ) d on true
        -- a stretch without any state block is nothing to show
        where i.is_run or d.state is not null
    ),
    rows as (
        -- plan
        select p.tenant_id, p.tenant_name, p.production_company_id,
               p.resource_uid, p.resource_name, p.resource_path, p.lane_id, p.step,
               'plan'::text as type,
               p.lane_item_id, p.sort_order, p.is_pinned, p.no_split, p.fixed_group,
               p.start_offset_in_seconds, p.duration_in_seconds,
               v_day_start + make_interval(secs => p.start_offset_in_seconds) as start_at,
               null::timestamp with time zone                                 as end_at,
               p.nest_ids, p.nest_count, p.batch_id, p.batch_name,
               p.material_id, p.material_name, p.impact_json, p.sqm, p.forecast_sqm, p.gross_sqm,
               p.part_status_json,
               jsonb_build_object(
                   'done_amount',          p.done_amount,
                   'remaining_amount',     p.remaining_amount,
                   'remaining_percentage', round(p.remaining_share * 100, 1)) as progress_json,
               p.state_json, p.group_state_json, null::jsonb as states_json, p.class_names,
               -- the variables the formula of the kind runs over
               p.param_json || jsonb_build_object(
                   'planned_start_offset_in_seconds', p.start_offset_in_seconds,
                   'production_impact_in_seconds',    p.duration_in_seconds,
                   'remaining_impact_in_seconds',     round(p.duration_in_seconds * p.remaining_share)::integer) as param_json
        from plan_row p

        union all
        -- progress: the remaining share of the plan, same item and start
        select p.tenant_id, p.tenant_name, p.production_company_id,
               p.resource_uid, p.resource_name, p.resource_path, p.lane_id, p.step,
               'progress'::text,
               p.lane_item_id, p.sort_order, p.is_pinned, p.no_split, p.fixed_group,
               p.start_offset_in_seconds,
               round(p.duration_in_seconds * p.remaining_share)::integer,
               v_day_start + make_interval(secs => p.start_offset_in_seconds),
               null::timestamp with time zone,
               p.nest_ids, p.nest_count, p.batch_id, p.batch_name,
               p.material_id, p.material_name, p.impact_json, p.sqm, p.forecast_sqm, p.gross_sqm,
               p.part_status_json,
               jsonb_build_object(
                   'done_amount',          p.done_amount,
                   'remaining_amount',     p.remaining_amount,
                   'remaining_percentage', round(p.remaining_share * 100, 1)),
               p.state_json, p.group_state_json, null::jsonb, p.class_names,
               p.param_json || jsonb_build_object(
                   'planned_start_offset_in_seconds', p.start_offset_in_seconds,
                   'production_impact_in_seconds',    p.duration_in_seconds,
                   'remaining_impact_in_seconds',     round(p.duration_in_seconds * p.remaining_share)::integer)
        from plan_row p
        where round(p.duration_in_seconds * p.remaining_share) > 0

        union all
        -- actual: the items of the lane's day, named by the resource that ran
        select l.tenant_id, l.tenant_name, l.production_company_id,
               l.resource_uid, l.resource_name, l.resource_path, l.lane_id, l.step,
               'actual'::text,
               null::bigint, null::numeric, false, false, null::text,
               a.start_offset_in_seconds, a.duration_in_seconds,
               a.start_at, a.end_at,
               coalesce((select array_agg(n.nest_id order by n.nest_id) from legacy.nest n where n.nest_name = any (a.nest_names)), '{}'::bigint[]),
               coalesce(cardinality(a.nest_names), 0),
               a.batch_id, a.batch_name,
               null::integer, null::text,
               null::jsonb, round(a.area_sqm, 2), null::numeric, null::numeric,
               '[]'::jsonb,
               null::jsonb,
               a.state_json, a.group_state_json, a.states_json,
               array_remove(array[a.state_json ->> 'class_name', case when a.is_run then 'actual-produced' end], null),
               jsonb_build_object(
                   'is_run',                          a.is_run,
                   'produced_count',                  a.produced_count,
                   'producing_in_seconds',            a.producing_seconds,
                   'actual_start_offset_in_seconds',  a.start_offset_in_seconds,
                   'actual_duration_in_seconds',      a.duration_in_seconds)
        from actual_row a
        join lane l on l.resource_uid = a.resource_uid
    )
    select r.tenant_id, r.tenant_name, r.production_company_id,
           r.resource_uid, r.resource_name, r.resource_path, r.lane_id, r.step,
           r.type, k.type_json,
           r.lane_item_id, r.sort_order, r.is_pinned, r.no_split, r.fixed_group,
           r.start_offset_in_seconds, r.duration_in_seconds, r.start_at, r.end_at,
           r.nest_ids, r.nest_count, r.batch_id, r.batch_name,
           r.material_id, r.material_name, r.impact_json, r.sqm, r.forecast_sqm, r.gross_sqm,
           r.part_status_json, r.progress_json, r.state_json, r.group_state_json, r.states_json,
           -- the class names of the kind ride along with the row's own
           (select array_agg(distinct c order by c)
            from unnest(r.class_names || coalesce(k.class_names, '{}'::text[])) as c) as class_names,
           r.param_json
    from rows r
    left join kind k on k.type = r.type
    where p_types is null or r.type = any (p_types)
    order by r.tenant_id, r.resource_path, k.sort_order nulls last, r.start_offset_in_seconds, r.sort_order;
end;
$$;

alter function action.get_resource_plan(timestamp with time zone, text, integer[], text[], text[], integer) owner to xfw3;

drop function if exists site.refresh_derived_data();

create function site.refresh_derived_data() returns void
	language plpgsql
as $$
#variable_conflict use_column
begin
    -- state shift aggregation: the writers (log.crud_state_log,
    -- log.crud_data_log) keep the table current per batch; this is the
    -- daily full rebuild that finalizes yesterday and catches anything
    -- that arrived outside those two
    perform log.upsert_state_shift_agg(current_date - 1);  -- finalize yesterday
    perform log.upsert_state_shift_agg(current_date);      -- refresh today

    -- materialized views
    refresh materialized view mapping.v_resource_capacity;

    -- the material resource plan: one per workday per line type, created
    -- ahead of time — the plannable items are generated from this planning
    -- later, so the plan must exist before any item does. mock.generate_plan
    -- builds the whole set: the plan (with tenant_ids), the material lanes
    -- from the weekly pattern (step impose: the nesting moments), a resource
    -- lane per impose machine the pattern names, plan_lane and the material
    -- link per lane.
    perform mock.generate_plan(d.date, 'impose', lt.line_type)
    from (select dt.date, dt.tenants_mandatory_day_off
          from action.dates dt
          where dt.date >= current_date
            and dt.date < current_date + 14
            and not dt.is_weekend) d
    cross join (select pl.line_type,
                       array_agg(distinct pl.tenant_id order by pl.tenant_id)
                           filter (where pl.tenant_id is not null) as tenant_ids
                from relation.production_line pl
                where pl.line_type is not null
                group by pl.line_type) lt
    where not (coalesce(lt.tenant_ids, d.tenants_mandatory_day_off) <@ d.tenants_mandatory_day_off and d.tenants_mandatory_day_off <> '{}')
      and not exists (select 1 from action.plan p
                      where p.plan_date = d.date
                        and p.type = 'material-resource-plan'
                        and p.line_type = lt.line_type);
end;
$$;

alter function site.refresh_derived_data() owner to xfw3;


COMMIT;

-- 3. backfill: the plans already stamped
DO $$
DECLARE
    v_regenerated integer := 0;
    v_lanes integer := 0;
    r record;
BEGIN
    -- the empty plans (stamped with the wrong step): away, and stamped again.
    -- Only the line types the pattern knows; a line type without pattern rows
    -- has an empty plan by right
    FOR r IN
        SELECT p.plan_id, p.plan_date, p.line_type
        FROM action.plan p
        WHERE p.type = 'material-resource-plan'
          AND p.plan_date >= current_date
          AND NOT EXISTS (SELECT 1 FROM action.plan_lane pl WHERE pl.plan_id = p.plan_id)
          AND EXISTS (SELECT 1
                      FROM mock.material_impose_plan m
                      JOIN mock.material_print_schedule s ON s.production_line_id = m.production_line_id
                      WHERE s.line = p.line_type AND m.step = 'impose')
        ORDER BY p.plan_date, p.line_type
    LOOP
        DELETE FROM action.plan WHERE plan_id = r.plan_id;
        PERFORM mock.generate_plan(r.plan_date, 'impose', r.line_type);
        v_regenerated := v_regenerated + 1;
    END LOOP;

    -- the plans with material lanes but no resource lanes: one lane per
    -- machine their patterns name, an existing lane of that day reused
    CREATE TEMP TABLE bf_resource ON COMMIT DROP AS
    SELECT DISTINCT p.plan_id, l.lane_date, m.resource_path
    FROM action.plan p
    JOIN action.plan_lane pl ON pl.plan_id = p.plan_id
    JOIN action.lane l ON l.lane_id = pl.lane_id
    JOIN action.lane_item li ON li.lane_id = l.lane_id AND li.source = 'material-plan'
    JOIN mock.material_impose_plan m ON m.material_impose_plan_id = split_part(li.source_ref, ':', 1)::bigint
    WHERE p.type = 'material-resource-plan'
      AND p.plan_date >= current_date
      AND m.resource_path IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM action.plan_lane pl2 JOIN action.resource_lane rl ON rl.lane_id = pl2.lane_id
                      WHERE pl2.plan_id = p.plan_id AND rl.resource_path = m.resource_path);

    ALTER TABLE bf_resource ADD COLUMN lane_id bigint;

    UPDATE bf_resource b
    SET lane_id = (SELECT rl.lane_id FROM action.resource_lane rl JOIN action.lane l ON l.lane_id = rl.lane_id
                   WHERE rl.resource_path = b.resource_path AND l.lane_date = b.lane_date ORDER BY rl.lane_id LIMIT 1);

    -- new lanes where none exists for the machine and day
    WITH need AS (
        SELECT DISTINCT b.lane_date, b.resource_path FROM bf_resource b WHERE b.lane_id IS NULL
    ),
    made AS (
        INSERT INTO action.lane (lane_date)
        SELECT n.lane_date FROM need n
        RETURNING lane_id, lane_date
    ),
    numbered_need AS (
        SELECT n.*, row_number() OVER (PARTITION BY n.lane_date ORDER BY n.resource_path) AS rn FROM need n
    ),
    numbered_made AS (
        SELECT m.*, row_number() OVER (PARTITION BY m.lane_date ORDER BY m.lane_id) AS rn FROM made m
    ),
    linked AS (
        -- runs even though nothing reads it: a data-modifying CTE always executes
        INSERT INTO action.resource_lane (lane_id, resource_path)
        SELECT nm.lane_id, nn.resource_path
        FROM numbered_made nm JOIN numbered_need nn USING (lane_date, rn)
        RETURNING lane_id
    )
    -- the pairing comes from the CTEs themselves: the lanes made in this
    -- statement are not yet visible in action.lane here
    UPDATE bf_resource b
    SET lane_id = nm.lane_id
    FROM numbered_made nm
    JOIN numbered_need nn USING (lane_date, rn)
    WHERE b.lane_id IS NULL AND b.resource_path = nn.resource_path AND b.lane_date = nn.lane_date;

    INSERT INTO action.plan_lane (plan_id, lane_id, sort_order)
    SELECT b.plan_id, b.lane_id,
           (SELECT coalesce(max(pl.sort_order), 0) FROM action.plan_lane pl WHERE pl.plan_id = b.plan_id)
             + 1000 + row_number() OVER (PARTITION BY b.plan_id ORDER BY b.resource_path)
    FROM bf_resource b
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_lanes = ROW_COUNT;

    RAISE NOTICE 'plans stamped again: %, resource lanes added to existing plans: %', v_regenerated, v_lanes;
END $$;

-- check after: impose rows on the resource board for the coming monday
SELECT type, count(*) AS rows, count(DISTINCT lane_id) AS lanes, count(*) FILTER (WHERE material_id IS NOT NULL) AS with_material,
       count(*) FILTER (WHERE nest_count > 0) AS with_nests, min(duration_in_seconds) AS min_duration, max(duration_in_seconds) AS max_duration
FROM action.get_resource_plan(p_until => '2026-09-07 06:00+02', p_line_type => 'sheet', p_steps => array['impose'])
GROUP BY type ORDER BY type;
SELECT resource_uid, lane_id, sort_order
FROM action.get_plan_lanes(p_until => '2026-09-07 06:00+02', p_line_type => 'sheet', p_steps => array['impose']);
