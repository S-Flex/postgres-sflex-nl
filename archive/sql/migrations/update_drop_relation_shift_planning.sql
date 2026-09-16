-- relation.shift_planning and relation.crud_shift_planning go: the shift
-- planning lives in log.hr_shift_planning (per department group and business
-- date, shift_json in the format of 8 Sep 2026), written by
-- log.crud_hr_shift_planning_log and read by get_resource_shift_employees and
-- the shift aggregation. No function in the repo reads the relation table any
-- more (11 Sep 2026); the three checks below confirm the same for the
-- database. Run them first; when all three come back empty, run the block.
-- Mirrors: sql/relation/shift_planning*.sql and crud_shift_planning.sql moved
-- to archive/sql/relation/.

-- 1. functions still reading the table or calling the crud (expect none)
SELECT n.nspname || '.' || p.proname AS fn
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE (p.prosrc ILIKE '%relation.shift_planning%' OR p.prosrc ILIKE '%crud_shift_planning%')
  AND p.proname <> 'crud_shift_planning';

-- 2. data_table rows pointing at the crud or the table (expect none; a row
--    here means a sync still writes into relation.shift_planning)
SELECT data_table, query, stored_proc
FROM site.data_table
WHERE query ILIKE '%relation.shift_planning%' OR stored_proc ILIKE '%crud_shift_planning%';

-- 3. foreign keys onto the table (expect none)
SELECT conrelid::regclass::text AS dependent_table, conname
FROM pg_constraint
WHERE confrelid = 'relation.shift_planning'::regclass;

-- what goes: rows and last write, for the record
SELECT count(*) AS rows, max(updated_at) AS last_write FROM relation.shift_planning;

BEGIN;

DROP FUNCTION IF EXISTS relation.crud_shift_planning(jsonb, boolean);
DROP TABLE IF EXISTS relation.shift_planning;

COMMIT;
