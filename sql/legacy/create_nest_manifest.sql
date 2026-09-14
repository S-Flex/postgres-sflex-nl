-- The fold of legacy.imposition_unit_manifest into legacy.nest.manifest_json
-- (docs/plan-planning-schema.md §3): the imposition group of the sheet
-- (legacy.get_imposition_group over its option codes), its item code paths,
-- and one entry per production step. The step and the machines of a row come
-- from catalog.item_group_resource: the item of the xbom row belongs to an
-- item group, the group names the machines (resource paths) that can do its
-- work, and the third label of such a path is the step. A row whose item
-- group names no machine is the sheet itself (or has no capability mapping
-- yet) and stays out of steps[]. The candidate machines of a step are the
-- paths of that step under the same site and line as the nest's production
-- line (site.tenant.abb, relation.production_line.line_type), every path of
-- the step when the line is unknown.
--
-- Reads the manifest rows, writes only legacy.nest. Called at the end of
-- legacy.create_imposition_unit_manifest, and on its own by
-- legacy.backfill_nest_manifest (the rows already exist, only the fold is
-- missing). Every requested nest is written, also one without rows: its
-- manifest becomes null, so a stale manifest never survives a re-nest.
drop function if exists legacy.create_nest_manifest(bigint[]);

create function legacy.create_nest_manifest(p_nest_ids bigint[]) returns void
	language sql
as $$
WITH step_order AS (
    -- the order of the steps, for the order of steps[]
    SELECT s.value ->> 'step' AS step, (s.value ->> 'order')::integer AS step_order
    FROM relation.lookup lk
    CROSS JOIN LATERAL jsonb_array_elements(lk.lookup_json) AS s(value)
    WHERE lk.lookup = 'lookup_step_category'
),
nest_line AS (
    -- the site and line of the nest: site.tenant.abb of the production
    -- line's tenant plus the line type, the first two labels of a path
    SELECT n.nest_id, pl.tenant_id,
           CASE WHEN t.abb IS NOT NULL AND pl.line_type IS NOT NULL
                THEN text2ltree(t.abb || '.' || pl.line_type) END AS site_line
    FROM legacy.nest n
    LEFT JOIN relation.production_line pl ON pl.line_id = (n.nest_json ->> 'production_line_id')::integer
    LEFT JOIN site.tenant t ON t.tenant_id = pl.tenant_id
    WHERE n.nest_id = ANY (p_nest_ids)
),
row_step AS (
    -- the steps of each row: the item of the row belongs to an item group,
    -- the group names its machines (catalog.item_group_resource), the
    -- third label of a machine path is the step. Only the machines of the
    -- nest's tenant, and on its site and line, count when those are known. A row can name
    -- several steps (a group with print and cut machines); a row without
    -- a mapping names none
    SELECT m.imposition_id, m.option_code, m.production_impact_per_unit, m.config_json,
           igr.step, igr.resource_path
    FROM legacy.imposition_unit_manifest m
    JOIN nest_line nl ON nl.nest_id = m.imposition_id
    LEFT JOIN catalog.item i ON i.item_code = m.item_code
    LEFT JOIN catalog.item_group_resource igr
           ON igr.item_group_code = i.item_group_code
          AND (nl.tenant_id IS NULL OR igr.tenant_id = nl.tenant_id)
          AND (nl.site_line IS NULL OR subpath(igr.resource_path, 0, 2) = nl.site_line)
    WHERE m.imposition_id = ANY (p_nest_ids)
),
step_agg AS (
    SELECT rs.imposition_id,
           jsonb_agg(jsonb_build_object(
               'step',                       rs.step,
               'option_codes',               rs.option_codes,
               'production_impact_per_unit', rs.production_impact_per_unit,
               'config',                     rs.config,
               'resource_paths',             rs.resource_paths)
               ORDER BY so.step_order NULLS LAST, rs.step) AS steps
    FROM (SELECT r.imposition_id, r.step,
                 (SELECT jsonb_agg(DISTINCT x.option_code) FROM (SELECT r2.option_code FROM row_step r2
                   WHERE r2.imposition_id = r.imposition_id AND r2.step = r.step) x) AS option_codes,
                 (SELECT sum(x.production_impact_per_unit) FROM (SELECT DISTINCT r2.option_code, r2.production_impact_per_unit
                   FROM row_step r2 WHERE r2.imposition_id = r.imposition_id AND r2.step = r.step) x) AS production_impact_per_unit,
                 -- the settings of the step: every config key of its rows
                 coalesce((SELECT jsonb_object_agg(c.key, c.value)
                           FROM (SELECT DISTINCT r2.option_code, r2.config_json FROM row_step r2
                                 WHERE r2.imposition_id = r.imposition_id AND r2.step = r.step) x
                           CROSS JOIN LATERAL jsonb_each(x.config_json) AS c(key, value)), '{}'::jsonb) AS config,
                 -- the machines of the step: the union over the item groups of its rows
                 jsonb_agg(DISTINCT ltree2text(r.resource_path)) AS resource_paths
          FROM row_step r
          WHERE r.step IS NOT NULL
          GROUP BY r.imposition_id, r.step) rs
    LEFT JOIN step_order so ON so.step = rs.step
    GROUP BY rs.imposition_id
),
group_of AS (
    -- the group of the nest for its tenant; a nest without a line is Dokkum's (1)
    SELECT m.imposition_id,
           coalesce(nl.tenant_id, 1) AS tenant_id,
           legacy.get_imposition_group(array_agg(DISTINCT m.option_code), coalesce(nl.tenant_id, 1)) AS imposition_group_id
    FROM legacy.imposition_unit_manifest m
    JOIN nest_line nl ON nl.nest_id = m.imposition_id
    WHERE m.imposition_id = ANY (p_nest_ids)
    GROUP BY m.imposition_id, nl.tenant_id
)
UPDATE legacy.nest n
SET manifest_json = CASE WHEN g.imposition_id IS NULL THEN NULL
                         ELSE jsonb_build_object(
                             'imposition_group_id', g.imposition_group_id,
                             'item_code_paths',     coalesce((SELECT jsonb_agg(ltree2text(p)) FROM unnest(ig.item_code_paths) AS p), '[]'::jsonb),
                             'steps',               coalesce(sa.steps, '[]'::jsonb))
                    END
FROM nest_line nl
LEFT JOIN group_of g ON g.imposition_id = nl.nest_id
LEFT JOIN legacy.imposition_group ig ON ig.imposition_group_id = g.imposition_group_id AND ig.tenant_id = g.tenant_id
LEFT JOIN step_agg sa ON sa.imposition_id = nl.nest_id
WHERE n.nest_id = nl.nest_id;
$$;

alter function legacy.create_nest_manifest(bigint[]) owner to xfw3;
