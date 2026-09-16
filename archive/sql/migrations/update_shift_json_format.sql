-- The shift format of action.dates.shift_json changed on 8 September 2026:
--   [{"tenants": [1, 2], "start_time": "06:00", "shift_duration": 32400,
--     "start_offset_in_seconds": 21600}, ...]
-- The two readers still took end_time, so the shift end was null: the OEE
-- formula failed (boards 29 and 62) and log.state_shift_agg has no rows after
-- 6 September.
--
-- 1. log.upsert_state_shift_agg: a window starts start_offset_in_seconds after
--    midnight and lasts shift_duration seconds. A machine is bucketed into the
--    shifts that name the tenant of its production line; a shift without
--    tenants takes every machine.
-- 2. log.get_resource_state_shift_totals: the same window rule, and only the
--    shifts and machines of p_tenant_ids.
-- 3. Rebuild log.state_shift_agg for the days without rows: 7 September up to
--    today. One notice per day with the rows written.
BEGIN;

-- ============ sql/log/upsert_state_shift_agg.sql ============
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
             (p_date::timestamp + make_interval(secs => (sh.value ->> 'start_offset_in_seconds')::integer
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
  -- with the tenants it is a shift of (start_offset_in_seconds after
  -- midnight, shift_duration seconds long). A machine belongs to the
  -- tenant of its production line and is bucketed into the shifts that
  -- name that tenant; a shift without tenants takes every machine.
  -- That column is already marked for removal (see
  -- archive/sql/migrations/migration_dates_tenants_day_off.sql section 3); a per-resource
  -- source (relation.shift_planning / relation.shift_registered_hours)
  -- replaces this CTE and nothing else in the function.
  -- ---------------------------------------------------------------
  window_def as (
      select sh.ordinality::integer as shift_index,
             (p_date::timestamp + make_interval(secs => (sh.value ->> 'start_offset_in_seconds')::integer))
                 at time zone 'Europe/Amsterdam' as shift_start,
             (p_date::timestamp + make_interval(secs => (sh.value ->> 'start_offset_in_seconds')::integer
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
      join window_res w
        on w.resource_uid = p.resource_uid
       and p.start_at < w.shift_end
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

-- ============ sql/log/get_resource_state_shift_totals.sql ============
-- same signature, dropped first so the script re-runs
drop function if exists log.get_resource_state_shift_totals(text[], timestamp with time zone, integer, text, text[], boolean, boolean, boolean, text, integer[]);

create function log.get_resource_state_shift_totals(p_resource_uids text[] DEFAULT NULL::text[], p_until timestamp with time zone DEFAULT CURRENT_TIMESTAMP, p_days integer DEFAULT 42, p_line_type text DEFAULT NULL::text, p_states text[] DEFAULT NULL::text[], p_include_weekends boolean DEFAULT true, p_include_mandatory_days_off boolean DEFAULT false, p_include_shifts boolean DEFAULT true, p_group_by text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[]) returns TABLE(shift_date date, shift_index integer, shift_start timestamp with time zone, shift_end timestamp with time zone, resource_uid text, resource_name text, tenant_name text, resource_uids jsonb, line text, step text, state text, state_json jsonb, counts_as text, duration_seconds numeric, duration_percentage numeric, param_json jsonb, oee_json jsonb, count_resources integer, sort_order integer)
	stable
	language plpgsql
as $$
#variable_conflict use_column
declare
  v_lookup_json jsonb;
  v_step_category_json jsonb;
  -- p_until is an exclusive instant: midnight belongs to the day before it,
  -- so the end of friday (saturday 00:00) shows friday, not an empty saturday
  v_until date := ((p_until - interval '1 second') at time zone 'Europe/Amsterdam')::date;
  v_all_resources boolean := (p_resource_uids is null or array_length(p_resource_uids, 1) is null);
  v_group_by text := coalesce(p_group_by, case when v_all_resources then 'step' else 'resource' end);
  v_keep_resource boolean;
  -- the steps that carry OEE for now; the other machines stay out of the
  -- totals whatever the caller asks. A lookup later
  v_oee_steps constant text[] := array['print', 'cut'];
  v_keep_step boolean;
  -- the OEE formulas. The bucket totals (counts_as in
  -- lookup_resource_state) go into param_json per group and
  -- evaluate_many_nas runs these lines over them. The not-producing
  -- bucket (idle, starved, blocked) sits inside production_in_seconds
  -- without being summed: that is the loss the OEE measures. Every time
  -- is in seconds, the frontend formats them as hh:mm
  v_formula_json jsonb := jsonb_build_array(
      'unavailable_in_seconds = breakdown_in_seconds + offline_in_seconds',
      'production_in_seconds = total_shift_in_seconds - unavailable_in_seconds',
      -- the tooltip rest value: unavailable time not already shown as
      -- its own area (breakdown/offline selected in the filter), so it
      -- is never counted twice
      'unavailable_rest_in_seconds = max(unavailable_in_seconds - shown_unavailable_in_seconds, 0)',
      -- the middle band of the chart: the production window minus
      -- producing and minus the losses drawn as their own area
      -- (starved, blocked, idle when selected). Bottom producing, then
      -- available, unavailable always on top; a selected loss moves
      -- out of available, a selected breakdown/offline out of unavailable
      'available_in_seconds = max(production_in_seconds - producing_in_seconds - shown_loss_in_seconds, 0)',
      -- percentages are 0-100, like every *_percentage in the database
      'producing_oee = production_in_seconds > 0 ? producing_in_seconds / production_in_seconds * 100 : 0',
      'breakdown_percentage = total_shift_in_seconds > 0 ? breakdown_in_seconds / total_shift_in_seconds * 100 : 0',
      'offline_percentage = total_shift_in_seconds > 0 ? offline_in_seconds / total_shift_in_seconds * 100 : 0',
      'planned_percentage = total_shift_in_seconds > 0 ? planned_in_seconds / total_shift_in_seconds * 100 : 0');
begin
  if v_group_by not in ('resource', 'step', 'line') then
    raise exception 'invalid p_group_by %, expected one of: resource, step, line', v_group_by;
  end if;

  v_keep_resource := (v_group_by = 'resource');
  v_keep_step     := (v_group_by in ('resource', 'step'));

  if v_all_resources then
    select array_agg(res.resource_uid)
    into p_resource_uids
    from relation.resource res
    left join relation.production_line pl on pl.line_id = res.line_id
    where p_line_type is null or pl.line_type = p_line_type;
  end if;

  -- only the machines of the OEE steps, asked for or not, and only the
  -- machines of the tenants asked for: a machine belongs to the tenant of
  -- its production line
  select array_agg(res.resource_uid)
  into p_resource_uids
  from relation.resource res
  left join relation.production_line pl on pl.line_id = res.line_id
  where res.resource_uid = any(p_resource_uids)
    and res.step = any(v_oee_steps)
    and (p_tenant_ids is null or pl.tenant_id = any(p_tenant_ids));

  -- the flat lookup with counts_as lives in log.lookup for now;
  -- relation.lookup keeps the old nested form until every reader
  -- has moved over
  select lk.lookup_json into v_lookup_json
  from log.lookup lk where lk.lookup = 'lookup_resource_state' limit 1;

  select lk.lookup_json into v_step_category_json
  from relation.lookup lk where lk.lookup = 'lookup_step_category' limit 1;

  return query
  with
  -- flat lookup: one node per state; alias_of resolves a source
  -- variant (starved.operator, blocked.operator) to the state it is
  state_map as (
    select s.value ->> 'code'                                          as state_code,
           coalesce(t.value ->> 'code', s.value ->> 'code')            as effective_code,
           coalesce(t.value, s.value)                                  as state_json,
           coalesce((t.value ->> 'order')::int, (s.value ->> 'order')::int) as state_order,
           coalesce(t.value ->> 'counts_as', s.value ->> 'counts_as')  as counts_as
    from jsonb_array_elements(v_lookup_json) as s(value)
    left join jsonb_array_elements(v_lookup_json) as t(value)
      on t.value ->> 'code' = s.value ->> 'alias_of'
  ),
  step_order as (
    select so.value ->> 'step' as step, (so.value ->> 'order')::int as step_order
    from jsonb_array_elements(v_step_category_json) as so(value)
  ),
  -- the days shown: the last p_days dates on or before the day of p_until
  -- that count (weekends and mandatory days off only when asked). Counted
  -- in shown days, not calendar days: with weekends excluded, one day asked
  -- on a saturday is the friday, not an empty window
  days as (
    select d.date, d.shift_json
    from action.dates d
    where d.date <= v_until
      and (p_include_weekends or not d.is_weekend)
      and (p_include_mandatory_days_off or not (coalesce(p_tenant_ids, d.tenants_mandatory_day_off) <@ d.tenants_mandatory_day_off and d.tenants_mandatory_day_off <> '{}'))
    order by d.date desc
    limit p_days
  ),
  resources as (
    select res.resource_uid, res.resource_name, res.step, pl.line, pl.tenant_id
    from relation.resource res
    left join relation.production_line pl on pl.line_id = res.line_id
    where res.resource_uid = any(p_resource_uids)
  ),
  -- the shifts of a date (action.dates.shift_json): each one starts
  -- start_offset_in_seconds after midnight and lasts shift_duration seconds,
  -- so an overnight shift needs no special case, and names the tenants it
  -- is a shift of. shift_index is the position in the array, the same
  -- index log.upsert_state_shift_agg buckets with. Only the shifts of the
  -- tenants asked for count
  shift_def as (
    select d.date as shift_date,
           sh.idx::int as shift_index,
           (d.date::timestamp + make_interval(secs => (sh.value ->> 'start_offset_in_seconds')::integer))
             at time zone 'Europe/Amsterdam' as shift_start,
           (d.date::timestamp + make_interval(secs => (sh.value ->> 'start_offset_in_seconds')::integer
                                                    + (sh.value ->> 'shift_duration')::integer))
             at time zone 'Europe/Amsterdam' as shift_end,
           (select array_agg(t::integer) from jsonb_array_elements_text(sh.value -> 'tenants') t) as tenant_ids
    from days d
    cross join lateral jsonb_array_elements(d.shift_json) with ordinality as sh(value, idx)
    where p_tenant_ids is null
       or not (sh.value ? 'tenants')
       or exists (select 1 from jsonb_array_elements_text(sh.value -> 'tenants') t
                  where t::integer = any(p_tenant_ids))
  ),
  -- a shift applies to a machine when it names the machine's tenant; a
  -- shift without tenants applies to every machine
  shift_resource as (
    select sd.shift_date, sd.shift_index, sd.shift_start, sd.shift_end,
           r.resource_uid, r.resource_name, r.line, r.step
    from shift_def sd
    join resources r
      on sd.tenant_ids is null or r.tenant_id = any(sd.tenant_ids)
  ),
  actual as (
    select agg.shift_date, agg.shift_index, agg.shift_start, agg.shift_end,
           agg.resource_uid, res.resource_name, pl.line, res.step,
           coalesce(sm.effective_code, agg.state) as state,
           sum(agg.duration_seconds)::numeric as seconds
    from log.state_shift_agg agg
    join relation.resource res on res.resource_uid = agg.resource_uid
    left join relation.production_line pl on pl.line_id = res.line_id
    join days d on d.date = agg.shift_date
    left join state_map sm on sm.state_code = agg.state
    where agg.resource_uid = any(p_resource_uids)
      -- running is the envelope of producing + starved.running: never a
      -- row of its own, it would count that time twice
      and agg.state <> 'running'
    group by agg.shift_date, agg.shift_index, agg.shift_start, agg.shift_end,
             agg.resource_uid, res.resource_name, pl.line, res.step,
             coalesce(sm.effective_code, agg.state)
  ),
  events as (
    select shift_date, shift_index, shift_start, shift_end,
           resource_uid, resource_name, line, step, state, seconds
    from actual
    union all
    -- a resource with no rows in a shift still gets the full window as
    -- idle, so the group stays visible and its OEE reads 0
    select sr.shift_date, sr.shift_index, sr.shift_start, sr.shift_end,
           sr.resource_uid, sr.resource_name, sr.line, sr.step, 'idle',
           extract(epoch from (sr.shift_end - sr.shift_start))::numeric
    from shift_resource sr
    where not exists (
      select 1 from actual a
      where a.resource_uid = sr.resource_uid
        and a.shift_date = sr.shift_date
        and a.shift_index = sr.shift_index
    )
  ),
  base as (
    select e.shift_date,
           case when p_include_shifts then e.shift_index else null::int end as shift_index,
           case when v_keep_resource then e.resource_uid else null::text end as resource_uid,
           case when v_keep_resource then e.resource_name else null::text end as resource_name,
           e.line,
           case when v_keep_step then e.step else null::text end as step,
           e.state,
           sum(e.seconds)::numeric as seconds,
           min(e.shift_start) as shift_start,
           max(e.shift_end) as shift_end
    from events e
    group by e.shift_date,
             case when p_include_shifts then e.shift_index else null::int end,
             case when v_keep_resource then e.resource_uid else null::text end,
             case when v_keep_resource then e.resource_name else null::text end,
             e.line,
             case when v_keep_step then e.step else null::text end,
             e.state
  ),
  -- the denominator: window length times the machines the shift applies
  -- to, from the shift definition alone — never from what happens to be
  -- logged
  totals as (
    select sr.shift_date,
           case when p_include_shifts then sr.shift_index else null::int end as shift_index,
           case when v_keep_resource then sr.resource_uid else null::text end as resource_uid,
           case when v_keep_resource then sr.resource_name else null::text end as resource_name,
           case when v_keep_step then sr.step else null::text end as step,
           sr.line,
           min(sr.shift_start) as shift_start,
           max(sr.shift_end) as shift_end,
           sum(extract(epoch from (sr.shift_end - sr.shift_start)))::numeric as total_seconds,
           count(distinct sr.resource_uid)::integer as count_resources
    from shift_resource sr
    group by sr.shift_date,
             case when p_include_shifts then sr.shift_index else null::int end,
             case when v_keep_resource then sr.resource_uid else null::text end,
             case when v_keep_resource then sr.resource_name else null::text end,
             case when v_keep_step then sr.step else null::text end,
             sr.line
  ),
  -- the filter selects series (set_field = counts_as in the chart): a
  -- state is drawn when its own code or its bucket is selected, so
  -- 'producing' draws setup too and 'offline' draws missingdata
  bucket_sums as (
    select b.shift_date, b.shift_index, b.resource_uid, b.step, b.line,
           sum(b.seconds) filter (where sm.counts_as = 'producing') as producing_seconds,
           sum(b.seconds) filter (where sm.counts_as = 'breakdown') as breakdown_seconds,
           sum(b.seconds) filter (where sm.counts_as = 'offline')   as offline_seconds,
           sum(b.seconds) filter (where sm.counts_as = 'planned')   as planned_seconds,
           -- the losses (the not-producing bucket) drawn as their own
           -- area: they move out of the available band
           sum(b.seconds) filter (where sm.counts_as = 'not-producing'
                                    and (p_states is null or b.state = any(p_states)
                                         or sm.counts_as = any(p_states))) as shown_loss_seconds,
           -- the unavailable time drawn as its own area: it moves out of
           -- the unavailable rest on top, so it is never counted twice
           sum(b.seconds) filter (where sm.counts_as in ('breakdown', 'offline')
                                    and (p_states is null or b.state = any(p_states)
                                         or sm.counts_as = any(p_states))) as shown_unavailable_seconds
    from base b
    left join state_map sm on sm.state_code = b.state
    group by b.shift_date, b.shift_index, b.resource_uid, b.step, b.line
  ),
  oee as (
    select t.shift_date, t.shift_index, t.resource_uid, t.resource_name,
           t.step, t.line, t.shift_start, t.shift_end,
           t.total_seconds, t.count_resources,
           -- unavailable time not already shown as its own area: its own
           -- synthetic state row at the top of the stack
           greatest(coalesce(bs.breakdown_seconds, 0) + coalesce(bs.offline_seconds, 0)
                    - coalesce(bs.shown_unavailable_seconds, 0), 0) as unavailable_rest_seconds,
           -- the middle band of the chart: production window minus
           -- producing minus the losses drawn as their own area (same as
           -- available_in_seconds in v_formula_json)
           greatest(t.total_seconds
                    - coalesce(bs.breakdown_seconds, 0) - coalesce(bs.offline_seconds, 0)
                    - coalesce(bs.producing_seconds, 0)
                    - coalesce(bs.shown_loss_seconds, 0), 0) as available_seconds,
           ev.param_json,
           public.evaluate_many_nas(v_formula_json, ev.param_json) as oee_json
    from totals t
    left join bucket_sums bs
      on bs.shift_date = t.shift_date
     and bs.shift_index is not distinct from t.shift_index
     and bs.resource_uid is not distinct from t.resource_uid
     and bs.step is not distinct from t.step
     and bs.line is not distinct from t.line
    cross join lateral (
      -- every time in whole seconds, the same unit as duration_seconds:
      -- the chart pins its y-scale to the window (y_axis.max_field) and
      -- the frontend formats hh:mm
      select jsonb_build_object(
                 'total_shift_in_seconds',       round(t.total_seconds, 0),
                 'producing_in_seconds',         round(coalesce(bs.producing_seconds, 0), 0),
                 'breakdown_in_seconds',         round(coalesce(bs.breakdown_seconds, 0), 0),
                 'offline_in_seconds',           round(coalesce(bs.offline_seconds, 0), 0),
                 'planned_in_seconds',           round(coalesce(bs.planned_seconds, 0), 0),
                 'shown_loss_in_seconds',        round(coalesce(bs.shown_loss_seconds, 0), 0),
                 'shown_unavailable_in_seconds', round(coalesce(bs.shown_unavailable_seconds, 0), 0)
             ) as param_json
    ) ev
  ),
  -- what a state row shows as. A sub-state of a bucket (setup in producing,
  -- missingdata in offline) is its own row only when selected by name;
  -- selected through its bucket it folds into the bucket's row, so the
  -- tooltip's producing line is the very number the OEE divides with, and
  -- with setup selected the producing row is producing minus setup. Nothing
  -- selected means everything by name; planned always passes for the plan
  -- line; a state not selected either way shows nowhere
  shown as (
    select b.shift_date, b.shift_index, b.shift_start, b.shift_end,
           b.resource_uid, b.resource_name, b.line, b.step,
           case when p_states is null or b.state = any(p_states) or b.state = 'planned' then b.state
                when sm.counts_as = any(p_states) then sm.counts_as
           end as state,
           sum(b.seconds) as seconds
    from base b
    left join state_map sm on sm.state_code = b.state
    group by b.shift_date, b.shift_index, b.shift_start, b.shift_end,
             b.resource_uid, b.resource_name, b.line, b.step,
             case when p_states is null or b.state = any(p_states) or b.state = 'planned' then b.state
                  when sm.counts_as = any(p_states) then sm.counts_as
             end
  ),
  final_rows as (
    select s.shift_date,
           coalesce(s.shift_index, 1) as shift_index,
           s.shift_start, s.shift_end,
           s.resource_uid, s.resource_name,
           s.line, s.step, s.state,
           sm.state_json,
           -- the series of the chart: a folded bucket row is the bucket, a
           -- sub-state selected by name is its own set
           s.state as counts_as,
           s.seconds as duration_seconds,
           round(s.seconds / nullif(o.total_seconds, 0) * 100, 2) as duration_percentage,
           o.param_json, o.oee_json, o.count_resources,
           sm.state_order
    from shown s
    left join state_map sm on sm.state_code = s.state
    join oee o
      on o.shift_date = s.shift_date
     and o.shift_index is not distinct from s.shift_index
     and o.resource_uid is not distinct from s.resource_uid
     and o.step is not distinct from s.step
     and o.line is not distinct from s.line
    where s.state is not null

    union all

    -- one synthetic 'available' row per group: the middle band of the
    -- stack between producing and unavailable. Whatever the selection,
    -- producing + drawn losses + available + drawn unavailable +
    -- unavailable rest sums to the window
    select o.shift_date,
           coalesce(o.shift_index, 1),
           o.shift_start, o.shift_end,
           o.resource_uid, o.resource_name,
           o.line, o.step,
           'available',
           sm.state_json,
           'available',
           o.available_seconds,
           round(o.available_seconds / nullif(o.total_seconds, 0) * 100, 2),
           o.param_json, o.oee_json, o.count_resources,
           sm.state_order
    from oee o
    left join state_map sm on sm.state_code = 'available'

    union all

    -- one synthetic 'unavailable' row per group: the breakdown/offline
    -- time not already shown as its own area, at the top of the stack.
    -- A normal state row, so the tooltip treats it like any other state;
    -- fully covered by the selection means no row at all
    select o.shift_date,
           coalesce(o.shift_index, 1),
           o.shift_start, o.shift_end,
           o.resource_uid, o.resource_name,
           o.line, o.step,
           'unavailable',
           sm.state_json,
           'unavailable',
           o.unavailable_rest_seconds,
           round(o.unavailable_rest_seconds / nullif(o.total_seconds, 0) * 100, 2),
           o.param_json, o.oee_json, o.count_resources,
           sm.state_order
    from oee o
    left join state_map sm on sm.state_code = 'unavailable'
    where o.unavailable_rest_seconds > 0
  )
  select fr.shift_date, fr.shift_index, fr.shift_start, fr.shift_end,
         fr.resource_uid, fr.resource_name,
         -- the tenant of the machine (its production line), for the chart
         -- title; null for a step or line group
         (select v.value ->> 'name'
          from relation.resource res
          join relation.production_line pl on pl.line_id = res.line_id
          join relation.lookup lk on lk.lookup = 'lookup_tenants'
          cross join lateral jsonb_array_elements(lk.lookup_json) as v(value)
          where res.resource_uid = fr.resource_uid
            and (v.value ->> 'tenant_id')::integer = pl.tenant_id
          limit 1) as tenant_name,
         (select jsonb_agg(r.resource_uid order by r.resource_uid)
             from resources r
             where r.line = fr.line
               and (fr.step is null or r.step = fr.step)) as resource_uids,
         fr.line, fr.step, fr.state, fr.state_json, fr.counts_as,
         fr.duration_seconds, fr.duration_percentage,
         fr.param_json, fr.oee_json, fr.count_resources,
         fr.state_order
  from final_rows fr
  left join step_order so on so.step = fr.step
  order by so.step_order nulls last, fr.step, fr.line, fr.resource_name,
           fr.shift_date, fr.shift_index, fr.state_order;
end;
$$;

alter function log.get_resource_state_shift_totals(text[], timestamp with time zone, integer, text, text[], boolean, boolean, boolean, text, integer[]) owner to xfw3;

-- ============ 3. rebuild the missing days ============
DO $do$
DECLARE
    v_day  date;
    v_rows integer;
BEGIN
    FOR v_day IN SELECT d::date FROM generate_series(date '2026-09-07', current_date, interval '1 day') AS d LOOP
        v_rows := log.upsert_state_shift_agg(v_day);
        RAISE NOTICE 'state_shift_agg % : % rows', v_day, v_rows;
    END LOOP;
END
$do$;

COMMIT;
