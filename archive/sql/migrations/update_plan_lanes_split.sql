-- Splits action.get_plan_lanes into two reads and simplifies both.
--
-- 1. action.get_plan_lanes_imposition_group -- the material lanes of the nest
--    boards (75, 76): p_step names the step of the plan to read. Reads a day
--    window (p_look_back_days / p_look_ahead_days), carries day_offset, and the
--    axis of p_view_code decides which moments are rows.
-- 2. action.get_plan_lanes_resource -- the resource lanes (81): p_steps names
--    the steps whose resources are lanes. Drives from the lane instead of from
--    every resource, so the LEFT JOIN and the "lane not null" filter are gone.
-- 3. p_plan_type is gone: the resource read never looked at it, and the
--    material read only ever reads a material-resource-plan.
-- 4. site.tenant replaces the lookup_tenants lookup, here and in the two
--    callers.
-- 5. Two helpers take the copied blocks out of the reads:
--    production.get_resource_setting (which setting wins for a resource) and
--    production.get_setting_numbers (the numeric keys of a setting_json).
--    NOTE: the two places that used to take any setting row of a resource now
--    ask for the setting of the row's imposition group (valid_resources) and
--    for the general setting without a group (the resource lanes) -- the rule
--    the resource_setting table itself documents.
-- 6. mock.get_impose_plan and action.get_resource_plan call the new name and
--    ask for the day of p_until only, so both boards read as before. The day
--    window of the nest board follows in the next step.
--
-- Run after this script: sql/update_data_group_partial.sql (75, 76, 81 point
-- their label read at the new data_table names).
BEGIN;

-- ============ 1. the helpers ============
-- The setting that wins for a resource: the longest matching path, a row
-- naming the imposition group beats a row without one, and of equal rows the
-- newest moved_at. That rule (production.resource_setting) sat as a lateral in
-- every board read; it lives here now.
--
-- p_imposition_group_id null asks for the general setting of the resource, the
-- one without a group.
create or replace function production.get_resource_setting(p_resource_path ltree, p_imposition_group_id integer DEFAULT NULL::integer) returns jsonb
    stable
    language sql
as $$
    SELECT s.setting_json
    FROM production.resource_setting s
    WHERE p_resource_path <@ s.resource_path
      AND (s.imposition_group_id IS NULL OR s.imposition_group_id = p_imposition_group_id)
    ORDER BY nlevel(s.resource_path) DESC,
             (s.imposition_group_id IS NOT NULL) DESC,
             s.moved_at DESC
    LIMIT 1
$$;

alter function production.get_resource_setting(ltree, integer) owner to xfw3;

-- The constants of a setting_json: its numeric keys. That is what a board
-- evaluates with — evaluate_many_nas rejects strings, so the formula, the
-- names and whatever else the setting carries stay out.
create or replace function production.get_setting_numbers(p_setting_json jsonb) returns jsonb
    immutable
    language sql
as $$
    SELECT coalesce(jsonb_object_agg(e.key, e.value)
                    FILTER (WHERE jsonb_typeof(e.value) = 'number'), '{}'::jsonb)
    FROM jsonb_each(coalesce(p_setting_json, '{}'::jsonb)) e
$$;

alter function production.get_setting_numbers(jsonb) owner to xfw3;

-- ============ 2. the two lane reads ============
drop function if exists mock.get_plan_lanes(timestamp with time zone, text, text, integer[], boolean, text);
drop function if exists action.get_plan_lanes(timestamp with time zone, text, text, integer[], boolean, text);
drop function if exists action.get_plan_lanes(timestamp with time zone, text, text, integer[], boolean, text, text[]);
drop function if exists action.get_plan_lanes(timestamp with time zone, text, text, integer[], boolean, text, text[], integer, integer, text);

