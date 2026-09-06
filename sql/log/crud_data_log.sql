create function log.crud_data_log(p_param_json jsonb, p_no_results boolean DEFAULT false) returns TABLE(track_by integer, crud text, data_log_id bigint, resource_uid text, filename text, nest_id integer, spec_id integer, amount numeric, sub_set text, start_at timestamp with time zone, end_at timestamp with time zone, metrics_json jsonb, source text, source_ref text, source_ts timestamp with time zone, nest_name text, production_time_seconds integer, page_number integer, data_json jsonb)
	language plpgsql
as $$
#variable_conflict use_column
declare
  rec jsonb;
  v_data jsonb;
  v_param integer;
begin

  for rec in
    select value from jsonb_array_elements(p_param_json) as e(value)
    where e.value ->> 'crud' is distinct from 'delete'
  loop

    v_data := rec -> 'data';

    v_param := case when v_data ->> 'step' = 'print'
                    then legacy.get_print_duration_according_to_specs(v_data ->> 'resource_uid', v_data ->> 'nest_name')::integer
                    else null
               end;

    return query
    insert into log.data as d (
      resource_uid, filename, nest_id, spec_id, amount, sub_set,
      start_at, end_at, metrics_json,
      source, source_ref, source_ts,
      nest_name, production_time_seconds, page_number, step, data_json
    )
    values (
      v_data ->> 'resource_uid',
      v_data ->> 'filename',
      (v_data ->> 'nest_id')::int,
      (v_data ->> 'spec_id')::int,
      nullif(v_data ->> 'amount', '')::numeric,
      v_data ->> 'sub_set',
      (v_data ->> 'start_at')::timestamptz,
      (v_data ->> 'end_at')::timestamptz,
      coalesce(v_data -> 'metrics_json', '[]'::jsonb),
      v_data ->> 'source',
      v_data ->> 'source_ref',
      (v_data ->> 'source_ts')::timestamptz,
      v_data ->> 'nest_name',
      coalesce(v_param, nullif(v_data ->> 'production_time_seconds', '')::integer),
      (v_data ->> 'page_number')::integer,
      v_data ->> 'step',
      v_data -> 'data_json'
    )
    on conflict (source, source_ref) where source_ref is not null do update set
      end_at = coalesce(excluded.end_at, d.end_at),
      metrics_json = excluded.metrics_json,
      nest_name = coalesce(excluded.nest_name, d.nest_name),
      production_time_seconds = coalesce(excluded.production_time_seconds, d.production_time_seconds),
      page_number = coalesce(excluded.page_number, d.page_number),
      step = coalesce(excluded.step, d.step),
      source_ts = coalesce(excluded.source_ts, d.source_ts),
      data_json = coalesce(excluded.data_json, d.data_json)
    returning
      (rec ->> 'track_by')::integer,
      rec ->> 'crud',
      d.data_log_id,
      d.resource_uid,
      d.filename,
      d.nest_id,
      d.spec_id,
      d.amount,
      d.sub_set,
      d.start_at,
      d.end_at,
      d.metrics_json,
      d.source,
      d.source_ref,
      d.source_ts,
      d.nest_name,
      d.production_time_seconds,
      d.page_number,
      d.data_json;

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
      where e.value ->> 'crud' is distinct from 'delete'
        and e.value -> 'data' ->> 'resource_uid' is not null
        and e.value -> 'data' ->> 'start_at' is not null
      group by dd.shift_date
  ) d;

  if p_no_results then return; end if;

end;
$$;

alter function log.crud_data_log(jsonb, boolean) owner to xfw3;

