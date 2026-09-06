-- ============================================================
-- Stap 7 van docs/plan-lane-model.md: één resource-bord met steps en types.
--   1. action.lane_item.type (text: plan | actual) vervangt level (0/1);
--      het vocabulaire staat in action.lookup / lookup_lane_item_type
--      (json/lookup/action/lookup_lane_item_type.json). progress wordt nooit
--      opgeslagen: de read leidt het af.
--   2. action.get_resource_plan vervangt mock.get_production_plan (81) en de
--      resourcemodus van get_impose_plan (78): rijen van type plan, progress
--      en actual, p_steps (null = alle steps van de dagplannen) en p_types.
--   3. action.get_plan_lanes in resourcemodus: per step het nieuwste plan van
--      de dag, p_steps null = alle steps (bij plan_type production-plan).
--   4. alle schrijvers van level volgen: crud_lane_item, crud_object,
--      sync_pv2_batch_items, legacy.crud_nest, mock.generate_plan.
--   5. lookup-lezers voor het filter: relation.get_step_categories,
--      action.get_lane_item_types, met data_tables; data_table
--      get_production_plan (207) wordt get_resource_plan.
--   6. data_group 78 (impose_resource_plan) vervalt; 81 en 82 volgen in
--      sql/update_data_group_partial.sql (resource_plan, resource_plan_filter).
-- Daarna sql/update_data_group_partial.sql draaien.
-- ============================================================

BEGIN;

-- 1. the kind of a lane item: type replaces level
ALTER TABLE action.lane_item ADD COLUMN type text NOT NULL DEFAULT 'plan';
UPDATE action.lane_item SET type = 'actual' WHERE level = 1;
ALTER TABLE action.lane_item DROP COLUMN level;
COMMENT ON COLUMN action.lane_item.type IS 'The kind of row, from action.lookup / lookup_lane_item_type: plan = the planning (written by the boards, pv2 and crud_nest); actual = what the machine did, folded in from log.data / log.state (later). progress is derived at read time and never stored. Same lane, same axis; the board renders the kinds apart.';
COMMENT ON COLUMN action.lane_item.source IS 'Who wrote the item: pv2 (crud_object), planner, log (type actual). Together with source_ref the upsert key.';

INSERT INTO action.lookup (lookup, lookup_json)
VALUES ('lookup_lane_item_type', $lk$[
  {
    "type": "plan",
    "sort_order": 0,
    "class_names": []
  },
  {
    "type": "progress",
    "sort_order": 1,
    "class_names": []
  },
  {
    "type": "actual",
    "sort_order": 2,
    "class_names": []
  }
]$lk$::jsonb)
ON CONFLICT (lookup) DO UPDATE SET lookup_json = EXCLUDED.lookup_json;

-- 2. the reads
DROP FUNCTION IF EXISTS mock.get_production_plan(timestamp with time zone, text, text, integer[], integer);

-- The one item read of the resource board (docs/plan-lane-model.md, stap 7):
-- one row per lane item on the resource lanes of the day's production plans,
-- for the steps asked (p_steps null = every step planned that day), in three
-- kinds of rows, named by lane_item.type and action.lookup /
-- lookup_lane_item_type:
--   * plan     — the item as planned (stored); its nests via
--                get_lane_item_impositions, the work of the set from the
--                orderline aggregate, whatever the status of the orderlines;
--   * progress — what of that plan is still to do for the lane's step: the
--                orderline amounts below the step's done status
--                (lookup_step_category.sequence), as a share of the plan's
--                duration. Same lane_item_id and start, shrinks as work moves
--                on, gone when everything is done. Derived here, never stored;
--   * actual   — what the machine did: the state blocks and produced items
--                from log.state / log.data (log.get_resource_state,
--                log.get_resource_produced), no lane_item_id.
-- The plan row carries progress_json (done, remaining, share, seconds) for its
-- tooltip. type_json is the lookup node of the row's type; its class_names
-- ride along in class_names as well, so the board styles the kinds without
-- code. p_types filters the kinds (null = all).
--
-- Replaces mock.get_production_plan (81) and the resource mode of
-- mock.get_impose_plan (78). The labels come from action.get_plan_lanes in
-- resource mode.
drop function if exists action.get_resource_plan(timestamp with time zone, text, integer[], text[], text[], integer);

