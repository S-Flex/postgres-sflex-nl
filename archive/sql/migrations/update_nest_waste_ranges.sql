-- The waste of the nests in ranges (docs/plan-nest-waste-ranges.md):
-- legacy.get_nest_waste_ranges, per material, day and waste range the nests,
-- their area, the average waste, the waste area and its cost at the purchase
-- price (the tenant's own active catalog.item_base_price row; null until
-- the material has one); a child material counted with its parent; the ranges
-- from legacy.lookup lookup_nest_waste_ranges, the total row marked is_total.
-- Plus mapping.get_materials, the material list of the filter, and the
-- data_table rows of both. The data_groups (96 table, 97 filter, 98 chart) are
-- in sql/update_data_group_partial.sql, run after this one.
BEGIN;

-- the ranges of the board (json/lookup/legacy/lookup_nest_waste_ranges.json)
UPDATE legacy.lookup SET lookup_json = $json$[
  {
    "code": "0-10",
    "range_min": 0,
    "range_max": 10,
    "sort_order": 0
  },
  {
    "code": "10-20",
    "range_min": 10,
    "range_max": 20,
    "sort_order": 1
  },
  {
    "code": "20-30",
    "range_min": 20,
    "range_max": 30,
    "sort_order": 2
  },
  {
    "code": "30-40",
    "range_min": 30,
    "range_max": 40,
    "sort_order": 3
  },
  {
    "code": "40-50",
    "range_min": 40,
    "range_max": 50,
    "sort_order": 4
  },
  {
    "code": "50-60",
    "range_min": 50,
    "range_max": 60,
    "sort_order": 5
  },
  {
    "code": "60-70",
    "range_min": 60,
    "range_max": 70,
    "sort_order": 6
  },
  {
    "code": "70-100",
    "range_max": 100,
    "range_min": 70,
    "sort_order": 7
  },
  {
    "code": "0-100",
    "range_max": 100,
    "range_min": 0,
    "sort_order": 8,
    "is_total": true,
    "class_names": [
      "aggregate"
    ]
  }
]$json$::jsonb WHERE lookup = 'lookup_nest_waste_ranges';
INSERT INTO legacy.lookup (lookup, lookup_json)
SELECT 'lookup_nest_waste_ranges', $json$[
  {
    "code": "0-10",
    "range_min": 0,
    "range_max": 10,
    "sort_order": 0
  },
  {
    "code": "10-20",
    "range_min": 10,
    "range_max": 20,
    "sort_order": 1
  },
  {
    "code": "20-30",
    "range_min": 20,
    "range_max": 30,
    "sort_order": 2
  },
  {
    "code": "30-40",
    "range_min": 30,
    "range_max": 40,
    "sort_order": 3
  },
  {
    "code": "40-50",
    "range_min": 40,
    "range_max": 50,
    "sort_order": 4
  },
  {
    "code": "50-60",
    "range_min": 50,
    "range_max": 60,
    "sort_order": 5
  },
  {
    "code": "60-70",
    "range_min": 60,
    "range_max": 70,
    "sort_order": 6
  },
  {
    "code": "70-100",
    "range_max": 100,
    "range_min": 70,
    "sort_order": 7
  },
  {
    "code": "0-100",
    "range_max": 100,
    "range_min": 0,
    "sort_order": 8,
    "is_total": true,
    "class_names": [
      "aggregate"
    ]
  }
]$json$::jsonb
WHERE NOT EXISTS (SELECT 1 FROM legacy.lookup WHERE lookup = 'lookup_nest_waste_ranges');

-- ============ sql/legacy/get_nest_waste_ranges.sql ============
-- The waste of the nests in ranges: per material, per day and per range of
-- waste_percentage (between 70 and 60, 60 and 50, ... 10 and 0, and above the
-- top bound) the nests, their area, the average waste and what that waste
-- costs, over the nests nested on the days of p_dates (a datemultirange; the
-- day of nested_at in Amsterdam time). A nest of a material whose imposition
-- group has a parent counts with the parent
-- (catalog.imposition_group.parent_imposition_group_id), as the queue and the
-- print schedule do. The ranges are legacy.lookup lookup_nest_waste_ranges
-- (json/lookup/legacy/lookup_nest_waste_ranges.json): code, range_min,
-- range_max and sort_order, is_total on the row that spans everything (the
-- board's total, the chart leaves it out), class_names for the board (the
-- total carries aggregate); a range takes range_min <= waste < range_max. Every range of a material and day is a row, also an empty one.
--
-- nest_count is the sum of legacy.nest.amount (the impositions of the sheet),
-- sqm is width * height * amount in m2 (the dimensions are cm), waste_sqm is
-- the sqm times the waste of the nest, waste_cost is waste_sqm times the
-- purchase price per m2 of the material: the active catalog.item_base_price
-- row of the material item for the tenant of the nest's production line (the
-- newest version), the first price tier (price_tiers_json -> 0 ->>
-- 'purchase_price'). Null when the material has no price for that tenant.
-- Set-based, one statement.
drop function if exists legacy.get_nest_waste_percentiles(datemultirange, integer[], numeric[]);
drop function if exists legacy.get_nest_waste_ranges(datemultirange, integer[], numeric[]);
drop function if exists legacy.get_nest_waste_ranges(datemultirange, integer[]);

