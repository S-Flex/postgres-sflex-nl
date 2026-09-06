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
