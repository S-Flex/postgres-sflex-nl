-- Testing phase of docs/plan-batch-lane-item.md (decided 9 sep 2026): every
-- impose item that was never released is released at the local midnight of
-- its lane date, today for the historic and the stamped days, and from now on
-- every day in site.refresh_derived_data for the days generate_plan adds.
-- Midnight, so every nest of that day lands on the one item of its material
-- (all instances are 0 today). Written straight into the event table, not
-- through action.crud_lane_item_event: an item without a time of its own
-- keeps flowing with the clock instead of being fixed at 00:00.
BEGIN;

-- ============ sql/site/refresh_derived_data.sql ============
create or replace function site.refresh_derived_data() returns void
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
    -- from the weekly pattern (step impose: the nesting moments), a resource
    -- lane per impose machine the pattern names, plan_lane and the material
    -- link per lane.
    perform mock.generate_plan(d.date, 'impose', lt.line_type)
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

    -- testing phase (docs/plan-batch-lane-item.md, decided 9 sep 2026): every
    -- impose item without a release is released at the local midnight of its
    -- lane date, so every nest of that day lands on it (a nest goes to the
    -- item released last before it was nested). Written straight into the
    -- event table, not through action.crud_lane_item_event, so an item
    -- without a time of its own keeps flowing with the clock. Goes when the
    -- planner releases items from the board.
    insert into action.lane_item_event (lane_item_id, status, moved_at)
    select li.lane_item_id, 'released',
           l.lane_date::timestamp at time zone 'Europe/Amsterdam'
    from action.lane_item li
    join action.lane l on l.lane_id = li.lane_id
    where l.step = 'impose'
      and li.type = 'plan'
      and li.source = 'material-plan'
      and not exists (select 1 from action.lane_item_event e
                      where e.lane_item_id = li.lane_item_id and e.status = 'released');
end;
$$;

alter function site.refresh_derived_data() owner to xfw3;


-- the historic and the stamped items, once now
insert into action.lane_item_event (lane_item_id, status, moved_at)
select li.lane_item_id, 'released',
       l.lane_date::timestamp at time zone 'Europe/Amsterdam'
from action.lane_item li
join action.lane l on l.lane_id = li.lane_id
where l.step = 'impose'
  and li.type = 'plan'
  and li.source = 'material-plan'
  and not exists (select 1 from action.lane_item_event e
                  where e.lane_item_id = li.lane_item_id and e.status = 'released');

COMMIT;

-- check: impose items and their release; expected without_release 0
select count(*) as impose_items,
       count(*) filter (where not exists (select 1 from action.lane_item_event e
                                          where e.lane_item_id = li.lane_item_id and e.status = 'released')) as without_release,
       min(l.lane_date) as first_day, max(l.lane_date) as last_day
from action.lane_item li
join action.lane l on l.lane_id = li.lane_id
where l.step = 'impose' and li.type = 'plan' and li.source = 'material-plan';