create function legacy.get_nest_waste_ranges(p_dates datemultirange DEFAULT datemultirange(daterange(current_date, current_date, '[]')), p_material_ids integer[] DEFAULT NULL::integer[]) returns TABLE(material_id integer, material_name text, nest_date date, range_min numeric, range_max numeric, waste_range text, is_total boolean, sort_order integer, class_names text[], nest_count integer, sqm numeric, avg_waste_percentage numeric, waste_sqm numeric, purchase_price_per_sqm numeric, waste_cost numeric)
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
        LEFT JOIN catalog.imposition_group g ON g.imposition_group_id = (n.nest_json ->> 'material_id')::integer
        LEFT JOIN relation.production_line pl ON pl.line_id = (n.nest_json ->> 'production_line_id')::integer
        WHERE (n.nested_at AT TIME ZONE 'Europe/Amsterdam')::date <@ p_dates
          AND n.nest_json ? 'waste_percentage'
          AND (p_material_ids IS NULL
               OR coalesce(g.parent_imposition_group_id, (n.nest_json ->> 'material_id')::integer) = ANY (p_material_ids))
    ),
    range AS (
        -- the ranges of the lookup: [range_min, range_max), the top one open
        SELECT (v.value ->> 'range_min')::numeric AS range_min,
               (v.value ->> 'range_max')::numeric AS range_max,
               v.value ->> 'code'                 AS waste_range,
               coalesce((v.value ->> 'is_total')::boolean, false) AS is_total,
               (v.value ->> 'sort_order')::integer AS sort_order,
               coalesce((SELECT array_agg(c.value) FROM jsonb_array_elements_text(coalesce(v.value -> 'class_names', '[]'::jsonb)) AS c(value)),
                        '{}'::text[]) AS class_names
        FROM legacy.lookup l
        CROSS JOIN LATERAL jsonb_array_elements(l.lookup_json) AS v(value)
        WHERE l.lookup = 'lookup_nest_waste_ranges'
    ),
    material AS (
        SELECT DISTINCT n.material_id, n.nest_date FROM nest n
    ),
    material_item AS (
        -- the material item of the group: the path in item group material
        SELECT g.imposition_group_id AS material_id, i.item_code
        FROM catalog.imposition_group g
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
    SELECT m.material_id,
           (SELECT mpl.material_name
            FROM mapping.material_production_line mpl
            WHERE mpl.material_id = m.material_id
            ORDER BY mpl.production_line_id
            LIMIT 1) AS material_name,
           m.nest_date,
           r.range_min,
           r.range_max,
           r.waste_range,
           r.is_total,
           r.sort_order,
           r.class_names,
           coalesce(sum(n.amount), 0)::integer                      AS nest_count,
           round(coalesce(sum(n.sqm), 0), 2)                        AS sqm,
           round(avg(n.waste_percentage), 1)                        AS avg_waste_percentage,
           round(coalesce(sum(n.sqm * n.waste_percentage / 100), 0), 2) AS waste_sqm,
           min(pr.purchase_price_per_sqm)                            AS purchase_price_per_sqm,
           round(sum(n.sqm * n.waste_percentage / 100 * pr.purchase_price_per_sqm), 2) AS waste_cost
    FROM material m
    CROSS JOIN range r
    LEFT JOIN nest n ON n.material_id = m.material_id
                    AND n.nest_date = m.nest_date
                    AND n.waste_percentage >= r.range_min
                    AND (r.range_max IS NULL OR n.waste_percentage < r.range_max)
    LEFT JOIN price pr ON pr.material_id = n.material_id AND pr.tenant_id = n.tenant_id
    GROUP BY m.material_id, m.nest_date, r.range_min, r.range_max, r.waste_range, r.is_total, r.sort_order, r.class_names
    ORDER BY m.material_id, m.nest_date, r.sort_order;
$$;

alter function legacy.get_nest_waste_ranges(datemultirange, integer[]) owner to xfw3;

DELETE FROM site.data_table WHERE data_table = 'get_nest_waste_percentiles';

INSERT INTO site.data_table (data_table, query, stored_proc, description, data_table_json, do_cache)
VALUES ('get_nest_waste_ranges',
        'legacy.get_nest_waste_ranges',
        '',
        'waste of the nests in ranges per material and day, with area and cost (boards 96 and 98)',
        '{"primary_keys": ["material_id", "nest_date", "range_min"]}'::jsonb,
        false)
ON CONFLICT (data_table) DO UPDATE
    SET query           = EXCLUDED.query,
        description     = EXCLUDED.description,
        data_table_json = EXCLUDED.data_table_json;

-- ============ sql/mapping/get_materials.sql ============
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

INSERT INTO site.data_table (data_table, query, stored_proc, description, data_table_json, do_cache)
VALUES ('get_materials',
        'mapping.get_materials',
        '',
        'the materials with a print schedule on the production lines given, parents only, ordered by name: the one list for every material select',
        '{"primary_keys": ["material_id"]}'::jsonb,
        false)
ON CONFLICT (data_table) DO UPDATE
    SET query           = EXCLUDED.query,
        description     = EXCLUDED.description,
        data_table_json = EXCLUDED.data_table_json;

COMMIT;

-- check: the last three days, the busiest ranges first
SELECT material_name, nest_date, waste_range, class_names, nest_count, sqm, avg_waste_percentage, waste_sqm, waste_cost
FROM legacy.get_nest_waste_ranges(datemultirange(daterange(current_date - 3, current_date, '[]')))
WHERE nest_count > 0
ORDER BY nest_count DESC
LIMIT 30;
