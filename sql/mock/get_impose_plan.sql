-- renamed from mock.get_nest_schedule (via get_imposition_plan); impose is
-- the step, imposition the object it produces
drop function if exists mock.get_nest_schedule(timestamp with time zone, text, text, integer[], boolean, integer, integer, integer);
drop function if exists mock.get_nest_schedule(timestamp with time zone, text, text, integer[], integer, integer, integer);
drop function if exists mock.get_imposition_plan(timestamp with time zone, text, text, integer[], integer, integer, integer);
drop function if exists mock.get_impose_plan(timestamp with time zone, text, text, integer[], boolean, integer, integer, integer);
drop function if exists mock.get_impose_plan(timestamp with time zone, text, text, integer[], integer, integer, integer);

create function mock.get_impose_plan(p_until timestamp with time zone DEFAULT now(), p_step text DEFAULT 'print'::text, p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_look_back_days integer DEFAULT 0, p_look_ahead_days integer DEFAULT 0, p_domain_id integer DEFAULT 1) returns TABLE(material_id integer, material_name text, production_line_id integer, tenant_id integer, tenant_name text, production_company_id integer, resource_uid text, resource_name text, resource_path ltree, delivery_hours integer, min_delivery_hours integer, sort_order numeric, param_json jsonb, formula jsonb, data jsonb, fixed_group text, is_pinned boolean, start_offset_in_seconds integer, next_start_offset_in_seconds integer, duration_in_seconds integer, nest_date date, orderline_count integer, product_amount numeric, part_amount integer, amount numeric, sqm numeric, forecast_sqm numeric, rework_count integer, rework_sqm numeric, impact_json jsonb, gross_sqm numeric, part_status_json jsonb, nest_ids bigint[], nest_count integer, seconds_to_logistics_date integer, class_names text[], unit_class_names text[], lane_item_id bigint, lane_id bigint)
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
begin
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
        -- the nests hung on this planned moment, if any: per lane item,
        -- not per lane — every extra moment carries its own nests. The
        -- reader gives the current set, inherited or own
        select b2.lane_item_id, array_agg(distinct x.imposition_id) as nest_ids
        from (select distinct lane_item_id from base where lane_item_id is not null) b2
        cross join lateral action.get_lane_item_impositions(b2.lane_item_id) x
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
           || jsonb_build_object('net_sqm', coalesce(r.sqm, 0)) as param_json,
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
           coalesce(r.class_names, '{}'::text[]),
           coalesce(r.unit_class_names, '{}'::text[]),
           r.lane_item_id, r.lane_id
    from row_data r
    left join tenant t on t.tenant_id = r.tenant_id
    order by r.tenant_id, r.sort_order;
end;
$$;

alter function mock.get_impose_plan(timestamp with time zone, text, text, integer[], integer, integer, integer) owner to xfw3;

-- the board query is planned per call and inlines the aggregate; JIT compiling
-- it costs seconds and never pays back
alter function mock.get_impose_plan(timestamp with time zone, text, text, integer[], integer, integer, integer) set jit = off;
