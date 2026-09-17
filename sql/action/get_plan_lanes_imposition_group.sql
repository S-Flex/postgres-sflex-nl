-- One read for the imposition-group lanes (labels) of the nest boards:
-- print_schedule (75), impose_plan (76) and whatever follows. One row per
-- pattern item (source material-plan) of the newest material plan of a day:
-- one per nest moment of a material (lane_item.instance, in moment order),
-- the schedule row through lane_item.source_ref
-- (<material_print_schedule_id>:<date>:<instance>). The nests of a row are its own batch
-- rows (action.batch_lane_item, docs/schedule-base.md §9); the instance
-- and the last status (action.lane_item_event) ride along. No noop
-- windows any more: the non-working time is the time scale's
-- (production.get_timeline_view_segments), not a row. imposition_group_id is
-- the material_id alias until the xbom groups arrive.
--
-- The resource lanes are action.get_plan_lanes_resource. p_step here names the
-- step of the plan to read (the plan whose steps carry it); p_steps there names
-- the steps whose resources are lanes -- two different questions, so two reads.
--
-- The nest moment of a row is on the item (lane_item.nest_moment_code, stamped
-- by mock.generate_plan: one item per code of material_print_schedule.nest_moment_codes,
-- instance in moment order). The lookup (lookup_nest_moments) gives the class
-- of that code: its fixed group, the moment it starts at -- on the day the code
-- is offset to, a 48+ item of plan day D nests on D+1 -- and the nest and
-- print time (nest_time, print_time: the third label level of board 75). The
-- material, line, tenant and impose path of a row come from the schedule row
-- named in source_ref; the item's own time is a time on the day of its moment.
--
-- The days in view are the days the time scale of p_view_code has segments for
-- (production.get_timeline_view_segments; with nest-time-scale the day before
-- and the day of p_until), each with the plan of its own date, so a row carries
-- the lane_item_id of that day's plan, its day_offset (-1 the day before, 0 the
-- day of p_until) and the plan_date behind it. Those days are working days: the
-- day before a Monday is the Friday before it, and a weekend or a mandatory day
-- off is no day. The axis decides which rows exist as well: the moment of a row
-- (its own time, else the moment of its class) has to fall inside its span. The
-- evening moment of the day before is therefore a row, while that day's noon
-- moment, which the axis does not reach, is not. A day between the first and
-- the last day of the view without segments of its own repeats day 0 -- the
-- repeat rule of the client as well (docs/handoff-time-scale-frontend.md). A
-- class without a moment lands nowhere and is a row on day 0 only. A view
-- without segments shows day 0 and every moment.
--
-- The offset rule: only a fixed group (its own time, else the class moment) or
-- a pinned item carries start_offset_in_seconds -- on a time scale. On a day
-- scale (segments of a day) every item carries its class moment, since a day
-- scale cannot chain within a day; the cards of board 75 need the item on its
-- day. Every other item is a filler
-- and serves null -- the client chains fillers itself (chain_scope), a
-- moved-but-unpinned item springs back on refresh. The offset counts from
-- midnight of day 0, as the segments of the axis do: a row of the day before
-- carries its own time minus a day, so the evening moment of that day comes out
-- negative. A day before day 0 is history: every item of it has its time (its
-- own, else the moment of its class) and is pinned, so nothing of yesterday
-- ends up in today's chain or moves. An item with nests is pinned as well: it
-- keeps the moment of its first nest (the lane item stores no time of its own
-- yet), while the items without nests keep flowing with the clock -- so a
-- nested row stays where it was nested and the free rows around it swap past it.
--
-- Duration is not computed here. The row carries the formula of its resource
-- and the variables, and the board evaluates -- otherwise a drag to another
-- resource could not change the duration. The chaining offset
-- (next_start_offset_in_seconds) belongs to the resource:
-- resource_json.next_start_lag_in_seconds; the connector mechanism replaces
-- this column later.
-- the return type changes (plan_date, then the nest moment), so the old one has to go first
drop function if exists action.get_plan_lanes_imposition_group(timestamp with time zone, text, text, integer[], boolean, integer, integer, text);
-- the version before the days came from the view
drop function if exists action.get_plan_lanes_imposition_group(timestamp with time zone, text, text, integer[], boolean, text);

