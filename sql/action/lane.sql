create table lane
(
	lane_id bigint generated always as identity
		primary key,
	-- the day this strip of time belongs to; the boards that show it, and
	-- their order per board, hang in plan_lane
	lane_date date not null,
	-- the step this lane plans: vocabulary relation.lookup lookup_step_category
	step text not null,
	-- the machine (docs/resource-path.md), or site.line.impose.width for a group lane
	resource_path ltree not null,
	-- backs the composite foreign key of batch_lane_item
	unique (lane_id, step)
);

comment on table lane is 'One strip of time on one day: the step and the path of what it plans. A machine-day carries the machine''s path; a group-day carries the impose path (site.line.impose.width) and an imposition_group_lane row. Which plans show the lane, and in what order, says plan_lane.';
comment on column lane.lane_date is 'The day of this strip of time. A lane is one machine-day or one group-day (imposition_group_lane); which plans show it says plan_lane.';

alter table lane owner to xfw3;

create index idx_lane_date
	on lane (lane_date);
