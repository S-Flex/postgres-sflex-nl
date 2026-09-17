-- Rollback of step 1e (sql/update_schedule_1e_lookup.sql): schedule.lookup
-- back out. action.lookup keeps its rows either way, so nothing is lost.

BEGIN;

DROP TABLE IF EXISTS schedule.lookup;

COMMIT;
