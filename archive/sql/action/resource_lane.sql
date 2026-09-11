-- The machine-day kind of lane (docs/plan-lane-model.md, stap 3): the lane
-- plans this machine, wherever it physically stands — a foil plan can carry a
-- printer standing in the sheet hall (plan_lane hangs the lane under both
-- boards). Snapshot at planning time (docs/resource-path.md). One lane per
-- machine per day: the creators (mock.generate_production_plan,
-- action.crud_object) look the lane up on (lane_date, resource_path) before
-- they make one.
create table resource_lane
(
	lane_id bigint
		primary key
		references lane
			on delete cascade,
	resource_path ltree not null
);

comment on table resource_lane is 'The machine of a lane (relation.resource.resource_path), recorded at planning time. A lane has this row or an imposition_group_lane row, never both.';

alter table resource_lane owner to xfw3;

create index idx_resource_lane_resource_path
	on resource_lane (resource_path);

create index idx_resource_lane_resource_path_gist
	on resource_lane using gist (resource_path);
