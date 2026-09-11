-- The materials a board can filter on: the materials with a print schedule
-- (mock.material_print_schedule) on the production lines given, one row per
-- material, ordered by name. A material whose imposition group has a parent
-- is not listed on its own: it nests, queues and counts with the parent
-- (catalog.imposition_group.parent_imposition_group_id). p_production_line_ids
-- null is every line. The one material list for every material select.
drop function if exists mapping.get_materials(text);
drop function if exists mapping.get_materials(integer[]);

create function mapping.get_materials(p_production_line_ids integer[] DEFAULT NULL::integer[]) returns TABLE(material_id integer, material_name text, production_line_ids integer[])
	stable
	language sql
as $$
    SELECT mps.material_id,
           min(mps.material_name)                                    AS material_name,
           array_agg(DISTINCT mps.production_line_id ORDER BY mps.production_line_id) AS production_line_ids
    FROM mock.material_print_schedule mps
    LEFT JOIN catalog.imposition_group g ON g.imposition_group_id = mps.material_id
    WHERE g.parent_imposition_group_id IS NULL
      AND (p_production_line_ids IS NULL OR mps.production_line_id = ANY (p_production_line_ids))
    GROUP BY mps.material_id
    ORDER BY min(mps.material_name), mps.material_id;
$$;

alter function mapping.get_materials(integer[]) owner to xfw3;
