-- Rollback of sql/update_schedule_01_schema.sql: the schema with everything in
-- it, the formula reader, the lookup and the two data_table rows. Nothing in
-- action.* was changed by step 1, so nothing there comes back.
BEGIN;

DELETE FROM site.data_table
WHERE data_table IN ('get_schedule_lane', 'get_schedule_lane_items')
  AND coalesce(query, stored_proc) LIKE 'schedule.%';

DELETE FROM action.lookup WHERE lookup = 'lookup_lane_item_event_type';

DROP FUNCTION IF EXISTS action.get_formula(text[], timestamp with time zone);

-- the formula table moved in from action (step 1c) goes back before the schema falls
ALTER TABLE IF EXISTS schedule.formula SET SCHEMA action;

DROP SCHEMA IF EXISTS schedule CASCADE;

COMMIT;
