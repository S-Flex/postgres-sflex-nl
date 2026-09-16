-- Rollback of sql/update_oee_report.sql: the data_table row, the function and
-- the formula row go.
BEGIN;

DELETE FROM site.data_table WHERE data_table = 'get_oee_report' AND query = 'log.get_oee_report';
DROP FUNCTION IF EXISTS log.get_oee_report(timestamp with time zone, text, integer[], ltree[], datemultirange, text[], integer);
DROP FUNCTION IF EXISTS log.get_oee_report(date, text, integer[], ltree[], datemultirange, text[], integer);
DROP FUNCTION IF EXISTS log.get_oee_report(date, text, integer[], ltree[], datemultirange, text, integer);
DELETE FROM production.formula WHERE formula_code = 'oee-report';

COMMIT;
