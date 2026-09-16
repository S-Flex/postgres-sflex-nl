-- mapping.crud_material took the string "null" of the hub payload into
-- line_json as a string, so line_json ->> 'delivery_hours' read 'null'. The
-- writer now turns that string into the JSON null for every key, and the
-- rows already written are cleaned the same way (today none carry it: 33
-- rows hold a JSON null, 36 have no delivery_hours key at all).
BEGIN;

-- ============ sql/mapping/crud_material.sql ============
-- The material payload of the hub: one element per material, the element
-- itself (minus crud) is the line_json. Shallow merge into every line row of
-- the material (new keys overwrite, untouched keys survive); a material
-- without a row gets one. The source serialises an empty value as the string
-- "null"; that is the JSON null here, for every key, so line_json ->>
-- 'delivery_hours' never reads 'null'. Set-based: no loop, no temp table.
create or replace function mapping.crud_material(p_param_json jsonb, p_no_results boolean DEFAULT false) returns TABLE(param_id integer, track_by integer, crud text, domain_id integer, material_id integer, material_name text)
	language sql
as $$
    WITH payload AS (
        SELECT row_number() OVER (ORDER BY coalesce((el ->> 'track_by')::integer, 0))::integer AS param_id,
               coalesce((el ->> 'track_by')::integer, 0) AS track_by,
               el ->> 'crud'                   AS crud,
               (el ->> 'domain_id')::integer   AS domain_id,
               (el ->> 'material_id')::integer AS material_id,
               el ->> 'material_name'          AS material_name,
               -- the string "null" is the JSON null
               (SELECT coalesce(jsonb_object_agg(e.key, CASE WHEN e.value = '"null"'::jsonb THEN 'null'::jsonb ELSE e.value END),
                                '{}'::jsonb)
                FROM jsonb_each(el - 'crud') AS e) AS line_json
        FROM jsonb_array_elements(p_param_json) AS el
    ),
    updated AS (
        UPDATE mapping.material_production_line mpl
        SET domain_id = p.domain_id,
            line_json = mpl.line_json || p.line_json
        FROM payload p
        WHERE mpl.material_id = p.material_id
        RETURNING mpl.material_id
    ),
    inserted AS (
        INSERT INTO mapping.material_production_line (domain_id, material_id, line_json)
        SELECT p.domain_id, p.material_id, p.line_json
        FROM payload p
        WHERE NOT EXISTS (SELECT 1 FROM mapping.material_production_line mpl
                          WHERE mpl.material_id = p.material_id)
        RETURNING material_id
    )
    -- the writes above run whether or not results are asked for
    SELECT p.param_id, p.track_by, p.crud, p.domain_id, p.material_id, p.material_name
    FROM payload p
    WHERE NOT p_no_results
    ORDER BY p.param_id;
$$;

alter function mapping.crud_material(jsonb, boolean) owner to xfw3;

-- the rows already written: every string "null" becomes the JSON null
UPDATE mapping.material_production_line mpl
SET line_json = (SELECT jsonb_object_agg(e.key, CASE WHEN e.value = '"null"'::jsonb THEN 'null'::jsonb ELSE e.value END)
                 FROM jsonb_each(mpl.line_json) AS e)
WHERE EXISTS (SELECT 1 FROM jsonb_each(mpl.line_json) AS e WHERE e.value = '"null"'::jsonb);

COMMIT;

-- check: expect 0 rows
SELECT material_id, production_line_id, e.key
FROM mapping.material_production_line mpl
CROSS JOIN LATERAL jsonb_each(mpl.line_json) AS e
WHERE e.value = '"null"'::jsonb;
