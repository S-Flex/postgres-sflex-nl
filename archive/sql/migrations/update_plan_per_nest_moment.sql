-- Step 5 of docs/plan-batch-lane-item.md: the day plan is stamped from the
-- schedule, one item per nest moment, and the weekly pattern goes.
--
-- 1. mock.material_print_schedule takes over what the pattern held: a key
--    (material_print_schedule_id), the impose path (resource_path, constant
--    per material in the pattern) and the rank (sort_order, the pattern's
--    lowest); unique on (material_id, production_line_id, tenant_id).
-- 2. action.lane_item.nest_moment_code: the nest moment of a material item.
--    source_ref of a material item becomes <material_print_schedule_id>:<date>:<instance>.
-- 3. production.get_nest_moment_instances: the codes of a row numbered in
--    moment order (day offset, nest time, code) -- the instance of the item.
-- 4. mock.generate_plan stamps from the schedule: a lane per row whose
--    interval says the day is a production day and that names an impose path,
--    one item per nest moment code. No write-through any more: the stamped
--    day is the truth (action.crud_lane_item), the schedule the template.
-- 5. The readers of the pattern move to the schedule row of the item:
--    action.get_plan_lanes_imposition_group (class per nest moment code, on
--    the day the code is offset to; nest_moment_code, nest_time, print_time),
--    legacy.crud_nest (the lane of a nest; ties in the release order go to
--    the lowest instance), mock.get_impose_plan_inflow.
-- 6. The items already stamped: today and before are migrated in place (the
--    ref, the first moment as their code; today gets its other moments as new
--    items, so nests and events stay where they are), the days after today
--    are re-stamped (no nests, no moves on them: checked 10 Sep).
-- 7. mock.material_impose_plan and mock.crud_material_impose_plan are dropped.
--
-- Not in here: site.refresh_derived_data keeps calling generate_plan with the
-- same signature; a schedule row without an impose path (Forex 5mm DZ, and
-- every non-adhesive and textile row) gets no lane until it has one.
BEGIN;

-- ── 1. the schedule takes over the pattern ──────────────────────────────────
ALTER TABLE mock.material_print_schedule
    ADD COLUMN material_print_schedule_id bigint GENERATED ALWAYS AS IDENTITY,
    ADD COLUMN resource_path ltree,
    ADD COLUMN sort_order numeric;

ALTER TABLE mock.material_print_schedule
    ADD CONSTRAINT material_print_schedule_pkey PRIMARY KEY (material_print_schedule_id),
    ADD CONSTRAINT material_print_schedule_material_line_tenant_uq UNIQUE (material_id, production_line_id, tenant_id);

COMMENT ON COLUMN mock.material_print_schedule.resource_path IS 'The impose resource the nest moments of the material are stamped on (relation.resource, site.line.impose.width or deeper); the lane takes the first four labels. Null: the material has no lane yet.';
COMMENT ON COLUMN mock.material_print_schedule.sort_order IS 'The rank of the material on the nest boards: plan_lane.sort_order of its lane and the base of lane_item.sort_order of its items.';

-- the pattern is constant per material (one path, no times, no pins: checked
-- 10 Sep 2026), so its path and lowest rank are the schedule's
UPDATE mock.material_print_schedule mps
SET resource_path = m.resource_path,
    sort_order    = m.sort_order
FROM (SELECT material_id, production_line_id, tenant_id,
             min(resource_path::text)::ltree AS resource_path,
             min(sort_order)                 AS sort_order
      FROM mock.material_impose_plan
      GROUP BY material_id, production_line_id, tenant_id) m
WHERE (mps.material_id, mps.production_line_id, mps.tenant_id)
    = (m.material_id, m.production_line_id, m.tenant_id);

-- ── 2. the nest moment on the item ──────────────────────────────────────────
ALTER TABLE action.lane_item ADD COLUMN nest_moment_code text;

COMMENT ON COLUMN action.lane_item.nest_moment_code IS 'The nest moment of a material item: a code of production.lookup lookup_nest_moments (30, 24, 18, 48, 48+, ...), stamped by mock.generate_plan from material_print_schedule.nest_moment_codes; the class of the item on the boards. Null for every other item.';
COMMENT ON COLUMN action.lane_item.source_ref IS 'The id of the item at its source: pv2 plannable_item_id; material-plan <material_print_schedule_id>:<date>:<instance>.';
COMMENT ON COLUMN action.plan.type IS 'material-resource-plan: the nest boards (lanes are the materials of mock.material_print_schedule and their impose resources); production-plan: the production schedule (lanes are resources, lane.resource_path).';

