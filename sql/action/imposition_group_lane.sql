-- The group-day kind of lane (docs/schedule-base.md §9): the lane of
-- one imposition group on the print schedule (75) and the impose plan (76).
-- imposition_group_id is for now an alias of material_id (the groups were
-- seeded 1:1 from the materials); the real groups from the xbom follow later.
create table imposition_group_lane
(
	lane_id bigint
		primary key
		references lane
			on delete cascade,
	imposition_group_id integer not null
);

comment on table imposition_group_lane is 'The imposition group of a lane. A lane with this row is a group-day; a lane without it is a machine-day (its resource_path is the machine).';

alter table imposition_group_lane owner to xfw3;

create index idx_imposition_group_lane_group
	on imposition_group_lane (imposition_group_id);
