-- Board 79 reads src get_impose_plan_inflow (changed in the data_group by hand
-- on 10 Sep 2026); the data_table row of that name replaces get_impose_plan_info
-- and points at the renamed function mock.get_impose_plan_inflow (renamed in
-- the database by hand as well).
BEGIN;

INSERT INTO site.data_table (data_table, query, stored_proc, description, data_table_json, do_cache)
VALUES ('get_impose_plan_inflow',
        'mock.get_impose_plan_inflow',
        '',
        'orderline manifest of a material plus the lane item and nest moment the nests land on, for the inflow sidebar (79)',
        '{"primary_keys": ["production_orderline_id"]}'::jsonb,
        false)
ON CONFLICT (data_table) DO UPDATE
    SET query           = EXCLUDED.query,
        description     = EXCLUDED.description,
        data_table_json = EXCLUDED.data_table_json;

DELETE FROM site.data_table WHERE data_table = 'get_impose_plan_info';

COMMIT;

-- check: one row, query mock.get_impose_plan_inflow
SELECT data_table, query FROM site.data_table WHERE data_table LIKE 'get_impose_plan_in%';