create function action.get_plan_lanes_imposition_group(p_until timestamp with time zone DEFAULT now(), p_step text DEFAULT 'impose'::text, p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_only_starting_today boolean DEFAULT true, p_view_code text DEFAULT 'nest-time-scale'::text) returns TABLE(imposition_group_id integer, material_id integer, material_name text, production_line_id integer, tenant_id integer, tenant_name text, resource_path ltree, resource_uid text, resource_name text, delivery_hours integer, min_delivery_hours integer, day_offset integer, plan_date date, sort_order numeric, param_json jsonb, formula jsonb, data jsonb, fixed_group text, is_pinned boolean, start_offset_in_seconds integer, next_start_offset_in_seconds integer, lane_item_id bigint, lane_id bigint, instance integer, status text, nest_moment_code text, nest_time time, print_time time)
	stable
	language plpgsql
as $$
#variable_conflict use_column
DECLARE
    v_date   date;
    v_group  jsonb;    -- nest moment code -> its fixed group
    v_offset jsonb;    -- nest moment code -> the moment the class starts at, on its own day
    v_moment jsonb;    -- nest moment code -> its lookup element (day_offset, nest and print time)
    v_from   integer;  -- the span the board draws, from midnight of day 0
    v_to     integer;  -- the end of the last segment, so exclusive
    v_look_back_days  integer;  -- the days the view reaches before day 0 ...
    v_look_ahead_days integer;  -- ... and after it
    -- a day scale (segments of a day, print-day-scale) places an item on a
    -- day and cannot chain fillers within one: every item with a code carries
    -- its class moment there. A time scale (nest-time-scale) keeps the
    -- fillers for the client to chain
    v_day_scale boolean;
