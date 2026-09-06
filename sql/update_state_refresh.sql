-- ============================================================
-- Update: log.state_shift_agg stays current after every batch. The builder
-- log.upsert_state_shift_agg gets a resource scope (p_resource_uids) and an
-- advisory lock per date; log.crud_state_log and log.crud_data_log end with
-- a rebuild of the machine-days they touched (day of start_at and the day
-- before); site.refresh_derived_data keeps the daily full rebuild.
-- Generated from the four mirrors in sql/log and sql/site.
-- ============================================================

BEGIN;

drop function if exists log.crud_state_log(jsonb, boolean);
drop function if exists log.crud_data_log(jsonb, boolean);
drop function if exists site.refresh_derived_data();

-- Rebuilds log.state_shift_agg for one date: delete-then-insert, so a state
-- that no longer applies disappears instead of lingering next to its
-- replacement.
--
-- p_resource_uids null rebuilds every resource of the date (the daily run in
-- site.refresh_derived_data). With a list only those resources are rebuilt:
-- that is how log.crud_state_log and log.crud_data_log keep the table
-- current after every batch, one machine-day at a time. One advisory lock
-- per date serialises the two: a batch from Zünd and one from Durst, or a
-- batch next to the daily run, never race on the same rows.
drop function if exists log.upsert_state_shift_agg(date);

create function log.upsert_state_shift_agg(p_date date DEFAULT (CURRENT_DATE - 1), p_resource_uids text[] DEFAULT NULL::text[])
 RETURNS integer
 LANGUAGE plpgsql
AS $function$
#variable_conflict use_column
declare
  v_from  timestamptz := p_date::timestamp at time zone 'Europe/Amsterdam';
  v_until timestamptz := (p_date + 1)::timestamp at time zone 'Europe/Amsterdam';
  v_count integer;
