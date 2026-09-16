-- Rollback of sql/update_item_group_liquid_sort.sql: the liquid items back in
-- the group material, the arrays and the nest copies re-sorted under that.
BEGIN;

UPDATE catalog.item i
SET item_group_code = 'material'
WHERE i.item_code_path <@ 'liquid'::ltree
  AND i.item_group_code = 'surface-finish';

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
