-- The setting that wins for a resource: the longest matching path, a row
-- naming the imposition group beats a row without one, and of equal rows the
-- newest moved_at. That rule (production.resource_setting) sat as a lateral in
-- every board read; it lives here now.
--
-- p_imposition_group_id null asks for the general setting of the resource, the
-- one without a group.
create or replace function production.get_resource_setting(p_resource_path ltree, p_imposition_group_id integer DEFAULT NULL::integer) returns jsonb
    stable
    language sql
as $$
    SELECT s.setting_json
    FROM production.resource_setting s
    WHERE p_resource_path <@ s.resource_path
      AND (s.imposition_group_id IS NULL OR s.imposition_group_id = p_imposition_group_id)
    ORDER BY nlevel(s.resource_path) DESC,
             (s.imposition_group_id IS NOT NULL) DESC,
             s.moved_at DESC
    LIMIT 1
$$;

alter function production.get_resource_setting(ltree, integer) owner to xfw3;
