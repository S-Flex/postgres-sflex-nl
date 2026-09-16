-- The day window of the nest board.
--
-- 1. action.get_plan_lanes_imposition_group walks working days, not calendar
--    days: the day before a Monday is the Friday before it, and a weekend or a
--    mandatory day off is no day at all. The date behind a day rides along as
--    plan_date (new column) next to day_offset, which stays the place on the
--    axis -- 0 the day of p_until, -1 the day before it.
-- 2. mock.get_impose_plan passes its own p_look_back_days / p_look_ahead_days
--    to that read instead of asking for one day, carries day_offset out, and
--    reads the work once per day (the day at the same clock time as p_until,
--    the same window around it). nest_date is the plan date of the row and
--    start_at its real moment: the plan date plus the time of day in the
--    offset, because the offset counts from midnight of day 0. The order is
--    day first, then the sort order of that day's plan, which starts over per
--    plan.
-- 3. p_date_type (new, last parameter, default 'nest') says on which date the
--    work of a row is judged. 'production' reads production_date instead, and
--    that is a third of the orderlines on this data -- so it stays a parameter
--    until the board asks for it.
--
-- Checked before delivery by running both bodies with literals instead of
-- variables, and by comparing pg_typeof of every column against the declared
-- one: day 0 comes out exactly as the board does now (49 rows, 873,6 sqm, 371
-- orderlines, 5908,7 forecast sqm for 7 september, sheet, tenants 1 and 2),
-- with Friday 4 september and Tuesday 8 september beside it. row_number()
-- returns bigint, so the day number is cast: day_offset is an integer column.
BEGIN;

-- ============ 1. the lanes of the days in view ============
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
-- day's plan, its day_offset (-1 the day before, 0 the day of p_until) and the
-- plan_date behind it. Those days are working days: the day before a Monday is
-- the Friday before it, and a weekend or a mandatory day off is no day. The
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
-- the return type changes (plan_date), so the old one has to go first
drop function if exists action.get_plan_lanes_imposition_group(timestamp with time zone, text, text, integer[], boolean, integer, integer, text);

