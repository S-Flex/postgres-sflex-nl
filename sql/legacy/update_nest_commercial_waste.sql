-- The commercial waste of the given nests: 100 minus the share of the sheet
-- that is sold. sold_area sums amount * width * height over the single
-- products of the nest; it can exceed the physical sheet when the same
-- bounding rectangle is sold to several customers (two triangles sharing one
-- rectangle), which correctly drives the percentage negative. Called by
-- legacy.crud_single_product and legacy.crud_nest, whichever arrives last.
drop function if exists legacy.update_nest_commercial_waste(bigint[]);

create function legacy.update_nest_commercial_waste(p_nest_ids bigint[]) returns void
	language sql
as $$
    WITH sold_area AS (
        SELECT sp.nest_id,
               sum(sp.amount
                   * (sp.single_product_json ->> 'width')::numeric
                   * (sp.single_product_json ->> 'height')::numeric) AS sold_area
        FROM legacy.single_product sp
        WHERE sp.nest_id = ANY (p_nest_ids)
        GROUP BY sp.nest_id
    )
    UPDATE legacy.nest n
    SET nest_json = jsonb_set(
        -- a null nest_json would make jsonb_set return null: start from {}
        COALESCE(n.nest_json, '{}'::jsonb),
        '{commercial_waste_percentage}',
        -- jsonb_set is strict: a null value (no material size) would wipe the
        -- whole nest_json, so the failure stays inside this one key
        COALESCE(
            to_jsonb(round(
                ((n.nest_json ->> 'material_width')::numeric * (n.nest_json ->> 'material_height')::numeric
                 - COALESCE(sa.sold_area, 0))
                / NULLIF((n.nest_json ->> 'material_width')::numeric * (n.nest_json ->> 'material_height')::numeric, 0)
                * 100, 2)),
            'null'::jsonb),
        true)
    FROM sold_area sa
    WHERE n.nest_id = sa.nest_id;
$$;

alter function legacy.update_nest_commercial_waste(bigint[]) owner to xfw3;
