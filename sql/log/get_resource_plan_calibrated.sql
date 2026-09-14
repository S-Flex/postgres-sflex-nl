create function log.get_resource_plan_impact(p_resource_uids text[] DEFAULT NULL::text[], p_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_until timestamp with time zone DEFAULT now(), p_line_type text DEFAULT NULL::text) returns TABLE(resource_uid text, state jsonb, group_state jsonb, layout_name text, step text, name text, nest_name text, filename text, page_number integer, batch_id integer, batch_name text, data jsonb, start_at timestamp with time zone, offset_seconds numeric, duration_seconds numeric)
	stable
	language sql
as $$
    with profile_speed as (
        select distinct on (vc.resource_uid, vc.width, vc.height, vc.sides, vc.material_id)
            vc.resource_uid,
            vc.width,
            vc.height,
            vc.sides,
            vc.material_id,
            vc.data_json
        from mapping.v_resource_capacity vc
        where vc.is_fastest_profile
        order by vc.resource_uid, vc.width, vc.height, vc.sides, vc.material_id
    )
    select
        grpb.resource_uid,
        (select s.value
         from relation.lookup lk,
              jsonb_array_elements(lk.lookup_json)        as ss(value),
              jsonb_array_elements(ss.value -> 'states')  as s(value)
         where lk.lookup = 'lookup_resource_state'
           and s.value ->> 'code' = 'impact'
         limit 1)                                          as state,
        (select gs.value
         from relation.lookup lk,
              jsonb_array_elements(lk.lookup_json)        as gs(value)
         where lk.lookup = 'lookup_resource_group_state'
           and gs.value ->> 'code' = (
               select s.value ->> 'group'
               from relation.lookup lk2,
                    jsonb_array_elements(lk2.lookup_json)        as ss(value),
                    jsonb_array_elements(ss.value -> 'states')   as s(value)
               where lk2.lookup = 'lookup_resource_state'
                 and s.value ->> 'code' = 'impact'
               limit 1
           )
         limit 1)                                          as group_state,
        grpb.layout_name,
        grpb.step,
        grpb.name,
        grpb.nest_name,
        null::text,
        grpb.page_number,
        grpb.batch_id,
        grpb.batch_name,
        grpb.data,
        grpb.start_at,
        grpb.offset_seconds,
        sum(
            (ba ->> 'total_amount')::int
            * (ps.data_json ->> 'duration')::numeric
            * 60
        )                                                  as duration_seconds
    from log.get_resource_plan_batch(p_resource_uids, p_from, p_until, p_line_type) grpb
    join profile_speed ps
        on ps.resource_uid = grpb.resource_uid
       and ps.width = greatest(
               trunc((grpb.data ->> 'width')::numeric)::integer,
               trunc((grpb.data ->> 'height')::numeric)::integer
           )
       and ps.height = least(
               trunc((grpb.data ->> 'width')::numeric)::integer,
               trunc((grpb.data ->> 'height')::numeric)::integer
           )
       and ps.material_id = (grpb.data ->> 'material_id')::integer
    cross join jsonb_array_elements(grpb.data -> 'batched_amounts') as ba
    where (grpb.data ->> 'material_id')::int is not null
    group by
        grpb.resource_uid, grpb.layout_name, grpb.step,
        grpb.name, grpb.nest_name, grpb.page_number,
        grpb.batch_id, grpb.batch_name, grpb.data, grpb.start_at,
        grpb.offset_seconds;
$$;

alter function log.get_resource_plan_impact(text[], timestamp with time zone, timestamp with time zone, text) owner to xfw3;

