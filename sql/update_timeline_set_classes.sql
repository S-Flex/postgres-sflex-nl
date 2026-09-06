-- ============================================================
-- One vocabulary for the kinds of timeline rows: plan, progress, actual
-- (6 sep). Cees renamed the group 'state' to 'actual' in log.lookup /
-- lookup_resource_state (the flat one); the nested one in relation.lookup
-- still said 'state', so a timeline with set_field state.group showed three
-- sets: plan, state and actual. This script:
--   1. renames the group 'state' to 'actual' in relation.lookup /
--      lookup_resource_state as well (the group nodes and their states), and
--      in log.get_resource_state_current, the one function that filters on it;
--   2. gives every kind a base class in action.lookup / lookup_lane_item_type:
--      class_names = [timeline-plan], [timeline-progress], [timeline-actual] —
--      get_resource_plan (81) already merges them into class_names,
--      get_impose_plan (76) does so from now on;
--   3. action.get_plan_timeline (56) puts 'timeline-' || state.group in front
--      of state.class_names, so its sets carry the same base classes.
-- The json mirrors (json/lookup/log, json/lookup/relation, json/lookup/action)
-- are updated with it. The css for the three classes is the frontend's.
-- Check afterwards (expected): relation groups all 'actual', no state with
-- group 'state'; every class_names of lookup_lane_item_type one element.
-- ============================================================

BEGIN;

-- 1. the nested lookup: the group nodes and their states
UPDATE relation.lookup l
SET lookup_json = (
    SELECT jsonb_agg(
               jsonb_set(
                   CASE WHEN g.value ->> 'group' = 'state' THEN jsonb_set(g.value, '{group}', '"actual"') ELSE g.value END,
                   '{states}',
                   coalesce((SELECT jsonb_agg(CASE WHEN s.value ->> 'group' = 'state'
                                                   THEN jsonb_set(s.value, '{group}', '"actual"') ELSE s.value END
                                              ORDER BY s.ord)
                             FROM jsonb_array_elements(g.value -> 'states') WITH ORDINALITY AS s(value, ord)),
                            '[]'::jsonb))
               ORDER BY g.ord)
    FROM jsonb_array_elements(l.lookup_json) WITH ORDINALITY AS g(value, ord))
WHERE l.lookup = 'lookup_resource_state';

-- 2. the base class per kind
UPDATE action.lookup l
SET lookup_json = (
    SELECT jsonb_agg(jsonb_set(e.value, '{class_names}', to_jsonb(array['timeline-' || (e.value ->> 'type')])) ORDER BY e.ord)
    FROM jsonb_array_elements(l.lookup_json) WITH ORDINALITY AS e(value, ord))
WHERE l.lookup = 'lookup_lane_item_type';

-- 3. the functions
drop function if exists log.get_resource_state_current(timestamp with time zone, text);

create function log.get_resource_state_current(p_until timestamp with time zone DEFAULT now(), p_model text DEFAULT NULL::text) returns TABLE(resource_uid text, state jsonb, layout_name text, type text, resource_name text, nest_name text, job_name text, page_number integer, start_at timestamp with time zone, offset_seconds numeric, duration_seconds numeric, capacity_sqm_per_day numeric, capacity_reserved_sqm numeric, capacity_left numeric, production_line_id integer)
	stable
	language plpgsql
as $$
#variable_conflict use_column
declare
    v_lookup_json jsonb;
