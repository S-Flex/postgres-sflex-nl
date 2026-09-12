-- The block of work on a lane (docs/plan-planning-schema.md §2, §3). Current
-- state only: every change writes a schedule.lane_item_event row, and the
-- status of the item is the status of its newest event. The kind of the item
-- (plan, progress, actual) is the lane_type of its lane. Timing is in
-- seconds, that is the contract: no unit in the key. The duration is not
-- stored: the board computes it from the item's own offsets and its work with
-- the duration formula of the view (action.formula 'duration-<view_code>'),
-- the way it chains items with the lag formula.
create table schedule.lane_item
(
	lane_item_id bigint generated always as identity
		primary key,
	lane_id bigint not null
		references schedule.lane,
	sort_order numeric not null,
	-- seconds since the local midnight of the lane day; null: the board chains it
	start_offset integer
		constraint lane_item_start_offset_check
			check (start_offset >= 0 and start_offset <= 86399),
	-- seconds since the local midnight of the lane day; null: the board
	-- computes it (duration formula)
	end_offset integer
		constraint lane_item_end_offset_check
			check (end_offset >= 0 and end_offset <= 86399),
	-- seconds per unit of the work
	production_impact_per_unit numeric,
	-- what is planned (§3.1); null on a step item that inherits it from its
	-- predecessor (§3.3)
	data_json jsonb,
	unique (lane_id, sort_order)
);

comment on table schedule.lane_item is 'The block of work on a lane. data_json says what: material or imposition group, nest moment, batches with nests, selected orderlines, summary. Null data_json = inherited along lane_item_dependency. History and status live in schedule.lane_item_event; the kind (plan, progress, actual) is the lane''s lane_type.';
comment on column schedule.lane_item.start_offset is 'Seconds since the local midnight of the lane day. Null: no time of its own, the board chains it after its predecessor with the lag formula.';
comment on column schedule.lane_item.end_offset is 'Seconds since the local midnight of the lane day. Null: the board computes it with the duration formula of the view; set by the planner (event resized) or a split.';

alter table schedule.lane_item owner to xfw3;

-- the upsert key of schedule.generate_day: one item per material and nest
-- moment on a lane
create unique index uq_schedule_lane_item_material_moment
	on schedule.lane_item (lane_id, (data_json ->> 'material_id'), (data_json ->> 'nest_moment_code'))
	where data_json ? 'material_id';

-- which item holds a nest: data_json @> '{"batches": [{"nest_ids": [123]}]}'
create index idx_schedule_lane_item_data_json
	on schedule.lane_item using gin (data_json jsonb_path_ops);
