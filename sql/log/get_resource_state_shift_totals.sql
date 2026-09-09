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