begin
    select lk.lookup_json
      into v_lookup_json
      from relation.lookup lk
     where lk.lookup = 'lookup_resource_state'
     limit 1;

    return query
    with state_map as (
        select g.value ->> 'code' as state_code, g.value as state_json
        from   jsonb_array_elements(v_lookup_json) as g(value)
        where  g.value ->> 'group' = 'actual'
        union all
        select s.value ->> 'code', s.value
        from   jsonb_array_elements(v_lookup_json)       as g(value),
               jsonb_array_elements(g.value -> 'states') as s(value)
        where  s.value ->> 'group' = 'actual'
    ),
    offline_state as (
        select state_json
        from   state_map
        where  state_code = 'offline'
        limit  1
    ),
    all_resources as (
        select res.resource_uid,
               res.resource_json,
               res.line_id
        from   relation.resource        res
        join   relation.production_line pl on pl.line_id = res.line_id
        where  pl.model = p_model
    ),
    -- LATERAL LIMIT 1 leunt op idx_log_state_resource_start (resource_uid, start_at desc)
    latest_log as (
        select
            ar.resource_uid,
            ll.state,
            ll.page_number,
            ll.start_at
        from all_resources ar
        left join lateral (
            select r.state,
                   r.page_number,
                   r.start_at
            from   log.state r
            where  r.resource_uid = ar.resource_uid
              and  r.start_at < p_until
            order by r.start_at desc
            limit 1
        ) ll on true
    ),
    capacity_per_resource as (
        select
            cap.resource_uid,
            sum(cap.capacity_sqm_per_day) as capacity_sqm_per_day,
            max(cap.param_hours_per_day)  as param_hours_per_day,
            max(cap.param_oee)            as param_oee
        from mapping.get_resource_weighted_capacity(
            null::text[],
            (current_date - 30)::date,
            current_date::date
        ) cap
        group by cap.resource_uid
    ),
    impact_per_resource as (
        select
            gi.resource_uid,
            sum(gi.duration_seconds) as total_impact_seconds
        from log.get_resource_plan_impact(
            null::text[], null::timestamptz, p_until, p_model
        ) gi
        group by gi.resource_uid
    ),
    reserved as (
        select
            cr.resource_uid,
            cr.capacity_sqm_per_day,
            round(
                cr.capacity_sqm_per_day
                / nullif(cr.param_hours_per_day * cr.param_oee * 3600, 0)
                * coalesce(ir.total_impact_seconds, 0),
                4
            ) as capacity_reserved_sqm
        from capacity_per_resource cr
        left join impact_per_resource ir on ir.resource_uid = cr.resource_uid
    )
    select
        ar.resource_uid,
        coalesce(sm.state_json, os.state_json),
        ar.resource_json ->> 'layout_name',
        ar.resource_json ->> 'type',
        ar.resource_json ->> 'name',
        null::text,   -- nest_name
        null::text,   -- job_name
        ll.page_number,
        coalesce(ll.start_at, p_until),
        null::numeric,
        null::numeric,
        coalesce(rv.capacity_sqm_per_day, 0),
        coalesce(rv.capacity_reserved_sqm, 0),
        coalesce(rv.capacity_sqm_per_day, 0)
        - coalesce(rv.capacity_reserved_sqm, 0),
        ar.line_id
    from        all_resources  ar
    cross join  offline_state  os
    left join   latest_log     ll on ll.resource_uid = ar.resource_uid
    left join   state_map      sm on sm.state_code   = ll.state
    left join   reserved       rv on rv.resource_uid = ar.resource_uid
    order by
        ar.resource_json ->> 'type' desc,
        ar.resource_json ->> 'name',
        coalesce(ll.start_at, p_until);
end;
$$;

alter function log.get_resource_state_current(timestamp with time zone, text) owner to xfw3;


drop function if exists action.get_plan_timeline(text, timestamp with time zone, timestamp with time zone);

create function action.get_plan_timeline(p_line_type text DEFAULT NULL::text, p_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_until timestamp with time zone DEFAULT now()) returns TABLE(action_id integer, line text, resource_uids text[], state jsonb, group_state jsonb, layout_name text, type text, name text, nest_name text, job_name text, page_number integer, batch_id integer, batch_name text, data jsonb, start_at timestamp with time zone, offset_in_seconds integer, next_trigger_type text, just_in_time boolean, param_json jsonb, formula jsonb, resource_plan_rank numeric, is_fixed_offset boolean, is_atomic boolean, parent_action_id integer, material_id integer, step text)
	stable
	language plpgsql
