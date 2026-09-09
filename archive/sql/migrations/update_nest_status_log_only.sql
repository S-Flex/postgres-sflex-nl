-- ============================================================
-- Besluit 6 sep: de nest-status wordt alleen via log.crud_data_log bijgewerkt
-- (legacy.sync_nest_status_from_log), nooit uit de orderregels. De
-- orderregel-regel van eerder vandaag (legacy.sync_nest_status_from_parts, de
-- aanroep in crud_data_log en de dagelijkse run in refresh_derived_data) gaat
-- eruit. De 17.526 statussen die de backfill ervan al optilde blijven staan;
-- ze zijn herkenbaar aan legacy.nest_log-regels met resource_uids = '{}'.
-- ============================================================

BEGIN;

DROP FUNCTION IF EXISTS legacy.sync_nest_status_from_parts(bigint[], date);

DROP FUNCTION IF EXISTS log.crud_data_log(jsonb, boolean);
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

  -- the nests this batch touched follow the machines: a print lifts the nest to
  -- printed, a cut to cut (legacy.sync_nest_status_from_log, lookup_step_category)
  perform legacy.sync_nest_status_from_log(
      (select array_agg(distinct e.value -> 'data' ->> 'nest_name')
       from jsonb_array_elements(p_param_json) as e(value)
       where e.value ->> 'crud' is distinct from 'delete'
         and e.value -> 'data' ->> 'nest_name' is not null))
  where exists (select 1 from jsonb_array_elements(p_param_json) as e(value)
                where e.value ->> 'crud' is distinct from 'delete'
                  and e.value -> 'data' ->> 'nest_name' is not null);

  if p_no_results then return; end if;

end;
$$;

alter function log.crud_data_log(jsonb, boolean) owner to xfw3;

DROP FUNCTION IF EXISTS site.refresh_derived_data();
create function site.refresh_derived_data() returns void
	language plpgsql
as $$
#variable_conflict use_column
begin
    -- state shift aggregation: the writers (log.crud_state_log,
    -- log.crud_data_log) keep the table current per batch; this is the
    -- daily full rebuild that finalizes yesterday and catches anything
    -- that arrived outside those two
    perform log.upsert_state_shift_agg(current_date - 1);  -- finalize yesterday
    perform log.upsert_state_shift_agg(current_date);      -- refresh today

    -- materialized views
    refresh materialized view mapping.v_resource_capacity;

    -- the material resource plan: one per workday per line type, created
    -- ahead of time — the plannable items are generated from this planning
    -- later, so the plan must exist before any item does. mock.generate_plan
    -- builds the whole set: the plan (with tenant_ids), the material lanes
    -- from the weekly pattern, plan_lane and the material link per lane.
    perform mock.generate_plan(d.date, 'print', lt.line_type)
    from (select dt.date, dt.tenants_mandatory_day_off
          from action.dates dt
          where dt.date >= current_date
            and dt.date < current_date + 14
            and not dt.is_weekend) d
    cross join (select pl.line_type,
                       array_agg(distinct pl.tenant_id order by pl.tenant_id)
                           filter (where pl.tenant_id is not null) as tenant_ids
                from relation.production_line pl
                where pl.line_type is not null
                group by pl.line_type) lt
    where not (coalesce(lt.tenant_ids, d.tenants_mandatory_day_off) <@ d.tenants_mandatory_day_off and d.tenants_mandatory_day_off <> '{}')
      and not exists (select 1 from action.plan p
                      where p.plan_date = d.date
                        and p.type = 'material-resource-plan'
                        and p.line_type = lt.line_type);
end;
$$;

alter function site.refresh_derived_data() owner to xfw3;

COMMIT;

-- check: nothing mentions the parts rule any more; expected: 0
SELECT count(*) AS functions_with_parts_rule
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE p.prokind = 'f' AND pg_get_functiondef(p.oid) ~ 'sync_nest_status_from_parts';
