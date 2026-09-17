-- Step 1f: schedule.dates (docs/schedule-base.md §3).
--
-- The calendar moves along to the schedule schema: schedule.dates is the same
-- table as action.dates, filled with the same rows. Nothing else moves:
-- action.dates keeps its rows and every reader keeps reading it until the
-- switch, when action.dates goes.
--
-- Checked against the live action.dates (16 Sep): five columns, primary key on
-- date, index on (weekday, date), 4018 rows from 2024-01-01 to 2034-12-31, all
-- with shift_json. sql/action/dates.sql is on that stand as well.
--
-- Rollback: sql/update_schedule_1f_dates_down.sql

BEGIN;

-- ── the table ────────────────────────────────────────────────────────────
CREATE TABLE schedule.dates
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

COMMENT ON TABLE schedule.dates IS 'The calendar of the planning: one row per day with its weekday, whether it is a weekend, the tenants that have the day off and the shifts of the day. Copy of action.dates, which goes when the planning switches over.';

COMMENT ON COLUMN schedule.dates.tenants_mandatory_day_off IS 'The tenants that have this day off; empty means a regular working day.';

COMMENT ON COLUMN schedule.dates.shift_json IS 'The shifts of the day, one element per shift: code, tenants (a shift without tenants counts for every resource), start_offset (seconds after midnight), shift_duration, break_times, start_time (readable only). Seconds are the contract.';

ALTER TABLE schedule.dates OWNER TO xfw3;

CREATE INDEX idx_schedule_dates_working_days
	ON schedule.dates (weekday, date);

-- ── the rows, copied as they are ─────────────────────────────────────────
INSERT INTO schedule.dates (date, weekday, is_weekend, tenants_mandatory_day_off, shift_json)
SELECT d.date, d.weekday, d.is_weekend, d.tenants_mandatory_day_off, d.shift_json
FROM action.dates d;

-- ── check: 4018 rows, 2024-01-01 to 2034-12-31, nothing on either side only ─
SELECT (SELECT count(*) FROM action.dates)   AS action_rows,
       (SELECT count(*) FROM schedule.dates) AS schedule_rows,
       (SELECT count(*) FROM (SELECT * FROM action.dates
                              EXCEPT SELECT * FROM schedule.dates) d) AS only_in_action,
       (SELECT count(*) FROM (SELECT * FROM schedule.dates
                              EXCEPT SELECT * FROM action.dates) d) AS only_in_schedule,
       (SELECT min(date) FROM schedule.dates) AS first_date,
       (SELECT max(date) FROM schedule.dates) AS last_date;

COMMIT;
