-- Step 3 of docs/plan-batch-lane-item.md: the readers. Run after
-- sql/update_batch_lane_item_writers.sql (step 2).
--
-- 1. action.get_plan_lanes_imposition_group: one row per pattern item, so
--    per instance; the nests and the first nest moment from the item's own
--    batch rows; two new columns, instance and status (the last event).
-- 2. mock.get_impose_plan: the nests of a row are its own batch rows, no
--    longer the whole lane; instance and status ride along.
-- 3. action.get_resource_plan: nest ids from the batch rows.
-- 4. action.crud_lane_item: no set delete (the batch rows cascade).
-- 5. mock.get_impose_plan_inflow: the read of the inflow sidebar (79), the
--    manifest plus the lane item and instance to release; the data_table
--    get_production_orderline_manifest points at it.
-- 6. The 769 items with source 'nest' (the old one-batch-per-item rule) go,
--    with their group links, events, edges and batch rows (cascade).
-- 7. action.imposition_lane_item, action.crud_imposition_lane_item and
--    action.get_lane_item_impositions are dropped: nothing reads them.
-- action.resource_lane stays until its readers and writers moved to
-- lane.resource_path (a step of its own).
BEGIN;

-- ============ sql/action/get_plan_lanes_imposition_group.sql ============
-- One read for the imposition-group lanes (labels) of the nest boards:
-- print_schedule (75), impose_plan (76) and whatever follows. One row per
-- pattern item (source material-plan) of the newest material plan of a day:
-- one per instance of a material moment, reached through lane_item.source_ref
-- (<material_impose_plan_id>:<date>). The nests of a row are its own batch
-- rows (action.batch_lane_item, docs/plan-batch-lane-item.md); the instance
-- and the last status (action.lane_item_event) ride along. No noop
-- windows any more: the non-working time is the time scale's
-- (production.get_timeline_view_segments), not a row. imposition_group_id is
-- the material_id alias until the xbom groups arrive.
--
-- The resource lanes are action.get_plan_lanes_resource. p_step here names the
-- step of the plan to read (the plan whose steps carry it); p_steps there names
-- the steps whose resources are lanes -- two different questions, so two reads.
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
-- a pinned item carries start_offset_in_seconds. Every other item is a filler
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
-- the return type changes (plan_date), so the old one has to go first
drop function if exists action.get_plan_lanes_imposition_group(timestamp with time zone, text, text, integer[], boolean, integer, integer, text);
-- the version before the days came from the view
drop function if exists action.get_plan_lanes_imposition_group(timestamp with time zone, text, text, integer[], boolean, text);