-- One read for the imposition-group lanes (labels) of the nest boards:
-- print_schedule (75), impose_plan (76) and whatever follows. One row per lane
-- (its pattern item) of the newest material plan of a day, reached through
-- lane_item.source_ref (<material_impose_plan_id>:<date>). The batch items of a
-- lane (source 'nest', one per extra batch) are not rows here: the boards
-- aggregate the lane and read the nests of all its items together
-- (mock.get_impose_plan); the batch items exist for the resource side. No noop
-- windows any more: the non-working time is the time scale's
-- (production.get_timeline_view_segments), not a row. imposition_group_id is
-- the material_id alias until the xbom groups arrive.
--
-- The resource lanes are action.get_plan_lanes_resource. p_step here names the
-- step of the plan to read (the plan whose steps carry it); p_steps there names
-- the steps whose resources are lanes -- two different questions, so two reads.
--
-- The days in view are p_look_back_days back to p_look_ahead_days ahead, each
-- with the plan of its own date, so a row carries the lane_item_id of that
-- day's plan and its day_offset (-1 the day before, 0 the day of p_until). The
-- axis decides which rows exist: the moment of a row (its own time, else the
-- moment of its class) has to fall inside the span of p_view_code. The evening
-- moment of the day before is therefore a row, while that day's noon moment,
-- which the axis does not reach, is not. A day the view has no segments for
-- repeats day 0 -- the repeat rule of the client as well
-- (docs/handoff-time-scale-frontend.md). A class without a moment lands nowhere
-- and is a row on day 0 only.
--
-- The offset rule: only a fixed group (its own time, else the class moment) or
-- a pinned item carries start_offset_in_seconds. Every other item is a filler
-- and serves null -- the client chains fillers itself (chain_scope), a
-- moved-but-unpinned item springs back on refresh. The offset counts from
-- midnight of day 0, as the segments of the axis do: a row of the day before
-- carries its own time minus a day, so the evening moment of that day comes out
-- negative.
--
-- Duration is not computed here. The row carries the formula of its resource
-- and the variables, and the board evaluates -- otherwise a drag to another
-- resource could not change the duration. The chaining offset
-- (next_start_offset_in_seconds) belongs to the resource:
-- resource_json.next_start_lag_in_seconds; the connector mechanism replaces
-- this column later.
create function action.get_plan_lanes_imposition_group(p_until timestamp with time zone DEFAULT now(), p_step text DEFAULT 'impose'::text, p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_only_starting_today boolean DEFAULT true, p_look_back_days integer DEFAULT 1, p_look_ahead_days integer DEFAULT 1, p_view_code text DEFAULT 'nest-time-scale'::text) returns TABLE(imposition_group_id integer, material_id integer, material_name text, production_line_id integer, tenant_id integer, tenant_name text, resource_path ltree, resource_uid text, resource_name text, delivery_hours integer, min_delivery_hours integer, day_offset integer, sort_order numeric, param_json jsonb, formula jsonb, data jsonb, fixed_group text, is_pinned boolean, start_offset_in_seconds integer, next_start_offset_in_seconds integer, lane_item_id bigint, lane_id bigint)
	stable
	language plpgsql
as $$
#variable_conflict use_column
DECLARE
    v_date   date;
    v_group  jsonb;    -- delivery class -> its fixed group
    v_offset jsonb;    -- delivery class -> the moment the class starts at
    v_from   integer;  -- the span the board draws, from midnight of day 0
    v_to     integer;  -- the end of the last segment, so exclusive
