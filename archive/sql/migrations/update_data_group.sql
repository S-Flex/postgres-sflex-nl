-- write the normalised data_group_json back into the site_data_group table
-- run from the repo root with psql, the json files stay the single source of truth:
--   psql -v ON_ERROR_STOP=1 -f sql/update_data_group.sql
--

\set payload `cat json/data_group/xfw3_site_data_group.json`

BEGIN;

-- set-based, one statement, no loop over the array
WITH payload AS (
    SELECT :'payload'::jsonb AS doc
),
src AS (
    SELECT (el ->> 'data_group_id')::integer AS data_group_id,
           el ->> 'data_group'               AS data_group,
           el -> 'data_group_json'           AS data_group_json
    FROM payload
             CROSS JOIN LATERAL jsonb_array_elements(payload.doc) AS el
)
UPDATE site.data_group t
SET data_group_json = s.data_group_json
FROM src s
WHERE t.data_group_id = s.data_group_id
  AND t.data_group_json IS DISTINCT FROM s.data_group_json;

-- every exported group must exist in the table, a missing id means the export
-- and the table have drifted apart
WITH payload AS (
    SELECT :'payload'::jsonb AS doc
),
src AS (
    SELECT (el ->> 'data_group_id')::integer AS data_group_id,
           el ->> 'data_group'               AS data_group
    FROM payload
             CROSS JOIN LATERAL jsonb_array_elements(payload.doc) AS el
)
SELECT s.data_group_id, s.data_group AS missing_in_table
FROM src s
         LEFT JOIN site.data_group t ON t.data_group_id = s.data_group_id
WHERE t.data_group_id IS NULL;

COMMIT;
