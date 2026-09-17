-- The vocabulary of the schedule schema (docs/schedule-base.md §3): same
-- shape as action.lookup, one row per lookup, the content in lookup_json.
-- Holds the three lane item lookups: lookup_lane_item_type (plan, progress,
-- actual), lookup_lane_item_status (plan, released, nested) and
-- lookup_lane_item_event_type (created, moved, resized, split, copied,
-- selected, placed, status-changed, deleted).
create table schedule.lookup
(
	lookup text not null
		constraint pk_schedule_lookup
			primary key,
	lookup_json jsonb
);

comment on table schedule.lookup is 'The lookups of the schedule schema, same shape as action.lookup: the lookup name as key, the content as a jsonb array in lookup_json. The content lives in the repo as json/lookup/schedule/<lookup>.json.';

alter table schedule.lookup owner to xfw3;
