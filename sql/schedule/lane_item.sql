-- The block of work on a lane (docs/plan-planning-schema.md §2, §3). Current
-- state only: every change writes a schedule.lane_item_event row, and the
-- status of the item is the status of its newest event. Timing is in
-- seconds, that is the contract: no unit in the key.
create table schedule.lane_item
(
	lane_item_id bigint generated always as identity
		primary key,
	lane_id bigint not null
		references schedule.lane,
	-- plan (stored), progress and actual (derived at read time):
	-- action.lookup lookup_lane_item_type
	lane_item_type text default 'plan' not null,
	sort_order numeric not null,
	-- seconds since the local midnight of the lane day; null: the board chains it
	start_offset integer
		constraint lane_item_start_offset_check
			check (start_offset >= 0 and start_offset <= 86399),
	-- seconds
	duration integer default 0 not null
		constraint lane_item_duration_check
			check (duration >= 0),
	-- seconds per unit of the work
	production_impact_per_unit numeric,
	-- what is planned (§3.1); null on a step item that inherits it from its
	-- predecessor (§3.3)
	data_json jsonb,
	unique (lane_id, sort_order)
);

comment on table schedule.lane_item is 'The block of work on a lane. data_json says what: material or imposition group, nest moment, batches with nests, selected orderlines, summary. Null data_json = inherited along lane_item_dependency. History and status live in schedule.lane_item_event.';
comment on column schedule.lane_item.start_offset is 'Seconds since the local midnight of the lane day. Null: no time of its own, the board chains it after its predecessor.';
comment on column schedule.lane_item.duration is 'Seconds. Grows as nests are placed (event placed), set by the planner (event resized), divided by a split.';

alter table schedule.lane_item owner to xfw3;

-- the upsert key of schedule.generate_day: one plan item per material and
-- nest moment on a lane
create unique index uq_schedule_lane_item_material_moment
	on schedule.lane_item (lane_id, (data_json ->> 'material_id'), (data_json ->> 'nest_moment_code'))
	where lane_item_type = 'plan' and data_json ? 'material_id';

-- which item holds a nest: data_json @> '{"batches": [{"nest_ids": [123]}]}'
create index idx_schedule_lane_item_data_json
	on schedule.lane_item using gin (data_json jsonb_path_ops);
