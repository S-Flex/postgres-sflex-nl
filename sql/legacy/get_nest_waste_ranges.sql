-- p_resource_uids keeps to the nests printed on those resources (a print job in
-- log.data ran there; legacy.nest has no resource). p_nest_date is one day, for the
-- sidebar per resource; p_dates wins when both are given, neither is today.
-- The waste of the nests in ranges: per tenant, material, day and range of
-- waste_percentage (between 70 and 60, 60 and 50, ... 10 and 0, and above the
-- top bound) the nests, their area, the average waste and what that waste
-- costs, over the nests nested on the days of p_dates (a datemultirange; the
-- day of nested_at in Amsterdam time). A nest of a material whose imposition
-- group has a parent counts with the parent
-- (legacy.imposition_group.parent_imposition_group_id), as the queue and the
-- print schedule do. The ranges are legacy.lookup lookup_nest_waste_ranges
-- (json/lookup/legacy/lookup_nest_waste_ranges.json): code, range_min,
-- range_max and sort_order, class_names for the board; a range takes
-- range_min <= waste < range_max. Every range of a tenant, material and day is
-- a row, also an empty one. There is no total row: the flow-table sums the
-- ranges itself (row_options.summary, 14 Sep 2026).
--
-- The tenant of a nest is the tenant of its production line
-- (nest_json.production_line_id -> relation.production_line.tenant_id); the
-- imposition groups are per tenant, so the group is joined on it (a nest
-- without a line takes Dokkum, 1). tenant_id and tenant_name are returned so
-- the board can tell the tenants apart.
--
-- nest_count is the sum of legacy.nest.amount (the impositions of the sheet),
-- sqm is width * height * amount in m2 (the dimensions are cm), waste_sqm is
-- the sqm times the waste of the nest, waste_cost is waste_sqm times the
-- purchase price per m2 of the material: the active catalog.item_base_price
-- row of the material item for the tenant of the nest (the newest version),
-- the first price tier (price_tiers_json -> 0 ->> 'purchase_price'). Null
-- when the material has no price for that tenant.
-- p_line_type keeps to the nests of the production lines of that type
-- (relation.production_line.line_type of the nest's line); null is every line.
-- Set-based, one statement. The return type changed (tenant columns, no
-- is_total), so the old signature goes first.
drop function if exists legacy.get_nest_waste_percentiles(datemultirange, integer[], numeric[]);
drop function if exists legacy.get_nest_waste_ranges(datemultirange, integer[], numeric[]);
drop function if exists legacy.get_nest_waste_ranges(datemultirange, integer[]);
drop function if exists legacy.get_nest_waste_ranges(datemultirange, integer[], text);
drop function if exists legacy.get_nest_waste_ranges(datemultirange, integer[], text, text[], date);

create function legacy.get_nest_waste_ranges(p_dates datemultirange DEFAULT NULL::datemultirange, p_material_ids integer[] DEFAULT NULL::integer[], p_line_type text DEFAULT NULL::text, p_resource_uids text[] DEFAULT NULL::text[], p_nest_date date DEFAULT NULL::date) returns TABLE(tenant_id integer, tenant_name text, material_id integer, material_name text, nest_date date, range_min numeric, range_max numeric, waste_range text, sort_order integer, class_names text[], nest_count integer, sqm numeric, avg_waste_percentage numeric, waste_sqm numeric, purchase_price_per_sqm numeric, waste_cost numeric)
	stable
	language sql
as $$
    WITH nest AS (
        -- the material (the parent for a child) and the tenant of a nest live
        -- in its json and its production line; legacy.nest has no columns for them
        SELECT coalesce(g.parent_imposition_group_id, (n.nest_json ->> 'material_id')::integer) AS material_id,
               pl.tenant_id,
               (n.nested_at AT TIME ZONE 'Europe/Amsterdam')::date AS nest_date,
               (n.nest_json ->> 'waste_percentage')::numeric         AS waste_percentage,
               coalesce(n.amount, 1)                                  AS amount,
               n.width * n.height / 10000 * coalesce(n.amount, 1)     AS sqm
        FROM legacy.nest n
        LEFT JOIN relation.production_line pl ON pl.line_id = (n.nest_json ->> 'production_line_id')::integer
        -- the group of the nest's tenant; a nest without a line is Dokkum's (1)
        LEFT JOIN legacy.imposition_group g ON g.imposition_group_id = (n.nest_json ->> 'material_id')::integer
                                           AND g.tenant_id = coalesce(pl.tenant_id, 1)
        -- the days: p_dates, else p_nest_date, else today
        WHERE (n.nested_at AT TIME ZONE 'Europe/Amsterdam')::date <@ coalesce(p_dates, datemultirange(daterange(coalesce(p_nest_date, current_date), coalesce(p_nest_date, current_date), '[]')))
          AND n.nest_json ? 'waste_percentage'
          -- the nests printed on the resources: a print job of the nest ran there
          AND (p_resource_uids IS NULL
               OR EXISTS (SELECT 1 FROM log.data dl
                          WHERE dl.nest_name = n.nest_name
                            AND dl.resource_uid = ANY (p_resource_uids)))
          AND (p_line_type IS NULL OR pl.line_type = p_line_type)
          AND (p_material_ids IS NULL
               OR coalesce(g.parent_imposition_group_id, (n.nest_json ->> 'material_id')::integer) = ANY (p_material_ids))
    ),
    range AS (
        -- the ranges of the lookup: [range_min, range_max), the top one open
        SELECT (v.value ->> 'range_min')::numeric AS range_min,
               (v.value ->> 'range_max')::numeric AS range_max,
               v.value ->> 'code'                 AS waste_range,
               (v.value ->> 'sort_order')::integer AS sort_order,
               coalesce((SELECT array_agg(c.value) FROM jsonb_array_elements_text(coalesce(v.value -> 'class_names', '[]'::jsonb)) AS c(value)),
                        '{}'::text[]) AS class_names
        FROM legacy.lookup l
        CROSS JOIN LATERAL jsonb_array_elements(l.lookup_json) AS v(value)
        WHERE l.lookup = 'lookup_nest_waste_ranges'
    ),
    material AS (
        SELECT DISTINCT n.tenant_id, n.material_id, n.nest_date FROM nest n
    ),
    material_item AS (
        -- the material item of the group: the path in item group material.
        -- DISTINCT: the same paths exist once per tenant
        SELECT DISTINCT g.imposition_group_id AS material_id, i.item_code
        FROM legacy.imposition_group g
        JOIN catalog.item i ON i.item_code_path = ANY (g.item_code_paths) AND i.item_group_code = 'material'
        WHERE g.imposition_group_id IN (SELECT m.material_id FROM material m)
    ),
    price AS (
        -- the purchase price per m2 of every material item, per tenant: the
        -- newest active base price of the tenant itself
        SELECT DISTINCT ON (bp.tenant_id, mi.material_id)
               bp.tenant_id, mi.material_id,
               (bp.price_tiers_json -> 0 ->> 'purchase_price')::numeric AS purchase_price_per_sqm
        FROM material_item mi
        JOIN catalog.item_base_price bp ON bp.item_code = mi.item_code
                                       AND bp.version_status = 'active'
        ORDER BY bp.tenant_id, mi.material_id, bp.created_at DESC, bp.version DESC
    )
    SELECT m.tenant_id,
           t.name AS tenant_name,
           m.material_id,
           -- the name on a line of the type in view first
           (SELECT mpl.material_name
            FROM mapping.material_production_line mpl
            LEFT JOIN relation.production_line pl ON pl.line_id = mpl.production_line_id
            WHERE mpl.material_id = m.material_id
            ORDER BY (pl.line_type = p_line_type) DESC NULLS LAST, mpl.production_line_id
            LIMIT 1) AS material_name,
           m.nest_date,
           r.range_min,
           r.range_max,
           r.waste_range,
           r.sort_order,
           r.class_names,
           coalesce(sum(n.amount), 0)::integer                      AS nest_count,
           round(coalesce(sum(n.sqm), 0), 2)                        AS sqm,
           round(avg(n.waste_percentage), 1)                        AS avg_waste_percentage,
           round(coalesce(sum(n.sqm * n.waste_percentage / 100), 0), 2) AS waste_sqm,
           min(pr.purchase_price_per_sqm)                            AS purchase_price_per_sqm,
           round(sum(n.sqm * n.waste_percentage / 100 * pr.purchase_price_per_sqm), 2) AS waste_cost
    FROM material m
    LEFT JOIN site.tenant t ON t.tenant_id = m.tenant_id
    CROSS JOIN range r
    LEFT JOIN nest n ON n.tenant_id IS NOT DISTINCT FROM m.tenant_id
                    AND n.material_id = m.material_id
                    AND n.nest_date = m.nest_date
                    AND n.waste_percentage >= r.range_min
                    AND (r.range_max IS NULL OR n.waste_percentage < r.range_max)
    LEFT JOIN price pr ON pr.material_id = n.material_id AND pr.tenant_id = n.tenant_id
    GROUP BY m.tenant_id, t.name, m.material_id, m.nest_date, r.range_min, r.range_max, r.waste_range, r.sort_order, r.class_names
    ORDER BY m.tenant_id, m.material_id, m.nest_date, r.sort_order;
$$;

alter function legacy.get_nest_waste_ranges(datemultirange, integer[], text, text[], date) owner to xfw3;
