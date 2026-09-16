-- Data groups (json/data_group/*.json): a field's nav opens its path on
-- ctrl-click: {"nav": {"path": ...}} in a field_config becomes
-- {"nav": {"on_ctrl_click": {"path": ...}}}. A field nav that an earlier run
-- turned into on_select is renamed as well. row_options.nav (on_select, menu)
-- is not touched. The live rows are rewritten in place (only those objects),
-- so edits made on the server since the last sync survive.
-- Rollback: sql/update_nav_on_ctrl_click_down.sql.
BEGIN;

-- walks a jsonb value; p_in_field is true for the entries of a field_config
CREATE OR REPLACE FUNCTION pg_temp.nav_on_ctrl_click(p jsonb, p_in_field boolean DEFAULT false) RETURNS jsonb
    LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE jsonb_typeof(p)
        WHEN 'object' THEN (
            SELECT coalesce(jsonb_object_agg(
                       e.key,
                       CASE
                           WHEN e.key = 'nav' AND p_in_field AND jsonb_typeof(e.value) = 'object' AND e.value ? 'path'
                               THEN (e.value - 'path') || jsonb_build_object('on_ctrl_click', jsonb_build_object('path', e.value -> 'path'))
                           WHEN e.key = 'nav' AND p_in_field AND jsonb_typeof(e.value) = 'object' AND e.value ? 'on_select' AND NOT e.value ? 'on_ctrl_click'
                               THEN (e.value - 'on_select') || jsonb_build_object('on_ctrl_click', e.value -> 'on_select')
                           WHEN e.key = 'field_config' AND jsonb_typeof(e.value) = 'object'
                               THEN (SELECT coalesce(jsonb_object_agg(f.key, pg_temp.nav_on_ctrl_click(f.value, true)), '{}'::jsonb)
                                     FROM jsonb_each(e.value) f)
                           ELSE pg_temp.nav_on_ctrl_click(e.value, false)
                       END), '{}'::jsonb)
            FROM jsonb_each(p) e)
        WHEN 'array' THEN (
            SELECT coalesce(jsonb_agg(pg_temp.nav_on_ctrl_click(e.value, false) ORDER BY e.ordinality), '[]'::jsonb)
            FROM jsonb_array_elements(p) WITH ORDINALITY e(value, ordinality))
        ELSE p END
$$;

UPDATE site.data_group d
SET data_group_json = pg_temp.nav_on_ctrl_click(d.data_group_json)
WHERE d.data_group_json::text LIKE '%"nav"%'
  AND d.data_group_json IS DISTINCT FROM pg_temp.nav_on_ctrl_click(d.data_group_json);

COMMIT;

-- expected: no field nav with a direct path left; the field navs carry on_ctrl_click
SELECT data_group_id, data_group,
       (data_group_json::text LIKE '%"nav": {"path"%')          AS still_direct_path,
       (data_group_json::text LIKE '%"nav": {"on_ctrl_click"%') AS has_on_ctrl_click,
       (data_group_json::text LIKE '%"nav": {"on_select"%')     AS has_on_select
FROM site.data_group
WHERE data_group_json::text LIKE '%"nav"%'
ORDER BY data_group_id;
