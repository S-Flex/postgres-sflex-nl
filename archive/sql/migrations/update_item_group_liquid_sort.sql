-- Imposition group order (14 Sep 2026). legacy.get_imposition_group sorts the
-- item code paths of a group by the sort_order of the item's group (material
-- 10, print-method 20, surface-finish 30), then by path. The four liquid.*
-- items (aquaseal, anti graffiti, antislip) sat in the group material, so a
-- liquid sorted among the materials and, alphabetically, before sheet:
-- {liquid.aquaseal.mat, sheet.dibond.premium.6mm, print.method.full.color}.
-- The orderline manifests (mapping.component_specs manifest_json.imposition
-- .item_code_paths) already carry material, print, liquid, so 490 open
-- orderlines matched their group as a set but not as an array.
--   1. catalog.item: the liquid items into the group surface-finish
--   2. legacy.imposition_group: the 39 arrays with a liquid re-sorted under
--      the rule; no two groups collapse into one (checked 14 Sep: 0 twins;
--      the unique constraint stops the script if that changed)
--   3. legacy.nest.manifest_json.item_code_paths: the copies of those arrays
--      on the nests of the last 30 days follow
-- Not touched: the stored orderline manifests. Their config merge takes the
-- highest item group level per key; liquid rows now carry level 30 instead of
-- 10, so a liquid key wins over a material key from the next refresh on.
-- Rollback: sql/update_item_group_liquid_sort_down.sql.
BEGIN;

-- ============ catalog.item ============
UPDATE catalog.item i
SET item_group_code = 'surface-finish'
WHERE i.item_code_path <@ 'liquid'::ltree
  AND i.item_group_code = 'material';

-- ============ legacy.imposition_group ============
WITH resorted AS (
    SELECT g.imposition_group_id,
           (SELECT array_agg(p.path ORDER BY (ig.item_group_json ->> 'sort_order')::numeric NULLS LAST, p.path)
            FROM unnest(g.item_code_paths) AS p(path)
            LEFT JOIN catalog.item i ON i.item_code_path = p.path
            LEFT JOIN catalog.item_group ig ON ig.item_group_code = i.item_group_code) AS item_code_paths
    FROM legacy.imposition_group g
)
UPDATE legacy.imposition_group g
SET item_code_paths = r.item_code_paths
FROM resorted r
WHERE r.imposition_group_id = g.imposition_group_id
  AND r.item_code_paths <> g.item_code_paths;

-- ============ legacy.nest.manifest_json ============
UPDATE legacy.nest n
SET manifest_json = jsonb_set(n.manifest_json, '{item_code_paths}',
                              (SELECT jsonb_agg(ltree2text(p.path) ORDER BY p.ordinality)
                               FROM unnest(g.item_code_paths) WITH ORDINALITY AS p(path, ordinality)))
FROM legacy.imposition_group g
WHERE g.imposition_group_id = (n.manifest_json ->> 'imposition_group_id')::integer
  AND n.nested_at >= current_date - 30
  AND n.manifest_json -> 'item_code_paths'
      <> (SELECT jsonb_agg(ltree2text(p.path) ORDER BY p.ordinality)
          FROM unnest(g.item_code_paths) WITH ORDINALITY AS p(path, ordinality));

COMMIT;

-- ============ check ============
-- expected: 4 liquid items in surface-finish, none left in material
SELECT item_group_code, count(*) FROM catalog.item WHERE item_code_path <@ 'liquid'::ltree GROUP BY 1;

-- expected: 0 groups out of order
WITH sorted AS (
    SELECT g.imposition_group_id, g.item_code_paths,
           (SELECT array_agg(p.path ORDER BY (ig.item_group_json ->> 'sort_order')::numeric NULLS LAST, p.path)
            FROM unnest(g.item_code_paths) AS p(path)
            LEFT JOIN catalog.item i ON i.item_code_path = p.path
            LEFT JOIN catalog.item_group ig ON ig.item_group_code = i.item_group_code) AS resorted
    FROM legacy.imposition_group g
)
SELECT count(*) FILTER (WHERE item_code_paths <> resorted) AS wrong_order FROM sorted;

-- expected: 50313 is {sheet.dibond.premium.6mm, print.method.full.color, liquid.aquaseal.mat}
SELECT imposition_group_id, item_code_paths FROM legacy.imposition_group WHERE imposition_group_id = 50313;

-- expected: same_set_other_order 0 for the open orderlines
WITH s AS (
    SELECT (SELECT array_agg(x::ltree) FROM jsonb_array_elements_text(cs.manifest_json -> 'imposition' -> 'item_code_paths') x) AS paths
    FROM mapping.component_specs cs
    WHERE cs.is_open AND cs.manifest_json -> 'imposition' ? 'item_code_paths'
)
SELECT count(*) FILTER (WHERE EXISTS (SELECT 1 FROM legacy.imposition_group g WHERE g.item_code_paths = s.paths)) AS exact_group_match,
       count(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM legacy.imposition_group g WHERE g.item_code_paths = s.paths)
                          AND EXISTS (SELECT 1 FROM legacy.imposition_group g WHERE g.item_code_paths @> s.paths AND g.item_code_paths <@ s.paths)) AS same_set_other_order
FROM s;
