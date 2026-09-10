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