create function action.get_plan_lanes_imposition_group(p_until timestamp with time zone DEFAULT now(), p_step text DEFAULT 'impose'::text, p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_only_starting_today boolean DEFAULT true, p_view_code text DEFAULT 'nest-time-scale'::text) returns TABLE(imposition_group_id integer, material_id integer, material_name text, production_line_id integer, tenant_id integer, tenant_name text, resource_path ltree, resource_uid text, resource_name text, delivery_hours integer, min_delivery_hours integer, day_offset integer, plan_date date, sort_order numeric, param_json jsonb, formula jsonb, data jsonb, fixed_group text, is_pinned boolean, start_offset_in_seconds integer, next_start_offset_in_seconds integer, lane_item_id bigint, lane_id bigint, instance integer, status text)
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
    v_look_back_days  integer;  -- the days the view reaches before day 0 ...
    v_look_ahead_days integer;  -- ... and after it
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
        -- one row per pattern item of that day's plan: one per instance
        SELECT d.day_offset, d.plan_date, li.lane_id, li.lane_item_id, li.sort_order, li.is_pinned,
               li.start_offset_in_seconds,
               igli.imposition_group_id,
               nullif(split_part(li.source_ref, ':', 1), '')::bigint AS material_impose_plan_id,
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
           i.lane_item_id, i.lane_id, i.instance, i.status
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
    -- only a fixed group (its own time, else the class moment), an item of a
    -- past day, a pinned item or an item with nests (its own time, else the
    -- clock time of its first nest on its day) has a time of its own; every
    -- other item is a filler and serves null -- the client chains fillers
    -- itself. The day of the row moves the offset to midnight of day 0
    CROSS JOIN LATERAL (
        SELECT CASE WHEN cls.fixed_group IS NOT NULL OR i.day_offset < 0
                    THEN coalesce(i.start_offset_in_seconds, cls.class_offset)
                    WHEN i.is_pinned THEN i.start_offset_in_seconds
                    WHEN i.has_nests
                    THEN coalesce(i.start_offset_in_seconds,
                                  extract(epoch FROM (i.first_nest_at AT TIME ZONE 'Europe/Amsterdam')
                                                     - i.plan_date::timestamp)::integer)
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

alter function action.get_plan_lanes_imposition_group(timestamp with time zone, text, text, integer[], boolean, text) owner to xfw3;


-- ============ sql/mock/get_impose_plan.sql ============
-- renamed from mock.get_nest_schedule (via get_imposition_plan); impose is
-- the step, imposition the object it produces
drop function if exists mock.get_nest_schedule(timestamp with time zone, text, text, integer[], boolean, integer, integer, integer);
drop function if exists mock.get_nest_schedule(timestamp with time zone, text, text, integer[], integer, integer, integer);
drop function if exists mock.get_imposition_plan(timestamp with time zone, text, text, integer[], integer, integer, integer);
drop function if exists mock.get_impose_plan(timestamp with time zone, text, text, integer[], boolean, integer, integer, integer);
drop function if exists mock.get_impose_plan(timestamp with time zone, text, text, integer[], integer, integer, integer);
drop function if exists mock.get_impose_plan(timestamp with time zone, text, text, integer[], integer, integer, integer, text);
drop function if exists mock.get_impose_plan(timestamp with time zone, text, text, integer[], integer, text, text);
-- the return type grows (instance, status), so the current one goes first
drop function if exists mock.get_impose_plan(timestamp with time zone, text, text, integer[], integer, integer, text, text);

-- The rows of the days in view. The time scale decides which days those are:
-- the days production.get_timeline_view_segments(p_view_code) has segments
-- for, so with nest-time-scale the evening of the day before and the day of
-- p_until, and nothing of the day after. Each day carries the plan of its own
-- date and its own work: the component specs whose nest date falls in the span
-- of that day on the axis, moved to that working day -- on the day before only
-- from the evening moment on (p_date_type says on which date the work is
-- judged: nest or production). p_threshold splits the work into its unit
-- classes (all together within 48 hours of production, else small and big
-- orders apart). Offsets count from midnight of the day of p_until, so a row
-- of the day before is negative. The order is tenant first, then day, then the
-- sort order of that day's plan.
--
-- every row is a plan row: type and type_json (the node of
-- lookup_lane_item_type, with sort_order, placement and formula) ride along as
-- on get_resource_plan, so the board reads the kind of row the same way. The
-- non-working time is the time scale's (get_timeline_view_segments), no rows.
create function mock.get_impose_plan(p_until timestamp with time zone DEFAULT now(), p_step text DEFAULT 'impose'::text, p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_threshold integer DEFAULT 1, p_domain_id integer DEFAULT 1, p_date_type text DEFAULT 'nest'::text, p_view_code text DEFAULT 'nest-time-scale'::text) returns TABLE(material_id integer, material_name text, production_line_id integer, tenant_id integer, tenant_name text, production_company_id integer, resource_uid text, resource_name text, resource_path ltree, delivery_hours integer, min_delivery_hours integer, sort_order numeric, param_json jsonb, formula jsonb, data jsonb, fixed_group text, is_pinned boolean, start_offset_in_seconds integer, next_start_offset_in_seconds integer, duration_in_seconds integer, nest_date date, orderline_count integer, product_amount numeric, part_amount integer, amount numeric, sqm numeric, forecast_sqm numeric, rework_count integer, rework_sqm numeric, impact_json jsonb, gross_sqm numeric, part_status_json jsonb, nest_ids bigint[], nest_count integer, seconds_to_logistics_date integer, class_names text[], unit_class_names text[], lane_item_id bigint, lane_id bigint, day_offset integer, type text, type_json jsonb, start_at timestamp with time zone, production_seconds_min integer, production_seconds_max integer, batch_count integer, delivery_hours_json jsonb, step_json jsonb, set_json jsonb, manifest_json jsonb, instance integer, status text)
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
    with segment as materialized (
        -- The axis, per day from what moment to what moment. With
        -- nest-time-scale that is the evening of the day before (the 18 hours
        -- moment) and the day of p_until. The lanes read takes its days from
        -- the same view. The dates of the segments are calendar days; the plan
        -- days below are working days, so a segment only lends its day_offset
        -- and its clock times
        select s.day_offset, s.date, s.start_at, s.end_at
        from production.get_timeline_view_segments(
                 p_code       => p_view_code,
                 p_until      => p_until,
                 p_look_back  => -1,
                 p_look_ahead => -1,
                 p_tenant_ids => p_tenant_ids) s
    ),
    base as (
        select b.day_offset, b.plan_date,
               b.material_id, b.material_name, b.production_line_id,
               b.tenant_id, b.tenant_name, b.resource_uid, b.resource_name,
               -- the row's own resource: valid_resources.resource_field reads it
               b.resource_path,
               b.delivery_hours, b.min_delivery_hours, b.sort_order,
               b.param_json, b.formula, b.data, b.fixed_group, b.is_pinned,
               b.start_offset_in_seconds, b.next_start_offset_in_seconds,
               b.lane_item_id, b.lane_id, b.instance, b.status
        -- The days in view, each with the plan of its own date; day_offset says
        -- which day a row comes from, plan_date the working day behind it (the
        -- day before a Monday is the Friday before it). The axis of the time
        -- scale decides which moments are rows, so a moment it does not reach
        -- (the noon of the day before) has none, and a day without a plan (a
        -- weekend) has none either. Only the materials whose interval
        -- (action.get_interval_dates on interval_start_date and interval_days)
        -- says that day is a production day; the rest of the plan stays out
        from action.get_plan_lanes_imposition_group(
                 p_until, p_step, p_line_type, p_tenant_ids, p_only_starting_today => true,
                 p_view_code => p_view_code) b
    ),
    lane_nest as (
        -- the nests of the row's own item: its batch rows together
        -- (action.batch_lane_item, one per batch, the null row for the nests
        -- not batched yet)
        select b2.lane_item_id, array_agg(distinct x) as nest_ids
        from (select distinct lane_item_id from base where lane_item_id is not null) b2
        join action.batch_lane_item bl on bl.lane_item_id = b2.lane_item_id
        cross join lateral unnest(bl.nest_ids) as x
        group by b2.lane_item_id
    ),
    -- One read for the work of every row: action.get_lane_item_work takes the
    -- scope of each row (the nests of its lane, else its material and line in
    -- the day window) and gives back the totals plus the two lists the board
    -- shows. The fold that used to live here -- an aggregate call per nest set
    -- and a lateral that summed the delivery classes back together -- is that
    -- function now, and board 81 reads the same one.
    work as (
        -- one call per day in view, with that day as the moment: a row of the
        -- day before carries the work of that day. The helper takes one moment
        -- for all the entries it gets, so the day is the loop
        select d.day_offset, w.*
        from (select distinct b.day_offset, b.plan_date from base b) d
        -- the span of that day on the axis, moved to its plan date: the first
        -- segment start to the last segment end. A segment carries a calendar
        -- date, the plan date is the working day, so the moment shifts by the
        -- days between them. A day without segments has no span, and the work
        -- reader then takes the whole plan date
        cross join lateral (
            select min(s.start_at + make_interval(days => d.plan_date - s.date)) as from_at,
                   max(s.end_at   + make_interval(days => d.plan_date - s.date)) as until_at
            from segment s
            where s.day_offset = d.day_offset) a
        cross join lateral action.get_lane_item_work(
                 -- that day at the same clock time as p_until
                 p_until            => (d.plan_date::timestamp
                                        + (p_until at time zone 'Europe/Amsterdam' - v_date::timestamp))
                                       at time zone 'Europe/Amsterdam',
                 p_scope_json       => (select jsonb_agg(jsonb_build_object(
                                                   'lane_item_id',       b.lane_item_id,
                                                   'nest_ids',           ln.nest_ids,
                                                   'material_id',        b.material_id,
                                                   'production_line_id', b.production_line_id,
                                                   'resource_path',      b.resource_path::text,
                                                   'param_json',         b.param_json))
                                        from base b
                                        left join lane_nest ln on ln.lane_item_id = b.lane_item_id
                                        where b.lane_item_id is not null
                                          and b.day_offset = d.day_offset),
                 p_date_type        => p_date_type,
                 p_status_sequences => v_status_sequences,
                 -- the day itself, and inside it the span of the axis: the
                 -- work of a row is the component specs whose nest date falls
                 -- between the first and the last moment of its day, so the
                 -- day before counts the evening moment only
                 p_look_back_days   => 0,
                 p_look_ahead_days  => 0,
                 p_from_at          => a.from_at,
                 p_until_at         => a.until_at,
                 -- the size at or below which an order is a small one (unit class)
                 p_threshold        => p_threshold,
                 p_tenant_ids       => p_tenant_ids,
                 p_domain_id        => p_domain_id) w
    ),
    row_data as (
        select b.*, ln.nest_ids,
               w.orderline_count, w.product_amount, w.part_amount, w.amount,
               w.sqm, w.forecast_sqm, w.rework_count, w.rework_sqm, w.impact_json, w.gross_sqm,
               w.specs_json, w.part_status_json, w.seconds_to_logistics_date,
               w.class_names, w.unit_class_names,
               -- the time of the row: the work of the width class only (30
               -- hours, from the manifests); the other classes ride along in
               -- the numbers, not in the time
               (w.delivery_hours_json -> v_width_delivery_hours::text
                    ->> 'production_impact_in_seconds')::integer as production_impact_in_seconds,
               w.production_seconds_min, w.production_seconds_max,
               w.batch_count, w.min_delivery_hours as work_min_delivery_hours,
               w.delivery_hours_json, w.step_json, w.set_json, w.manifest_json
        from base b
        left join lane_nest ln on ln.lane_item_id = b.lane_item_id
        left join work w on w.lane_item_id = b.lane_item_id and w.day_offset = b.day_offset
    )
    select r.material_id, r.material_name, r.production_line_id,
           r.tenant_id, r.tenant_name, t.production_company_id, r.resource_uid, r.resource_name,
           r.resource_path,
           r.delivery_hours,
           -- the shortest delivery time in the work of the row; without work the
           -- setting of the material
           coalesce(r.work_min_delivery_hours, r.min_delivery_hours), r.sort_order,
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
           -- the day of the row: the plan date its lane comes from. Working
           -- days, so the day before a Monday is the Friday before it
           r.plan_date as nest_date,
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
           r.lane_item_id, r.lane_id, r.day_offset,
           -- the kind of row: every row is a plan row
           'plan'::text,
           v_plan_type_json,
           -- the moment the row starts: its own plan date plus the time of day
           -- in the offset. The offset itself counts from midnight of day 0 (the
           -- axis), and with working days that is another date than the plan
           -- date of the row -- the day before a Monday is the Friday before it
           case when r.start_offset_in_seconds is not null
                then (r.plan_date::timestamp
                      + make_interval(secs => r.start_offset_in_seconds - r.day_offset * 86400))
                     at time zone 'Europe/Amsterdam' end,
           -- what the work costs on the fastest and on the slowest machine of
           -- every step, the batches behind the row, and the three lists
           r.production_seconds_min, r.production_seconds_max,
           coalesce(r.batch_count, 0),
           coalesce(r.delivery_hours_json, '{}'::jsonb),
           coalesce(r.step_json, '{}'::jsonb),
           coalesce(r.set_json, '[]'::jsonb),
           coalesce(r.manifest_json, '[]'::jsonb),
           -- the instance of the moment and the last status of the item
           r.instance, r.status
    from row_data r
    left join site.tenant t on t.tenant_id = r.tenant_id
    -- tenant first, then the day: sort_order starts over per plan, so without
    -- the day in front of it the days would interleave
    order by r.tenant_id, r.day_offset, r.sort_order;
end;
$$;

alter function mock.get_impose_plan(timestamp with time zone, text, text, integer[], integer, integer, text, text) owner to xfw3;

-- the board query is planned per call and inlines the aggregate; JIT compiling
-- it costs seconds and never pays back
alter function mock.get_impose_plan(timestamp with time zone, text, text, integer[], integer, integer, text, text) set jit = off;


-- ============ sql/action/get_resource_plan.sql ============
-- The one item read of the resource board (docs/plan-lane-model.md, stap 7):
-- one row per lane item on the resource lanes of the day's plans — the
-- production plans, and the impose plan (material-resource-plan) whose
-- resource lanes are the impose machines and whose items are the material
-- items whose pattern names that machine (stap 7c) —
-- for the steps asked (p_steps null = every step planned that day), in three
-- kinds of rows, named by lane_item.type and action.lookup /
-- lookup_lane_item_type:
--   * plan     — the item as planned (stored); its nests from its batch rows
--                (action.batch_lane_item), the work of the set from the
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
-- mock.get_impose_plan (78). The labels come from action.get_plan_lanes_resource in
-- the resource read.
drop function if exists action.get_resource_plan(timestamp with time zone, text, integer[], text[], text[], integer);

create function action.get_resource_plan(p_until timestamp with time zone DEFAULT now(), p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_steps text[] DEFAULT NULL::text[], p_types text[] DEFAULT NULL::text[], p_domain_id integer DEFAULT 1)
    returns TABLE(tenant_id integer, tenant_name text, production_company_id integer, resource_uid text, resource_name text, resource_path ltree, lane_id bigint, step text, type text, type_json jsonb, lane_item_id bigint, sort_order numeric, is_pinned boolean, no_split boolean, fixed_group text, start_offset_in_seconds integer, duration_in_seconds integer, start_at timestamp with time zone, end_at timestamp with time zone, nest_ids bigint[], nest_count integer, batch_id integer, batch_name text, material_id integer, material_name text, impact_json jsonb, sqm numeric, forecast_sqm numeric, gross_sqm numeric, part_status_json jsonb, progress_json jsonb, state_json jsonb, group_state_json jsonb, states_json jsonb, class_names text[], param_json jsonb, min_delivery_hours integer, production_seconds_min integer, production_seconds_max integer, batch_count integer, delivery_hours_json jsonb, step_json jsonb, set_json jsonb, manifest_json jsonb)
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
               b.resource_path, b.fixed_group, b.start_offset_in_seconds, b.param_json
        -- the day of p_until only: a resource board is one day, while the
        -- lanes read gives every day of its view
        from action.get_plan_lanes_imposition_group(
                 p_until, p_line_type => p_line_type, p_tenant_ids => p_tenant_ids,
                 p_only_starting_today => true) b
        where b.lane_id is not null
          and b.day_offset = 0
    ),
    -- planned items with the nests hung on them (their batch rows,
    -- action.batch_lane_item): the items on the lane itself (production
    -- plans), plus for an impose lane the items of every material lane whose
    -- pattern names its resource — the pattern items with the class time and
    -- fixed group of board 76, one per instance
    item as (
        select li.lane_item_id, li.lane_id, li.sort_order, li.is_pinned, li.no_split,
               li.fixed_group, li.start_offset_in_seconds, li.duration_in_seconds,
               null::integer as material_id, null::text as material_name, null::integer as production_line_id,
               '{}'::jsonb as param_json,
               (select array_agg(distinct x)
                from action.batch_lane_item bl
                cross join lateral unnest(bl.nest_ids) as x
                where bl.lane_item_id = li.lane_item_id) as nest_ids
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
               ml.param_json,
               (select array_agg(distinct x)
                from action.batch_lane_item bl
                cross join lateral unnest(bl.nest_ids) as x
                where bl.lane_item_id = li.lane_item_id)
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
        cross join lateral unnest(coalesce(i.nest_ids, '{}'::bigint[])) as nid
        join legacy.nest n on n.nest_id = nid
        left join legacy.batch b on b.batch_id = n.batch_id
        left join mapping.internal_status ist on ist.code = n.nest_json ->> 'internal_status_code' and ist.domain_id = p_domain_id
        group by i.lane_item_id
    ),
    -- One read for the work of every item: action.get_lane_item_work takes the
    -- scope of each item (its own nests, else its material and line on the day)
    -- and gives back the totals plus the lists. Board 76 reads the same
    -- function, so both boards agree on every item.
    work as (
        select w.*
        from action.get_lane_item_work(
                 p_until            => p_until,
                 p_scope_json       => (select jsonb_agg(jsonb_build_object(
                                                   'lane_item_id',       i.lane_item_id,
                                                   'nest_ids',           i.nest_ids,
                                                   'material_id',        i.material_id,
                                                   'production_line_id', i.production_line_id,
                                                   'resource_path',      l.resource_path::text,
                                                   'param_json',         i.param_json))
                                        from item i
                                        join lane l on l.lane_id = i.lane_id
                                        where i.nest_ids is not null or i.material_id is not null),
                 p_date_type        => 'nest',
                 p_status_sequences => v_status_sequences,
                 p_look_back_days   => 0,
                 p_look_ahead_days  => 0,
                 p_tenant_ids       => p_tenant_ids,
                 p_domain_id        => p_domain_id) w
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
                         then greatest(coalesce(w.production_impact_in_seconds, 0),
                                       v_min_duration_in_seconds)
                    else greatest(ceil(coalesce(nf.run_sqm, 0) * v_standard_seconds_per_sqm
                                       / coalesce(nullif(mock.get_resource_speed_factor(w.material_id, l.resource_uid), 0), 1))::integer,
                                  v_min_duration_in_seconds) end                       as duration_in_seconds,
               coalesce(i.nest_ids, '{}'::bigint[])                                   as nest_ids,
               coalesce(cardinality(i.nest_ids), 0)                                    as nest_count,
               nf.batch_id, nf.batch_name,
               -- the material of the set, else of the material item itself; the
               -- work of the set, else the open work of the material
               coalesce(w.material_id, i.material_id)                                  as material_id,
               coalesce(w.material_name, i.material_name)                              as material_name,
               w.impact_json                                                           as impact_json,
               w.sqm                                                                   as sqm,
               w.forecast_sqm                                                          as forecast_sqm,
               w.gross_sqm                                                             as gross_sqm,
               coalesce(w.part_status_json, '[]'::jsonb)                               as part_status_json,
               -- the state of a planned item is the least advanced status of its
               -- nests, from the same lookup the actual rows use
               (select st.value from jsonb_array_elements(v_state_lookup) as ss(value)
                                     cross join lateral jsonb_array_elements(ss.value -> 'states') as st(value)
                 where st.value ->> 'code' = coalesce(nf.internal_status_code, 'batch') limit 1) as state_json,
               (select ss.value - 'states' from jsonb_array_elements(v_state_lookup) as ss(value)
                                           cross join lateral jsonb_array_elements(ss.value -> 'states') as st(value)
                 where st.value ->> 'code' = coalesce(nf.internal_status_code, 'batch') limit 1) as group_state_json,
               coalesce(w.class_names, '{}'::text[])                                   as class_names,
               jsonb_build_object(
                   'standard_production_impact_in_seconds', ceil(coalesce(nf.run_sqm, 0) * v_standard_seconds_per_sqm)::integer,
                   'run_sqm',                                round(coalesce(nf.run_sqm, 0), 2),
                   'speed_factor',                           mock.get_resource_speed_factor(coalesce(w.material_id, i.material_id), l.resource_uid),
                   'orderline_count',                        w.orderline_count) as param_json,
               -- what is done and what remains for the lane's step: the part
               -- amounts at or past the step's done status against the rest.
               -- Without orderline amounts nothing is known to be done
               coalesce(pr.done_amount, 0)                                             as done_amount,
               coalesce(pr.remaining_amount, 0)                                        as remaining_amount,
               case when coalesce(pr.done_amount, 0) + coalesce(pr.remaining_amount, 0) > 0
                    then coalesce(pr.remaining_amount, 0) / (coalesce(pr.done_amount, 0) + coalesce(pr.remaining_amount, 0))
                    else 1 end                                                         as remaining_share,
               -- what the work costs on the fastest and on the slowest machine of
               -- every step, the batches behind the item, and the lists
               w.min_delivery_hours, w.production_seconds_min, w.production_seconds_max,
               coalesce(w.batch_count, 0)                                              as batch_count,
               coalesce(w.delivery_hours_json, '{}'::jsonb)                            as delivery_hours_json,
               coalesce(w.step_json, '{}'::jsonb)                                      as step_json,
               coalesce(w.set_json, '[]'::jsonb)                                       as set_json,
               coalesce(w.manifest_json, '[]'::jsonb)                                  as manifest_json
        from item i
        join lane l on l.lane_id = i.lane_id
        left join item_nest nf on nf.lane_item_id = i.lane_item_id
        left join work w on w.lane_item_id = i.lane_item_id
        left join lateral (
            select sum((e.value ->> 'amount')::numeric) filter (where (e.value ->> 'sequence')::integer >= l.done_sequence) as done_amount,
                   sum((e.value ->> 'amount')::numeric) filter (where (e.value ->> 'sequence')::integer <  l.done_sequence) as remaining_amount
            from jsonb_array_elements(coalesce(w.part_status_json, '[]'::jsonb)) as e(value)
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
                   'remaining_impact_in_seconds',     round(p.duration_in_seconds * p.remaining_share)::integer) as param_json,
               p.min_delivery_hours, p.production_seconds_min, p.production_seconds_max,
               p.batch_count, p.delivery_hours_json, p.step_json, p.set_json, p.manifest_json
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
                   'remaining_impact_in_seconds',     round(p.duration_in_seconds * p.remaining_share)::integer),
               p.min_delivery_hours, p.production_seconds_min, p.production_seconds_max,
               p.batch_count, p.delivery_hours_json, p.step_json, p.set_json, p.manifest_json
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
                   'actual_duration_in_seconds',      a.duration_in_seconds),
               null::integer, null::integer, null::integer,
               0, '{}'::jsonb, '{}'::jsonb, '[]'::jsonb, '[]'::jsonb
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
           r.param_json,
           r.min_delivery_hours, r.production_seconds_min, r.production_seconds_max,
           r.batch_count, r.delivery_hours_json, r.step_json, r.set_json, r.manifest_json
    from rows r
    left join kind k on k.type = r.type
    where p_types is null or r.type = any (p_types)
    order by r.tenant_id, r.resource_path, k.sort_order nulls last, r.start_offset_in_seconds, r.sort_order;
