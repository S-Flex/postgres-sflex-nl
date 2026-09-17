-- Rollback of step 1f (sql/update_schedule_1f_dates.sql): schedule.dates back
-- out. action.dates keeps its rows either way, so nothing is lost.

BEGIN;

DROP TABLE IF EXISTS schedule.dates;

COMMIT;
