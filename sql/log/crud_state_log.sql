create function log.crud_state_log(p_param_json jsonb, p_no_results boolean DEFAULT false) returns TABLE(track_by integer, crud text, state_log_id bigint, resource_uid text, state text, reason text, start_at timestamp with time zone, detail jsonb, source text, source_ref text, source_ts timestamp with time zone)
	language plpgsql
as $$
#variable_conflict use_column
declare
  rec record;
  v_data jsonb;
  v_resource text;
  v_state text;
  v_start_at timestamp with time zone;
  v_prev_id bigint;
  v_prev_state text;
  v_prev_start_at timestamp with time zone;
begin

  for rec in
    select
      e.value as value,
      lead(e.value -> 'data' ->> 'state') over w as next_state,
      lead((e.value -> 'data' ->> 'start_at')::timestamptz) over w as next_start_at
    from jsonb_array_elements(p_param_json) as e(value)
    where e.value ->> 'crud' = 'create'
    window w as (
      partition by e.value -> 'data' ->> 'resource_uid'
      order by (e.value -> 'data' ->> 'start_at')::timestamptz,
               (e.value ->> 'track_by')::integer
    )
    order by e.value -> 'data' ->> 'resource_uid',
             (e.value -> 'data' ->> 'start_at')::timestamptz,
             (e.value ->> 'track_by')::integer
  loop

    v_data := rec.value -> 'data';
    v_resource := v_data ->> 'resource_uid';
    v_state := v_data ->> 'state';
    v_start_at := (v_data ->> 'start_at')::timestamptz;

    -- transient binnen de batch: binnen 5s opgevolgd door een andere state -> nooit inserten
    if rec.next_start_at is not null
       and rec.next_state is distinct from v_state
       and rec.next_start_at - v_start_at <= interval '5 second' then
      continue;
    end if;

    -- source_ref + state already ingested: skip, do not add
    if (v_data ->> 'source_ref') is not null
       and exists (
         select 1
         from log.state s
         where s.source = v_data ->> 'source'
           and s.source_ref = v_data ->> 'source_ref'
           and s.state = v_state
       ) then
      continue;
    end if;

    -- last existing record for this resource, up to this moment
    select s.state_log_id, s.state, s.start_at
    into v_prev_id, v_prev_state, v_prev_start_at
    from log.state s
    where s.resource_uid = v_resource
      and s.start_at <= v_start_at
    order by s.start_at desc, s.state_log_id desc
    limit 1;

    -- vangnet voor de batchgrens: voorganger die alsnog een transient blijkt;
    -- na elke delete de voorganger opnieuw ophalen
    while v_prev_id is not null
      and v_state is distinct from v_prev_state
      and v_start_at - v_prev_start_at <= interval '5 second'
    loop
      delete from log.state s where s.state_log_id = v_prev_id;

      select s.state_log_id, s.state, s.start_at
      into v_prev_id, v_prev_state, v_prev_start_at
      from log.state s
      where s.resource_uid = v_resource
        and s.start_at <= v_start_at
      order by s.start_at desc, s.state_log_id desc
      limit 1;
    end loop;

    -- no state change relative to the (possibly new) predecessor: collapse
    if v_prev_id is not null and v_state is not distinct from v_prev_state then
      continue;
    end if;

    return query
    insert into log.state as s (
      resource_uid, state, reason, start_at, detail,
      source, source_ref, source_ts
    )
    values (
      v_resource,
      v_state,
      v_data ->> 'reason',
      v_start_at,
      coalesce(v_data -> 'detail', '{}'::jsonb),
      v_data ->> 'source',
      v_data ->> 'source_ref',
      (v_data ->> 'source_ts')::timestamptz
    )
    on conflict on constraint uq_state_log do nothing
    returning
      (rec.value ->> 'track_by')::integer,
      rec.value ->> 'crud',
      s.state_log_id,
      s.resource_uid,
      s.state,
      s.reason,
      s.start_at,
      s.detail,
      s.source,
      s.source_ref,
      s.source_ts;

  end loop;

  -- keep the shift aggregate current: rebuild the machine-days this batch
  -- touched. The date is the Amsterdam day of start_at, and the day before
  -- as well, because a night window of yesterday runs into today
  perform log.upsert_state_shift_agg(d.shift_date, d.resource_uids)
  from (
      select dd.shift_date,
             array_agg(distinct (e.value -> 'data' ->> 'resource_uid')) as resource_uids
      from jsonb_array_elements(p_param_json) as e(value)
      cross join lateral (
          values (((e.value -> 'data' ->> 'start_at')::timestamptz at time zone 'Europe/Amsterdam')::date),
                 (((e.value -> 'data' ->> 'start_at')::timestamptz at time zone 'Europe/Amsterdam')::date - 1)
      ) as dd(shift_date)
      where e.value ->> 'crud' = 'create'
        and e.value -> 'data' ->> 'resource_uid' is not null
        and e.value -> 'data' ->> 'start_at' is not null
      group by dd.shift_date
  ) d;

  if p_no_results then return; end if;

end;
$$;

alter function log.crud_state_log(jsonb, boolean) owner to xfw3;