BEGIN
    v_date := (p_until AT TIME ZONE current_setting('TimeZone'))::date;

    -- The default schedule per delivery class (production.lookup,
    -- lookup_nest_moments). A schedule is a template, so this is where a lane
    -- item gets its first time; once the planner moves the item, the item wins
    -- (see the coalesce below).
    SELECT coalesce(jsonb_object_agg(v.value ->> 'code', v.value -> 'fixed_group')
                    FILTER (WHERE v.value ->> 'fixed_group' IS NOT NULL), '{}'::jsonb),
           coalesce(jsonb_object_agg(v.value ->> 'code',
                                     v.value #> '{nest_moments,0,nest_time,start_offset_in_seconds}')
                    FILTER (WHERE v.value #>> '{nest_moments,0,nest_time,start_offset_in_seconds}' IS NOT NULL),
                    '{}'::jsonb)
    INTO v_group, v_offset
    FROM production.lookup l
    CROSS JOIN LATERAL jsonb_array_elements(l.lookup_json) AS v(value)
    WHERE l.lookup = 'lookup_nest_moments';

    -- The span of the axis: the first segment of the first day in view to the
    -- last segment of the last day, counted from midnight of day 0. A day the
    -- view has no segments for repeats day 0. Taking the day out of a segment
    -- offset gives its time on its own day; adding the day of a row back puts
    -- that row on the axis.
    WITH segment AS (
        SELECT s.day_offset,
               min(s.start_offset_in_seconds - s.day_offset * 86400) AS from_in_seconds,
               max(s.end_offset_in_seconds   - s.day_offset * 86400) AS to_in_seconds
        FROM production.get_timeline_view_segments(
                 p_code       => p_view_code,
                 p_until      => p_until,
                 p_look_back  => -1,
                 p_look_ahead => -1,
                 p_tenant_ids => p_tenant_ids) s
        GROUP BY s.day_offset
    )
    SELECT min(d.day_offset * 86400 + coalesce(s.from_in_seconds, z.from_in_seconds)),
           max(d.day_offset * 86400 + coalesce(s.to_in_seconds,   z.to_in_seconds))
    INTO v_from, v_to
    FROM generate_series(-coalesce(p_look_back_days, 0),
                          coalesce(p_look_ahead_days, 0)) AS d(day_offset)
    LEFT JOIN segment s ON s.day_offset = d.day_offset
    LEFT JOIN segment z ON z.day_offset = 0;

    RETURN QUERY
    WITH plan_day AS (
        SELECT d.day_offset, v_date + d.day_offset AS plan_date
        FROM generate_series(-coalesce(p_look_back_days, 0),
                              coalesce(p_look_ahead_days, 0)) AS d(day_offset)
    ),
    item AS (
        -- one row per lane of that day's plan: its pattern item
        SELECT d.day_offset, li.lane_id, li.lane_item_id, li.sort_order, li.is_pinned,
               li.start_offset_in_seconds,
               igli.imposition_group_id,
               nullif(split_part(li.source_ref, ':', 1), '')::bigint AS material_impose_plan_id
        FROM plan_day d
        CROSS JOIN LATERAL (
            -- the newest material plan of that date, step and line type
            SELECT p.plan_id
            FROM action.plan p
            WHERE p.plan_date = d.plan_date
              AND p.type = 'material-resource-plan'
              AND p_step = ANY (p.steps)
              AND (p_line_type IS NULL OR p.line_type = p_line_type)
            ORDER BY p.plan_id DESC
            LIMIT 1
        ) tp
        JOIN action.plan_lane pl ON pl.plan_id = tp.plan_id
        JOIN action.lane_item li ON li.lane_id = pl.lane_id
                                AND li.type = 'plan' AND li.source = 'material-plan'
        LEFT JOIN action.imposition_group_lane_item igli ON igli.lane_item_id = li.lane_item_id
    ),
    -- one interval check per distinct (start, days) pair of the plan's own
    -- materials and per day in view, instead of one per row: a check costs
    -- ~0,5 ms in get_interval_dates, so per row it was hundreds of
    -- milliseconds. The extra (null, 1) pair covers materials without a
    -- schedule row.
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
        SELECT s.interval_start_date, s.interval_days, w.day_offset
        FROM (SELECT DISTINCT mps.interval_start_date,
                     coalesce(nullif(mps.interval_days, 0), 1) AS interval_days
              FROM item i
              JOIN mock.material_impose_plan m ON m.material_impose_plan_id = i.material_impose_plan_id
              JOIN mock.material_print_schedule mps
                   ON (mps.material_id, mps.production_line_id, mps.tenant_id)
                    = (m.material_id, m.production_line_id, m.tenant_id)
              UNION
              SELECT NULL::date, 1) s
        CROSS JOIN plan_day w
        WHERE NOT p_only_starting_today
           OR EXISTS (
                  SELECT 1
                  FROM action.get_interval_dates(
                           (SELECT min(d.date)
                            FROM action.dates d
                            WHERE d.date >= coalesce(s.interval_start_date, w.plan_date)
                              AND d.is_weekend = false
                              AND NOT (coalesce(p_tenant_ids, d.tenants_mandatory_day_off) <@ d.tenants_mandatory_day_off and d.tenants_mandatory_day_off <> '{}')),
                           w.plan_date, s.interval_days, 1, false, false, 0,
                           p_tenant_ids) AS i(interval_date)
                  WHERE i.interval_date = w.plan_date)
    )
    SELECT i.imposition_group_id,
           -- alias: the group id is the material id until the xbom groups arrive
           coalesce(m.material_id, i.imposition_group_id),
           mps.material_name, m.production_line_id,
           m.tenant_id, t.name,
           m.resource_path, r.resource_uid, r.resource_name,
           mps.delivery_hours, mps.min_delivery_hours,
           i.day_offset, i.sort_order,
           -- the variables the board evaluates with: the resource constants,
           -- the format of the group, and the work itself
           production.get_setting_numbers(rs.setting_json)
           || coalesce(w.format_json, '{}'::jsonb)
           || jsonb_build_object('specs', coalesce(mpl.line_json -> 'specs', '[]'::jsonb)),
           coalesce(rs.setting_json -> 'formula', '[]'::jsonb),
           jsonb_build_object('valid_resources', coalesce(vres.resources, '[]'::jsonb)),
           cls.fixed_group,
           -- the mutable truth lives on the lane item
           i.is_pinned,
           c.start_offset_in_seconds,
           (r.resource_json ->> 'next_start_lag_in_seconds')::integer,
           i.lane_item_id, i.lane_id
    FROM item i
    LEFT JOIN mock.material_impose_plan m ON m.material_impose_plan_id = i.material_impose_plan_id
    LEFT JOIN mock.material_print_schedule mps
           ON (mps.material_id, mps.production_line_id, mps.tenant_id)
            = (m.material_id, m.production_line_id, m.tenant_id)
    LEFT JOIN mapping.material_production_line mpl
           ON (mpl.material_id, mpl.production_line_id) = (m.material_id, m.production_line_id)
    LEFT JOIN relation.resource r ON r.resource_path = m.resource_path
    LEFT JOIN site.tenant t ON t.tenant_id = m.tenant_id
    -- the speed setting of that resource for that group
    CROSS JOIN LATERAL (
        SELECT production.get_resource_setting(m.resource_path, i.imposition_group_id) AS setting_json
    ) rs
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
    -- every impose resource the item may be dragged to, with its own constants
    -- for this group, so the duration follows the gesture
    LEFT JOIN LATERAL (
        SELECT jsonb_agg(jsonb_build_object('resource_path', vr.resource_path::text,
                                            'resource_name', vr.resource_name)
                         || production.get_setting_numbers(
                                production.get_resource_setting(vr.resource_path, i.imposition_group_id))
                         ORDER BY vr.resource_path) AS resources
        FROM relation.resource vr
        WHERE vr.resource_path ~ '*.impose.*'
          AND subpath(vr.resource_path, 0, 2) = subpath(m.resource_path, 0, 2)
    ) vres ON true
    -- the class of the row: its fixed group and the moment the class starts at
    CROSS JOIN LATERAL (
        SELECT v_group  ->> mps.delivery_hours::text            AS fixed_group,
               (v_offset ->> mps.delivery_hours::text)::integer AS class_offset
    ) cls
    -- only a fixed group (its own time, else the class moment) or a pinned item
    -- has a time of its own; every other item is a filler and serves null --
    -- the client chains fillers itself. The day of the row moves the offset to
    -- midnight of day 0
    CROSS JOIN LATERAL (
        SELECT CASE WHEN cls.fixed_group IS NOT NULL
                    THEN coalesce(i.start_offset_in_seconds, cls.class_offset)
                    WHEN i.is_pinned THEN i.start_offset_in_seconds
               END + i.day_offset * 86400 AS start_offset_in_seconds
    ) c
    WHERE (p_tenant_ids IS NULL OR m.tenant_id = ANY (p_tenant_ids))
      -- only materials whose interval says the day of the row is a production day
      AND (NOT p_only_starting_today OR EXISTS (
               SELECT 1 FROM allowed_interval ai
               WHERE ai.interval_start_date IS NOT DISTINCT FROM mps.interval_start_date
                 AND ai.interval_days = coalesce(nullif(mps.interval_days, 0), 1)
                 AND ai.day_offset = i.day_offset))
      -- the axis decides which moments are rows: the time the row carries,
      -- else the moment of its class. A moment inside the span counts also
      -- when it falls in a gap between two segments -- the client places such
      -- an item at the start of the next segment
      AND CASE WHEN coalesce(c.start_offset_in_seconds, cls.class_offset) IS NULL
                    -- a class without a moment lands nowhere and is a row on
                    -- the day of p_until only
                    THEN i.day_offset = 0
               WHEN v_from IS NULL THEN true
               ELSE coalesce(c.start_offset_in_seconds,
                             cls.class_offset + i.day_offset * 86400)
                    BETWEEN v_from AND v_to - 1
          END
    ORDER BY i.day_offset, m.tenant_id, i.sort_order;
END;
$$;

alter function action.get_plan_lanes_imposition_group(timestamp with time zone, text, text, integer[], boolean, integer, integer, text) owner to xfw3;

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

-- ============ 3. the callers ============
-- renamed from mock.get_nest_schedule (via get_imposition_plan); impose is
-- the step, imposition the object it produces
drop function if exists mock.get_nest_schedule(timestamp with time zone, text, text, integer[], boolean, integer, integer, integer);
drop function if exists mock.get_nest_schedule(timestamp with time zone, text, text, integer[], integer, integer, integer);
drop function if exists mock.get_imposition_plan(timestamp with time zone, text, text, integer[], integer, integer, integer);
drop function if exists mock.get_impose_plan(timestamp with time zone, text, text, integer[], boolean, integer, integer, integer);
drop function if exists mock.get_impose_plan(timestamp with time zone, text, text, integer[], integer, integer, integer);

-- every row is a plan row: type and type_json (the node of
-- lookup_lane_item_type, with sort_order, placement and formula) ride along as
-- on get_resource_plan, so the board reads the kind of row the same way. The
-- non-working time is the time scale's (get_timeline_view_segments), no rows.
create function mock.get_impose_plan(p_until timestamp with time zone DEFAULT now(), p_step text DEFAULT 'impose'::text, p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_look_back_days integer DEFAULT 1, p_look_ahead_days integer DEFAULT 1, p_domain_id integer DEFAULT 1) returns TABLE(material_id integer, material_name text, production_line_id integer, tenant_id integer, tenant_name text, production_company_id integer, resource_uid text, resource_name text, resource_path ltree, delivery_hours integer, min_delivery_hours integer, sort_order numeric, param_json jsonb, formula jsonb, data jsonb, fixed_group text, is_pinned boolean, start_offset_in_seconds integer, next_start_offset_in_seconds integer, duration_in_seconds integer, nest_date date, orderline_count integer, product_amount numeric, part_amount integer, amount numeric, sqm numeric, forecast_sqm numeric, rework_count integer, rework_sqm numeric, impact_json jsonb, gross_sqm numeric, part_status_json jsonb, nest_ids bigint[], nest_count integer, seconds_to_logistics_date integer, class_names text[], unit_class_names text[], lane_item_id bigint, lane_id bigint, type text, type_json jsonb, start_at timestamp with time zone)
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
    -- the width of a row counts the work of this delivery class only (hours):
    -- the other classes ride along in the numbers, not in the time. A lookup later
    v_width_delivery_hours     constant integer := 30;
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
        -- the day of p_until only; the day window of the axis follows later
        from action.get_plan_lanes_imposition_group(
                 p_until, p_step, p_line_type, p_tenant_ids, p_only_starting_today => true,
                 p_look_back_days => 0, p_look_ahead_days => 0) b
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
                       na.class_names, na.unit_class_names, na.production_impact_in_seconds,
                       na.delivery_hours
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
                       wa.class_names, wa.unit_class_names, wa.production_impact_in_seconds,
                       wa.delivery_hours
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
                   -- the time of the row: the work of the width class only
                   sum(a.production_impact_in_seconds) filter (where a.delivery_hours = v_width_delivery_hours)::integer
                                                   as production_impact_in_seconds,
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
                                     greatest(coalesce(r.production_impact_in_seconds, 0), v_min_duration_in_seconds)) as param_json,
           r.formula, r.data,
           r.fixed_group, r.is_pinned,
           r.start_offset_in_seconds, r.next_start_offset_in_seconds,
           -- a row lasts the standard production impact of its orderlines of the
           -- width class (30 hours, from the manifests), never shorter than the
           -- floor. The machine formula in param_json stays for the resource side.
           greatest(coalesce(r.production_impact_in_seconds, 0),
                    v_min_duration_in_seconds)                as duration_in_seconds,
           -- the day the row's orderlines nest: the plan date of the board
           v_date as nest_date,
           r.orderline_count, r.product_amount, r.part_amount, r.amount,
           r.sqm, r.forecast_sqm, r.rework_count, r.rework_sqm, r.impact_json, r.gross_sqm,
           coalesce(r.part_status_json, '[]'::jsonb),
           -- the nests of the lane items, not the ones the orderlines sit on
           coalesce(r.nest_ids, '{}'::bigint[]),
           coalesce(cardinality(r.nest_ids), 0),
           r.seconds_to_logistics_date,
           -- the class names of the work plus those of the kind
           coalesce((select array_agg(distinct c order by c)
                     from unnest(coalesce(r.class_names, '{}'::text[]) || v_plan_class_names) as c),
                    '{}'::text[]),
           coalesce(r.unit_class_names, '{}'::text[]),
           r.lane_item_id, r.lane_id,
           -- the kind of row: every row is a plan row
           'plan'::text,
           v_plan_type_json,
           -- the absolute start of the row: the plan date's midnight plus the offset
           -- (the board's formulas compare it with current_offset_in_seconds)
           case when r.start_offset_in_seconds is not null
                then (v_date::timestamp at time zone 'Europe/Amsterdam') + make_interval(secs => r.start_offset_in_seconds) end
    from row_data r
    left join site.tenant t on t.tenant_id = r.tenant_id
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
        select t.tenant_id, t.name as tenant_name, t.abb, t.production_company_id
        from site.tenant t
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
        -- the day of p_until only: a resource board is one day
        from action.get_plan_lanes_imposition_group(
                 p_until, p_line_type => p_line_type, p_tenant_ids => p_tenant_ids,
                 p_only_starting_today => true,
                 p_look_back_days => 0, p_look_ahead_days => 0) b
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

-- ============ 4. the data_table the boards read the labels through ============
-- the existing row keeps its id and becomes the material read
UPDATE site.data_table
SET data_table  = 'get_plan_lanes_imposition_group',
    query       = 'action.get_plan_lanes_imposition_group',
    description = 'get_plan_lanes_imposition_group'
WHERE data_table = 'get_plan_lanes';

-- the resource read is a row of its own; data_table_id is a GENERATED ALWAYS
-- identity, so the sequence gives the id
INSERT INTO site.data_table (data_table, query, stored_proc, description,
                             data_table_json, do_cache)
SELECT 'get_plan_lanes_resource', 'action.get_plan_lanes_resource', '',
       'get_plan_lanes_resource',
       jsonb_build_object('primary_keys',
                          jsonb_build_array('tenant_id', 'resource_uid', 'lane_id')),
       false
WHERE NOT EXISTS (SELECT 1 FROM site.data_table WHERE data_table = 'get_plan_lanes_resource');

COMMIT;

-- ============ checks (read-only) ============

-- 1. what is there now: the two reads, the two helpers, and nothing left of
--    the old name
SELECT n.nspname || '.' || p.proname AS fn,
       pg_get_function_identity_arguments(p.oid) AS args
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE p.proname IN ('get_plan_lanes', 'get_plan_lanes_imposition_group',
                    'get_plan_lanes_resource', 'get_resource_setting', 'get_setting_numbers')
ORDER BY 1, 2;

-- 2. the material lanes per day: how many rows, how many with a time of their
--    own, and the first and last moment on the axis. Day -1 only shows rows
--    when a plan of that date exists.
SELECT day_offset,
       count(*)                                        AS row_count,
       count(*) FILTER (WHERE fixed_group IS NOT NULL) AS fixed_rows,
       min(start_offset_in_seconds)                    AS first_offset,
       max(start_offset_in_seconds)                    AS last_offset
FROM action.get_plan_lanes_imposition_group(
         p_until => '2026-09-08 06:00+02', p_line_type => 'sheet')
GROUP BY day_offset
ORDER BY day_offset;

-- 3. the order the boards read: day first, then the sort order per plan
SELECT day_offset, tenant_id, sort_order, delivery_hours, fixed_group,
       start_offset_in_seconds, material_name
FROM action.get_plan_lanes_imposition_group(
         p_until => '2026-09-08 06:00+02', p_line_type => 'sheet')
ORDER BY day_offset, tenant_id, sort_order
LIMIT 40;

-- 4. the day of p_until only is what the two boards read, so this has to be
--    the row count board 76 shows
SELECT count(*) AS rows_day_0
FROM action.get_plan_lanes_imposition_group(
         p_until => '2026-09-08 06:00+02', p_line_type => 'sheet',
         p_look_back_days => 0, p_look_ahead_days => 0);

-- 5. the resource lanes of board 81
SELECT tenant_id, step, resource_uid, sort_order, lane_id,
       param_json, formula
FROM action.get_plan_lanes_resource(
         p_until => '2026-09-08 06:00+02', p_line_type => 'sheet')
ORDER BY tenant_id, sort_order NULLS LAST, resource_path;

-- 6. the two boards themselves still read (and how long they take)
EXPLAIN (ANALYZE, SUMMARY)
SELECT * FROM mock.get_impose_plan('2026-09-08 06:00+02', 'impose', 'sheet');

EXPLAIN (ANALYZE, SUMMARY)
SELECT * FROM action.get_resource_plan('2026-09-08 06:00+02', 'sheet');
