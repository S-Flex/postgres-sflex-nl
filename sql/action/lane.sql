create table lane
(
	lane_id bigint generated always as identity
		primary key,
	-- the day this strip of time belongs to; the boards that show it, and
	-- their order per board, hang in plan_lane
	lane_date date not null
);

comment on table lane is 'One strip of time on one day. What the strip is for says exactly one of the two subtype rows: resource_lane (a machine-day) or imposition_group_lane (a material / imposition group). Which plans show the lane, and in what order, says plan_lane.';
comment on column lane.lane_date is 'The day of this strip of time. A lane is one machine-day (resource_lane) or one group-day (imposition_group_lane); which plans show it says plan_lane.';

alter table lane owner to xfw3;

create index idx_lane_date
	on lane (lane_date);
