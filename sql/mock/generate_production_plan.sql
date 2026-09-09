drop function if exists mock.generate_production_plan(date, text, text);

create function mock.generate_production_plan(p_date date, p_step text DEFAULT 'print'::text, p_line_type text DEFAULT 'sheet'::text) returns TABLE(plan_id bigint, lane_id bigint, sort_order numeric)
	language plpgsql
as $$
#variable_conflict use_column
declare
    v_plan_id bigint;
begin
    -- A production plan for one day and one step. Lanes are machine-days:
    -- created once per machine per day, then hung under this plan; a lane
    -- another plan already made is reused (archive/docs/plan-production-schedule.md).
    insert into action.plan (plan_date, steps, type, line_type)
    values (p_date, array[p_step], 'production-plan', p_line_type)
    returning plan_id into v_plan_id;

    -- ensure the machine-day lane of every active resource of the step: the
    -- lane and its resource_lane row, ids drawn up front so the two inserts
    -- pair without a temp table
    with missing as (
        select r.resource_path, r.step,
               nextval(pg_get_serial_sequence('action.lane', 'lane_id')) as lane_id
        from relation.resource r
        join relation.production_line pl on pl.line_id = r.line_id
        where r.active and r.resource_path is not null
          and r.step = p_step and pl.line_type = p_line_type
          and not exists (select 1
                          from action.lane l
                          join action.resource_lane rl on rl.lane_id = l.lane_id
                          where l.lane_date = p_date and rl.resource_path = r.resource_path)
    ),
    new_lane as (
        insert into action.lane (lane_id, lane_date, step, resource_path)
        overriding system value
        select m.lane_id, p_date, m.step, m.resource_path from missing m
        returning lane_id
    )
    insert into action.resource_lane (lane_id, resource_path)
    select m.lane_id, m.resource_path from missing m;

    -- hang them under the plan, in the order the resources carry
    return query
    insert into action.plan_lane (plan_id, lane_id, sort_order)
    select v_plan_id, l.lane_id,
           row_number() over (order by (r.resource_json ->> 'pv2_order')::numeric nulls last, r.resource_name)::numeric
    from relation.resource r
    join relation.production_line pl on pl.line_id = r.line_id
    join action.resource_lane rl on rl.resource_path = r.resource_path
    join action.lane l on l.lane_id = rl.lane_id and l.lane_date = p_date
    where r.active and r.resource_path is not null
      and r.step = p_step and pl.line_type = p_line_type
    returning plan_id, lane_id, sort_order;
end;
$$;

alter function mock.generate_production_plan(date, text, text) owner to xfw3;
