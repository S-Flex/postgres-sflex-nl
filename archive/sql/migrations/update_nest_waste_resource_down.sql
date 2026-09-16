-- Rollback of sql/update_nest_waste_resource.sql: the two data_groups go, the read
-- goes back to the version of sql/update_nest_waste_line_type.sql (three parameters).
-- The page resource-nest-waste in pages.json is removed by hand.
BEGIN;
DELETE FROM site.data_group WHERE data_group IN ('resource_nest_waste_ranges', 'resource_nest_waste_ranges_chart');
DROP FUNCTION IF EXISTS legacy.get_nest_waste_ranges(datemultirange, integer[], text, text[], date);
COMMIT;
-- then rerun the function section of sql/update_nest_waste_line_type.sql