BEGIN
    SELECT coalesce((v.value ->> 'segment_size_in_seconds')::integer >= 86400, false)
    INTO v_day_scale
    FROM production.lookup l
    CROSS JOIN LATERAL jsonb_array_elements(l.lookup_json) AS v(value)
    WHERE l.lookup = 'lookup_timeline_views'
      AND v.value ->> 'code' = p_view_code;
    v_day_scale := coalesce(v_day_scale, false);

    v_date := (p_until AT TIME ZONE current_setting('TimeZone'))::date;

    -- The classes per nest moment code (production.lookup,
    -- lookup_nest_moments): the fixed group, the moment the class starts at
    -- and the element itself. A class is a template, so this is where a lane
    -- item gets its first time; once the planner moves the item, the item wins
    -- (see the coalesce below).
    SELECT coalesce(jsonb_object_agg(v.value ->> 'code', v.value -> 'fixed_group')
                    FILTER (WHERE v.value ->> 'fixed_group' IS NOT NULL), '{}'::jsonb),
           coalesce(jsonb_object_agg(v.value ->> 'code',
                                     v.value #> '{nest_moments,0,nest_time,start_offset_in_seconds}')
                    FILTER (WHERE v.value #>> '{nest_moments,0,nest_time,start_offset_in_seconds}' IS NOT NULL),
                    '{}'::jsonb),
           coalesce(jsonb_object_agg(v.value ->> 'code', v.value), '{}'::jsonb)
    INTO v_group, v_offset, v_moment
    FROM production.lookup l
    CROSS JOIN LATERAL jsonb_array_elements(l.lookup_json) AS v(value)
    WHERE l.lookup = 'lookup_nest_moments';

    -- The days in view and the span of the axis. The days are the ones the
    -- view has segments for, before and after day 0; the span runs from the
    -- first segment of the first day to the last segment of the last day,
    -- counted from midnight of day 0. A day in between without segments of its
    -- own repeats day 0. Taking the day out of a segment offset gives its time
    -- on its own day; adding the day of a row back puts that row on the axis.
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
    SELECT b.look_back_days, b.look_ahead_days,
           min(d.day_offset * 86400 + coalesce(s.from_in_seconds, z.from_in_seconds)),
           max(d.day_offset * 86400 + coalesce(s.to_in_seconds,   z.to_in_seconds))
    INTO v_look_back_days, v_look_ahead_days, v_from, v_to
    FROM (SELECT coalesce(-least(min(day_offset), 0), 0)   AS look_back_days,
                 coalesce(greatest(max(day_offset), 0), 0) AS look_ahead_days
          FROM segment) b
    CROSS JOIN generate_series(-b.look_back_days, b.look_ahead_days) AS d(day_offset)
    LEFT JOIN segment s ON s.day_offset = d.day_offset
    LEFT JOIN segment z ON z.day_offset = 0
    GROUP BY b.look_back_days, b.look_ahead_days;

    RETURN QUERY
    WITH plan_day AS (
        -- The days in view are working days, not calendar days: the day before
        -- a Monday is the Friday before it. day_offset is the place on the axis
        -- (0 the day of p_until, -1 the day before it), plan_date the working
        -- day that fills it -- a weekend and a mandatory day off of the tenants
        -- asked are no day at all (action.dates). Bounded to four months, which
        -- covers any view.
        SELECT 0 AS day_offset, v_date AS plan_date
        UNION ALL
        SELECT -b.day_number, b.date
        FROM (SELECT d.date, row_number() OVER (ORDER BY d.date DESC)::integer AS day_number
              FROM action.dates d
              WHERE d.date < v_date AND d.date >= v_date - 120
                AND d.is_weekend = false
                AND NOT (coalesce(p_tenant_ids, d.tenants_mandatory_day_off) <@ d.tenants_mandatory_day_off
                         AND d.tenants_mandatory_day_off <> '{}')) b
        WHERE b.day_number <= v_look_back_days
        UNION ALL
        SELECT a.day_number, a.date
        FROM (SELECT d.date, row_number() OVER (ORDER BY d.date)::integer AS day_number
              FROM action.dates d
              WHERE d.date > v_date AND d.date <= v_date + 120
                AND d.is_weekend = false
                AND NOT (coalesce(p_tenant_ids, d.tenants_mandatory_day_off) <@ d.tenants_mandatory_day_off
                         AND d.tenants_mandatory_day_off <> '{}')) a
        WHERE a.day_number <= v_look_ahead_days
    ),
    item AS (
        -- one row per material item of that day's plan: one per nest moment
        SELECT d.day_offset, d.plan_date, li.lane_id, li.lane_item_id, li.sort_order, li.is_pinned,
               li.start_offset_in_seconds, li.nest_moment_code,
               igli.imposition_group_id,
               nullif(split_part(li.source_ref, ':', 1), '')::bigint AS material_print_schedule_id,
               -- the nests of the item itself and the moment the first one was made
               nst.first_nest_at IS NOT NULL AS has_nests,
               nst.first_nest_at,
               li.instance,
               -- the last status of the item: plan until it is released
               coalesce(ev.status, 'plan') AS status
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
        LEFT JOIN LATERAL (
            SELECT min(n.nested_at) AS first_nest_at
            FROM action.batch_lane_item b
            JOIN legacy.nest n ON n.nest_id = ANY (b.nest_ids)
            WHERE b.lane_item_id = li.lane_item_id
        ) nst ON true
        LEFT JOIN LATERAL (
            SELECT e.status
            FROM action.lane_item_event e
            WHERE e.lane_item_id = li.lane_item_id
            ORDER BY e.moved_at DESC, e.lane_item_event_id DESC
            LIMIT 1
        ) ev ON true
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
              JOIN mock.material_print_schedule mps ON mps.material_print_schedule_id = i.material_print_schedule_id
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
           coalesce(mps.material_id, i.imposition_group_id),
           mps.material_name, mps.production_line_id,
           mps.tenant_id, t.name,
           mps.resource_path, r.resource_uid, r.resource_name,
           mps.delivery_hours, mps.min_delivery_hours,
           i.day_offset, i.plan_date, i.sort_order,
           -- the variables the board evaluates with: the resource constants,
           -- the format of the group, and the work itself
           production.get_setting_numbers(rs.setting_json)
           || coalesce(w.format_json, '{}'::jsonb)
           -- the sizes of the material and its media type (1 sheet, 3 roll):
           -- what a reader needs to say how much of a size the work takes
           || jsonb_build_object('specs', coalesce(mpl.line_json -> 'specs', '[]'::jsonb),
                                 'material_media_type_id',
                                 (mpl.line_json ->> 'material_media_type_id')::integer),
           coalesce(rs.setting_json -> 'formula', '[]'::jsonb),
           jsonb_build_object('valid_resources', coalesce(vres.resources, '[]'::jsonb)),
           cls.fixed_group,
           -- the mutable truth lives on the lane item; a past day is pinned as a
           -- whole, and so is an item that already has nests
           i.is_pinned OR i.day_offset < 0 OR i.has_nests,
           c.start_offset_in_seconds,
           (r.resource_json ->> 'next_start_lag_in_seconds')::integer,
           i.lane_item_id, i.lane_id, i.instance, i.status,
           -- the nest moment of the row and the nest and print time of that
           -- moment (see the head of the file)
           i.nest_moment_code,
           (v_moment #>> ARRAY[i.nest_moment_code, 'nest_moments', '0', 'nest_time', 'time'])::time,
           (v_moment #>> ARRAY[i.nest_moment_code, 'nest_moments', '0', 'print_time', 'time'])::time
    FROM item i
    LEFT JOIN mock.material_print_schedule mps ON mps.material_print_schedule_id = i.material_print_schedule_id
    LEFT JOIN mapping.material_production_line mpl
           ON (mpl.material_id, mpl.production_line_id) = (mps.material_id, mps.production_line_id)
    LEFT JOIN relation.resource r ON r.resource_path = mps.resource_path
    LEFT JOIN site.tenant t ON t.tenant_id = mps.tenant_id
    -- the speed setting of that resource for that group
    CROSS JOIN LATERAL (
        SELECT production.get_resource_setting(mps.resource_path, i.imposition_group_id) AS setting_json
    ) rs
    -- the format of the group: waste and imposition size, first entry that
    -- matches the material width of the resource path
    LEFT JOIN LATERAL (
        SELECT jsonb_build_object(
                   'waste_percentage', (f.value ->> 'waste_percentage')::numeric,
                   'imposition_sqm', (f.value ->> 'imposition_sqm')::numeric) AS format_json
        FROM legacy.imposition_group g
        CROSS JOIN LATERAL jsonb_array_elements(coalesce(g.rules_json -> 'waste', '[]'::jsonb)) f
        WHERE g.imposition_group_id = i.imposition_group_id
          -- the group of the row's tenant; a row without one is Dokkum's (1)
          AND g.tenant_id = coalesce(mps.tenant_id, 1)
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
          AND subpath(vr.resource_path, 0, 2) = subpath(mps.resource_path, 0, 2)
    ) vres ON true
    -- the class of the row is its nest moment code: the fixed group, the moment
    -- the class starts at -- on the day the code is offset to, so a 48+ item of
    -- plan day D lands on D+1 -- and the item's own time, a time on that same day
    CROSS JOIN LATERAL (
        SELECT coalesce((v_moment #>> ARRAY[i.nest_moment_code, 'day_offset'])::integer, 0) AS moment_day_offset
    ) md
    CROSS JOIN LATERAL (
        SELECT v_group ->> i.nest_moment_code AS fixed_group,
               (v_offset ->> i.nest_moment_code)::integer + md.moment_day_offset * 86400 AS class_offset,
               i.start_offset_in_seconds + md.moment_day_offset * 86400 AS own_offset
    ) cls
    -- only a fixed group (its own time, else the class moment), an item of a
    -- past day, a pinned item or an item with nests (its own time, else the
    -- clock time of its first nest on its day) has a time of its own; every
    -- other item is a filler and serves null -- the client chains fillers
    -- itself. The day of the row moves the offset to midnight of day 0
    CROSS JOIN LATERAL (
        SELECT CASE WHEN cls.fixed_group IS NOT NULL OR i.day_offset < 0 OR v_day_scale
                    THEN coalesce(cls.own_offset, cls.class_offset)
                    WHEN i.is_pinned THEN cls.own_offset
                    WHEN i.has_nests
                    THEN coalesce(cls.own_offset,
                                  extract(epoch FROM (i.first_nest_at AT TIME ZONE 'Europe/Amsterdam')
                                                     - i.plan_date::timestamp)::integer)
               END + i.day_offset * 86400 AS start_offset_in_seconds
    ) c
    WHERE (p_tenant_ids IS NULL OR mps.tenant_id = ANY (p_tenant_ids))
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
    ORDER BY i.day_offset, mps.tenant_id, i.sort_order;
END;
$$;

alter function action.get_plan_lanes_imposition_group(timestamp with time zone, text, text, integer[], boolean, text) owner to xfw3;
