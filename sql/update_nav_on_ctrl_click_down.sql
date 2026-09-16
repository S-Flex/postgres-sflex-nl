-- Rollback of sql/update_nav_on_ctrl_click.sql: a field nav whose on_ctrl_click
-- holds only a path goes back to nav.path.
BEGIN;

CREATE OR REPLACE FUNCTION pg_temp.nav_path(p jsonb) RETURNS jsonb
    LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE jsonb_typeof(p)
        WHEN 'object' THEN (
            SELECT coalesce(jsonb_object_agg(
                       e.key,
                       CASE WHEN e.key = 'nav' AND jsonb_typeof(e.value) = 'object'
                             AND e.value -> 'on_ctrl_click' ? 'path'
                             AND (SELECT count(*) FROM jsonb_object_keys(e.value -> 'on_ctrl_click')) = 1
                            THEN (e.value - 'on_ctrl_click') || jsonb_build_object('path', e.value -> 'on_ctrl_click' -> 'path')
                            ELSE pg_temp.nav_path(e.value) END), '{}'::jsonb)
            FROM jsonb_each(p) e)
        WHEN 'array' THEN (
            SELECT coalesce(jsonb_agg(pg_temp.nav_path(e.value) ORDER BY e.ordinality), '[]'::jsonb)
            FROM jsonb_array_elements(p) WITH ORDINALITY e(value, ordinality))
        ELSE p END
$$;

UPDATE site.data_group d
SET data_group_json = pg_temp.nav_path(d.data_group_json)
WHERE d.data_group_json::text LIKE '%"nav": {"on_ctrl_click": {"path"%';

COMMIT;
