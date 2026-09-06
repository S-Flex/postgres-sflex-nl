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

