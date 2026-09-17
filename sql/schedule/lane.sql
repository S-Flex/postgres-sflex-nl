-- One strip of time: one step on one machine on one day
-- (docs/schedule-base.md §3). The material boards group the items of
-- these lanes by material or imposition group; there is no other lane kind.
-- The kind of the work -- plan, progress, actual -- is not a property of the
-- lane but of the work on it: schedule.lane_item.lane_item_type. One lane
-- carries every kind, so the board can draw them on the same axis.
create table schedule.lane
(
	lane_id bigint generated always as identity
		primary key,
	plan_id bigint not null
		references schedule.plan,
	lane_date date not null,
	-- vocabulary relation.lookup lookup_step_category
	step text not null,
	-- the machine, docs/resource-path.md; an impose lane carries the impose
	-- path of mock.material_print_schedule (site.line.impose.width)
	resource_path ltree not null,
	sort_order numeric default 0 not null,
	unique (plan_id, lane_date, step, resource_path)
);

comment on table schedule.lane is 'One step on one resource_path on one day. Unique per plan, day, step and path; the items on it are schedule.lane_item, each with its own lane_item_type (plan, progress, actual).';

alter table schedule.lane owner to xfw3;

create index idx_schedule_lane_date
	on schedule.lane (lane_date);

create index idx_schedule_lane_resource_path
	on schedule.lane using gist (resource_path);