create function action.get_resource_plan(p_until timestamp with time zone DEFAULT now(), p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_steps text[] DEFAULT NULL::text[], p_types text[] DEFAULT NULL::text[], p_domain_id integer DEFAULT 1)
    returns TABLE(tenant_id integer, tenant_name text, production_company_id integer, resource_uid text, resource_name text, resource_path ltree, lane_id bigint, step text, type text, type_json jsonb, lane_item_id bigint, sort_order numeric, is_pinned boolean, no_split boolean, fixed_group text, start_offset_in_seconds integer, duration_in_seconds integer, start_at timestamp with time zone, end_at timestamp with time zone, nest_ids bigint[], nest_count integer, batch_id integer, batch_name text, material_id integer, material_name text, impact_json jsonb, sqm numeric, gross_sqm numeric, part_status_json jsonb, progress_json jsonb, state_json jsonb, group_state_json jsonb, class_names text[], param_json jsonb)
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
begin
    select lk.lookup_json into v_state_lookup
    from relation.lookup lk where lk.lookup = 'lookup_resource_state';

    select lk.lookup_json into v_type_lookup
    from action.lookup lk where lk.lookup = 'lookup_lane_item_type';

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
    -- the steps asked, else every step a production plan of the day carries
    wanted_step as (
        select distinct s.step
        from action.plan p
        cross join lateral unnest(p.steps) as s(step)
        where p.plan_date = v_date
          and p.type = 'production-plan'
          and (p_line_type is null or p.line_type = p_line_type)
          and (p_steps is null or s.step = any (p_steps))
    ),
    the_plan as (
        -- per step the newest production plan of the day that covers it
        select distinct on (ws.step) ws.step, p.plan_id
        from wanted_step ws
        join action.plan p on ws.step = any (p.steps)
        where p.plan_date = v_date
          and p.type = 'production-plan'
          and (p_line_type is null or p.line_type = p_line_type)
        order by ws.step, p.plan_id desc
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
    -- planned items with the nests hung on them
    item as (
        select li.lane_item_id, li.lane_id, li.sort_order, li.is_pinned, li.no_split,
               li.fixed_group, li.start_offset_in_seconds, li.duration_in_seconds,
               (select array_agg(distinct x.imposition_id)
                from action.get_lane_item_impositions(li.lane_item_id) x) as nest_ids
        from action.lane_item li
        join lane on lane.lane_id = li.lane_id
        where li.type = 'plan'
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
               sum(r.gross_sqm)                as gross_sqm,
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
    -- the plan rows: the lane's resource names the row
    plan_row as (
        select l.tenant_id, l.tenant_name, l.production_company_id,
               l.resource_uid, l.resource_name, l.resource_path, l.lane_id, l.step,
               i.lane_item_id, i.sort_order, i.is_pinned, i.no_split, i.fixed_group,
               i.start_offset_in_seconds,
               -- pv2's duration when it sent one, else the print time of the run
               -- (nest area x amount) at the resource's speed, never shorter
               -- than the minimum
               case when i.duration_in_seconds > 0 then i.duration_in_seconds
                    else greatest(ceil(coalesce(nf.run_sqm, 0) * v_standard_seconds_per_sqm
                                       / coalesce(nullif(mock.get_resource_speed_factor(ag.material_id, l.resource_uid), 0), 1))::integer,
                                  v_min_duration_in_seconds) end                       as duration_in_seconds,
               coalesce(i.nest_ids, '{}'::bigint[])                                   as nest_ids,
               coalesce(cardinality(i.nest_ids), 0)                                    as nest_count,
               nf.batch_id, nf.batch_name,
               ag.material_id, ag.material_name,
               ag.impact_json, ag.sqm, ag.gross_sqm,
               coalesce(ag.part_status_json, '[]'::jsonb)                              as part_status_json,
               -- the state of a planned item is the least advanced status of its
               -- nests, from the same lookup the actual rows use
               (select st.value from jsonb_array_elements(v_state_lookup) as ss(value)
                                     cross join lateral jsonb_array_elements(ss.value -> 'states') as st(value)
                 where st.value ->> 'code' = coalesce(nf.internal_status_code, 'batch') limit 1) as state_json,
               (select ss.value - 'states' from jsonb_array_elements(v_state_lookup) as ss(value)
                                           cross join lateral jsonb_array_elements(ss.value -> 'states') as st(value)
                 where st.value ->> 'code' = coalesce(nf.internal_status_code, 'batch') limit 1) as group_state_json,
               coalesce(ag.class_names, '{}'::text[])                                  as class_names,
               jsonb_build_object(
                   'standard_production_impact_in_seconds', ceil(coalesce(nf.run_sqm, 0) * v_standard_seconds_per_sqm)::integer,
                   'run_sqm',                                round(coalesce(nf.run_sqm, 0), 2),
                   'speed_factor',                           mock.get_resource_speed_factor(ag.material_id, l.resource_uid),
                   'orderline_count',                        ag.orderline_count)      as param_json,
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
        left join lateral (
            select sum((e.value ->> 'amount')::numeric) filter (where (e.value ->> 'sequence')::integer >= l.done_sequence) as done_amount,
                   sum((e.value ->> 'amount')::numeric) filter (where (e.value ->> 'sequence')::integer <  l.done_sequence) as remaining_amount
            from jsonb_array_elements(coalesce(ag.part_status_json, '[]'::jsonb)) as e(value)
            where l.done_sequence is not null
        ) pr on true
    ),
    -- actual: the state blocks and the produced items of the lanes'
    -- resources, up to the viewed moment (the log functions clip to now());
    -- skipped altogether when the actual rows are not asked for
    actual_state as (
        select s.resource_uid, s.state, s.group_state, s.start_at,
               s.duration_seconds, s.data, s.nest_name
        from log.get_resource_state(
                 (select array_agg(l.resource_uid) from lane l), v_day_start, least(p_until, v_day_end), null) s
        where p_types is null or 'actual' = any (p_types)
    ),
    actual_produced as (
        select r.resource_uid, r.state, r.group_state, r.start_at,
               r.duration_seconds, r.data, r.nest_name
        from log.get_resource_produced(
                 (select array_agg(l.resource_uid) from lane l), v_day_start, least(p_until, v_day_end), null) r
        where p_types is null or 'actual' = any (p_types)
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
               p.material_id, p.material_name, p.impact_json, p.sqm, p.gross_sqm,
               p.part_status_json,
               jsonb_build_object(
                   'done_amount',          p.done_amount,
                   'remaining_amount',     p.remaining_amount,
                   'remaining_percentage', round(p.remaining_share * 100, 1),
                   'remaining_in_seconds', round(p.duration_in_seconds * p.remaining_share)::integer) as progress_json,
               p.state_json, p.group_state_json, p.class_names, p.param_json
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
               p.material_id, p.material_name, p.impact_json, p.sqm, p.gross_sqm,
               p.part_status_json,
               jsonb_build_object(
                   'done_amount',          p.done_amount,
                   'remaining_amount',     p.remaining_amount,
                   'remaining_percentage', round(p.remaining_share * 100, 1),
                   'remaining_in_seconds', round(p.duration_in_seconds * p.remaining_share)::integer),
               p.state_json, p.group_state_json, p.class_names, p.param_json
        from plan_row p
        where round(p.duration_in_seconds * p.remaining_share) > 0

        union all
        -- actual: state blocks, named by the resource that ran
        select l.tenant_id, l.tenant_name, l.production_company_id,
               l.resource_uid, l.resource_name, l.resource_path, l.lane_id, l.step,
               'actual'::text,
               null::bigint, null::numeric, false, false, null::text,
               extract(epoch from (rs.start_at - v_day_start))::integer,
               rs.duration_seconds::integer,
               rs.start_at,
               rs.start_at + make_interval(secs => rs.duration_seconds),
               '{}'::bigint[], 0,
               null::integer, null::text,
               null::integer, null::text,
               null::jsonb, null::numeric, null::numeric,
               '[]'::jsonb,
               null::jsonb,
               rs.state, rs.group_state,
               array_remove(array[rs.state ->> 'class_name'], null),
               coalesce(rs.data, '{}'::jsonb)
        from actual_state rs
        join lane l on l.resource_uid = rs.resource_uid

        union all
        -- actual: produced items, named by the resource that ran
        select l.tenant_id, l.tenant_name, l.production_company_id,
               l.resource_uid, l.resource_name, l.resource_path, l.lane_id, l.step,
               'actual'::text,
               null::bigint, null::numeric, false, false, null::text,
               extract(epoch from (rp.start_at - v_day_start))::integer,
               rp.duration_seconds::integer,
               rp.start_at,
               rp.start_at + make_interval(secs => coalesce(rp.duration_seconds, 0)),
               case when (rp.data ->> 'nest_id') is not null then array[(rp.data ->> 'nest_id')::bigint] else '{}'::bigint[] end,
               case when (rp.data ->> 'nest_id') is not null then 1 else 0 end,
               (rp.data ->> 'batch_id')::integer, null::text,
               null::integer, null::text,
               null::jsonb, null::numeric, null::numeric,
               '[]'::jsonb,
               null::jsonb,
               rp.state, rp.group_state,
               array_remove(array[rp.state ->> 'class_name', 'realized-produced'], null),
               coalesce(rp.data, '{}'::jsonb) || jsonb_build_object('nest_name', rp.nest_name)
        from actual_produced rp
        join lane l on l.resource_uid = rp.resource_uid
    )
    select r.tenant_id, r.tenant_name, r.production_company_id,
           r.resource_uid, r.resource_name, r.resource_path, r.lane_id, r.step,
           r.type, k.type_json,
           r.lane_item_id, r.sort_order, r.is_pinned, r.no_split, r.fixed_group,
           r.start_offset_in_seconds, r.duration_in_seconds, r.start_at, r.end_at,
           r.nest_ids, r.nest_count, r.batch_id, r.batch_name,
           r.material_id, r.material_name, r.impact_json, r.sqm, r.gross_sqm,
           r.part_status_json, r.progress_json, r.state_json, r.group_state_json,
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

-- One read for the lanes (labels) of every plan board: print_schedule,
-- impose_plan, impose_resource_plan, production_resource_plan and whatever
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

-- 4. the writers
DROP FUNCTION IF EXISTS action.crud_lane_item(jsonb, boolean);
create function action.crud_lane_item(p_param_json jsonb, p_no_results boolean DEFAULT false) returns TABLE(param_id integer, track_by integer, crud text, lane_item_id bigint, lane_id bigint, material_impose_plan_id bigint)
	language sql
as $$
    -- The client mutations of the planning boards, on lane_item level. Every
    -- mutation writes through to mock.material_impose_plan, so re-stamping a
    -- plan reproduces what the planner did:
    --   update — move/pin/sort: the item and its pattern row
    --   create — an extra moment: a new pattern row with the next instance,
    --            plus the lane and the item it stamps to
    --   delete — the moment, its impositions and its pattern row
    --
    -- Set-based throughout: ids are drawn from the sequences up front, so a
    -- created row can be paired back to its payload row without a temp table.
    WITH payload AS (
        SELECT row_number() OVER ()::integer AS param_id,
               coalesce(te.track_by, 0)      AS track_by,
               te.crud, te.lane_item_id, te.lane_id, te.plan_id,
               te.start_offset_in_seconds, te.sort_order, te.is_pinned,
               te.imposition_group_id
        FROM jsonb_array_elements(p_param_json) AS t(element)
        CROSS JOIN LATERAL jsonb_to_record(t.element) AS te(
            track_by integer, crud text, lane_item_id bigint, lane_id bigint,
            plan_id bigint, start_offset_in_seconds integer, sort_order numeric,
            is_pinned boolean, imposition_group_id integer)
    ),
    -- what an update or a copy starts from: the item, its lane and the
    -- pattern row it was stamped from (source_ref is <mrp_id>:<date>)
    source AS (
        SELECT p.param_id,
               li.lane_item_id, li.lane_id, li.sort_order, li.start_offset_in_seconds,
               li.is_pinned, li.duration_in_seconds,
               l.lane_date,
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
    new_lane AS (
        INSERT INTO action.lane (lane_id, lane_date)
        OVERRIDING SYSTEM VALUE
        SELECT t.new_lane_id, t.lane_date
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
             duration_in_seconds, is_pinned, no_split, type, source, source_ref)
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
               t.new_pattern_id || ':' || t.lane_date
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
    deleted_link AS (
        DELETE FROM action.imposition_lane_item x
        USING payload p
        WHERE p.crud = 'delete' AND x.lane_item_id = p.lane_item_id
        RETURNING x.lane_item_id
    ),
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

create or replace function action.crud_object(p_param_json jsonb, p_no_results boolean DEFAULT false) returns jsonb
	language plpgsql
as $$
DECLARE
    result          jsonb;
    last_updated_at timestamp;
BEGIN
    -- ============================================================
    -- normalize every payload element into one set. resource_uid is
    -- never sent directly by the caller — only the pv2 resource_id is —
    -- so it is resolved here via relation.resource.pv2_id.
    -- ============================================================
    CREATE TEMP TABLE param_table ON COMMIT DROP AS
    SELECT
        (el ->> 'plannable_item_id')::integer                          AS plannable_item_id,
        el ->> 'crud'                                                   AS crud,
        (el ->> 'domain_id')::integer                                   AS domain_id,
        (el ->> 'company_id')::integer                                  AS company_id,
        (el ->> 'contact_id')::integer                                  AS contact_id,
        (el ->> 'team_id')::bigint                                      AS team_id,
        (el ->> 'section_id')::integer                                  AS section_id,
        (el ->> 'batch_id')::integer                                    AS batch_id,
        el ->> 'machine_type'                                            AS machine_type,
        res.resource_uid,
        COALESCE((el ->> 'is_fixed_offset')::boolean, false)             AS is_fixed_offset,
        (el ->> 'deleted_at') IS NOT NULL                                AS is_delete,
        jsonb_set(el, '{data}', (el ->> 'data')::jsonb, true)            AS action_json,
        (el ->> 'updated_at')::timestamp AT TIME ZONE 'Europe/Amsterdam' AS updated_at
    FROM jsonb_array_elements(p_param_json) AS el
    LEFT JOIN relation.resource res
           ON res.resource_json ->> 'pv2_id' = el ->> 'resource_id';

    -- ============================================================
    -- deletes: rows flagged with deleted_at
    -- ============================================================
    DELETE FROM action.object o
    USING param_table pt
    WHERE pt.crud = 'merge'
      AND pt.is_delete
      AND (o.action_json ->> 'plannable_item_id')::integer = pt.plannable_item_id;

    -- ============================================================
    -- upserts: rank continues from the existing count per
    -- resource_uid + day, then increments per row in updated_at order —
    -- same convention as generate_planning_objects. IS NOT DISTINCT FROM
    -- (instead of =) so rows without a resource_uid are grouped and
    -- ranked correctly instead of each restarting at 0.
    -- offset_in_seconds is always computed from start_at relative to
    -- 06:00 Amsterdam of that day — the canonical planning time field —
    -- never taken from the payload. Everything written through crud_object
    -- is atomic by definition, so is_atomic is hardcoded true.
    -- ============================================================
    WITH existing_rank AS (
        SELECT
            o.resource_uid,
            (o.start_at AT TIME ZONE 'Europe/Amsterdam')::date AS day,
            count(*)                                            AS cnt
        FROM action.object o
        WHERE o.parent_action_id IS NULL
        GROUP BY 1, 2
    ),
    batch_rows AS (
        SELECT
            pt.*,
            (pt.action_json ->> 'start_date')::timestamp AT TIME ZONE 'Europe/Amsterdam' AS start_at_local,
            ((pt.action_json ->> 'start_date')::timestamp AT TIME ZONE 'Europe/Amsterdam')::date AS day
        FROM param_table pt
        WHERE pt.crud = 'merge' AND NOT pt.is_delete
    ),
    ranked AS (
        SELECT
            br.*,
            EXTRACT(EPOCH FROM (br.start_at_local - (br.day + time '06:00')))::integer AS offset_in_seconds,
            row_number() OVER (
                PARTITION BY br.resource_uid, br.day
                ORDER BY br.updated_at NULLS FIRST
            ) AS batch_seq
        FROM batch_rows br
    )
    INSERT INTO action.object (
        domain_id, company_id, contact_id, team_id, section_id,
        action_json, start_at, end_at, batch_id,
        resource_uid, resource_plan_rank, is_fixed_offset, offset_in_seconds, is_atomic
    )
    SELECT
        r.domain_id, r.company_id, r.contact_id, r.team_id, r.section_id,
        r.action_json,
        r.start_at_local,
        (r.action_json ->> 'end_date')::timestamp AT TIME ZONE 'Europe/Amsterdam',
        r.batch_id,
        r.resource_uid,
        (COALESCE(er.cnt, 0) + r.batch_seq) * 1000,
        r.is_fixed_offset,
        r.offset_in_seconds,
        true
    FROM ranked r
    LEFT JOIN existing_rank er
           ON er.resource_uid IS NOT DISTINCT FROM r.resource_uid
          AND er.day          IS NOT DISTINCT FROM r.day
    ON CONFLICT (((action_json->>'plannable_item_id')::integer))
    DO UPDATE SET
        action_json        = EXCLUDED.action_json,
        start_at           = EXCLUDED.start_at,
        end_at             = EXCLUDED.end_at,
        batch_id           = EXCLUDED.batch_id,
        resource_uid       = EXCLUDED.resource_uid,
        resource_plan_rank = EXCLUDED.resource_plan_rank,
        is_fixed_offset    = EXCLUDED.is_fixed_offset,
        offset_in_seconds  = EXCLUDED.offset_in_seconds,
        is_atomic          = true;

    -- ============================================================
    -- resolve parent_action_id now that every row in this batch
    -- (parents included, regardless of arrival order) exists.
    -- chain: printer is root; coater/laminator is child of printer;
    -- cutter is child of coater/laminator if one exists for the batch,
    -- else child of printer
    -- ============================================================
    UPDATE action.object o
    SET parent_action_id = parent.action_id
    FROM param_table pt
    CROSS JOIN LATERAL (
        SELECT p.action_id
        FROM action.object p
        WHERE p.batch_id = pt.batch_id
          AND (
              (pt.machine_type IN ('coater', 'laminator') AND (p.action_json ->> 'machine_type') = 'printer')
              OR (pt.machine_type = 'cutter' AND (p.action_json ->> 'machine_type') IN ('coater', 'laminator'))
          )
        ORDER BY p.action_id DESC
        LIMIT 1
    ) parent
    WHERE pt.crud = 'merge'
      AND NOT pt.is_delete
      AND pt.batch_id IS NOT NULL
      AND pt.machine_type IN ('coater', 'laminator', 'cutter')
      AND (o.action_json ->> 'plannable_item_id')::integer = pt.plannable_item_id;

    -- cutter fallback: no coater/laminator sibling found for this batch,
    -- so fall back to the printer directly
    UPDATE action.object o
    SET parent_action_id = printer.action_id
    FROM param_table pt
    CROSS JOIN LATERAL (
        SELECT p.action_id
        FROM action.object p
        WHERE p.batch_id = pt.batch_id
          AND (p.action_json ->> 'machine_type') = 'printer'
        ORDER BY p.action_id DESC
        LIMIT 1
    ) printer
    WHERE pt.crud = 'merge'
      AND NOT pt.is_delete
      AND pt.batch_id IS NOT NULL
      AND pt.machine_type = 'cutter'
      AND o.parent_action_id IS NULL
      AND (o.action_json ->> 'plannable_item_id')::integer = pt.plannable_item_id;

    -- ============================================================
    -- the new plan model: the same items as action.plan -> lane ->
    -- lane_item (type plan), with their nests and dependencies. One
    -- production plan per day and line type covering every step in the
    -- payload; one lane per resource (its resource_path); one lane_item
    -- per plannable item, found again on the next payload through
    -- (source 'pv2', source_ref plannable_item_id). Only type 'batch'
    -- items are planning items; batch-reserved / batch-initiated are not.
    -- Items whose resource has no resource_path yet cannot get a lane and
    -- are skipped until it has one.
    -- ============================================================
    CREATE TEMP TABLE new_item ON COMMIT DROP AS
    SELECT pt.plannable_item_id,
           pt.plannable_item_id::text                                              AS source_ref,
           pt.batch_id,
           pt.machine_type,
           r.resource_path,
           r.step,
           -- the plan's line type is the ORDER's, from the batch; a machine can
           -- physically stand in another department (a foil order on a printer
           -- in the sheet hall still belongs to the foil plan)
           coalesce(bpl.line_type, pl.line_type) as line_type,
           pl.line_type                              as physical_line_type,
           ((pt.action_json ->> 'start_date')::timestamp AT TIME ZONE 'Europe/Amsterdam')                     AS start_at,
           -- start_date is Amsterdam local time; its date IS the plan date.
           -- No AT TIME ZONE here: the date cast would run in the session
           -- timezone (GMT) and shift items starting just after midnight
           -- to the previous day, blowing the 0..86399 offset check.
           ((pt.action_json ->> 'start_date')::timestamp)::date                                                AS plan_date,
           (pt.action_json ->> 'start_date')::timestamp                                                        AS start_local,
           (pt.action_json ->> 'end_date')::timestamp                                                          AS end_local,
           pt.is_fixed_offset,
           pt.action_json -> 'data' -> 'batched_amounts'                                                       AS batched_amounts
    FROM param_table pt
    JOIN relation.resource r          ON r.resource_uid = pt.resource_uid
    JOIN relation.production_line pl  ON pl.line_id = r.line_id
    LEFT JOIN legacy.batch b          ON b.batch_id = pt.batch_id
    LEFT JOIN relation.production_line bpl ON bpl.line_id = (b.batch_json ->> 'production_line_id')::integer
    WHERE pt.crud = 'merge'
      AND NOT pt.is_delete
      AND COALESCE(pt.action_json ->> 'type', 'batch') = 'batch'
      AND r.resource_path IS NOT NULL
      AND (pt.action_json ->> 'start_date') IS NOT NULL;

    -- deletes: the item, its nests and its edges (edges cascade)
    DELETE FROM action.imposition_lane_item nli
    USING action.lane_item li, param_table pt
    WHERE nli.lane_item_id = li.lane_item_id
      AND li.source = 'pv2' AND li.source_ref = pt.plannable_item_id::text
      AND pt.crud = 'merge' AND pt.is_delete;

    DELETE FROM action.lane_item li
    USING param_table pt
    WHERE li.source = 'pv2' AND li.source_ref = pt.plannable_item_id::text
      AND pt.crud = 'merge' AND pt.is_delete;

    -- the day's production plan per line type: the newest one, or a new one
    -- (the material-resource-plan is calendar-driven and created in
    -- site.refresh_derived_data, ahead of the plannable items)
    INSERT INTO action.plan (plan_date, steps, type, line_type)
    SELECT d.plan_date, array_agg(DISTINCT d.step ORDER BY d.step), 'production-plan', d.line_type
    FROM (SELECT ni.plan_date, ni.step, ni.line_type FROM new_item ni
          UNION ALL
          SELECT ni.plan_date, ni.step, ni.physical_line_type FROM new_item ni
          WHERE ni.physical_line_type IS DISTINCT FROM ni.line_type) d
    WHERE NOT EXISTS (SELECT 1 FROM action.plan p
                      WHERE p.plan_date = d.plan_date AND p.type = 'production-plan'
                        AND p.line_type IS NOT DISTINCT FROM d.line_type)
    GROUP BY d.plan_date, d.line_type;

    -- and every step of the payload in the plan's steps
    UPDATE action.plan p
    SET steps = (SELECT array_agg(DISTINCT s ORDER BY s)
                 FROM unnest(p.steps || x.steps) AS s)
    FROM (SELECT d.plan_date, d.line_type, array_agg(DISTINCT d.step) AS steps
          FROM (SELECT ni.plan_date, ni.step, ni.line_type FROM new_item ni
                UNION ALL
                SELECT ni.plan_date, ni.step, ni.physical_line_type FROM new_item ni
                WHERE ni.physical_line_type IS DISTINCT FROM ni.line_type) d
          GROUP BY d.plan_date, d.line_type) x
    WHERE p.plan_id = (SELECT p2.plan_id FROM action.plan p2
                       WHERE p2.plan_date = x.plan_date AND p2.type = 'production-plan'
                         AND p2.line_type IS NOT DISTINCT FROM x.line_type
                       ORDER BY p2.plan_id DESC LIMIT 1)
      AND NOT (p.steps @> x.steps);

    -- the plan of every item, resolved once
    CREATE TEMP TABLE item_plan ON COMMIT DROP AS
    SELECT d.*,
           (SELECT p.plan_id FROM action.plan p
            WHERE p.plan_date = d.plan_date AND p.type = 'production-plan'
              AND p.line_type IS NOT DISTINCT FROM d.line_type
            ORDER BY p.plan_id DESC LIMIT 1) AS plan_id,
           CASE WHEN d.physical_line_type IS DISTINCT FROM d.line_type THEN
           (SELECT p.plan_id FROM action.plan p
            WHERE p.plan_date = d.plan_date AND p.type = 'production-plan'
              AND p.line_type IS NOT DISTINCT FROM d.physical_line_type
            ORDER BY p.plan_id DESC LIMIT 1) END AS physical_plan_id
    FROM new_item d;

    -- the machine-day lane of every item, created once, then hung under
    -- the order's plan AND the physical department's plan, so both boards
    -- see the machine's full occupation
    WITH missing AS (
        SELECT DISTINCT ip.plan_date, ip.resource_path
        FROM item_plan ip
        WHERE NOT EXISTS (SELECT 1
                          FROM action.lane l
                          JOIN action.resource_lane rl ON rl.lane_id = l.lane_id
                          WHERE l.lane_date = ip.plan_date AND rl.resource_path = ip.resource_path)
    ),
    with_id AS (
        SELECT m.plan_date, m.resource_path,
               nextval(pg_get_serial_sequence('action.lane', 'lane_id')) AS lane_id
        FROM missing m
    ),
    new_lane AS (
        INSERT INTO action.lane (lane_id, lane_date)
        OVERRIDING SYSTEM VALUE
        SELECT w.lane_id, w.plan_date FROM with_id w
        RETURNING lane_id
    )
    INSERT INTO action.resource_lane (lane_id, resource_path)
    SELECT w.lane_id, w.resource_path FROM with_id w;

    INSERT INTO action.plan_lane (plan_id, lane_id, sort_order)
    SELECT x.plan_id, x.lane_id,
           COALESCE((SELECT max(pl2.sort_order) FROM action.plan_lane pl2 WHERE pl2.plan_id = x.plan_id), 0)
             + row_number() OVER (PARTITION BY x.plan_id ORDER BY x.lane_id)
    FROM (SELECT DISTINCT pp.plan_id, l.lane_id
          FROM (SELECT ip.plan_id, ip.plan_date, ip.resource_path FROM item_plan ip
                UNION
                SELECT ip.physical_plan_id, ip.plan_date, ip.resource_path FROM item_plan ip
                WHERE ip.physical_plan_id IS NOT NULL) pp
          JOIN action.resource_lane rl ON rl.resource_path = pp.resource_path
          JOIN action.lane l ON l.lane_id = rl.lane_id AND l.lane_date = pp.plan_date) x
    WHERE NOT EXISTS (SELECT 1 FROM action.plan_lane pl3
                      WHERE pl3.plan_id = x.plan_id AND pl3.lane_id = x.lane_id);

    -- the items: offset in seconds since the plan date's local midnight,
    -- duration from the pv2 end, pinned when pv2 fixes the offset, never
    -- split. sort_order is a placeholder here; the lanes are renumbered
    -- below (it is unique per lane).
    INSERT INTO action.lane_item AS li
        (lane_id, sort_order, start_offset_in_seconds, duration_in_seconds,
         is_pinned, no_split, type, source, source_ref)
    SELECT l.lane_id,
           -1 * ip.plannable_item_id,
           EXTRACT(EPOCH FROM (ip.start_local - ip.plan_date::timestamp))::integer,
           GREATEST(COALESCE(EXTRACT(EPOCH FROM (ip.end_local - ip.start_local))::integer, 0), 0),
           ip.is_fixed_offset, true, 'plan', 'pv2', ip.source_ref
    FROM item_plan ip
    JOIN action.resource_lane rl ON rl.resource_path = ip.resource_path
    JOIN action.lane l ON l.lane_id = rl.lane_id AND l.lane_date = ip.plan_date
    ON CONFLICT (source, source_ref) DO UPDATE SET
        lane_id                 = EXCLUDED.lane_id,
        sort_order              = EXCLUDED.sort_order,
        start_offset_in_seconds = EXCLUDED.start_offset_in_seconds,
        duration_in_seconds     = EXCLUDED.duration_in_seconds,
        is_pinned               = EXCLUDED.is_pinned;

    -- renumber every touched lane by start, in two steps so the unique
    -- (lane_id, sort_order) never collides on the way
    UPDATE action.lane_item li
    SET sort_order = -1 * li.lane_item_id
    WHERE li.type = 'plan'
      AND li.lane_id IN (SELECT DISTINCT l.lane_id FROM item_plan ip
                         JOIN action.resource_lane rl ON rl.resource_path = ip.resource_path
    JOIN action.lane l ON l.lane_id = rl.lane_id AND l.lane_date = ip.plan_date);

    UPDATE action.lane_item li
    SET sort_order = x.rank * 1000
    FROM (SELECT li2.lane_item_id,
                 row_number() OVER (PARTITION BY li2.lane_id
                                    ORDER BY li2.start_offset_in_seconds, li2.lane_item_id) AS rank
          FROM action.lane_item li2
          WHERE li2.type = 'plan'
            AND li2.lane_id IN (SELECT DISTINCT l.lane_id FROM item_plan ip
                                JOIN action.resource_lane rl ON rl.resource_path = ip.resource_path
    JOIN action.lane l ON l.lane_id = rl.lane_id AND l.lane_date = ip.plan_date)) x
    WHERE li.lane_item_id = x.lane_item_id;

    -- the nests and the chain of the items, one batch per lane item: the
    -- main item holds the nests of the item's batch, a nest that legacy.nest
    -- meanwhile books on another batch gets an extra item next to it, and the
    -- edges run per batch. One place for that rule, shared with the backfill
    -- (docs/plan-lane-model.md stap 3b)
    PERFORM action.sync_pv2_batch_items(array(SELECT ip.plannable_item_id FROM item_plan ip));

    -- ============================================================
    -- fill print_production_unit_id in legacy.batch if it is still null
    -- ============================================================
    UPDATE legacy.batch b
    SET batch_json = jsonb_set(
        b.batch_json,
        '{print_production_unit_id}',
        to_jsonb((pt.action_json ->> 'resource_id')::int)
    )
    FROM param_table pt
    WHERE pt.crud = 'merge'
      AND NOT pt.is_delete
      AND (pt.action_json ->> 'machine_type') = 'printer'
      AND (pt.action_json ->> 'resource_id') IS NOT NULL
      AND pt.batch_id IS NOT NULL
      AND b.batch_id = pt.batch_id
      AND (b.batch_json ->> 'print_production_unit_id') IS NULL;

    SELECT MAX(pt.updated_at) INTO last_updated_at
    FROM param_table pt;

    IF last_updated_at IS NOT NULL THEN
        UPDATE mapping.persistent_vars
        SET value = last_updated_at - INTERVAL '2 minutes'
        WHERE key = 'last_plannable_item_updated_at';
    END IF;

    IF p_no_results THEN
        RETURN '[]'::jsonb;
    END IF;

    SELECT jsonb_agg(to_jsonb(pt.*))
    INTO result
    FROM param_table pt;

    RETURN COALESCE(result, '[]'::jsonb);
END;
$$;

alter function action.crud_object(jsonb, boolean) owner to xfw3;

-- One batch per lane item for the pv2 planning (docs/plan-lane-model.md,
-- stap 3b). A plannable item of pv2 (action.object, type 'batch') is one lane
-- item: source 'pv2', source_ref <plannable_item_id>. Its batched_amounts name
-- the nests; when legacy.nest meanwhile books a nest on another batch, that
-- nest may not stay on the item of the other batch. A nest without a batch
-- yet (nests are made first and batched later) counts as the item's own. A
-- nest on another batch gets its own item next to the main one: source 'pv2',
-- source_ref <plannable_item_id>:<batch>, same lane and start, the block's
-- duration shared by nest count (the main item keeps its share). Extra items
-- whose batch left are removed again.
--
-- Sets and edges of the main and extra items are replaced as a whole, the
-- way crud_object did for the main item: the pv2 planning is the source of
-- truth here, not history. The chain runs per batch: a coater/laminator item
-- of batch B follows the printer item of batch B, a cutter item of batch B
-- follows the coater/laminator of B, else the printer of B — where "the item
-- of batch B" is the extra item <id>:<B> when the parent object holds B as an
-- extra, else its main item.
--
-- Called by action.crud_object after its upsert (for the payload's items) and
-- by the backfill (for every item). Set-based, no loop.
drop function if exists action.sync_pv2_batch_items(bigint[]);

create function action.sync_pv2_batch_items(p_plannable_item_ids bigint[]) returns integer
	language plpgsql
as $$
#variable_conflict use_column
DECLARE
    v_items integer;
BEGIN
    -- every nest of every item, with the batch legacy.nest books it on
    CREATE TEMP TABLE pv2_nest ON COMMIT DROP AS
    SELECT (o.action_json ->> 'plannable_item_id')                AS source_ref,
           coalesce(o.batch_id, 0)                                 AS item_batch,
           o.action_json ->> 'machine_type'                        AS machine_type,
           GREATEST(COALESCE(EXTRACT(EPOCH FROM ((o.action_json ->> 'end_date')::timestamp
                                                 - (o.action_json ->> 'start_date')::timestamp))::integer, 0), 0)
                                                                   AS block_duration,
           (ba.value ->> 'nest_id')::bigint                        AS nest_id,
           (ba.value ->> 'sequence')::numeric                      AS sequence,
           -- a nest without a batch yet belongs to the item's batch (nests are
           -- made first and batched later); only a nest on another batch leaves
           coalesce(n.batch_id, o.batch_id, 0)                     AS batch_key
    FROM action.object o
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(o.action_json -> 'data' -> 'batched_amounts', '[]'::jsonb)) AS ba(value)
    JOIN legacy.nest n ON n.nest_id = (ba.value ->> 'nest_id')::bigint
    WHERE (o.action_json ->> 'plannable_item_id')::bigint = ANY (p_plannable_item_ids)
      AND (ba.value ->> 'nest_id') IS NOT NULL;

    -- per (item, batch) the lane item it belongs to: the main item for the
    -- item's own batch (also when none of the nests is on it any more), an
    -- extra item per other batch
    CREATE TEMP TABLE pv2_item ON COMMIT DROP AS
    WITH batch AS (
        SELECT source_ref, item_batch AS batch_key FROM pv2_nest
        UNION
        SELECT source_ref, batch_key FROM pv2_nest
    ),
    cnt AS (
        SELECT source_ref, batch_key, count(*) AS nests FROM pv2_nest GROUP BY 1, 2
    ),
    total AS (
        SELECT source_ref, count(*) AS all_nests, max(block_duration) AS block_duration, max(item_batch) AS item_batch
        FROM pv2_nest GROUP BY 1
    )
    SELECT b.source_ref, b.batch_key,
           CASE WHEN b.batch_key = t.item_batch THEN b.source_ref
                ELSE b.source_ref || ':' || b.batch_key END               AS item_ref,
           coalesce(c.nests, 0)                                          AS nests,
           t.all_nests,
           round(t.block_duration::numeric * coalesce(c.nests, 0) / nullif(t.all_nests, 0))::integer AS duration_in_seconds,
           main.lane_item_id                                             AS main_item_id,
           main.lane_id, main.sort_order AS main_sort_order,
           main.start_offset_in_seconds, main.is_pinned
    FROM batch b
    JOIN total t ON t.source_ref = b.source_ref
    LEFT JOIN cnt c ON c.source_ref = b.source_ref AND c.batch_key = b.batch_key
    JOIN action.lane_item main ON main.source = 'pv2' AND main.source_ref = b.source_ref;

    -- the extra items, next to the main item in its lane
    INSERT INTO action.lane_item AS li
        (lane_id, sort_order, start_offset_in_seconds, duration_in_seconds,
         is_pinned, no_split, type, source, source_ref)
    SELECT pi.lane_id,
           pi.main_sort_order + row_number() OVER (PARTITION BY pi.source_ref ORDER BY pi.batch_key),
           pi.start_offset_in_seconds, pi.duration_in_seconds, pi.is_pinned, true, 'plan', 'pv2', pi.item_ref
    FROM pv2_item pi
    WHERE pi.item_ref <> pi.source_ref
    ON CONFLICT (source, source_ref) DO UPDATE SET
        lane_id                 = EXCLUDED.lane_id,
        sort_order              = EXCLUDED.sort_order,
        start_offset_in_seconds = EXCLUDED.start_offset_in_seconds,
        duration_in_seconds     = EXCLUDED.duration_in_seconds,
        is_pinned               = EXCLUDED.is_pinned;

    -- the main item keeps its share of the block
    UPDATE action.lane_item li
    SET duration_in_seconds = pi.duration_in_seconds
    FROM pv2_item pi
    WHERE pi.item_ref = pi.source_ref
      AND li.lane_item_id = pi.main_item_id
      AND li.duration_in_seconds IS DISTINCT FROM pi.duration_in_seconds;

    -- extra items whose batch left: their sets, edges (cascade) and the item
    DELETE FROM action.imposition_lane_item x
    USING action.lane_item li
    WHERE x.lane_item_id = li.lane_item_id
      AND li.source = 'pv2'
      AND split_part(li.source_ref, ':', 1)::bigint = ANY (p_plannable_item_ids)
      AND li.source_ref LIKE '%:%'
      AND NOT EXISTS (SELECT 1 FROM pv2_item pi WHERE pi.item_ref = li.source_ref);

    DELETE FROM action.lane_item li
    WHERE li.source = 'pv2'
      AND split_part(li.source_ref, ':', 1)::bigint = ANY (p_plannable_item_ids)
      AND li.source_ref LIKE '%:%'
      AND NOT EXISTS (SELECT 1 FROM pv2_item pi WHERE pi.item_ref = li.source_ref);

    -- the sets of main and extra items, replaced as a whole
    DELETE FROM action.imposition_lane_item x
    USING action.lane_item li
    WHERE x.lane_item_id = li.lane_item_id
      AND li.source = 'pv2'
      AND split_part(li.source_ref, ':', 1)::bigint = ANY (p_plannable_item_ids);

    INSERT INTO action.imposition_lane_item (imposition_id, lane_item_id, sort_order)
    SELECT DISTINCT ON (pn.nest_id, li.lane_item_id)
           pn.nest_id, li.lane_item_id, pn.sequence
    FROM pv2_nest pn
    JOIN pv2_item pi ON pi.source_ref = pn.source_ref AND pi.batch_key = pn.batch_key
    JOIN action.lane_item li ON li.source = 'pv2' AND li.source_ref = pi.item_ref
    ORDER BY pn.nest_id, li.lane_item_id, pn.sequence;

    -- the chain per batch: edges of main and extra items replaced as a whole
    DELETE FROM action.lane_item_dependency d
    USING action.lane_item li
    WHERE d.to_lane_item_id = li.lane_item_id
      AND li.source = 'pv2'
      AND split_part(li.source_ref, ':', 1)::bigint = ANY (p_plannable_item_ids);

    INSERT INTO action.lane_item_dependency (from_lane_item_id, to_lane_item_id)
    SELECT parent.lane_item_id, child.lane_item_id
    FROM pv2_item pi
    JOIN pv2_nest pn0 ON pn0.source_ref = pi.source_ref
    JOIN action.lane_item child ON child.source = 'pv2' AND child.source_ref = pi.item_ref
    CROSS JOIN LATERAL (
        -- the object of batch B one step earlier, and its item that holds B:
        -- the extra item <id>:<B> when B is an extra there, else the main item
        SELECT p.lane_item_id
        FROM action.object o
        JOIN action.lane_item p
          ON p.source = 'pv2'
         AND p.source_ref = CASE WHEN coalesce(o.batch_id, 0) = pi.batch_key
                                 THEN o.action_json ->> 'plannable_item_id'
                                 ELSE (o.action_json ->> 'plannable_item_id') || ':' || pi.batch_key END
        WHERE (o.batch_id = pi.batch_key
               OR EXISTS (SELECT 1 FROM action.lane_item e
                          WHERE e.source = 'pv2'
                            AND e.source_ref = (o.action_json ->> 'plannable_item_id') || ':' || pi.batch_key))
          AND (   (pn0.machine_type IN ('coater', 'laminator') AND o.action_json ->> 'machine_type' = 'printer')
               OR (pn0.machine_type = 'cutter' AND o.action_json ->> 'machine_type' IN ('coater', 'laminator', 'printer')))
        ORDER BY CASE WHEN o.action_json ->> 'machine_type' IN ('coater', 'laminator') THEN 0 ELSE 1 END,
                 o.action_id DESC
        LIMIT 1
    ) parent
    WHERE pi.nests > 0
      AND pi.batch_key <> 0
      AND pn0.machine_type IN ('coater', 'laminator', 'cutter')
      AND pn0.nest_id = (SELECT min(x.nest_id) FROM pv2_nest x WHERE x.source_ref = pi.source_ref)
    ON CONFLICT DO NOTHING;

    SELECT count(*) INTO v_items FROM pv2_item;
    RETURN v_items;
END;
$$;

alter function action.sync_pv2_batch_items(bigint[]) owner to xfw3;

DROP FUNCTION IF EXISTS legacy.crud_nest(jsonb, boolean);
create function legacy.crud_nest(p_param_json jsonb, p_no_results boolean DEFAULT false) returns TABLE(param_id integer, track_by integer, crud text, domain_id integer, batch_id bigint, nest_id bigint, nest_counter integer, reproduced_counter integer, nest_name text, amount integer, width numeric, height numeric, nest_json jsonb, sort_order integer, status jsonb, possible_states bigint, possible_multiple_states bigint)
	language plpgsql
as $$
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

        IF rec.crud IN ('create','merge') THEN
            INSERT INTO legacy.nest (
                batch_uid, domain_id, nest_id, nest_counter, reproduced_counter,
                nest_name, amount, width, height, nest_json, sort_order,
                status_json, possible_states, possible_multiple_states, nested_at, updated_at
            ) VALUES (
                v_batch_uid, rec.domain_id, rec.nest_id, rec.nest_counter, rec.reproduced_counter,
                rec.nest_name, rec.amount, rec.width, rec.height,
                -- never insert a bare NULL into nest_json
                COALESCE(rec.nest_json, '{}'::jsonb),
                rec.sort_order,
                rec.status, rec.possible_states, rec.possible_multiple_states, rec.nest_date, rec.updated_at
            )
            ON CONFLICT ON CONSTRAINT uq_nest_id DO UPDATE
                SET batch_uid                = EXCLUDED.batch_uid,
                    nest_name                = EXCLUDED.nest_name,
                    amount                   = EXCLUDED.amount,
                    width                    = EXCLUDED.width,
                    height                   = EXCLUDED.height,
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

        ELSIF rec.crud = 'update' THEN
            UPDATE legacy.nest n
            SET
                batch_uid                = v_batch_uid,
                -- merge instead of replace, same reasoning as the create/merge branch above
                nest_json                = COALESCE(n.nest_json, '{}'::jsonb)
                                            || COALESCE(rec.nest_json, '{}'::jsonb),
                sort_order               = rec.sort_order,
                status_json              = rec.status,
                possible_states          = rec.possible_states,
                possible_multiple_states = rec.possible_multiple_states,
                nested_at                = rec.nest_date,
                updated_at               = rec.updated_at
            WHERE n.nest_id = rec.nest_id;
        END IF;
    END LOOP;

    UPDATE legacy.nest n
    SET batch_uid = b.batch_uid
    FROM legacy.batch b
    WHERE n.batch_uid IS NULL
      AND b.batch_id = (n.nest_json ->> 'batch_id')::integer;

    -- ── nest → lane item (docs/nest-planning-lane-items.md §3) ─────────
    -- Every nest hangs on a lane item of the material-resource-plan of its
    -- day: plan → plan_lane → lane (the material lane) → lane_item. The
    -- item picked is the latest one starting at or before the nest moment
    -- (the stamped items are 0-duration moments, so a covering-window match
    -- would never hit), else the first of the day. Durations are never
    -- stored here: the boards derive them at read time — nests from
    -- width × height × sum(amount), the future from the aggregate and the
    -- material sizes in line_json.specs.
    CREATE TEMP TABLE nest_link ON COMMIT DROP AS
    WITH payload AS (
        SELECT pt.nest_id, pt.sort_order,
               (n.nest_json ->> 'material_id')::integer        AS material_id,
               (n.nest_json ->> 'production_line_id')::integer AS production_line_id,
               (COALESCE(pt.nest_date, n.nested_at) AT TIME ZONE 'Europe/Amsterdam')::date AS plan_date,
               extract(epoch FROM (COALESCE(pt.nest_date, n.nested_at) AT TIME ZONE 'Europe/Amsterdam')::time)::integer AS nest_seconds,
               lower(COALESCE(n.nest_json ->> 'status', '')) LIKE 'cancel%' AS is_cancelled,
               -- one batch per lane item; a nest without a batch is its own group
               coalesce(n.batch_id, 0) AS batch_key
        FROM param_table pt
        JOIN legacy.nest n ON n.nest_id = pt.nest_id
        WHERE pt.crud IN ('create', 'merge', 'update')
    )
    SELECT p.nest_id, p.sort_order, p.nest_seconds, p.is_cancelled, p.batch_key,
           lane.lane_id
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
        -- the lane of the nest material on that plan: the group lane.
        -- imposition_group_id acts as an alias of material_id for now (the
        -- groups were seeded 1:1 from the material ids); later the nests
        -- resolve their real imposition group here.
        -- The plan carries both tenants, so a material has one lane per
        -- production line; the line of the nest decides which one. The line
        -- of a lane sits on the pattern row its item was stamped from
        -- (source_ref = <material_impose_plan_id>:<date>). Before this, the
        -- first lane won and 1.338 nests of the other line landed on the
        -- wrong tenant's item (24 aug - 4 sep).
        SELECT igl.lane_id
        FROM action.plan_lane apl
        JOIN action.imposition_group_lane igl ON igl.lane_id = apl.lane_id
        JOIN action.lane_item li2 ON li2.lane_id = igl.lane_id AND li2.source = 'material-plan'
        JOIN mock.material_impose_plan mip
          ON mip.material_impose_plan_id = nullif(split_part(li2.source_ref, ':', 1), '')::bigint
        WHERE apl.plan_id = tp.plan_id
          AND igl.imposition_group_id = p.material_id
          AND mip.production_line_id = p.production_line_id
        ORDER BY apl.sort_order
        LIMIT 1
    ) lane ON true;

    -- ── one batch per lane item (docs/plan-lane-model.md stap 3b) ────────
    -- Per (lane, batch) one item: the item whose current set carries the
    -- batch; else an item without nests (the pattern item first, then by
    -- sort_order), handed out one per batch; else a new item, source 'nest',
    -- source_ref <lane_id>:<batch>, no time of its own (a filler the client
    -- chains), no_split. A nest that gets its batch later moves from the
    -- null-batch item to the batch item through the set write below.
    CREATE TEMP TABLE batch_item ON COMMIT DROP AS
    WITH need AS (
        SELECT DISTINCT ns.lane_id, ns.batch_key
        FROM nest_link ns
        WHERE ns.lane_id IS NOT NULL AND NOT ns.is_cancelled
    ),
    item_batch AS (
        -- the batch each plan item on those lanes carries today; null = no nests
        SELECT li.lane_item_id, li.lane_id, li.sort_order, li.source,
               (SELECT coalesce(n.batch_id, 0)
                FROM action.get_lane_item_impositions(li.lane_item_id) x
                JOIN legacy.nest n ON n.nest_id = x.imposition_id
                LIMIT 1) AS batch_key
        FROM action.lane_item li
        WHERE li.type = 'plan'
          AND li.lane_id IN (SELECT nd.lane_id FROM need nd)
    ),
    by_batch AS (
        SELECT nd.lane_id, nd.batch_key, min(ib.lane_item_id) AS lane_item_id
        FROM need nd
        JOIN item_batch ib ON ib.lane_id = nd.lane_id AND ib.batch_key = nd.batch_key
        GROUP BY nd.lane_id, nd.batch_key
    ),
    free_item AS (
        SELECT ib.lane_id, ib.lane_item_id,
               row_number() OVER (PARTITION BY ib.lane_id
                                  ORDER BY (ib.source = 'material-plan') DESC, ib.sort_order, ib.lane_item_id) AS rn
        FROM item_batch ib
        WHERE ib.batch_key IS NULL
    ),
    needs_item AS (
        SELECT nd.lane_id, nd.batch_key,
               row_number() OVER (PARTITION BY nd.lane_id ORDER BY nd.batch_key) AS rn
        FROM need nd
        WHERE NOT EXISTS (SELECT 1 FROM by_batch bb
                          WHERE bb.lane_id = nd.lane_id AND bb.batch_key = nd.batch_key)
    )
    SELECT bb.lane_id, bb.batch_key, bb.lane_item_id
    FROM by_batch bb
    UNION ALL
    SELECT ni.lane_id, ni.batch_key, fi.lane_item_id
    FROM needs_item ni
    LEFT JOIN free_item fi ON fi.lane_id = ni.lane_id AND fi.rn = ni.rn;

    -- the batches without an item get one, behind the existing items of the lane
    INSERT INTO action.lane_item
        (lane_id, sort_order, start_offset_in_seconds, no_split, type, source, source_ref)
    SELECT bi.lane_id,
           (SELECT coalesce(max(li.sort_order), 0) FROM action.lane_item li WHERE li.lane_id = bi.lane_id)
             + 1000 * row_number() OVER (PARTITION BY bi.lane_id ORDER BY bi.batch_key),
           NULL, true, 'plan', 'nest', bi.lane_id || ':' || bi.batch_key
    FROM batch_item bi
    WHERE bi.lane_item_id IS NULL
    ON CONFLICT ON CONSTRAINT lane_item_source_ref_uq DO NOTHING;

    UPDATE batch_item bi
    SET lane_item_id = li.lane_item_id
    FROM action.lane_item li
    WHERE bi.lane_item_id IS NULL
      AND li.source = 'nest' AND li.source_ref = bi.lane_id || ':' || bi.batch_key;

    -- a new item carries the group of its lane, like a pattern item does
    INSERT INTO action.imposition_group_lane_item (imposition_group_id, lane_item_id)
    SELECT igl.imposition_group_id, bi.lane_item_id
    FROM batch_item bi
    JOIN action.imposition_group_lane igl ON igl.lane_id = bi.lane_id
    WHERE NOT EXISTS (SELECT 1 FROM action.imposition_group_lane_item g WHERE g.lane_item_id = bi.lane_item_id)
    ON CONFLICT DO NOTHING;

    -- The material-lane sets are append-only (docs/plan-lane-model.md stap
    -- 2): every item a payload nest leaves or joins gets its set written
    -- anew — the current set minus the payload nests, plus the payload nests
    -- that land on it. An item left without impositions gets the explicit
    -- empty set (one row, imposition_id null), so it does not fall back to
    -- inheriting. The pv2 machine links belong to action.crud_object and
    -- stay untouched. Cancelled nests only leave. No plan or lane for the
    -- day: no link, never an invented lane — the backfill catches it later.
    WITH target AS (
        SELECT ns.nest_id, ns.sort_order, bi.lane_item_id
        FROM nest_link ns
        JOIN batch_item bi ON bi.lane_id = ns.lane_id AND bi.batch_key = ns.batch_key
        WHERE NOT ns.is_cancelled
          AND bi.lane_item_id IS NOT NULL
    ),
    -- the material-lane items that hold a payload nest today, plus the
    -- items the payload lands on
    touched AS (
        SELECT DISTINCT i.lane_item_id
        FROM action.imposition_lane_item i
        JOIN action.lane_item li ON li.lane_item_id = i.lane_item_id
        WHERE li.source IN ('material-plan', 'nest')
          AND i.imposition_id IN (SELECT ns.nest_id FROM nest_link ns)
          AND i.moved_at = (SELECT max(x.moved_at) FROM action.imposition_lane_item x
                            WHERE x.lane_item_id = i.lane_item_id)
        UNION
        SELECT t.lane_item_id FROM target t
    ),
    -- the current set of those items, without the payload nests
    kept AS (
        SELECT i.lane_item_id, i.imposition_id, i.sort_order
        FROM action.imposition_lane_item i
        JOIN touched t ON t.lane_item_id = i.lane_item_id
        WHERE i.imposition_id IS NOT NULL
          AND i.imposition_id NOT IN (SELECT ns.nest_id FROM nest_link ns)
          AND i.moved_at = (SELECT max(x.moved_at) FROM action.imposition_lane_item x
                            WHERE x.lane_item_id = i.lane_item_id)
    ),
    new_set AS (
        SELECT lane_item_id, imposition_id, sort_order FROM kept
        UNION ALL
        SELECT t.lane_item_id, t.nest_id, t.sort_order FROM target t
    )
    INSERT INTO action.imposition_lane_item (lane_item_id, imposition_id, sort_order)
    SELECT n.lane_item_id, n.imposition_id, n.sort_order
    FROM new_set n
    UNION ALL
    SELECT t.lane_item_id, NULL, NULL
    FROM touched t
    WHERE NOT EXISTS (SELECT 1 FROM new_set n WHERE n.lane_item_id = t.lane_item_id);

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

-- the output column follows the renamed table, so the old signature goes first
drop function if exists mock.generate_plan(date, text, text);

create function mock.generate_plan(p_date date, p_step text, p_line_type text) returns TABLE(plan_id bigint, lane_id bigint, material_impose_plan_id bigint)
	language sql
as $$
    WITH pattern AS (
        SELECT DISTINCT ON (m.sort_order)
               m.material_impose_plan_id, m.sort_order, m.material_id,
               m.start_offset_in_seconds, m.is_pinned
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

-- 5. the lookup readers and the data tables
-- The production steps, from relation.lookup / lookup_step_category
-- (json/lookup/relation/lookup_step_category.json): per step its order and
-- the status at which the step's work is done. Feeds the steps filter of the
-- resource board (resource_plan_filter): the filter reads the lookup, never a
-- copy in its config. A step added to the lookup shows up without a change.
drop function if exists relation.get_step_categories();

create function relation.get_step_categories() returns TABLE(step text, sort_order integer, done_sequence integer, done_internal_status_code text)
    stable
    language sql
as $$
    SELECT s.value ->> 'step',
           (s.value ->> 'order')::integer,
           (s.value ->> 'sequence')::integer,
           s.value ->> 'internal_status_code'
    FROM relation.lookup lk
    CROSS JOIN LATERAL jsonb_array_elements(lk.lookup_json) AS s(value)
    WHERE lk.lookup = 'lookup_step_category'
    ORDER BY (s.value ->> 'order')::integer;
$$;

alter function relation.get_step_categories() owner to xfw3;

-- The kinds of lane item rows, from action.lookup / lookup_lane_item_type
-- (json/lookup/action/lookup_lane_item_type.json): plan, progress, actual.
-- Feeds the types filter of the resource board (resource_plan_filter): the
-- filter reads the lookup, never a copy in its config.
drop function if exists action.get_lane_item_types();

create function action.get_lane_item_types() returns TABLE(type text, sort_order integer, class_names text[])
    stable
    language sql
as $$
    SELECT t.value ->> 'type',
           (t.value ->> 'sort_order')::integer,
           coalesce((SELECT array_agg(c) FROM jsonb_array_elements_text(coalesce(t.value -> 'class_names', '[]'::jsonb)) c), '{}'::text[])
    FROM action.lookup lk
    CROSS JOIN LATERAL jsonb_array_elements(lk.lookup_json) AS t(value)
    WHERE lk.lookup = 'lookup_lane_item_type'
    ORDER BY (t.value ->> 'sort_order')::integer;
$$;

alter function action.get_lane_item_types() owner to xfw3;

UPDATE site.data_table
SET data_table = 'get_resource_plan',
    query = 'action.get_resource_plan',
    description = 'get_resource_plan',
    data_table_json = '{"primary_keys": ["tenant_id", "resource_uid", "type", "lane_item_id", "start_offset_in_seconds"]}'::jsonb
WHERE data_table = 'get_production_plan';

INSERT INTO site.data_table (data_table, query, stored_proc, description, data_table_json, do_cache, forbidden_cache_param_keys)
SELECT v.data_table, v.query, '', v.data_table, NULL, false,
       '["userContactId", "userCompanyId", "hostname", "userLanguage", "config"]'::jsonb
FROM (VALUES ('get_step_categories', 'relation.get_step_categories'),
             ('get_lane_item_types', 'action.get_lane_item_types')) AS v(data_table, query)
WHERE NOT EXISTS (SELECT 1 FROM site.data_table t WHERE t.data_table = v.data_table);

-- 6. board 78 goes; 81 and 82 follow in the partial
DELETE FROM site.data_group WHERE data_group_id = 78;

COMMIT;

-- check 1: the resource board reads; expected on 2026-09-04 sheet: plan 150,
-- progress 50, actual 838 (plan and actual rows identical to the old 81)
SELECT type, count(*) AS rows, count(DISTINCT lane_item_id) AS items
FROM action.get_resource_plan('2026-09-04 10:00+02', 'sheet')
GROUP BY type ORDER BY type;

-- check 2: filters; expected: only cut lanes, and no actual rows
SELECT step, type, count(*) FROM action.get_resource_plan('2026-09-04 10:00+02', 'sheet', NULL, array['cut'], array['plan', 'progress'])
GROUP BY step, type ORDER BY step, type;

-- check 3: the labels in production-plan mode without steps; expected: one
-- row per resource lane of the day's plans (sheet: print, coat and cut lanes)
SELECT count(*) AS lanes, count(DISTINCT lane_id) AS distinct_lanes, array_agg(DISTINCT ltree2text(subpath(resource_path, 2, 1))) AS steps
FROM action.get_plan_lanes('2026-09-04 10:00+02', 'print', 'sheet', NULL, false, 'production-plan', NULL);

-- check 4: the filter sources; expected: 12 steps, 3 types
SELECT (SELECT count(*) FROM relation.get_step_categories()) AS steps,
       (SELECT count(*) FROM action.get_lane_item_types()) AS types;

-- check 5: nothing reads level any more; expected: 0
SELECT count(*) AS functions_with_level
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE p.prokind = 'f' AND n.nspname IN ('action', 'mock', 'legacy', 'site')
  AND pg_get_functiondef(p.oid) ~ '\mli2?\.level\M|\mlevel = 0\M|, level,';

-- check 6: the material boards still read; expected: rows
SELECT count(*) AS labels_76 FROM action.get_plan_lanes('2026-09-04 10:00+02', 'print', 'sheet', NULL, true, 'material-resource-plan', NULL);
SELECT count(*) AS rows_76 FROM mock.get_impose_plan('2026-09-04 10:00+02', 'print', 'sheet');
