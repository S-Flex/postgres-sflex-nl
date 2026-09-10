-- The pattern: one row per planned imposing moment, keyed by weekday, step,
-- impose path, material and instance. The chaining offset is not here — it
-- lives on the impose resource (resource_json.next_start_lag_in_seconds and
-- next_start_after_first_item), so a moment has no length of its own to
-- absorb into a following spacer.
drop function if exists mock.crud_material_resource_plan(jsonb, boolean);
-- the two-argument version from before the spacer logic disappeared
drop function if exists mock.crud_material_impose_plan(jsonb, boolean);

create or replace function mock.crud_material_impose_plan(p_data jsonb) returns SETOF mock.material_impose_plan
	language sql
as $$
    INSERT INTO mock.material_impose_plan
        (weekday, step, resource_path, sort_order, material_id, instance,
         production_line_id, tenant_id, start_offset_in_seconds, is_pinned)
    SELECT (e ->> 'weekday')::smallint,
            e ->> 'step',
           (e ->> 'resource_path')::ltree,
           (e ->> 'sort_order')::numeric,
           (e ->> 'material_id')::integer,
           coalesce((e ->> 'instance')::integer, 0),
           (e ->> 'production_line_id')::integer,
           (e ->> 'tenant_id')::integer,
           (e ->> 'start_offset_in_seconds')::integer,
           (e ->> 'is_pinned')::boolean
    FROM jsonb_array_elements(p_data) AS e
    RETURNING *;
$$;

alter function mock.crud_material_impose_plan(jsonb) owner to xfw3;
