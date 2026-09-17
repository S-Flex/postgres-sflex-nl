-- The calendar of the planning (docs/schedule-base.md §3): one row per day
-- with its weekday, whether it is a weekend, the tenants that have the day off
-- and the shifts of the day. Copy of action.dates, which goes at the switch.
create table schedule.dates
(
	date date not null
		constraint pk_schedule_dates
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

comment on table schedule.dates is 'The calendar of the planning: one row per day with its weekday, whether it is a weekend, the tenants that have the day off and the shifts of the day. Copy of action.dates, which goes when the planning switches over.';

comment on column schedule.dates.tenants_mandatory_day_off is 'The tenants that have this day off; empty means a regular working day.';

comment on column schedule.dates.shift_json is 'The shifts of the day, one element per shift: code, tenants (a shift without tenants counts for every resource), start_offset (seconds after midnight), shift_duration, break_times, start_time (readable only). Seconds are the contract.';

alter table schedule.dates owner to xfw3;

create index idx_schedule_dates_working_days
	on schedule.dates (weekday, date);