-- ── 3. the moment order ─────────────────────────────────────────────────────

-- ============ sql/production/get_nest_moment_instances.sql ============
-- The nest moments of a material in moment order: the codes of a schedule
-- row (material_print_schedule.nest_moment_codes) numbered 0, 1, 2 by the
-- moment the lookup (production.lookup, lookup_nest_moments) puts them at --
-- the day the code is offset to, then the nest time on that day, then the
-- code. That number is lane_item.instance of the item stamped for the code
-- (mock.generate_plan); a code the lookup does not know sorts last.
create or replace function production.get_nest_moment_instances(p_nest_moment_codes text[]) returns TABLE(nest_moment_code text, instance integer)
	stable
	language sql
as $$
    SELECT c.code,
           (row_number() OVER (ORDER BY coalesce((m.value ->> 'day_offset')::integer, 0),
                                        coalesce((m.value #>> '{nest_moments,0,nest_time,start_offset_in_seconds}')::integer, 0),
                                        c.code) - 1)::integer
    FROM unnest(p_nest_moment_codes) AS c(code)
    LEFT JOIN (SELECT v.value
               FROM production.lookup l
               CROSS JOIN LATERAL jsonb_array_elements(l.lookup_json) AS v(value)
               WHERE l.lookup = 'lookup_nest_moments') m ON m.value ->> 'code' = c.code;
$$;

alter function production.get_nest_moment_instances(text[]) owner to xfw3;

-- ── 4. the stamp ────────────────────────────────────────────────────────────

-- ============ sql/mock/generate_plan.sql ============
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

-- ── 5. the readers and the writer ───────────────────────────────────────────

-- ============ sql/action/get_plan_lanes_imposition_group.sql ============
-- One read for the imposition-group lanes (labels) of the nest boards:
-- print_schedule (75), impose_plan (76) and whatever follows. One row per
-- pattern item (source material-plan) of the newest material plan of a day:
-- one per nest moment of a material (lane_item.instance, in moment order),
-- the schedule row through lane_item.source_ref
-- (<material_print_schedule_id>:<date>:<instance>). The nests of a row are its own batch
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
BEGIN
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
        SELECT CASE WHEN cls.fixed_group IS NOT NULL OR i.day_offset < 0
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

-- ============ sql/action/crud_lane_item.sql ============
drop function if exists action.crud_lane_item(jsonb, boolean);

create function action.crud_lane_item(p_param_json jsonb, p_no_results boolean DEFAULT false) returns TABLE(param_id integer, track_by integer, crud text, lane_item_id bigint, lane_id bigint, material_print_schedule_id bigint)
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
    -- data keeps its value. A copy is one more moment of the source item's
    -- nest moment (nest_moment_code), the next instance on its lane. The
    -- stamped day is the truth: nothing writes through to the schedule
    -- (mock.material_print_schedule), a move stays on the item.
    --   update — move/pin/sort the item
    --   create — an extra moment: the lane (a fresh one when asked) and the item
    --   delete — the moment; its batch rows, events and links cascade
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
    -- schedule row it was stamped from (source_ref is
    -- <material_print_schedule_id>:<date>:<instance>)
    source AS (
        SELECT p.param_id,
               li.lane_item_id, li.lane_id, li.sort_order, li.start_offset_in_seconds,
               li.is_pinned, li.duration_in_seconds, li.nest_moment_code,
               l.lane_date, l.resource_path,
               -- only a material item names a schedule row
               CASE WHEN li.source = 'material-plan'
                    THEN nullif(split_part(li.source_ref, ':', 1), '')::bigint END AS material_print_schedule_id,
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
    -- ── create ────────────────────────────────────────────────────────────
    -- ids up front: the lane (only for a copy that needs its own lane) and
    -- the item itself
    new_id AS (
        SELECT p.param_id, p.track_by, p.plan_id, p.sort_order, p.is_pinned,
               p.start_offset_in_seconds, p.lane_id AS given_lane_id,
               coalesce(p.imposition_group_id, s.imposition_group_id) AS imposition_group_id,
               coalesce(p.resource_path, s.resource_path)             AS resource_path,
               s.material_print_schedule_id, s.nest_moment_code,
               s.lane_id AS from_lane_id,
               nextval('action.lane_item_lane_item_id_seq') AS new_lane_item_id,
               CASE WHEN p.lane_id IS NULL AND s.lane_id IS NULL
                    THEN nextval('action.lane_lane_id_seq') END AS new_lane_id
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
    -- the place of the new item on its lane: the next instance, and without a
    -- rank from the client a rank behind the lane, spread so a batch never
    -- collides on the unique (lane_id, sort_order)
    placed AS (
        SELECT t.*,
               ((SELECT coalesce(max(li3.instance), -1)
                 FROM action.lane_item li3 WHERE li3.lane_id = t.lane_id AND li3.type = 'plan')
                + row_number() OVER (PARTITION BY t.lane_id ORDER BY t.param_id))::integer AS instance,
               coalesce(t.sort_order,
                        (SELECT coalesce(max(li2.sort_order), 0)
                         FROM action.lane_item li2 WHERE li2.lane_id = t.lane_id)
                        + 1000 * row_number() OVER (ORDER BY t.param_id)) AS item_sort_order
        FROM target t
        WHERE t.lane_id IS NOT NULL
    ),
    new_item AS (
        INSERT INTO action.lane_item
            (lane_item_id, lane_id, sort_order, start_offset_in_seconds,
             duration_in_seconds, is_pinned, no_split, type, source, source_ref,
             instance, nest_moment_code)
        OVERRIDING SYSTEM VALUE
        SELECT pl.new_lane_item_id, pl.lane_id, pl.item_sort_order,
               coalesce(pl.start_offset_in_seconds, 0), 0,
               coalesce(pl.is_pinned, false), true, 'plan', 'material-plan',
               -- the shape generate_plan stamps; a create without a source
               -- item names no schedule row and gets no ref
               pl.material_print_schedule_id || ':' || pl.lane_date || ':' || pl.instance,
               pl.instance, pl.nest_moment_code
        FROM placed pl
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
    )
    SELECT p.param_id, p.track_by, p.crud,
           coalesce(t.new_lane_item_id, p.lane_item_id),
           coalesce(t.lane_id, p.lane_id),
           s.material_print_schedule_id
    FROM payload p
    LEFT JOIN target t ON t.param_id = p.param_id
    LEFT JOIN source s ON s.param_id = p.param_id
    WHERE NOT p_no_results
    ORDER BY p.param_id;
$$;

alter function action.crud_lane_item(jsonb, boolean) owner to xfw3;

-- ============ sql/legacy/crud_nest.sql ============
-- same signature, dropped first so the script re-runs
drop function if exists legacy.crud_nest(jsonb, boolean);

create function legacy.crud_nest(p_param_json jsonb, p_no_results boolean DEFAULT false) returns TABLE(param_id integer, track_by integer, crud text, domain_id integer, batch_id bigint, nest_id bigint, nest_counter integer, reproduced_counter integer, nest_name text, amount integer, width numeric, height numeric, nest_json jsonb, sort_order integer, status jsonb, possible_states bigint, possible_multiple_states bigint)
	language plpgsql
as $$
#variable_conflict use_column
DECLARE
    last_updated_at timestamp;
    rec             record;
    v_batch_uid     bigint;
BEGIN
    CREATE TEMP TABLE param_table ON COMMIT DROP AS
    SELECT
        row_number() OVER ()::integer     AS param_id,
        COALESCE(te.track_by, 0)          AS track_by,
        te.crud,
        te.domain_id,
        te.batch_id,
        te.nest_id,
        COALESCE(te.nest_counter, 1)      AS nest_counter,
        COALESCE(te.reproduced_counter, 0) AS reproduced_counter,
        te.nest_name,
        te.amount,
        te.width::numeric(10,1)           AS width,
        te.height::numeric(10,1)          AS height,
        t.element                         AS nest_json,
        te.sort_order,
        te.status,
        te.possible_states,
        te.possible_multiple_states,
        te.nest_date,
        te.updated_at
    FROM jsonb_array_elements(p_param_json) AS t(element)
    CROSS JOIN LATERAL jsonb_to_record(t.element) AS te(
        track_by                 integer,
        crud                     text,
        domain_id                integer,
        batch_id                 bigint,
        nest_id                  bigint,
        nest_counter             integer,
        reproduced_counter       integer,
        nest_name                text,
        amount                   integer,
        width                    numeric,
        height                   numeric,
        sort_order               integer,
        status                   jsonb,
        possible_states          bigint,
        possible_multiple_states bigint,
        nest_date                timestamptz,
        updated_at               timestamptz
    );

    FOR rec IN
        SELECT * FROM param_table pt ORDER BY pt.updated_at ASC NULLS FIRST
    LOOP
        SELECT b.batch_uid INTO v_batch_uid
        FROM legacy.batch b
        WHERE b.batch_id = rec.batch_id;

        -- create, merge and update are one upsert: an update of a nest that
        -- is not here yet (a backfill, or the update overtook the create)
        -- inserts it instead of touching nothing. The fields an update may
        -- not carry keep their value.
        IF rec.crud IN ('create', 'merge', 'update') THEN
            INSERT INTO legacy.nest (
                batch_uid, domain_id, nest_id, nest_counter, reproduced_counter,
                nest_name, amount, width, height, nest_json, sort_order,
                status_json, possible_states, possible_multiple_states, nested_at, updated_at
            ) VALUES (
                v_batch_uid, COALESCE(rec.domain_id, 1), rec.nest_id, rec.nest_counter, rec.reproduced_counter,
                rec.nest_name, rec.amount, rec.width, rec.height,
                -- never insert a bare NULL into nest_json
                COALESCE(rec.nest_json, '{}'::jsonb),
                rec.sort_order,
                rec.status, rec.possible_states, rec.possible_multiple_states, rec.nest_date, rec.updated_at
            )
            ON CONFLICT ON CONSTRAINT uq_nest_id DO UPDATE
                SET batch_uid                = EXCLUDED.batch_uid,
                    nest_name                = COALESCE(EXCLUDED.nest_name, legacy.nest.nest_name),
                    amount                   = COALESCE(EXCLUDED.amount, legacy.nest.amount),
                    width                    = COALESCE(EXCLUDED.width, legacy.nest.width),
                    height                   = COALESCE(EXCLUDED.height, legacy.nest.height),
                    -- merge instead of replace: keys not present in the incoming
                    -- payload (e.g. commercial_waste_percentage, which is
                    -- computed elsewhere and not part of this event) are kept.
                    -- Incoming keys still win over existing ones on conflict.
                    nest_json                = COALESCE(legacy.nest.nest_json, '{}'::jsonb)
                                                || COALESCE(EXCLUDED.nest_json, '{}'::jsonb),
                    sort_order               = EXCLUDED.sort_order,
                    status_json              = EXCLUDED.status_json,
                    possible_states          = EXCLUDED.possible_states,
                    possible_multiple_states = EXCLUDED.possible_multiple_states,
                    nested_at                = EXCLUDED.nested_at,
                    updated_at               = EXCLUDED.updated_at;
        END IF;

        IF rec.crud IN ('create', 'merge') THEN
            -- insert into legacy.nest_log when a nest is created (initial 'ripped' entry, full amount)
            INSERT INTO legacy.nest_log
                (nest_id, from_status_sequence, to_status_sequence, amount, remaining_impact_delta, resource_uids, moved_at)
            SELECT
                n.nest_id,
                NULL,
                l.sequence,
                n.amount,
                NULL,
                '{}'::text[],
                now()
            FROM legacy.nest n,
                 relation.lookup rl,
                 jsonb_to_recordset(rl.lookup_json) AS l(step text, sequence int)
            WHERE n.nest_id = rec.nest_id
              AND rl.lookup = 'lookup_step_category'
              AND l.step = 'ripped';
        END IF;
    END LOOP;

    -- The single products of a nest may arrive before the nest (their sync
    -- runs ahead of the nest sync, and a backfill of the nests is slower):
    -- they carry no nest_amount yet and the nest has no commercial waste.
    -- Complete them now that the nest is here.
    UPDATE legacy.single_product sp
    SET single_product_json = COALESCE(sp.single_product_json, '{}'::jsonb)
                              || jsonb_build_object('nest_amount', n.amount)
    FROM legacy.nest n
    WHERE n.nest_id = sp.nest_id
      AND n.amount IS NOT NULL
      AND sp.single_product_json ->> 'nest_amount' IS NULL
      AND n.nest_id IN (SELECT pt.nest_id FROM param_table pt
                        WHERE pt.crud IN ('create', 'merge', 'update'));

    PERFORM legacy.update_nest_commercial_waste(
        array(SELECT DISTINCT pt.nest_id
              FROM param_table pt
              WHERE pt.crud IN ('create', 'merge', 'update')
                AND pt.nest_id IS NOT NULL));

    UPDATE legacy.nest n
    SET batch_uid = b.batch_uid
    FROM legacy.batch b
    WHERE n.batch_uid IS NULL
      AND b.batch_id = (n.nest_json ->> 'batch_id')::integer;

    -- ── nest → lane item (docs/plan-batch-lane-item.md) ──────────────────
    -- The material lane of a nest: the newest material-resource-plan of its
    -- nested_at date and the line type of its production line, the lane of
    -- its material (imposition_group_id is the alias) whose pattern item was
    -- stamped from that production line. The item on that lane, in this
    -- order: the no_split item that already holds the nest's batch (a
    -- no_split item keeps its whole batch); where the nest sits today (a
    -- planner move stays); else the item released last at or before
    -- nested_at (action.lane_item_event). An item that was never released
    -- receives no nests: the nest waits for the backfill.
    CREATE TEMP TABLE nest_link ON COMMIT DROP AS
    WITH payload AS (
        SELECT DISTINCT pt.nest_id,
               (n.nest_json ->> 'material_id')::integer        AS material_id,
               (n.nest_json ->> 'production_line_id')::integer AS production_line_id,
               (n.nested_at AT TIME ZONE 'Europe/Amsterdam')::date AS plan_date,
               n.nested_at,
               lower(COALESCE(n.nest_json ->> 'status', '')) LIKE 'cancel%' AS is_cancelled,
               n.batch_id::bigint                              AS batch_id
        FROM param_table pt
        JOIN legacy.nest n ON n.nest_id = pt.nest_id
        WHERE pt.crud IN ('create', 'merge', 'update')
    ),
    placed AS (
        SELECT p.*, lane.lane_id
        FROM payload p
        LEFT JOIN relation.production_line prl ON prl.line_id = p.production_line_id
        LEFT JOIN LATERAL (
            SELECT ap.plan_id
            FROM action.plan ap
            WHERE ap.plan_date = p.plan_date
              AND ap.type = 'material-resource-plan'
              AND (prl.line_type IS NULL OR ap.line_type = prl.line_type)
            ORDER BY ap.plan_id DESC
            LIMIT 1
        ) tp ON true
        LEFT JOIN LATERAL (
            -- the lane of the nest material on that plan; the line of a lane
            -- sits on the schedule row its items were stamped from
            -- (source_ref <material_print_schedule_id>:<date>:<instance>)
            SELECT igl.lane_id
            FROM action.plan_lane apl
            JOIN action.imposition_group_lane igl ON igl.lane_id = apl.lane_id
            JOIN action.lane_item li2 ON li2.lane_id = igl.lane_id AND li2.source = 'material-plan'
            JOIN mock.material_print_schedule mps
              ON mps.material_print_schedule_id = nullif(split_part(li2.source_ref, ':', 1), '')::bigint
            WHERE apl.plan_id = tp.plan_id
              AND igl.imposition_group_id = p.material_id
              AND mps.production_line_id = p.production_line_id
            ORDER BY apl.sort_order
            LIMIT 1
        ) lane ON true
    )
    SELECT pl.nest_id, pl.nested_at, pl.is_cancelled, pl.batch_id,
           coalesce(ns.lane_item_id, cur.lane_item_id, rel.lane_item_id) AS lane_item_id
    FROM placed pl
    LEFT JOIN LATERAL (
        SELECT li.lane_item_id
        FROM action.lane_item li
        JOIN action.batch_lane_item b ON b.lane_item_id = li.lane_item_id
        WHERE li.lane_id = pl.lane_id AND li.no_split
          AND pl.batch_id IS NOT NULL AND b.batch_id = pl.batch_id
        ORDER BY li.instance, li.lane_item_id
        LIMIT 1
    ) ns ON true
    LEFT JOIN LATERAL (
        SELECT b.lane_item_id
        FROM action.batch_lane_item b
        WHERE b.step = 'impose' AND b.nest_ids @> array[pl.nest_id]
        LIMIT 1
    ) cur ON true
    LEFT JOIN LATERAL (
        SELECT e.lane_item_id
        FROM action.lane_item_event e
        JOIN action.lane_item li ON li.lane_item_id = e.lane_item_id
        WHERE li.lane_id = pl.lane_id AND li.type = 'plan'
          AND e.status = 'released' AND e.moved_at <= pl.nested_at
        -- items released at the same moment (the midnight release of the
        -- testing phase): the first moment of the day takes the nests
        ORDER BY e.moved_at DESC, li.instance, e.lane_item_event_id DESC
        LIMIT 1
    ) rel ON true;

    -- ── the batch rows (docs/plan-batch-lane-item.md) ────────────────────
    -- A payload nest leaves every impose row that is not its target row
    -- (another item, another batch, or cancelled), joins the row of its batch
    -- on its item -- the null row for a nest without a batch -- and rows left
    -- empty disappear. Two inserts: the unique key of the batch rows is
    -- (lane_item_id, batch_id), that of the null rows the partial index.
    UPDATE action.batch_lane_item b
    SET nest_ids = coalesce((SELECT array_agg(x ORDER BY x)
                             FROM unnest(b.nest_ids) AS x
                             WHERE NOT EXISTS (SELECT 1 FROM nest_link ns
                                               WHERE ns.nest_id = x
                                                 AND (ns.is_cancelled
                                                      OR ns.lane_item_id IS DISTINCT FROM b.lane_item_id
                                                      OR ns.batch_id IS DISTINCT FROM b.batch_id))),
                            '{}'::bigint[])
    WHERE b.step = 'impose'
      AND b.nest_ids && (SELECT array_agg(ns.nest_id) FROM nest_link ns);

    INSERT INTO action.batch_lane_item (lane_item_id, lane_id, step, batch_id, nest_ids)
    SELECT ns.lane_item_id, li.lane_id, l.step, ns.batch_id,
           array_agg(ns.nest_id ORDER BY ns.nest_id)
    FROM nest_link ns
    JOIN action.lane_item li ON li.lane_item_id = ns.lane_item_id
    JOIN action.lane l ON l.lane_id = li.lane_id
    WHERE NOT ns.is_cancelled AND ns.batch_id IS NOT NULL
    GROUP BY ns.lane_item_id, li.lane_id, l.step, ns.batch_id
    ON CONFLICT (lane_item_id, batch_id) DO UPDATE
        SET nest_ids = (SELECT array_agg(DISTINCT x ORDER BY x)
                        FROM unnest(action.batch_lane_item.nest_ids || EXCLUDED.nest_ids) AS x);

    INSERT INTO action.batch_lane_item (lane_item_id, lane_id, step, batch_id, nest_ids)
    SELECT ns.lane_item_id, li.lane_id, l.step, NULL,
           array_agg(ns.nest_id ORDER BY ns.nest_id)
    FROM nest_link ns
    JOIN action.lane_item li ON li.lane_item_id = ns.lane_item_id
    JOIN action.lane l ON l.lane_id = li.lane_id
    WHERE NOT ns.is_cancelled AND ns.batch_id IS NULL
    GROUP BY ns.lane_item_id, li.lane_id, l.step
    ON CONFLICT (lane_item_id) WHERE batch_id IS NULL DO UPDATE
        SET nest_ids = (SELECT array_agg(DISTINCT x ORDER BY x)
                        FROM unnest(action.batch_lane_item.nest_ids || EXCLUDED.nest_ids) AS x);

    DELETE FROM action.batch_lane_item b
    WHERE b.step = 'impose' AND b.nest_ids = '{}'::bigint[];

    -- the first nest on an item marks it nested (action.lane_item_event)
    INSERT INTO action.lane_item_event (lane_item_id, status, moved_at)
    SELECT ns.lane_item_id, 'nested', min(ns.nested_at)
    FROM nest_link ns
    WHERE NOT ns.is_cancelled AND ns.lane_item_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM action.lane_item_event e
                      WHERE e.lane_item_id = ns.lane_item_id AND e.status = 'nested')
    GROUP BY ns.lane_item_id;

    -- ── imposition → unit manifest ────────────────────────────────────
    -- What the imposition is made of, snapshotted from the orderline
    -- manifests it holds (legacy.single_product is the bridge). Rebuilt for
    -- every nest in this payload, so a re-nest or a merge refreshes it.
    -- Cancelled nests keep their manifest: it records what was imposed, not
    -- what is still planned — the lane link above is what disappears.
    PERFORM legacy.create_imposition_unit_manifest(
        array(SELECT DISTINCT pt.nest_id
              FROM param_table pt
              WHERE pt.crud IN ('create', 'merge', 'update')
                AND pt.nest_id IS NOT NULL));

    SELECT MAX(pt.updated_at) INTO last_updated_at
    FROM param_table pt;

    IF last_updated_at IS NOT NULL THEN
        UPDATE mapping.persistent_vars
        SET value = last_updated_at - INTERVAL '2 minutes'
        WHERE key = 'last_nest_updated_at';
    END IF;

    IF NOT p_no_results THEN
        RETURN QUERY
        SELECT pt.param_id, pt.track_by, pt.crud, pt.domain_id,
               pt.batch_id, pt.nest_id, pt.nest_counter, pt.reproduced_counter,
               pt.nest_name, pt.amount, pt.width, pt.height, pt.nest_json,
               pt.sort_order, pt.status, pt.possible_states, pt.possible_multiple_states
        FROM param_table pt
        ORDER BY pt.param_id;
    END IF;
END;
$$;

alter function legacy.crud_nest(jsonb, boolean) owner to xfw3;

-- ============ sql/mock/get_impose_plan_inflow.sql ============
-- The read of the inflow sidebar (79, impose_plan_inflow): the orderline
-- manifest of a material (mapping.get_production_orderline_manifest, every
-- column as is) plus the lane item the nests of that material will land on,
-- so the release button knows what to release. Per production line of the
-- rows: the items of the material on the newest material plan of
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
    -- the items of the material on that plan (one per nest moment), per
    -- production line: the line sits on the schedule row of the item
    item AS (
        SELECT li.lane_item_id, li.instance, m.production_line_id,
               EXISTS (SELECT 1 FROM action.lane_item_event e
                       WHERE e.lane_item_id = li.lane_item_id AND e.status = 'released') AS is_released
        FROM plan
        JOIN action.plan_lane pl ON pl.plan_id = plan.plan_id
        JOIN action.imposition_group_lane igl ON igl.lane_id = pl.lane_id
        JOIN action.lane_item li ON li.lane_id = pl.lane_id AND li.type = 'plan' AND li.source = 'material-plan'
        JOIN mock.material_print_schedule m
          ON m.material_print_schedule_id = nullif(split_part(li.source_ref, ':', 1), '')::bigint
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

-- ── 6. the items already stamped ────────────────────────────────────────────
-- today and before: the ref names the schedule row, the item is the first
-- moment of its material (every item is instance 0: checked 10 Sep)
UPDATE action.lane_item li
SET source_ref       = mps.material_print_schedule_id || ':' || l.lane_date || ':' || li.instance,
    nest_moment_code = nm.nest_moment_code
FROM action.lane l,
     mock.material_impose_plan m,
     mock.material_print_schedule mps
     CROSS JOIN LATERAL production.get_nest_moment_instances(mps.nest_moment_codes) nm
WHERE l.lane_id = li.lane_id
  AND nm.instance = li.instance
  AND li.source = 'material-plan'
  AND l.lane_date <= current_date
  AND m.material_impose_plan_id = nullif(split_part(li.source_ref, ':', 1), '')::bigint
  AND (mps.material_id, mps.production_line_id, mps.tenant_id)
    = (m.material_id, m.production_line_id, m.tenant_id);

-- today: the other moments of every material as new items on the same lane
INSERT INTO action.lane_item
    (lane_id, sort_order, start_offset_in_seconds, is_pinned,
     no_split, type, source, source_ref, instance, nest_moment_code)
SELECT li.lane_id, li.sort_order + x.instance, NULL, false, true, 'plan',
       'material-plan', mps.material_print_schedule_id || ':' || l.lane_date || ':' || x.instance,
       x.instance, x.nest_moment_code
FROM action.lane_item li
JOIN action.lane l ON l.lane_id = li.lane_id
JOIN mock.material_print_schedule mps
  ON mps.material_print_schedule_id = nullif(split_part(li.source_ref, ':', 1), '')::bigint
CROSS JOIN LATERAL production.get_nest_moment_instances(mps.nest_moment_codes) x
WHERE li.source = 'material-plan'
  AND li.instance = 0
  AND l.lane_date = current_date
  AND x.instance > 0;

INSERT INTO action.imposition_group_lane_item (imposition_group_id, lane_item_id)
SELECT igl.imposition_group_id, li.lane_item_id
FROM action.lane_item li
JOIN action.lane l ON l.lane_id = li.lane_id
JOIN action.imposition_group_lane igl ON igl.lane_id = li.lane_id
WHERE li.source = 'material-plan'
  AND l.lane_date = current_date
  AND NOT EXISTS (SELECT 1 FROM action.imposition_group_lane_item g
                  WHERE g.lane_item_id = li.lane_item_id);

-- the days after today: re-stamped. Items first (lane_item.lane_id has no
-- cascade), then the material lanes; the resource lanes stay and are reused
DELETE FROM action.lane_item li
USING action.lane l
WHERE l.lane_id = li.lane_id
  AND li.source = 'material-plan'
  AND l.lane_date > current_date;

DELETE FROM action.lane l
USING action.imposition_group_lane igl
WHERE igl.lane_id = l.lane_id
  AND l.lane_date > current_date;

DELETE FROM action.plan p
WHERE p.type = 'material-resource-plan'
  AND p.plan_date > current_date;

DO $do$
DECLARE
    v_plans integer := 0;
BEGIN
    -- the same rule as site.refresh_derived_data: every workday of the coming
    -- two weeks per line type, unless every tenant of the line has that day off
    SELECT count(*)
    INTO v_plans
    FROM (SELECT dt.date, dt.tenants_mandatory_day_off
          FROM action.dates dt
          WHERE dt.date > current_date
            AND dt.date < current_date + 14
            AND NOT dt.is_weekend) d
    CROSS JOIN (SELECT pl.line_type,
                       array_agg(DISTINCT pl.tenant_id ORDER BY pl.tenant_id)
                           FILTER (WHERE pl.tenant_id IS NOT NULL) AS tenant_ids
                FROM relation.production_line pl
                WHERE pl.line_type IS NOT NULL
                GROUP BY pl.line_type) lt
    CROSS JOIN LATERAL mock.generate_plan(d.date, 'impose', lt.line_type) g
    WHERE NOT (coalesce(lt.tenant_ids, d.tenants_mandatory_day_off) <@ d.tenants_mandatory_day_off
               AND d.tenants_mandatory_day_off <> '{}');
    RAISE NOTICE 're-stamped: % material lanes on the days after today', v_plans;
END
$do$;

-- ── 7. the pattern goes ─────────────────────────────────────────────────────
DROP FUNCTION mock.crud_material_impose_plan(jsonb);
DROP TABLE mock.material_impose_plan;

COMMIT;

-- ── checks (read-only) ──────────────────────────────────────────────────────
-- every material item names a schedule row and a nest moment
SELECT count(*) AS material_items,
       count(*) FILTER (WHERE mps.material_print_schedule_id IS NULL) AS without_schedule_row,
       count(*) FILTER (WHERE li.nest_moment_code IS NULL)            AS without_moment
FROM action.lane_item li
LEFT JOIN mock.material_print_schedule mps
       ON mps.material_print_schedule_id = nullif(split_part(li.source_ref, ':', 1), '')::bigint
WHERE li.source = 'material-plan';

-- per day: lanes, items, moments per lane (today and after)
SELECT l.lane_date, count(DISTINCT l.lane_id) AS lanes, count(li.lane_item_id) AS items,
       round(count(li.lane_item_id)::numeric / nullif(count(DISTINCT l.lane_id), 0), 2) AS items_per_lane
FROM action.lane l
JOIN action.imposition_group_lane igl ON igl.lane_id = l.lane_id
LEFT JOIN action.lane_item li ON li.lane_id = l.lane_id AND li.source = 'material-plan'
WHERE l.lane_date >= current_date
GROUP BY l.lane_date
ORDER BY l.lane_date;

-- the label rows of board 75 today: code, times and class per row
SELECT material_name, tenant_id, instance, nest_moment_code, nest_time, print_time, fixed_group, start_offset_in_seconds
FROM action.get_plan_lanes_imposition_group(p_line_type => 'sheet', p_view_code => 'print-day-scale', p_only_starting_today => false)
WHERE day_offset = 0
ORDER BY tenant_id, sort_order
LIMIT 20;