as $$
#variable_conflict use_column
DECLARE
    v_lookup_json        jsonb;
    v_step_category_json jsonb;
    v_group_state_json   jsonb;
    v_formula_json       jsonb;
    v_teams_json         jsonb;
BEGIN
    IF p_until IS NULL THEN
        p_until := ((COALESCE(p_from::date, CURRENT_DATE) + 1)::timestamp AT TIME ZONE 'Europe/Amsterdam');
    END IF;

    IF p_from IS NULL THEN
        p_from := (COALESCE(p_until::date, CURRENT_DATE)::timestamp + interval '6 hours') AT TIME ZONE 'Europe/Amsterdam';
    END IF;

    SELECT lk.lookup_json INTO v_lookup_json
      FROM relation.lookup lk WHERE lk.lookup = 'lookup_resource_state';

    SELECT lk.lookup_json INTO v_group_state_json
      FROM relation.lookup lk WHERE lk.lookup = 'lookup_resource_group_state';

    SELECT lk.lookup_json INTO v_step_category_json
      FROM relation.lookup lk WHERE lk.lookup = 'lookup_step_category';

    SELECT lk.lookup_json INTO v_teams_json
      FROM relation.lookup lk WHERE lk.lookup = 'lookup_production_teams';

    v_formula_json := jsonb_build_array(
        'is_locked=offset_in_seconds<current_offset_in_seconds?1:0',
        'batch_duration=standard_production_impact/speed_factor',
        'first_item_duration=first_item_standard_production_impact/speed_factor',
        'duration_in_seconds=batch_duration'
    );

    RETURN QUERY
    WITH resolved AS (
        SELECT
            o.action_id,
            o.resource_uid,
            o.action_json,
            o.start_at,
            o.offset_in_seconds,
            o.standard_production_impact,
            o.resource_plan_rank,
            o.is_fixed_offset,
            o.is_atomic,
            o.parent_action_id,
            o.batch_id,
            (o.action_json -> 'data' ->> 'material_id')::integer AS material_id,
            (o.action_json -> 'data' ->> 'first_item_standard_production_impact')::integer
                AS first_item_standard_production_impact,
            o.action_json ->> 'name' AS batch_name,
            -- data-provided duration (e.g. for maintenance/breaks, which have no
            -- standard_production_impact) — used as a fallback before the
            -- hard 3600 default in param_json below.
            (o.action_json -> 'data' ->> 'duration_in_seconds')::numeric AS duration_in_seconds,
            (SELECT s.value
             FROM jsonb_array_elements(v_lookup_json)        AS ss(value),
                  jsonb_array_elements(ss.value -> 'states') AS s(value)
             WHERE s.value ->> 'code' = COALESCE(
                 NULLIF(o.action_json ->> 'status', ''),
                 o.action_json ->> 'type',
                 'batch')
             LIMIT 1)                               AS state
        FROM action.object o
    ),
    lines AS (
        SELECT DISTINCT pl.line_id
        FROM relation.production_line pl
        WHERE pl.line_type = p_line_type
    ),
    -- Per resource_uid + material_id, the rank of the FIRST batch-reserved
    -- action. Only that specific action may carry plan-alert/plan-warning/
    -- plan-signal/plan-info; every other action has them stripped.
    first_reserved AS (
        SELECT resource_uid, material_id, MIN(resource_plan_rank) AS first_rank
        FROM resolved
        WHERE resolved.action_json ->> 'type' = 'batch-reserved'
        GROUP BY resource_uid, material_id
    ),
    -- Aggregate is called once per distinct line_id, not once per row.
    mat_agg AS (
        SELECT l.line_id, a.*
        FROM lines l
        CROSS JOIN LATERAL mock.get_material_planning_aggregate(l.line_id) a
    ),
    step_order AS (
        SELECT
            sc.value ->> 'step'          AS step,
            (sc.value ->> 'order')::int  AS step_order
        FROM jsonb_array_elements(v_step_category_json) AS sc(value)
    )
    SELECT
        rs.action_id,
        pl.line,
        ARRAY[res.resource_uid],
        -- Replace the single 'class_name' key with a 'class_names' array:
        -- the base class of the set (timeline-plan, timeline-actual, from the
        -- state's group), the state's own class name and the material aggregate's.
        -- plan-warning/plan-alert/plan-signal/plan-info only kept on the
        -- FIRST batch-reserved action per resource_uid + material_id.
        COALESCE(rs.state, '{}'::jsonb)
            - 'class_name'
            || jsonb_build_object(
                'class_names',
                to_jsonb(array_remove(
                    ARRAY(
                        SELECT DISTINCT x
                        FROM unnest(
                            array_cat(
                                ARRAY['timeline-' || (rs.state ->> 'group'), rs.state ->> 'class_name'],
                                COALESCE(ma.class_name, ARRAY[]::text[])
                            )
                        ) AS x
                        WHERE NOT (
                            NOT (
                                rs.action_json ->> 'type' = 'batch-reserved'
                                AND rs.resource_plan_rank = fr.first_rank
                            )
                            AND x IN ('plan-warning', 'plan-alert', 'plan-signal', 'plan-info')
                        )
                    ),
                    NULL
                ))
            ) AS state,
        (SELECT gs.value
         FROM jsonb_array_elements(v_group_state_json) AS gs(value)
         WHERE gs.value ->> 'code' = rs.state ->> 'group'
         LIMIT 1),
        res.resource_json ->> 'layout_name',
        res.resource_json ->> 'type',
        res.resource_json ->> 'name',
        NULL::text,
        NULL::text,
        NULL::integer,
        rs.batch_id,
        rs.batch_name,
        -- Enrich data with a material_summary block from the aggregate,
        -- the day/night team codes for this resource_uid, and the line's
        -- break_times (used client-side for duration/interruption calculations).
        COALESCE(rs.action_json -> 'data', '{}'::jsonb)
            || jsonb_build_object(
                'material_summary',
                CASE WHEN ma.material_id IS NOT NULL THEN
                    jsonb_build_object(
                        'ready_to_nest_count',          ma.ready_to_nest_count,
                        'ready_to_nest_product_amount',  ma.ready_to_nest_product_amount,
                        'ready_to_nest_sqm',             ma.ready_to_nest_sqm,
                        'needs_dtp_count',                ma.needs_dtp_count,
                        'needs_dtp_product_amount',       ma.needs_dtp_product_amount,
                        'needs_dtp_sqm',                  ma.needs_dtp_sqm,
                        'rework_lines_count',              ma.rework_lines_count,
                        'rework_amount',                   ma.rework_amount,
                        'rework_sqm',                      ma.rework_sqm
                    )
                ELSE NULL
                END
            )
            || CASE WHEN (res.resource_json ->> 'has_break_times')::boolean IS TRUE
                    THEN jsonb_build_object('break_times', pl.line_json -> 'break_times')
                    ELSE '{}'::jsonb
               END
            || jsonb_build_object(
                'shifts',
                (SELECT jsonb_build_object('first', t.value ->> 'day_shift', 'second', t.value ->> 'night_shift')
                 FROM jsonb_array_elements(v_teams_json) AS t(value)
                 WHERE t.value ->> 'resource_uid' = res.resource_uid
                 LIMIT 1)
            ) AS data,
        rs.start_at,
        rs.offset_in_seconds,
        res.resource_json ->> 'next_trigger_type',
        (res.resource_json ->> 'just_in_time')::boolean,
        jsonb_build_object(
            'standard_production_impact',               coalesce(rs.standard_production_impact, rs.duration_in_seconds, 3600),
            'speed_factor',                             mock.get_resource_speed_factor(rs.material_id, res.resource_uid),
            'first_item_standard_production_impact',    coalesce(rs.first_item_standard_production_impact, 3600),
            'fixed_lag_duration',                       (res.resource_json ->> 'fixed_lag_duration')::numeric
        ) || COALESCE(pfm.param_json, '{}'::jsonb) AS param_json,
        v_formula_json,
        rs.resource_plan_rank,
        rs.is_fixed_offset,
        rs.is_atomic,
        rs.parent_action_id,
        rs.material_id,
        res.step
    FROM relation.resource        res
    JOIN relation.production_line pl  ON pl.line_id = res.line_id
    LEFT JOIN resolved            rs  ON rs.resource_uid = res.resource_uid
                                     AND rs.start_at >= p_from
                                     AND rs.start_at <  p_until
    LEFT JOIN mat_agg              ma ON ma.line_id = pl.line_id
                                     AND ma.material_id = rs.material_id
    LEFT JOIN first_reserved       fr ON fr.resource_uid = res.resource_uid
                                     AND fr.material_id = rs.material_id
    LEFT JOIN step_order            so ON so.step = res.step
    LEFT JOIN log.production_forecast_material pfm
                                       ON pfm.production_line_id = pl.line_id
                                      AND pfm.material_id        = rs.material_id
                                      AND pfm.date                = (rs.start_at AT TIME ZONE 'Europe/Amsterdam')::date
    WHERE pl.line_type = p_line_type AND res.step IS NOT NULL
    ORDER BY pl.line_id, so.step_order, res.resource_json ->> 'pv2_order', rs.start_at;
END;
$$;

alter function action.get_plan_timeline(text, timestamp with time zone, timestamp with time zone) owner to xfw3;


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
create function mock.get_impose_plan(p_until timestamp with time zone DEFAULT now(), p_step text DEFAULT 'print'::text, p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_look_back_days integer DEFAULT 0, p_look_ahead_days integer DEFAULT 0, p_domain_id integer DEFAULT 1) returns TABLE(material_id integer, material_name text, production_line_id integer, tenant_id integer, tenant_name text, production_company_id integer, resource_uid text, resource_name text, resource_path ltree, delivery_hours integer, min_delivery_hours integer, sort_order numeric, param_json jsonb, formula jsonb, data jsonb, fixed_group text, is_pinned boolean, start_offset_in_seconds integer, next_start_offset_in_seconds integer, duration_in_seconds integer, nest_date date, orderline_count integer, product_amount numeric, part_amount integer, amount numeric, sqm numeric, forecast_sqm numeric, rework_count integer, rework_sqm numeric, impact_json jsonb, gross_sqm numeric, part_status_json jsonb, nest_ids bigint[], nest_count integer, seconds_to_logistics_date integer, class_names text[], unit_class_names text[], lane_item_id bigint, lane_id bigint, type text, type_json jsonb)
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
           case when r.lane_item_id is not null then v_plan_type_json end
    from row_data r
    left join tenant t on t.tenant_id = r.tenant_id
    order by r.tenant_id, r.sort_order;
end;
$$;

alter function mock.get_impose_plan(timestamp with time zone, text, text, integer[], integer, integer, integer) owner to xfw3;

-- the board query is planned per call and inlines the aggregate; JIT compiling
-- it costs seconds and never pays back
alter function mock.get_impose_plan(timestamp with time zone, text, text, integer[], integer, integer, integer) set jit = off;

COMMIT;

-- check: expected 4 group nodes 'actual', 0 states with group 'state', 3 kinds with one class each
SELECT (SELECT string_agg(DISTINCT g.value ->> 'group', ',') FROM relation.lookup l, jsonb_array_elements(l.lookup_json) g WHERE l.lookup = 'lookup_resource_state') AS relation_groups,
       (SELECT count(*) FROM relation.lookup l, jsonb_array_elements(l.lookup_json) g, jsonb_array_elements(g.value -> 'states') s WHERE l.lookup = 'lookup_resource_state' AND s.value ->> 'group' = 'state') AS states_still_state,
       (SELECT string_agg(e.value ->> 'type' || ':' || (e.value -> 'class_names')::text, ' ') FROM action.lookup l, jsonb_array_elements(l.lookup_json) e WHERE l.lookup = 'lookup_lane_item_type') AS kinds;
