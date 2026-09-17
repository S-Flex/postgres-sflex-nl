-- Read-only: does catalog.item.item_json carry everything that
-- mapping.material_production_line.line_json.specs carries?
-- (docs/supply-handling.md). Run before sql/update_item_supply_unit_height.sql.
--
-- The legacy spec has weight and thickness in the spec itself; on the item
-- those moved to item_json.params, one set for the whole item. Everything else
-- should be there key for key, value for value.

-- ── 1. which keys occur on each side, and how often ──────────────────────
WITH legacy AS (
    SELECT s.key, count(*) AS n
    FROM mapping.material_production_line m
    CROSS JOIN LATERAL jsonb_array_elements(coalesce(m.line_json -> 'specs', '[]'::jsonb)) e
    CROSS JOIN LATERAL jsonb_each(e.value) s
    GROUP BY s.key
),
item AS (
    SELECT s.key, count(*) AS n
    FROM catalog.item i
    CROSS JOIN LATERAL jsonb_array_elements(coalesce(i.item_json -> 'specs', '[]'::jsonb)) e
    CROSS JOIN LATERAL jsonb_each(e.value) s
    GROUP BY s.key
)
SELECT coalesce(l.key, t.key) AS key,
       l.n AS in_material_production_line,
       t.n AS in_item_json
FROM legacy l
FULL JOIN item t ON t.key = l.key
ORDER BY 1;

-- ── 2. per material: the specs on both sides, side by side ───────────────
-- A row where item_specs is null is a material without an item; a row where
-- the two jsonb differ by more than weight/thickness needs a look.
SELECT m.material_id,
       i.item_code,
       i.item_json ->> 'media_type' AS media_type,
       jsonb_array_length(coalesce(m.line_json -> 'specs', '[]'::jsonb))  AS legacy_specs,
       jsonb_array_length(coalesce(i.item_json -> 'specs', '[]'::jsonb))  AS item_specs,
       i.item_json -> 'params'                                           AS item_params
FROM mapping.material_production_line m
LEFT JOIN catalog.item i ON (i.item_json ->> 'material_id')::integer = m.material_id
ORDER BY m.material_id
LIMIT 100;

-- ── 3. the values themselves: every legacy spec key that the item misses ─
-- Expect only weight and thickness (they live in item_json.params now).
-- Anything else in this result is information that did not make the move.
SELECT m.material_id, i.item_code, s.key,
       s.value        AS legacy_value,
       ie.value -> s.key AS item_value
FROM mapping.material_production_line m
JOIN catalog.item i ON (i.item_json ->> 'material_id')::integer = m.material_id
CROSS JOIN LATERAL jsonb_array_elements(coalesce(m.line_json -> 'specs', '[]'::jsonb)) le
CROSS JOIN LATERAL jsonb_each(le.value) s
LEFT JOIN LATERAL (
    SELECT e.value
    FROM jsonb_array_elements(coalesce(i.item_json -> 'specs', '[]'::jsonb)) e
    WHERE e.value ->> 'article_code' = le.value ->> 'article_code'
    LIMIT 1
) ie ON true
WHERE ie.value IS NULL OR NOT (ie.value ? s.key) OR ie.value -> s.key IS DISTINCT FROM s.value
ORDER BY s.key, m.material_id
LIMIT 200;

-- ── 4. materials on one side only ────────────────────────────────────────
SELECT 'only in material_production_line' AS side, count(*) AS materials
FROM mapping.material_production_line m
WHERE NOT EXISTS (SELECT 1 FROM catalog.item i
                  WHERE (i.item_json ->> 'material_id')::integer = m.material_id)
UNION ALL
SELECT 'only in catalog.item', count(*)
FROM catalog.item i
WHERE i.item_json ? 'material_id'
  AND NOT EXISTS (SELECT 1 FROM mapping.material_production_line m
                  WHERE m.material_id = (i.item_json ->> 'material_id')::integer);
