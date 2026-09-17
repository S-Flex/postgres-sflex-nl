-- The block of work on a lane (docs/schedule-base.md §3, §5). Current
-- state only: every change writes a schedule.lane_item_event row, and the
-- status of the item is the status of its newest event. The kind of the item
-- (plan, progress, actual) is its own lane_item_type, so one lane carries
-- every kind. Timing is in seconds, that is the contract: no unit in the key.
-- The duration is not stored: the board computes it from the item's own
-- offsets and its work with the duration formula of the view
-- (schedule.formula 'duration-<view_code>'), the way it chains items with the
-- lag formula.
create table schedule.lane_item
(
	lane_item_id bigint generated always as identity
		primary key,
	lane_id bigint not null
		references schedule.lane,
	-- plan (what is planned), progress (what is left of it), actual (what the
	-- resource did): action.lookup lookup_lane_item_type
	lane_item_type text default 'plan' not null,
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
	-- setup before and teardown after the work, in seconds, stamped from
	-- catalog.item_group_resource.item_group_json of the item groups on the
	-- resource of the lane; every step has its own (impose, print and cut differ)
	lead_in integer,
	lead_out integer,
	-- what is planned (§5.1); null on a step item that inherits it from its
	-- predecessor (§5.3)
	data_json jsonb,
	created_at timestamp with time zone default now() not null,
	updated_at timestamp with time zone default now() not null,
	unique (lane_id, sort_order)
);

comment on table schedule.lane_item is 'The block of work on a lane. data_json says what: material or imposition group, nest moment, batches with nests, selected orderlines, summary. Null data_json = inherited along lane_item_dependency. History and status live in schedule.lane_item_event; the kind (plan, progress, actual) is the item''s own lane_item_type.';
comment on column schedule.lane_item.lane_item_type is 'The kind of the row, from action.lookup / lookup_lane_item_type: plan = what is planned, progress = what is left of it, actual = what the resource did. One lane carries every kind; the board draws them on the same axis.';
comment on column schedule.lane_item.start_offset is 'Seconds since the local midnight of the lane day. Null: no time of its own, the board chains it after its predecessor with the lag formula.';
comment on column schedule.lane_item.end_offset is 'Seconds since the local midnight of the lane day. Null: the board computes it with the duration formula of the view; set by the planner (event resized) or a split.';
comment on column schedule.lane_item.lead_in is 'Setup seconds before the work, stamped from catalog.item_group_resource.item_group_json of the work''s item groups on the resource of the lane.';
comment on column schedule.lane_item.lead_out is 'Teardown seconds after the work, stamped from catalog.item_group_resource.item_group_json of the work''s item groups on the resource of the lane.';

alter table schedule.lane_item owner to xfw3;

-- the upsert key of schedule.generate_day: one item per material and nest
-- moment on a lane, per kind
create unique index uq_schedule_lane_item_material_moment
	on schedule.lane_item (lane_id, lane_item_type, (data_json ->> 'material_id'), (data_json ->> 'nest_moment_code'))
	where data_json ? 'material_id';

-- which item holds a nest: data_json @> '{"batches": [{"nest_ids": [123]}]}'
create index idx_schedule_lane_item_data_json
	on schedule.lane_item using gin (data_json jsonb_path_ops);
