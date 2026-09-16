-- Rollback of sql/update_plan_calibrated.sql: lookup code back to impact in
-- both lookups, the function back to log.get_resource_plan_impact, the caller
-- and the aggregator the version before the change (no plan_calibrated row),
-- the plan_calibrated rows of the aggregate deleted.
BEGIN;

UPDATE relation.lookup lk
SET lookup_json = (
    SELECT jsonb_agg(
               CASE WHEN g.value ? 'states' THEN
                   jsonb_set(g.value, '{states}',
                       (SELECT jsonb_agg(
                                   CASE WHEN s.value ->> 'code' = 'plan_calibrated'
                                        THEN s.value || '{"code": "impact"}'::jsonb
                                        ELSE s.value END
                                   ORDER BY s.ordinality)
                        FROM jsonb_array_elements(g.value -> 'states') WITH ORDINALITY AS s))
               ELSE g.value END
               ORDER BY g.ordinality)
    FROM jsonb_array_elements(lk.lookup_json) WITH ORDINALITY AS g)
WHERE lk.lookup = 'lookup_resource_state';

UPDATE log.lookup lk
SET lookup_json = (
    SELECT jsonb_agg(
               CASE WHEN s.value ->> 'code' = 'plan_calibrated'
                    THEN s.value || '{"code": "impact"}'::jsonb
                    ELSE s.value END
               ORDER BY s.ordinality)
    FROM jsonb_array_elements(lk.lookup_json) WITH ORDINALITY AS s)
WHERE lk.lookup = 'lookup_resource_state';

DELETE FROM log.state_shift_agg WHERE state = 'plan_calibrated';

DROP FUNCTION IF EXISTS log.get_resource_plan_calibrated(text[], timestamp with time zone, timestamp with time zone, text);
DROP FUNCTION IF EXISTS log.get_resource_state_current(timestamp with time zone, text);

-- ============ sql/log/get_resource_plan_impact.sql (before) ============
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


-- ============ sql/log/get_resource_state_current.sql (before) ============
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


