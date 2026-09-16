-- Test the xbom impact formulas without writing anything: resolves the xbom
-- rows for the given orderlines exactly like mapping.create_spec_unit_manifest
-- and shows the variables plus the COMPLETE public.evaluate_many_nas result
-- per row. Fill the array below and run; rows without a formula show
-- has_formula = false and a null result.
--
-- The formula hangs on the xbom row through formula_code: catalog.formula,
-- active version, formula_json is the line array (last line wins the column).
-- Variables per row, same as the builder, least specific first: numeric keys
-- of the item's item_json, then its params (weight, thickness), then the
-- numeric keys of the xbom row's param_json, and width/height of the
-- orderline plus amount = 1 (per unit) win over all of them.

WITH ids AS (
    SELECT '{1,2,3}'::integer[] AS production_orderline_ids   -- <<< fill in
),
orderline_codes AS (
    SELECT cs.production_orderline_id,
           unnest(t.option_codes) AS option_code
    FROM   ids, mapping.component_specs cs
    JOIN   mapping.sales_orderline_option slo
           ON slo.sales_orderline_id = cs.sales_orderline_id
    JOIN   mapping.option_translation t
           ON t.product_api_code = slo.product_api_code
           AND t.api_code = slo.api_code
    WHERE  cs.production_orderline_id = ANY(ids.production_orderline_ids)

    UNION

    SELECT cs.production_orderline_id,
           unnest(t.option_codes)
    FROM   ids, mapping.component_specs cs
    JOIN   mapping.option_translation t
           ON t.material_id = cs.material_id
    WHERE  cs.production_orderline_id = ANY(ids.production_orderline_ids)
),
default_codes AS (
    SELECT DISTINCT cs.production_orderline_id, c.option_code
    FROM   ids, mapping.component_specs cs
    JOIN   mapping.sales_orderline_option slo
           ON slo.sales_orderline_id = cs.sales_orderline_id
    JOIN   mapping.option_translation t
           ON t.product_api_code = slo.product_api_code
           AND t.api_code = 'default'
    CROSS  JOIN LATERAL unnest(t.option_codes) AS c(option_code)
    WHERE  cs.production_orderline_id = ANY(ids.production_orderline_ids)
      AND  NOT EXISTS (
               SELECT 1
               FROM   orderline_codes o
               WHERE  o.production_orderline_id = cs.production_orderline_id
                 AND  split_part(o.option_code, '.', 1) = split_part(c.option_code, '.', 1)
           )
),
selected AS (
    SELECT   production_orderline_id,
             array_agg(DISTINCT option_code) AS option_codes
    FROM     (SELECT * FROM orderline_codes
              UNION
              SELECT * FROM default_codes) all_codes
    GROUP BY production_orderline_id
),
matched AS (
    SELECT s.production_orderline_id,
           x.xbom_id, x.option_code, x.item_code, x.scope, x.param_json,
           x.formula_code,
           string_to_array(x.option_code, ';')              AS code_parts,
           cardinality(string_to_array(x.option_code, ';')) AS part_count
    FROM   selected s
    JOIN   catalog.xbom x
      ON   string_to_array(x.option_code, ';') <@ s.option_codes
    WHERE  x.version_status = 'active'
),
filtered AS (
    SELECT m.*
    FROM   matched m
    WHERE  NOT EXISTS (
               SELECT 1
               FROM   matched m2
               WHERE  m2.production_orderline_id = m.production_orderline_id
                 AND  m2.scope      = m.scope
                 AND  m2.code_parts @> m.code_parts
                 AND  m2.part_count > m.part_count
           )
)
SELECT f.production_orderline_id,
       f.option_code,
       f.item_code,
       f.scope,
       f.formula_code,
       cf.formula_json IS NOT NULL                 AS has_formula,
       cf.formula_json                             AS formula,
       vars.variables,
       CASE WHEN cf.formula_json IS NOT NULL
            THEN public.evaluate_many_nas(cf.formula_json, vars.variables)
       END                                         AS evaluate_result
FROM   filtered f
LEFT   JOIN mapping.component_specs cs
       ON cs.production_orderline_id = f.production_orderline_id
LEFT   JOIN catalog.item ci
       ON ci.item_code = f.item_code
LEFT   JOIN LATERAL (
    SELECT c.formula_json
    FROM   catalog.formula c
    WHERE  c.formula_code = f.formula_code
      AND  c.version_status = 'active'
    ORDER BY c.version DESC
    LIMIT 1
) cf ON true
CROSS  JOIN LATERAL (
    SELECT coalesce((SELECT jsonb_object_agg(e.key, e.value)
                     FROM jsonb_each(ci.item_json) e
                     WHERE jsonb_typeof(e.value) = 'number'), '{}'::jsonb)
           || coalesce((SELECT jsonb_object_agg(e.key, e.value)
                        FROM jsonb_each(ci.item_json -> 'params') e
                        WHERE jsonb_typeof(e.value) = 'number'), '{}'::jsonb)
           || coalesce((SELECT jsonb_object_agg(e.key, e.value)
                        FROM jsonb_each(f.param_json) e
                        WHERE jsonb_typeof(e.value) = 'number'), '{}'::jsonb)
           || jsonb_build_object(
                  'width',  coalesce(cs.product_width, 0),
                  'height', coalesce(cs.product_height, 0),
                  'amount', 1) AS variables
) vars
ORDER BY f.production_orderline_id, f.scope, f.option_code;
