-- The imposition group of a planned slot. On the item, not on the lane: a
-- copied slot takes its group along, and lane_item stays generic (pv2
-- machine items carry no group). Same shape as batch_lane_item. The group
-- ids were seeded 1:1 from the material ids (planning moves from material
-- to imposition group).
create table action.imposition_group_lane_item
(
	imposition_group_id integer not null
		references catalog.imposition_group,
	lane_item_id bigint not null
		references action.lane_item
			on delete cascade,
	constraint imposition_group_lane_item_pk
		primary key (imposition_group_id, lane_item_id)
);

alter table action.imposition_group_lane_item owner to xfw3;

create index ix_imposition_group_lane_item_lane_item_id
	on action.imposition_group_lane_item (lane_item_id);