create function action.get_plan_lanes_imposition_group(p_until timestamp with time zone DEFAULT now(), p_step text DEFAULT 'impose'::text, p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_only_starting_today boolean DEFAULT true, p_look_back_days integer DEFAULT 1, p_look_ahead_days integer DEFAULT 1, p_view_code text DEFAULT 'nest-time-scale'::text) returns TABLE(imposition_group_id integer, material_id integer, material_name text, production_line_id integer, tenant_id integer, tenant_name text, resource_path ltree, resource_uid text, resource_name text, delivery_hours integer, min_delivery_hours integer, day_offset integer, plan_date date, sort_order numeric, param_json jsonb, formula jsonb, data jsonb, fixed_group text, is_pinned boolean, start_offset_in_seconds integer, next_start_offset_in_seconds integer, lane_item_id bigint, lane_id bigint)
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
        -- The days in view are working days, not calendar days: the day before
        -- a Monday is the Friday before it. day_offset is the place on the axis
        -- (0 the day of p_until, -1 the day before it), plan_date the working
        -- day that fills it -- a weekend and a mandatory day off of the tenants
        -- asked are no day at all (action.dates). Bounded to four months, which
        -- covers any window a board asks for.
        SELECT 0 AS day_offset, v_date AS plan_date
        UNION ALL
        SELECT -b.day_number, b.date
        FROM (SELECT d.date, row_number() OVER (ORDER BY d.date DESC)::integer AS day_number
              FROM action.dates d
              WHERE d.date < v_date AND d.date >= v_date - 120
                AND d.is_weekend = false
                AND NOT (coalesce(p_tenant_ids, d.tenants_mandatory_day_off) <@ d.tenants_mandatory_day_off
                         AND d.tenants_mandatory_day_off <> '{}')) b
        WHERE b.day_number <= coalesce(p_look_back_days, 0)
        UNION ALL
        SELECT a.day_number, a.date
        FROM (SELECT d.date, row_number() OVER (ORDER BY d.date)::integer AS day_number
              FROM action.dates d
              WHERE d.date > v_date AND d.date <= v_date + 120
                AND d.is_weekend = false
                AND NOT (coalesce(p_tenant_ids, d.tenants_mandatory_day_off) <@ d.tenants_mandatory_day_off
                         AND d.tenants_mandatory_day_off <> '{}')) a
        WHERE a.day_number <= coalesce(p_look_ahead_days, 0)
    ),
    item AS (
        -- one row per lane of that day's plan: its pattern item
        SELECT d.day_offset, d.plan_date, li.lane_id, li.lane_item_id, li.sort_order, li.is_pinned,
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

-- ============ 2. the board ============
-- renamed from mock.get_nest_schedule (via get_imposition_plan); impose is
-- the step, imposition the object it produces
drop function if exists mock.get_nest_schedule(timestamp with time zone, text, text, integer[], boolean, integer, integer, integer);
drop function if exists mock.get_nest_schedule(timestamp with time zone, text, text, integer[], integer, integer, integer);
drop function if exists mock.get_imposition_plan(timestamp with time zone, text, text, integer[], integer, integer, integer);
drop function if exists mock.get_impose_plan(timestamp with time zone, text, text, integer[], boolean, integer, integer, integer);
drop function if exists mock.get_impose_plan(timestamp with time zone, text, text, integer[], integer, integer, integer);
drop function if exists mock.get_impose_plan(timestamp with time zone, text, text, integer[], integer, integer, integer, text);

-- The rows of the days in view: p_look_back_days back to p_look_ahead_days
-- ahead, each with the plan of its own date and its own work (p_date_type says
-- on which date that work is judged: nest or production). Offsets count from
-- midnight of the day of p_until, so a row of the day before is negative, and
-- the order is day first, then the sort order of that day's plan.
--
-- every row is a plan row: type and type_json (the node of
-- lookup_lane_item_type, with sort_order, placement and formula) ride along as
-- on get_resource_plan, so the board reads the kind of row the same way. The
-- non-working time is the time scale's (get_timeline_view_segments), no rows.
create function mock.get_impose_plan(p_until timestamp with time zone DEFAULT now(), p_step text DEFAULT 'impose'::text, p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_look_back_days integer DEFAULT 1, p_look_ahead_days integer DEFAULT 1, p_domain_id integer DEFAULT 1, p_date_type text DEFAULT 'nest'::text) returns TABLE(material_id integer, material_name text, production_line_id integer, tenant_id integer, tenant_name text, production_company_id integer, resource_uid text, resource_name text, resource_path ltree, delivery_hours integer, min_delivery_hours integer, sort_order numeric, param_json jsonb, formula jsonb, data jsonb, fixed_group text, is_pinned boolean, start_offset_in_seconds integer, next_start_offset_in_seconds integer, duration_in_seconds integer, nest_date date, orderline_count integer, product_amount numeric, part_amount integer, amount numeric, sqm numeric, forecast_sqm numeric, rework_count integer, rework_sqm numeric, impact_json jsonb, gross_sqm numeric, part_status_json jsonb, nest_ids bigint[], nest_count integer, seconds_to_logistics_date integer, class_names text[], unit_class_names text[], lane_item_id bigint, lane_id bigint, day_offset integer, type text, type_json jsonb, start_at timestamp with time zone, production_seconds_min integer, production_seconds_max integer, batch_count integer, delivery_hours_json jsonb, step_json jsonb, set_json jsonb, manifest_json jsonb)
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
        select b.day_offset, b.plan_date,
               b.material_id, b.material_name, b.production_line_id,
               b.tenant_id, b.tenant_name, b.resource_uid, b.resource_name,
               -- the row's own resource: valid_resources.resource_field reads it
               b.resource_path,
               b.delivery_hours, b.min_delivery_hours, b.sort_order,
               b.param_json, b.formula, b.data, b.fixed_group, b.is_pinned,
               b.start_offset_in_seconds, b.next_start_offset_in_seconds,
               b.lane_item_id, b.lane_id
        -- The days in view: p_look_back_days back to p_look_ahead_days ahead,
        -- each with the plan of its own date; day_offset says which day a row
        -- comes from. The axis of the time scale decides which moments are rows,
        -- so a day it does not reach has none, and a day without a plan (a
        -- weekend) has none either. Only the materials whose interval
        -- (action.get_interval_dates on interval_start_date and interval_days)
        -- says that day is a production day; the rest of the plan stays out
        from action.get_plan_lanes_imposition_group(
                 p_until, p_step, p_line_type, p_tenant_ids, p_only_starting_today => true,
                 p_look_back_days => p_look_back_days,
                 p_look_ahead_days => p_look_ahead_days) b
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
    -- One read for the work of every row: action.get_lane_item_work takes the
    -- scope of each row (the nests of its lane, else its material and line in
    -- the day window) and gives back the totals plus the two lists the board
    -- shows. The fold that used to live here -- an aggregate call per nest set
    -- and a lateral that summed the delivery classes back together -- is that
    -- function now, and board 81 reads the same one.
    work as (
        -- one call per day in view, with that day as the moment: a row of the
        -- day before carries the work around that day. The helper takes one
        -- moment for all the entries it gets, so the day is the loop
        select d.day_offset, w.*
        from (select distinct b.day_offset, b.plan_date from base b) d
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
                 -- the same window around that day as the board asks for, so a
                 -- day shows what a planner sees waiting there
                 p_look_back_days   => p_look_back_days,
                 p_look_ahead_days  => p_look_ahead_days,
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
           coalesce(r.manifest_json, '[]'::jsonb)
    from row_data r
    left join site.tenant t on t.tenant_id = r.tenant_id
    -- day first: sort_order starts over per plan, so without the day in front
    -- the days would interleave
    order by r.day_offset, r.tenant_id, r.sort_order;
end;
$$;

alter function mock.get_impose_plan(timestamp with time zone, text, text, integer[], integer, integer, integer, text) owner to xfw3;

-- the board query is planned per call and inlines the aggregate; JIT compiling
-- it costs seconds and never pays back
alter function mock.get_impose_plan(timestamp with time zone, text, text, integer[], integer, integer, integer, text) set jit = off;

COMMIT;
-- ============ checks (read-only) ============

-- 1. the days in view are working days: for a Monday the day before is the
--    Friday. plan_date is the date, day_offset the place on the axis
SELECT day_offset, plan_date, to_char(plan_date, 'Dy') AS weekday,
       count(*)                                        AS row_count,
       count(*) FILTER (WHERE fixed_group IS NOT NULL) AS fixed_rows,
       min(start_offset_in_seconds)                    AS first_offset,
       max(start_offset_in_seconds)                    AS last_offset
FROM action.get_plan_lanes_imposition_group(
         '2026-09-07T10:30:00+02:00', 'impose', 'sheet', ARRAY[1,2], true, 1, 1)
GROUP BY 1, 2
ORDER BY 1;

-- 2. the board, per day: the moment of a row is its own date plus the time of
--    day, the offset stays the place on the axis
SELECT day_offset, nest_date, to_char(nest_date, 'Dy') AS weekday,
       count(*)                                  AS row_count,
       count(*) FILTER (WHERE sqm > 0)           AS with_work,
       count(*) FILTER (WHERE batch_count > 0)   AS with_batches,
       min(start_offset_in_seconds)              AS first_offset,
       max(start_offset_in_seconds)              AS last_offset,
       min(start_at)                             AS first_start_at,
       round(sum(sqm), 1)                        AS sqm,
       sum(orderline_count)                      AS orderlines
FROM mock.get_impose_plan('2026-09-07T10:30:00+02:00', 'impose', 'sheet', ARRAY[1,2], 1, 1)
GROUP BY 1, 2
ORDER BY 1;

-- 3. day 0 unchanged: 49 rows, 873,6 sqm, 371 orderlines, 5908,7 forecast sqm
SELECT count(*) AS row_count, round(sum(sqm), 1) AS sqm,
       sum(orderline_count) AS orderlines, round(sum(forecast_sqm), 1) AS forecast_sqm
FROM mock.get_impose_plan('2026-09-07T10:30:00+02:00', 'impose', 'sheet', ARRAY[1,2], 1, 1)
WHERE day_offset = 0;

-- 4. the read order: day first, then the sort order of that day's plan
SELECT day_offset, nest_date, tenant_id, sort_order, delivery_hours, fixed_group,
       start_offset_in_seconds, start_at, material_name
FROM mock.get_impose_plan('2026-09-07T10:30:00+02:00', 'impose', 'sheet', ARRAY[1,2], 1, 1)
ORDER BY day_offset, tenant_id, sort_order
LIMIT 30;

-- 5. what production_date would do instead of nest_date, per day
SELECT day_offset, count(*) FILTER (WHERE sqm > 0) AS with_work,
       round(sum(sqm), 1) AS sqm, sum(orderline_count) AS orderlines
FROM mock.get_impose_plan('2026-09-07T10:30:00+02:00', 'impose', 'sheet', ARRAY[1,2], 1, 1, 1, 'production')
GROUP BY 1
ORDER BY 1;

-- 6. and what it costs
EXPLAIN (ANALYZE, SUMMARY)
SELECT * FROM mock.get_impose_plan('2026-09-07T10:30:00+02:00', 'impose', 'sheet', ARRAY[1,2], 1, 1);
