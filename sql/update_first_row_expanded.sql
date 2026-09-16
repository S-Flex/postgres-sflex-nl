-- first_row_expanded on the containers of the two resource sidebars (15 Sep 2026):
-- the first group of the block opens expanded. Only the data_groups change, in
-- place; the reads are not touched. json/data_group/<name>.json carry the same.
BEGIN;

UPDATE site.data_group
SET data_group_json = jsonb_set(data_group_json, '{0,flow_board_config,row_options,first_row_expanded}', 'true'::jsonb)
WHERE data_group IN ('resource_error_log', 'resource_nest_waste_ranges');

COMMIT;

-- expected: both with first_row_expanded true
SELECT data_group, data_group_json -> 0 -> 'flow_board_config' -> 'row_options' AS row_options
FROM site.data_group
WHERE data_group IN ('resource_error_log', 'resource_nest_waste_ranges')
ORDER BY 1;
