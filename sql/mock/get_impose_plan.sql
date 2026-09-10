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