-- ============ sql/log/upsert_state_shift_agg.sql (before, start_offset version) ============
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
drop function if exists log.upsert_state_shift_agg(date, text[]);

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
  -- scan until the end of the last window: an overnight window (start
  -- plus duration past midnight) runs into the next date, so events and
  -- production after 00:00 still belong to this date's windows.
  -- greatest() ignores the null that max() returns when the date has
  -- no shift_json, so v_until then simply stays at the day end
  select greatest(v_until, max(
             (p_date::timestamp + make_interval(secs => (sh.value ->> 'start_offset')::integer
                                                      + (sh.value ->> 'shift_duration')::integer))
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
  -- Today: action.dates.shift_json — one array for the date, each shift
  -- with the tenants it is a shift of (start_offset after
  -- midnight, shift_duration seconds long). A machine belongs to the
  -- tenant of its production line and is bucketed into the shifts that
  -- name that tenant; a shift without tenants takes every machine.
  -- That column is already marked for removal (see
  -- archive/sql/migrations/migration_dates_tenants_day_off.sql section 3); a per-resource
  -- source (log.hr_shift_planning / relation.shift_registered_hours)
  -- replaces this CTE and nothing else in the function.
  -- ---------------------------------------------------------------
  window_def as (
      select sh.ordinality::integer as shift_index,
             (p_date::timestamp + make_interval(secs => (sh.value ->> 'start_offset')::integer))
                 at time zone 'Europe/Amsterdam' as shift_start,
             (p_date::timestamp + make_interval(secs => (sh.value ->> 'start_offset')::integer
                                                      + (sh.value ->> 'shift_duration')::integer))
                 at time zone 'Europe/Amsterdam' as shift_end,
             (select array_agg(t::integer) from jsonb_array_elements_text(sh.value -> 'tenants') t) as tenant_ids
      from action.dates d
      cross join lateral jsonb_array_elements(d.shift_json)
                         with ordinality as sh(value, ordinality)
      where d.date = p_date
        and d.shift_json is not null
  ),
  -- the windows per machine: the shifts that name the tenant of its
  -- production line, or every shift when the shift names no tenant
  window_res as (
      select w.shift_index, w.shift_start, w.shift_end, res.resource_uid
      from window_def w
      join relation.resource res
        on p_resource_uids is null or res.resource_uid = any (p_resource_uids)
      left join relation.production_line pl on pl.line_id = res.line_id
      where w.tenant_ids is null or pl.tenant_id = any (w.tenant_ids)
  ),
  events as (
      select s.resource_uid, s.state, s.start_at
      from log.state s
      where s.start_at >= v_from
        and s.start_at <  v_until
        and (p_resource_uids is null or s.resource_uid = any (p_resource_uids))

      union all

      -- the state each resource was in when its window opened, so a
      -- window with no events of its own is still covered
      select w.resource_uid, c.state, w.shift_start
      from window_res w
      cross join lateral (
          select s.state
          from log.state s
          where s.resource_uid = w.resource_uid
            and s.start_at <= w.shift_start
          order by s.start_at desc
          limit 1
      ) c
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
      join window_res w
        on w.resource_uid = t.resource_uid
       and t.start_at >= w.shift_start
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
      -- production time per shift: the log.data jobs (print and cut) that
      -- overlap the window, clipped to it
      select w.shift_index,
             dl.resource_uid,
             sum(extract(epoch from (
                 least(dl.start_at + dl.production_time_seconds * interval '1 second',
                       w.shift_end)
                 - greatest(dl.start_at, w.shift_start)
             )))::numeric as produced_seconds
      from log.data dl
      join window_res w
        on w.resource_uid = dl.resource_uid
       and dl.start_at < w.shift_end
       and dl.start_at + dl.production_time_seconds * interval '1 second' > w.shift_start
      where dl.production_time_seconds > 0
        and (p_resource_uids is null or dl.resource_uid = any (p_resource_uids))
      group by w.shift_index, dl.resource_uid
  ),
  -- the sheet area produced per shift: every job counts in the shift it
  -- starts in, amount x the nest size (legacy.nest width x height, cm)
  output as (
      select w.shift_index,
             dl.resource_uid,
             sum(dl.amount * n.width * n.height / 10000)::numeric as actual_output_sqm
      from log.data dl
      -- the size of the nest by name; the newest one when a name was reused
      join lateral (select n0.width, n0.height
                    from legacy.nest n0
                    where n0.nest_name = dl.nest_name
                    order by n0.nest_id desc
                    limit 1) n on true
      join window_res w
        on w.resource_uid = dl.resource_uid
       and dl.start_at >= w.shift_start
       and dl.start_at <  w.shift_end
      where dl.nest_name is not null
        and dl.amount is not null
        and (p_resource_uids is null or dl.resource_uid = any (p_resource_uids))
      group by w.shift_index, dl.resource_uid
  ),
  -- the pv2 items of the printers and cutters: their window on the machine
  -- and the sheet area they plan (batched_amounts x nest size)
  plan_items as (
      select r.resource_uid,
             ao.start_at,
             ao.start_at + (ao.action_json ->> 'duration')::numeric * interval '1 minute' as end_at,
             (select sum((ba.value ->> 'amount')::numeric * n.width * n.height / 10000)
              from jsonb_array_elements(coalesce(ao.action_json -> 'data' -> 'batched_amounts', '[]'::jsonb)) as ba(value)
              join legacy.nest n on n.nest_id = (ba.value ->> 'nest_id')::bigint
              where (ba.value ->> 'nest_id') is not null) as planned_output_sqm
      from action.object ao
      join relation.resource r
        on r.resource_json ->> 'pv2_id' = ao.action_json ->> 'resource_id'
      where ao.start_at >= v_from
        and ao.start_at <  v_until
        and ao.action_json ->> 'machine_type' in ('printer', 'cutter')
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
             )))::numeric as duration_seconds,
             -- an item's area counts in the shift it starts in
             sum(p.planned_output_sqm) filter (where p.start_at >= w.shift_start
                                                 and p.start_at <  w.shift_end) as planned_output_sqm
      from plan_items p
      join window_res w
        on w.resource_uid = p.resource_uid
       and p.start_at < w.shift_end
       and p.end_at   > w.shift_start
      group by w.shift_index, w.shift_start, w.shift_end, p.resource_uid
  ),
  -- the rows of the date. planned_output_sqm sits on the planned row,
  -- actual_output_sqm on the producing row; every other row carries null.
  -- Producing is the produced time inside the logged running state; a
  -- machine that produced without a running state in the shift still gets
  -- its producing row, with 0 seconds and the area it produced
  all_rows as (
      select shift_index, shift_start, shift_end, resource_uid, state, duration_seconds,
             null::numeric as planned_output_sqm, null::numeric as actual_output_sqm
      from logged
      union all
      select l.shift_index, l.shift_start, l.shift_end, l.resource_uid,
             'producing',
             least(coalesce(p.produced_seconds, 0), l.duration_seconds),
             null, o.actual_output_sqm
      from logged l
      left join produced p
        on p.shift_index   = l.shift_index
       and p.resource_uid  = l.resource_uid
      left join output o
        on o.shift_index   = l.shift_index
       and o.resource_uid  = l.resource_uid
      where l.state = 'running'
      union all
      select w.shift_index, w.shift_start, w.shift_end, o.resource_uid,
             'producing', 0, null, o.actual_output_sqm
      from output o
      join window_res w
        on w.shift_index = o.shift_index and w.resource_uid = o.resource_uid
      where not exists (select 1 from logged l
                        where l.shift_index = o.shift_index
                          and l.resource_uid = o.resource_uid
                          and l.state = 'running')
      union all
      -- starved.running: the machine reports running but nothing is produced
      -- behind it (waiting for an operator). Its own code, so producing +
      -- starved.running = running stays verifiable; the lookup aliases it to
      -- starved for display and counting
      select l.shift_index, l.shift_start, l.shift_end, l.resource_uid,
             'starved.running',
             greatest(l.duration_seconds - coalesce(p.produced_seconds, 0), 0),
             null, null
      from logged l
      left join produced p
        on p.shift_index   = l.shift_index
       and p.resource_uid  = l.resource_uid
      where l.state = 'running'
      union all
      select shift_index, shift_start, shift_end, resource_uid, 'planned', duration_seconds,
             planned_output_sqm, null
      from plan_windowed
  )
  insert into log.state_shift_agg
      (shift_date, shift_index, resource_uid, state, shift_start, shift_end, duration_seconds,
       planned_output_sqm, actual_output_sqm)
  select p_date,
         a.shift_index,
         a.resource_uid,
         a.state,
         a.shift_start,
         a.shift_end,
         sum(a.duration_seconds),
         sum(a.planned_output_sqm),
         sum(a.actual_output_sqm)
  from all_rows a
  group by a.shift_index, a.resource_uid, a.state, a.shift_start, a.shift_end
  having sum(a.duration_seconds) > 0
      or sum(a.planned_output_sqm) > 0
      or sum(a.actual_output_sqm) > 0;

  get diagnostics v_count = row_count;
  return v_count;
end;
$function$


alter function log.upsert_state_shift_agg(date, text[]) owner to xfw3;

COMMIT;
SELECT log.upsert_state_shift_agg(current_date - 1) AS rows_yesterday;
SELECT log.upsert_state_shift_agg(current_date)     AS rows_today;