begin
  -- scan until the end of the last window: an overnight window
  -- (end_time <= start_time, +1 day) runs past midnight, so events and
  -- production after 00:00 still belong to this date's windows.
  -- greatest() ignores the null that max() returns when the date has
  -- no shift_json, so v_until then simply stays at the day end
  select greatest(v_until, max(
             (p_date + (sh.value ->> 'end_time')::time
                     + case when (sh.value ->> 'end_time')::time
                                 <= (sh.value ->> 'start_time')::time
                            then interval '1 day' else interval '0' end)
                 at time zone 'Europe/Amsterdam'))
    into v_until
  from action.dates d
  cross join lateral jsonb_array_elements(d.shift_json) as sh(value)
  where d.date = p_date
    and d.shift_json is not null;

  -- one writer per date at a time (released at commit)
  perform pg_advisory_xact_lock(hashtext('log.state_shift_agg'), p_date - date '2000-01-01');

  -- the date is rebuilt for the resources in scope, so a state that no
  -- longer applies disappears instead of lingering next to its replacement
  delete from log.state_shift_agg
  where shift_date = p_date
    and (p_resource_uids is null or resource_uid = any (p_resource_uids));

  with
  -- ---------------------------------------------------------------
  -- SWAP POINT: the windows this date is bucketed into.
  -- Today: action.dates.shift_json — one definition for every
  -- resource. That column is already marked for removal (see
  -- sql/migration_dates_tenants_day_off.sql section 3); a per-resource
  -- source (relation.shift_planning / relation.shift_registered_hours)
  -- replaces this CTE and nothing else in the function.
  -- ---------------------------------------------------------------
  window_def as (
      select sh.ordinality::integer as shift_index,
             (p_date + (sh.value ->> 'start_time')::time)
                 at time zone 'Europe/Amsterdam' as shift_start,
             (p_date + (sh.value ->> 'end_time')::time
                     + case when (sh.value ->> 'end_time')::time
                                 <= (sh.value ->> 'start_time')::time
                            then interval '1 day' else interval '0' end)
                 at time zone 'Europe/Amsterdam' as shift_end
      from action.dates d
      cross join lateral jsonb_array_elements(d.shift_json)
                         with ordinality as sh(value, ordinality)
      where d.date = p_date
        and d.shift_json is not null
  ),
  events as (
      select s.resource_uid, s.state, s.start_at
      from log.state s
      where s.start_at >= v_from
        and s.start_at <  v_until
        and (p_resource_uids is null or s.resource_uid = any (p_resource_uids))

      union all

      -- the state each resource was in when the window opened, so a
      -- window with no events of its own is still covered
      select res.resource_uid, c.state, w.shift_start
      from relation.resource res
      cross join window_def w
      cross join lateral (
          select s.state
          from log.state s
          where s.resource_uid = res.resource_uid
            and s.start_at <= w.shift_start
          order by s.start_at desc
          limit 1
      ) c
      where p_resource_uids is null or res.resource_uid = any (p_resource_uids)
  ),
  timeline as (
      select e.resource_uid,
             e.state,
             e.start_at,
             lead(e.start_at, 1, v_until)
                 over (partition by e.resource_uid order by e.start_at) as end_at
      from events e
  ),
  -- everything log.state itself reports, clipped to its window
  logged as (
      select w.shift_index,
             w.shift_start,
             w.shift_end,
             t.resource_uid,
             t.state,
             sum(extract(epoch from (least(t.end_at, w.shift_end) - t.start_at)))::numeric
                 as duration_seconds
      from timeline t
      join window_def w
        on t.start_at >= w.shift_start
       and t.start_at <  w.shift_end
      group by w.shift_index, w.shift_start, w.shift_end, t.resource_uid, t.state
  ),
  -- measured production time inside the same windows. The production is
  -- spread over [start_at, start_at + production_time_seconds] and clipped
  -- per window: booking the full amount at start_at (the old behaviour)
  -- spilled 133 h in 14 days into the wrong shift whenever a job crossed
  -- the boundary, and that excess then vanished against the least() cap.
  -- end_at is not used: 2.172 of 44.595 rows have production_time_seconds
  -- beyond their wall time.
  produced as (
      select w.shift_index,
             dl.resource_uid,
             sum(extract(epoch from (
                 least(dl.start_at + dl.production_time_seconds * interval '1 second',
                       w.shift_end)
                 - greatest(dl.start_at, w.shift_start)
             )))::numeric as produced_seconds
      from log.data dl
      join window_def w
        on dl.start_at < w.shift_end
       and dl.start_at + dl.production_time_seconds * interval '1 second' > w.shift_start
      where dl.production_time_seconds > 0
        and (p_resource_uids is null or dl.resource_uid = any (p_resource_uids))
      group by w.shift_index, dl.resource_uid
  ),
  -- planning: estimated production time. Printers only, matched on
  -- pv2_id; a plan item that crosses a window boundary is clipped so
  -- each window gets its own share
  plan_items as (
      select r.resource_uid,
             ao.start_at,
             ao.start_at + (ao.action_json ->> 'duration')::numeric * interval '1 minute' as end_at
      from action.object ao
      join relation.resource r
        on r.resource_json ->> 'pv2_id' = ao.action_json ->> 'resource_id'
      where ao.start_at >= v_from
        and ao.start_at <  v_until
        and ao.action_json ->> 'machine_type' = 'printer'
        and (ao.action_json ->> 'type') <> 'interruption'
        and (p_resource_uids is null or r.resource_uid = any (p_resource_uids))
  ),
  plan_windowed as (
      select w.shift_index,
             w.shift_start,
             w.shift_end,
             p.resource_uid,
             sum(extract(epoch from (
                 least(p.end_at, w.shift_end) - greatest(p.start_at, w.shift_start)
             )))::numeric as duration_seconds
      from plan_items p
      join window_def w
        on p.start_at < w.shift_end
       and p.end_at   > w.shift_start
      group by w.shift_index, w.shift_start, w.shift_end, p.resource_uid
  ),
  all_rows as (
      select shift_index, shift_start, shift_end, resource_uid, state, duration_seconds
      from logged

      union all

      -- producing: the measured part of the running envelope
      select l.shift_index, l.shift_start, l.shift_end, l.resource_uid,
             'producing',
             least(coalesce(p.produced_seconds, 0), l.duration_seconds)
      from logged l
      left join produced p
        on p.shift_index   = l.shift_index
       and p.resource_uid  = l.resource_uid
      where l.state = 'running'

      union all

      -- starved.running: the machine reports running but nothing is
      -- produced behind it — waiting (for an operator). Its own code so
      -- producing + starved.running = running stays verifiable; the
      -- lookup aliases it to starved for display and counting.
      -- LEFT join: running with zero log.data rows must become
      -- starved.running in full — an inner join would leave that time
      -- in no bucket at all
      select l.shift_index, l.shift_start, l.shift_end, l.resource_uid,
             'starved.running',
             greatest(l.duration_seconds - coalesce(p.produced_seconds, 0), 0)
      from logged l
      left join produced p
        on p.shift_index   = l.shift_index
       and p.resource_uid  = l.resource_uid
      where l.state = 'running'

      union all

      select shift_index, shift_start, shift_end, resource_uid, 'planned', duration_seconds
      from plan_windowed
  )
  insert into log.state_shift_agg
      (shift_date, shift_index, resource_uid, state, shift_start, shift_end, duration_seconds)
  select p_date,
         a.shift_index,
         a.resource_uid,
         a.state,
         a.shift_start,
         a.shift_end,
         sum(a.duration_seconds)
  from all_rows a
  group by a.shift_index, a.resource_uid, a.state, a.shift_start, a.shift_end
  having sum(a.duration_seconds) > 0;

  get diagnostics v_count = row_count;
  return v_count;
end;
$function$


alter function log.upsert_state_shift_agg(date, text[]) owner to xfw3;

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

-- check 1: the builder has its scope; expected: one row with two arguments
SELECT pg_get_function_identity_arguments(p.oid) AS args
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'log' AND p.proname = 'upsert_state_shift_agg';

-- check 2: a scoped rebuild of one machine-day is idempotent and touches
-- nothing else. Run the three statements one after the other; expected:
-- rows_before = rows_after, and the rebuilt count equals that machine's rows
SELECT resource_uid, count(*) AS rows_before
FROM log.state_shift_agg
WHERE shift_date = current_date
GROUP BY resource_uid ORDER BY resource_uid LIMIT 1;

SELECT log.upsert_state_shift_agg(current_date, array[(SELECT resource_uid FROM log.state_shift_agg
                                                        WHERE shift_date = current_date
                                                        ORDER BY resource_uid LIMIT 1)]) AS rows_rebuilt;

SELECT count(*) AS rows_after_all_resources
FROM log.state_shift_agg
WHERE shift_date = current_date;
