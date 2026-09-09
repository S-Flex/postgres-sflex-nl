-- The material-forecast list (data_group 95) expands every date group when
-- one is opened: without primary keys the rows have no identity. The keys
-- are the unique index of log.production_forecast_material, all four served
-- by mock.get_production_forecast_material. data_table_json was null here,
-- so coalesce before jsonb_set.
BEGIN;

UPDATE site.data_table
SET data_table_json = jsonb_set(
        coalesce(data_table_json, '{}'::jsonb), '{primary_keys}',
        '["date", "production_line_id", "production_company_id", "material_id"]'::jsonb)
WHERE data_table = 'get_production_forecast_material';

-- verify: one row with the four keys
SELECT data_table, query, data_table_json -> 'primary_keys' AS primary_keys
FROM site.data_table
WHERE data_table = 'get_production_forecast_material';

COMMIT;
