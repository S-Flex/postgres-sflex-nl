-- The date param of oee_report and oee_report_filter loses its default_value
-- "now()" (15 Sep 2026): the hub renders it as a full timestamp and the read's
-- p_date (a date) rejects it (PARAM_TYPE_MISMATCH / INVALID_DATE). The read
-- defaults to today by itself. In place, nothing else changes; the two json
-- files carry the same.
BEGIN;

UPDATE site.data_group d
SET data_group_json = jsonb_set(d.data_group_json, '{0,params}',
        (SELECT jsonb_agg(CASE WHEN p.value ->> 'key' = 'date' THEN p.value - 'default_value' ELSE p.value END ORDER BY p.ordinality)
         FROM jsonb_array_elements(d.data_group_json -> 0 -> 'params') WITH ORDINALITY AS p(value, ordinality)))
WHERE d.data_group IN ('oee_report', 'oee_report_filter');

COMMIT;

-- expected: the date param without default_value on both
SELECT data_group, p.value AS date_param
FROM site.data_group d
CROSS JOIN LATERAL jsonb_array_elements(d.data_group_json -> 0 -> 'params') AS p(value)
WHERE d.data_group IN ('oee_report', 'oee_report_filter') AND p.value ->> 'key' = 'date'
ORDER BY 1;
