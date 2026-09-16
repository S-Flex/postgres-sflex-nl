-- Rollback of sql/update_resource_error_log.sql. The page and menu item in json/data are removed by hand (git).
BEGIN;
DELETE FROM site.data_group WHERE data_group = 'resource_error_log';
DELETE FROM site.data_table WHERE data_table = 'get_resource_error_log';
DROP FUNCTION IF EXISTS log.get_resource_error_log(text, date, integer);
COMMIT;
