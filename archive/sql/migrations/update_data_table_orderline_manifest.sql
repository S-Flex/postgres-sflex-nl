-- Board 79 (impose_plan_inflow) reads src get_production_orderline_manifest,
-- but site.data_table has no row of that name, so the board has no source.
-- This row points it at the manifest function. Step 3 of
-- docs/plan-batch-lane-item.md swaps the query for the pass-through that
-- adds lane_item_id and instance; the data_table name stays.
BEGIN;

INSERT INTO site.data_table (data_table, query, stored_proc, description, data_table_json, do_cache)
VALUES ('get_production_orderline_manifest',
        'mapping.get_production_orderline_manifest',
        '',
        'orderline manifest of a material for the inflow board (79)',
        '{"primary_keys": ["production_orderline_id"]}'::jsonb,
        false)
ON CONFLICT (data_table) DO UPDATE
    SET query           = EXCLUDED.query,
        data_table_json = EXCLUDED.data_table_json;

COMMIT;

-- check; expected one row
SELECT data_table, query, data_table_json
FROM site.data_table
WHERE data_table = 'get_production_orderline_manifest';
