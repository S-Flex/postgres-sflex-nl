-- Rollback of sql/update_shift_employees_log.sql: the lookup back in legacy (as
-- Cees changed it, [{code, i18n}]), lookup_absence gone, the read, the teams and
-- the OEE report back to sql/update_shift_employees_line.sql and the previous
-- sql/update_oee_report.sql, the data_table on the legacy read, data_group 42
-- as it was live on 15 Sep 2026 (json in git before this change).
BEGIN;
INSERT INTO legacy.lookup (lookup, lookup_json)
SELECT 'lookup_shift', lookup_json FROM log.lookup WHERE lookup = 'lookup_shift'
ON CONFLICT (lookup) DO UPDATE SET lookup_json = EXCLUDED.lookup_json;
DELETE FROM log.lookup WHERE lookup IN ('lookup_shift', 'lookup_absence');
DROP FUNCTION IF EXISTS log.get_resource_shift_employees(integer, date);
UPDATE site.data_table SET query = 'legacy.get_resource_shift_employees' WHERE data_table = 'get_resource_shift_employees';
COMMIT;
-- then rerun sql/update_shift_employees_line.sql (legacy read, teams, status bar) and
-- restore data_group 42 from git.