end;
$$;

alter function action.get_resource_plan(timestamp with time zone, text, integer[], text[], text[], integer) owner to xfw3;


-- ============ sql/action/crud_lane_item.sql ============
drop function if exists action.crud_lane_item(jsonb, boolean);

create function action.crud_lane_item(p_param_json jsonb, p_no_results boolean DEFAULT false) returns TABLE(param_id integer, track_by integer, crud text, lane_item_id bigint, lane_id bigint, material_impose_plan_id bigint)
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
    -- data keeps its value. A copy is the next instance of the moment on its
    -- lane (lane_item.instance). Every mutation writes through to mock.material_impose_plan, so
    -- re-stamping a plan reproduces what the planner did:
    --   update — move/pin/sort: the item and its pattern row
    --   create — an extra moment: a new pattern row with the next instance,
    --            plus the lane and the item it stamps to
    --   delete — the moment and its pattern row; its batch rows cascade
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
    -- pattern row it was stamped from (source_ref is <mrp_id>:<date>)
    source AS (
        SELECT p.param_id,
               li.lane_item_id, li.lane_id, li.sort_order, li.start_offset_in_seconds,
               li.is_pinned, li.duration_in_seconds,
               l.lane_date, l.resource_path,
               -- only a pattern item has a pattern row; a batch item (source
               -- 'nest', source_ref <lane_id>:<batch>) writes nothing through
               CASE WHEN li.source = 'material-plan'
                    THEN nullif(split_part(li.source_ref, ':', 1), '')::bigint END AS material_impose_plan_id,
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
    updated_pattern AS (
        -- the write-through: the same move on the template
        UPDATE mock.material_impose_plan m
        SET sort_order              = coalesce(p.sort_order, m.sort_order),
            start_offset_in_seconds = coalesce(p.start_offset_in_seconds, m.start_offset_in_seconds),
            is_pinned               = coalesce(p.is_pinned, m.is_pinned),
            moved_at                = now()
        FROM payload p
        JOIN source s ON s.param_id = p.param_id
        WHERE p.crud = 'update' AND m.material_impose_plan_id = s.material_impose_plan_id
        RETURNING m.material_impose_plan_id
    ),
    -- ── create ────────────────────────────────────────────────────────────
    -- ids up front: the pattern row, the lane (only for a copy that needs its
    -- own lane) and the item itself
    new_id AS (
        SELECT p.param_id, p.track_by, p.plan_id, p.sort_order, p.is_pinned,
               p.start_offset_in_seconds, p.lane_id AS given_lane_id,
               coalesce(p.imposition_group_id, s.imposition_group_id) AS imposition_group_id,
               coalesce(p.resource_path, s.resource_path)             AS resource_path,
               s.material_impose_plan_id AS from_pattern_id,
               s.lane_id                 AS from_lane_id,
               nextval('mock.material_resource_plan_material_resource_plan_id_seq') AS new_pattern_id,
               nextval('action.lane_item_lane_item_id_seq')                          AS new_lane_item_id,
               CASE WHEN p.lane_id IS NULL AND s.lane_id IS NULL
                    THEN nextval('action.lane_lane_id_seq') END                      AS new_lane_id
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
    -- the new pattern row: the copy of the source row with the next instance
    new_pattern AS (
        INSERT INTO mock.material_impose_plan
            (material_impose_plan_id, weekday, step, resource_path, sort_order,
             material_id, instance, production_line_id, tenant_id,
             start_offset_in_seconds, is_pinned)
        OVERRIDING SYSTEM VALUE
        SELECT t.new_pattern_id, m.weekday, m.step, m.resource_path,
               coalesce(t.sort_order, m.sort_order), m.material_id,
               -- the next repeat of this moment in its own lane
               (SELECT coalesce(max(m2.instance), 0) + 1
                FROM mock.material_impose_plan m2
                WHERE m2.weekday = m.weekday AND m2.step = m.step
                  AND m2.resource_path IS NOT DISTINCT FROM m.resource_path
                  AND m2.material_id IS NOT DISTINCT FROM m.material_id),
               m.production_line_id, m.tenant_id,
               coalesce(t.start_offset_in_seconds, m.start_offset_in_seconds),
               coalesce(t.is_pinned, m.is_pinned)
        FROM target t
        JOIN mock.material_impose_plan m ON m.material_impose_plan_id = t.from_pattern_id
        RETURNING material_impose_plan_id
    ),
    new_item AS (
        INSERT INTO action.lane_item
            (lane_item_id, lane_id, sort_order, start_offset_in_seconds,
             duration_in_seconds, is_pinned, no_split, type, source, source_ref, instance)
        OVERRIDING SYSTEM VALUE
        SELECT t.new_lane_item_id, t.lane_id,
               -- no rank from the client: append behind the lane, spread so a
               -- batch never collides on the unique (lane_id, sort_order)
               coalesce(t.sort_order,
                        (SELECT coalesce(max(li2.sort_order), 0)
                         FROM action.lane_item li2 WHERE li2.lane_id = t.lane_id)
                        + 1000 * row_number() OVER (ORDER BY t.param_id)),
               coalesce(t.start_offset_in_seconds, 0), 0,
               coalesce(t.is_pinned, false), true, 'plan',
               'material-plan',
               -- same shape generate_plan stamps, so the item stays idempotent
               t.new_pattern_id || ':' || t.lane_date,
               -- the next repeat of the moment on its lane
               (SELECT coalesce(max(li3.instance), -1)
                FROM action.lane_item li3 WHERE li3.lane_id = t.lane_id AND li3.type = 'plan')
               + row_number() OVER (PARTITION BY t.lane_id ORDER BY t.param_id)
        FROM target t
        WHERE t.lane_id IS NOT NULL
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
    ),
    deleted_pattern AS (
        -- without this the moment returns at the next stamp
        DELETE FROM mock.material_impose_plan m
        USING payload p
        JOIN source s ON s.param_id = p.param_id
        WHERE p.crud = 'delete' AND m.material_impose_plan_id = s.material_impose_plan_id
        RETURNING m.material_impose_plan_id
    )
    SELECT p.param_id, p.track_by, p.crud,
           coalesce(t.new_lane_item_id, p.lane_item_id),
           coalesce(t.lane_id, p.lane_id),
           coalesce(t.new_pattern_id, s.material_impose_plan_id)
    FROM payload p
    LEFT JOIN target t ON t.param_id = p.param_id
    LEFT JOIN source s ON s.param_id = p.param_id
    WHERE NOT p_no_results
    ORDER BY p.param_id;
$$;

alter function action.crud_lane_item(jsonb, boolean) owner to xfw3;


-- ============ sql/mock/get_impose_plan_inflow.sql ============
-- The read of the inflow sidebar (79, impose_plan_inflow): the orderline
-- manifest of a material (mapping.get_production_orderline_manifest, every
-- column as is) plus the lane item the nests of that material will land on,
-- so the release button knows what to release. Per production line of the
-- rows: the pattern items of the material on the newest material plan of
-- p_date, and of those the first instance not released yet (instance 0
-- before 1); when every instance is released, the last one, the item the
-- nests go to now. p_instance is honoured when it names an instance that is
-- still unreleased; otherwise the rule wins, so a sidebar opened from the
-- 14:00 instance while 10:00 is still open points at 10:00.
drop function if exists mock.get_impose_plan_inflow(integer, date, integer, integer, text, integer, integer, integer[]);

create function mock.get_impose_plan_inflow(p_material_id integer, p_date date DEFAULT CURRENT_DATE, p_look_ahead_days integer DEFAULT '-1'::integer, p_threshold integer DEFAULT 1, p_line_type text DEFAULT NULL::text, p_instance integer DEFAULT NULL::integer, p_domain_id integer DEFAULT 1, p_tenant_ids integer[] DEFAULT NULL::integer[]) returns TABLE(number text, order_sequence integer, order_id integer, production_order_id integer, production_orderline_id integer, sales_orderline_id integer, customer_json jsonb, material_id integer, material_name text, product_amount numeric, sqm numeric, product_width numeric, product_height numeric, ship_separately boolean, production_line_id integer, production_company_id integer, tenant_name text, internal_status_code text, status_sequence integer, status_level text, status_title text, part_amount integer, part_status_json jsonb, nest_date date, production_date date, logistics_date date, logistics_at timestamp without time zone, shipment_date date, dates_json jsonb, impact_json jsonb, rejected_amount numeric, produced_amount numeric, nest_json jsonb, nest_ids bigint[], delivery_class_names text[], class_names text[], unit_class_names text[], queue_class_names text[], manifest_json jsonb, fill_percentage numeric, lane_item_id bigint, instance integer)
	stable
	language sql
as $$
    WITH plan AS (
        SELECT p.plan_id
        FROM action.plan p
        WHERE p.plan_date = p_date
          AND p.type = 'material-resource-plan'
          AND (p_line_type IS NULL OR p.line_type = p_line_type)
        ORDER BY p.plan_id DESC
        LIMIT 1
    ),
    -- the pattern items of the material on that plan, per production line
    item AS (
        SELECT li.lane_item_id, li.instance, m.production_line_id,
               EXISTS (SELECT 1 FROM action.lane_item_event e
                       WHERE e.lane_item_id = li.lane_item_id AND e.status = 'released') AS is_released
        FROM plan
        JOIN action.plan_lane pl ON pl.plan_id = plan.plan_id
        JOIN action.imposition_group_lane igl ON igl.lane_id = pl.lane_id
        JOIN action.lane_item li ON li.lane_id = pl.lane_id AND li.type = 'plan' AND li.source = 'material-plan'
        JOIN mock.material_impose_plan m
          ON m.material_impose_plan_id = nullif(split_part(li.source_ref, ':', 1), '')::bigint
        WHERE igl.imposition_group_id = p_material_id
    ),
    pick AS (
        SELECT DISTINCT ON (i.production_line_id) i.production_line_id, i.lane_item_id, i.instance
        FROM item i
        ORDER BY i.production_line_id,
                 (NOT i.is_released AND i.instance = p_instance) DESC,
                 i.is_released,
                 CASE WHEN i.is_released THEN -i.instance ELSE i.instance END
    )
    SELECT m.*, pk.lane_item_id, pk.instance
    FROM mapping.get_production_orderline_manifest(
             p_material_id, p_date, p_look_ahead_days, p_threshold, p_domain_id, p_tenant_ids) m
    LEFT JOIN pick pk ON pk.production_line_id = m.production_line_id;
$$;

alter function mock.get_impose_plan_inflow(integer, date, integer, integer, text, integer, integer, integer[]) owner to xfw3;


UPDATE site.data_table
SET query = 'mock.get_impose_plan_inflow',
    description = 'orderline manifest of a material for the inflow board (79), with the lane item to release'
WHERE data_table = 'get_production_orderline_manifest';

-- the items of the old rule
DELETE FROM action.lane_item WHERE source = 'nest';

-- the old set table and its functions
DROP FUNCTION IF EXISTS action.crud_imposition_lane_item(jsonb, boolean);
DROP FUNCTION IF EXISTS action.get_lane_item_impositions(bigint, timestamp with time zone);
DROP TABLE IF EXISTS action.imposition_lane_item;

COMMIT;

-- check: nothing references the old objects any more; expected 0 rows
SELECT n.nspname || '.' || p.proname AS still_referencing
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE p.prosrc LIKE '%imposition_lane_item%' OR p.prosrc LIKE '%get_lane_item_impositions%';

-- check: board 76 today, rows per instance with their own nests
SELECT material_name, instance, status, nest_count, start_offset_in_seconds
FROM mock.get_impose_plan(p_line_type => 'sheet')
WHERE day_offset = 0
ORDER BY tenant_id, sort_order
LIMIT 15;

-- check: the inflow read names a lane item per production line
SELECT production_line_id, lane_item_id, instance, count(*) AS orderlines
FROM mock.get_impose_plan_inflow(26, current_date, p_line_type => 'sheet')
GROUP BY 1, 2, 3;
