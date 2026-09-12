-- Append-only: one row per change of a lane item, written by
-- schedule.crud_lane_item in the same statement as the change
-- (docs/plan-planning-schema.md §3.4). Two vocabularies, both in action.lookup:
-- event_type says what was done (lookup_lane_item_event_type: created, moved,
-- resized, split, copied, selected, placed, status-changed, deleted), status
-- says where the item is after it (lookup_lane_item_status: plan, released,
-- nested). The item has no status column: its status is the status of its
-- newest event, its status at a moment the status of its newest event before
-- that moment.
create table schedule.lane_item_event
(
	lane_item_event_id bigint generated always as identity
		primary key,
	lane_item_id bigint not null
		references schedule.lane_item
			on delete cascade,
	-- what was done: action.lookup lookup_lane_item_event_type
	event_type text not null,
	-- the status after this event: action.lookup lookup_lane_item_status
	status text not null,
	-- the changed keys with their old and new value, e.g.
	-- {"start_offset": {"from": 3600, "to": 7200}}; {} when the status column
	-- says it all
	event_json jsonb default '{}'::jsonb not null,
	-- the contact who did it; null for the system
	moved_by integer,
	moved_at timestamp with time zone default now() not null
);

comment on table schedule.lane_item_event is 'The history of a lane item, one row per change. event_type = what was done, status = the status after it, event_json = the changed keys with from/to. The newest row per item is its status.';

alter table schedule.lane_item_event owner to xfw3;

create index idx_schedule_lane_item_event_item_moved_at
	on schedule.lane_item_event (lane_item_id asc, moved_at desc);

create index idx_schedule_lane_item_event_moved_at
	on schedule.lane_item_event (moved_at);
