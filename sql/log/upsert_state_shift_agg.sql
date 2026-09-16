-- Rebuilds log.state_shift_agg for one date: delete-then-insert, so a state
-- that no longer applies disappears instead of lingering next to its
-- replacement.
-- Rows per shift and machine, each with the code of its shift window
-- (shift_json code: day, evening, night): the logged states, producing and starved.running
-- derived from them, planned (the pv2 items as planned) and plan_calibrated
-- (the same items timed at the machine's fastest profile speed).
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
             sh.value ->> 'code' as shift_code,
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
  -- starts in, amount x the nest size (legacy.nest width x height, cm); the
  -- customer-order area is that area less the waste of the nest
  -- (nest_json waste_percentage, 0..100)
  output as (
      select w.shift_index,
             dl.resource_uid,
             sum(dl.amount * n.width * n.height / 10000)::numeric as actual_gross_output_sqm,
             sum(dl.amount * n.width * n.height / 10000 * (1 - coalesce(n.waste_percentage, 0) / 100))::numeric as actual_net_output_sqm
      from log.data dl
      -- the size and the waste of the nest by name; the newest one when a name was reused
      join lateral (select n0.width, n0.height, (n0.nest_json ->> 'waste_percentage')::numeric as waste_percentage
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
  -- the calibrated plan: the same pv2 items, timed at the fastest profile
  -- speed of the machine for their nest size and material
  -- (log.get_resource_plan_calibrated), clipped per window. The batch
  -- function needs a resource list: null means every machine
  calibrated_items as (
      select c.resource_uid,
             c.start_at,
             c.start_at + c.duration_seconds * interval '1 second' as end_at
      from log.get_resource_plan_calibrated(
               coalesce(p_resource_uids, (select array_agg(r.resource_uid) from relation.resource r)),
               v_from,
               -- the batch function runs to the end of the day of p_until
               v_from + interval '12 hours',
               null) c
  ),
  calibrated_windowed as (
      select w.shift_index,
             w.shift_start,
             w.shift_end,
             c.resource_uid,
             sum(extract(epoch from (
                 least(c.end_at, w.shift_end) - greatest(c.start_at, w.shift_start)
             )))::numeric as duration_seconds
      from calibrated_items c
      join window_res w
        on w.resource_uid = c.resource_uid
       and c.start_at < w.shift_end
       and c.end_at   > w.shift_start
      group by w.shift_index, w.shift_start, w.shift_end, c.resource_uid
  ),
  -- the rows of the date. planned_output_sqm sits on the planned row, the
  -- two output areas on the producing row; every other row carries null.
  -- Producing is the produced time inside the logged running state; a
  -- machine that produced without a running state in the shift still gets
  -- its producing row, with 0 seconds and the area it produced
  all_rows as (
      select shift_index, shift_start, shift_end, resource_uid, state, duration_seconds,
             null::numeric as planned_output_sqm, null::numeric as actual_gross_output_sqm, null::numeric as actual_net_output_sqm
      from logged
      union all
      select l.shift_index, l.shift_start, l.shift_end, l.resource_uid,
             'producing',
             least(coalesce(p.produced_seconds, 0), l.duration_seconds),
             null, o.actual_gross_output_sqm, o.actual_net_output_sqm
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
             'producing', 0, null, o.actual_gross_output_sqm, o.actual_net_output_sqm
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
             null, null, null
      from logged l
      left join produced p
        on p.shift_index   = l.shift_index
       and p.resource_uid  = l.resource_uid
      where l.state = 'running'
      union all
      select shift_index, shift_start, shift_end, resource_uid, 'planned', duration_seconds,
             planned_output_sqm, null, null
      from plan_windowed
      union all
      select shift_index, shift_start, shift_end, resource_uid, 'plan_calibrated', duration_seconds,
             null, null, null
      from calibrated_windowed
  )
  insert into log.state_shift_agg
      (shift_date, shift_index, shift_code, resource_uid, state, shift_start, shift_end, duration_seconds,
       planned_output_sqm, actual_gross_output_sqm, actual_net_output_sqm)
  select p_date,
         a.shift_index,
         wd.shift_code,
         a.resource_uid,
         a.state,
         a.shift_start,
         a.shift_end,
         sum(a.duration_seconds),
         sum(a.planned_output_sqm),
         sum(a.actual_gross_output_sqm),
         sum(a.actual_net_output_sqm)
  from all_rows a
  join window_def wd on wd.shift_index = a.shift_index
  group by a.shift_index, wd.shift_code, a.resource_uid, a.state, a.shift_start, a.shift_end
  having sum(a.duration_seconds) > 0
      or sum(a.planned_output_sqm) > 0
      or sum(a.actual_gross_output_sqm) > 0;

  get diagnostics v_count = row_count;
  return v_count;
end;
$function$


alter function log.upsert_state_shift_agg(date, text[]) owner to xfw3;
