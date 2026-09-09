-- Fills xbom item_code for unlinked imposition rows whose option_code
-- starts with material.*. The material.<x> part finds the candidates
-- through mapping.option_translation; print-coverage.* picks the variant:
-- double-sided wants a double/DZ description, single-sided and unprinted
-- want the base variant. Ties resolve by how well the description matches
-- the option slug (exact, then prefix, then the shortest = base variant).
-- Rows without a candidate stay null for hand-work.
WITH unfilled AS (
    SELECT x.xbom_id, x.option_code,
           split_part(x.option_code, ';', 1) AS material_code,
           (SELECT part FROM unnest(string_to_array(x.option_code, ';')) part
            WHERE part LIKE 'print-coverage.%') AS coverage
    FROM catalog.xbom x
    WHERE x.scope = 'imposition'
      AND x.item_code IS NULL
      AND x.option_code LIKE 'material.%'
),
candidate AS (
    SELECT u.xbom_id, u.option_code, u.coverage,
           t.material_id, t.description,
           trim(replace(replace(lower(u.material_code), 'material.', ''), '-', ' ')) AS slug,
           trim(regexp_replace(lower(t.description), '[^a-z0-9]+', ' ', 'g'))        AS desc_norm,
           CASE
               WHEN u.coverage = 'print-coverage.double-sided' THEN
                   CASE WHEN t.description ~* '(double|\mdz\M)' THEN 2 ELSE 0 END
               ELSE
                   CASE WHEN t.description ~* 'single' THEN 2
                        WHEN t.description !~* '(double|\mdz\M)' THEN 1
                        ELSE 0 END
           END AS score
    FROM unfilled u
    JOIN mapping.option_translation t
      ON t.material_id IS NOT NULL
     AND u.material_code = ANY (t.option_codes)
),
winner AS (
    SELECT DISTINCT ON (c.xbom_id)
           c.xbom_id, c.material_id, c.score
    FROM candidate c
    ORDER BY c.xbom_id,
             c.score DESC,
             (c.desc_norm = c.slug) DESC,
             (c.desc_norm LIKE c.slug || '%' OR c.slug LIKE c.desc_norm || '%') DESC,
             length(c.description),
             c.material_id
)
UPDATE catalog.xbom x
SET item_code = upper(replace(ltree2text(g.item_code_paths[1]), '.', '-'))
FROM winner w
JOIN catalog.imposition_group g ON g.imposition_group_id = w.material_id
WHERE x.xbom_id = w.xbom_id
  AND w.score > 0
  AND x.item_code IS NULL;
