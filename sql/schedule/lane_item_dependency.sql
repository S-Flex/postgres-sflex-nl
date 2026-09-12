-- Which item follows which: many-to-many, from is the predecessor. Written by
-- schedule.crud_lane_item from legacy.nest.manifest_json steps[] when a nest is
-- placed, and by a split or merge on the board. An item without data_json
-- inherits it from its predecessors (schedule.get_lane_item_data).
create table schedule.lane_item_dependency
(
	from_lane_item_id bigint not null
		references schedule.lane_item
			on delete cascade,
	to_lane_item_id bigint not null
		references schedule.lane_item
			on delete cascade,
	primary key (from_lane_item_id, to_lane_item_id)
);

comment on table schedule.lane_item_dependency is 'from = predecessor, to = successor. A step item (print after impose, cut after print) hangs on its predecessor and inherits its data_json until it gets one of its own.';

alter table schedule.lane_item_dependency owner to xfw3;

create index idx_schedule_lane_item_dependency_to
	on schedule.lane_item_dependency (to_lane_item_id);
