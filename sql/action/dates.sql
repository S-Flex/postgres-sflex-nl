-- The calendar of the planning: one row per day. Copied to schedule.dates in
-- step 1f (docs/schedule-base.md §3); this table goes at the switch.
create table dates
(
	date date not null
		constraint pk_dates
			primary key,
	weekday smallint not null,
	is_weekend boolean not null,
	-- the tenants that have this day off; empty means a regular working day
	tenants_mandatory_day_off integer[] default '{}'::integer[] not null,
	-- the shifts of the day, one element per shift: code, tenants (a shift
	-- without tenants counts for every resource), start_offset (seconds after
	-- midnight), shift_duration, break_times, and start_time to read only --
	-- the functions reckon with the offset
	shift_json jsonb
);

comment on column dates.tenants_mandatory_day_off is 'The tenants that have this day off; replaces the boolean is_mandatory_day_off, which stays until every reader is adapted.';

alter table dates owner to xfw3;

create index idx_action_dates_working_days
	on dates (weekday, date);
