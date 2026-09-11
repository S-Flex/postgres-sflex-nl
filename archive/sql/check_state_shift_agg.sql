-- Read-only checks on log.state_shift_agg: what is stored per resource, per
-- shift, per state, and whether it reconciles with log.state / log.data.
-- Nothing here writes; run the blocks separately.

-- ------------------------------------------------------------------
-- 1. totals per state per shift for one resource
--    the main view: one row per state, plus the window it belongs to
--    and what share of that window it is
-- ------------------------------------------------------------------
select a.shift_date,
       a.shift_index,
       r.resource_name,
       r.step,
       a.shift_start at time zone 'Europe/Amsterdam'          as shift_start_local,
       a.shift_end   at time zone 'Europe/Amsterdam'          as shift_end_local,
       round(extract(epoch from (a.shift_end - a.shift_start)) / 3600.0, 2) as window_hours,
       a.state,
       round(a.duration_seconds / 3600.0, 2)                  as hours,
       round(a.duration_seconds
             / nullif(extract(epoch from (a.shift_end - a.shift_start)), 0) * 100, 1) as percent_of_window
from log.state_shift_agg a
join relation.resource r on r.resource_uid = a.resource_uid
where r.resource_name = :resource_name           -- e.g. 'Dürst P5-500'
  and a.shift_date between :from_date and :until_date
order by a.shift_date, a.shift_index, a.duration_seconds desc;


-- ------------------------------------------------------------------
-- 2. one line per shift: does the stored data add up?
--    logged_hours  = states that come straight from log.state
--    derived_hours = producing + starved (computed from log.data)
--    logged_hours should equal window_hours; running should equal
--    producing + starved
-- ------------------------------------------------------------------
select a.shift_date,
       a.shift_index,
       r.resource_name,
       r.step,
       round(extract(epoch from (max(a.shift_end) - min(a.shift_start))) / 3600.0, 2) as window_hours,
       round(sum(a.duration_seconds) filter (
                 where a.state not in ('producing', 'starved.running', 'planned')
             ) / 3600.0, 2)                                    as logged_hours,
       round(sum(a.duration_seconds) filter (where a.state = 'running')   / 3600.0, 2) as running_hours,
       round(sum(a.duration_seconds) filter (where a.state = 'producing') / 3600.0, 2) as producing_hours,
       round(sum(a.duration_seconds) filter (where a.state = 'starved')   / 3600.0, 2) as starved_hours,
       round(sum(a.duration_seconds) filter (where a.state = 'planned')   / 3600.0, 2) as planned_hours,
       count(*)                                                                        as state_rows
from log.state_shift_agg a
join relation.resource r on r.resource_uid = a.resource_uid
where a.shift_date between :from_date and :until_date
group by a.shift_date, a.shift_index, r.resource_name, r.step
order by a.shift_date, r.resource_name, a.shift_index;


-- ------------------------------------------------------------------
-- 3. per day instead of per shift: the same totals rolled up, with the
--    covered window next to the 24 hours of the day, so it is visible
--    how much of the day is in no shift at all
-- ------------------------------------------------------------------
select a.shift_date,
       r.resource_name,
       r.step,
       count(distinct a.shift_index)                                       as shifts,
       round(sum(distinct extract(epoch from (a.shift_end - a.shift_start))) / 3600.0, 2) as covered_hours,
       24 - round(sum(distinct extract(epoch from (a.shift_end - a.shift_start))) / 3600.0, 2) as uncovered_hours,
       round(sum(a.duration_seconds) filter (where a.state = 'producing') / 3600.0, 2) as producing_hours,
       round(sum(a.duration_seconds) filter (where a.state = 'breakdown') / 3600.0, 2) as breakdown_hours,
       round(sum(a.duration_seconds) filter (where a.state = 'offline')   / 3600.0, 2) as offline_hours,
       round(sum(a.duration_seconds) filter (where a.state = 'planned')   / 3600.0, 2) as planned_hours
from log.state_shift_agg a
join relation.resource r on r.resource_uid = a.resource_uid
where a.shift_date between :from_date and :until_date
group by a.shift_date, r.resource_name, r.step
order by a.shift_date, r.resource_name;


-- ------------------------------------------------------------------
-- 4. where do the shift windows come from, and do they differ per
--    weekday / weekend? one row per date
-- ------------------------------------------------------------------
select d.date,
       d.weekday,
       d.is_weekend,
       d.tenants_mandatory_day_off,
       jsonb_array_length(d.shift_json)                     as shift_count,
       (select string_agg((sh.value ->> 'start_time') || '-' || (sh.value ->> 'end_time'), ', '
                          order by sh.ordinality)
        from jsonb_array_elements(d.shift_json) with ordinality as sh(value, ordinality)) as windows,
       (select round(sum(
                   extract(epoch from (
                       (sh.value ->> 'end_time')::time - (sh.value ->> 'start_time')::time
                   ))) / 3600.0, 2)
        from jsonb_array_elements(d.shift_json) as sh(value))                             as hours_per_day
from action.dates d
where d.date between :from_date and :until_date
order by d.date;


-- ------------------------------------------------------------------
-- 5. the candidate replacement sources for the shift window:
--    is there anything in them, and does it cover weekends?
-- ------------------------------------------------------------------
select 'relation.shift_planning' as source,
       count(*)                  as rows,
       count(distinct resource_uid) as resources,
       min(plan_date)            as first_date,
       max(plan_date)            as last_date,
       count(*) filter (where extract(isodow from plan_date) >= 6) as weekend_rows
from relation.shift_planning
union all
select 'relation.shift_registered_hours',
       count(*),
       count(distinct resource_uid),
       min(start_at)::date,
       max(start_at)::date,
       count(*) filter (where extract(isodow from start_at) >= 6)
from relation.shift_registered_hours
union all
select 'log.hr_shift_planning',
       count(*),
       0,
       min(business_date),
       max(business_date),
       count(*) filter (where extract(isodow from business_date) >= 6)
from log.hr_shift_planning;


-- ------------------------------------------------------------------
-- 6. states present in the data but missing from lookup_resource_state
--    expected after the lookup update: no rows
-- ------------------------------------------------------------------
with lookup_codes as (
    select g.value ->> 'code' as code
    from relation.lookup l,
         jsonb_array_elements(l.lookup_json) as g(value)
    where l.lookup = 'lookup_resource_state'
    union
    select s.value ->> 'code'
    from relation.lookup l,
         jsonb_array_elements(l.lookup_json)            as g(value),
         jsonb_array_elements(g.value -> 'states')      as s(value)
    where l.lookup = 'lookup_resource_state'
),
used as (
    select distinct state from log.state
    union
    select distinct state from log.state_shift_agg
)
select u.state
from used u
left join lookup_codes lc on lc.code = u.state
where lc.code is null
order by u.state;
