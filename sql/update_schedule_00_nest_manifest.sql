-- Step 0 of docs/plan-planning-schema.md: the nest manifest.
--   1. catalog.item_group_resource: which machines (resource paths) can do
--      the work of an item group; the third label of a path is the step.
--      Created when missing; when it exists it has to carry item_group_code,
--      resource_path and step, or the script stops. Its rows are data: one
--      row per item group and machine or branch (site.line.step...).
--   2. legacy.nest.manifest_json: the imposition group, item code paths and
--      production steps of a sheet, with the candidate machines per step,
--      from that table.
--   3. legacy.create_imposition_unit_manifest writes it after its rows.
--   4. Backfill: the nests nested in the last 30 days, 500 at a time. A nest
--      whose item groups have no rows in item_group_resource yet gets an
--      empty steps[]; rerun the backfill block after filling the table.
-- The lag rows in action.formula ('lag-<view_code>') are read in step 1.
-- Rollback: sql/update_schedule_00_nest_manifest_down.sql (keeps the table).
BEGIN;

-- ============ sql/catalog/item_group_resource.sql ============
DO $guard$
BEGIN
    IF to_regclass('catalog.item_group_resource') IS NOT NULL THEN
        IF (SELECT count(*) FROM information_schema.columns
            WHERE table_schema = 'catalog' AND table_name = 'item_group_resource'
              AND column_name IN ('item_group_code', 'resource_path', 'step')) < 3 THEN
            RAISE EXCEPTION 'catalog.item_group_resource exists without item_group_code, resource_path and step; align it with sql/catalog/item_group_resource.sql first';
        END IF;
        RAISE NOTICE 'catalog.item_group_resource exists, kept as is';
    END IF;
END
$guard$;

-- Which machines can do the work of an item group: one row per item group
-- and resource path. The path is a machine or a branch of the resource tree
-- (docs/resource-path.md, site.line.step.…), so one row can cover every
-- machine of a step on a line. The step is the third label of the path,
-- stored as a generated column so it can be indexed and joined without
-- relation.resource.
--
-- Read by legacy.create_imposition_unit_manifest: the item groups of the xbom
-- rows of a sheet say which steps the sheet goes through and on which
-- machines (legacy.nest.manifest_json steps[]); the planning makes the step
-- items from that (docs/plan-planning-schema.md §3.2).
create table if not exists catalog.item_group_resource
(
	item_group_resource_id bigint generated always as identity
		primary key,
	item_group_code text not null
		references catalog.item_group (item_group_code),
	-- a machine or a branch: at least site.line.step
	resource_path ltree not null
		constraint item_group_resource_path_check
			check (nlevel(resource_path) >= 3),
	-- the third label of the path, the step of the work
	step text generated always as (ltree2text(subpath(resource_path, 2, 1))) stored,
	created_at timestamp with time zone default now() not null,
	unique (item_group_code, resource_path)
);

comment on table catalog.item_group_resource is 'The machines (or branches of the resource tree) that can do the work of an item group. step is the third label of resource_path. Source of the steps and candidate machines in legacy.nest.manifest_json.';

alter table catalog.item_group_resource owner to xfw3;

create index if not exists idx_item_group_resource_step
	on catalog.item_group_resource (step);

create index if not exists idx_item_group_resource_path
	on catalog.item_group_resource using gist (resource_path);

-- ============ legacy.nest.manifest_json ============
ALTER TABLE legacy.nest ADD COLUMN IF NOT EXISTS manifest_json jsonb;

COMMENT ON COLUMN legacy.nest.manifest_json IS 'The manifest of the sheet: its imposition group and item code paths, and per production step the option codes, the candidate machines (resource_paths from catalog.item_group_resource, same site and line as the nest) and the seconds per sheet. Written by legacy.create_imposition_unit_manifest; the planning (schedule.crud_lane_item) makes the step items and their dependencies from steps[].';

-- ============ sql/legacy/create_imposition_unit_manifest.sql ============
-- Rebuild the manifest of the given impositions. Same delete-insert shape as
-- mapping.create_spec_unit_manifest, so calling it twice is calling it once.
-- Set-based, no loop.
--
-- The chain, and why it runs this way:
--   1. the orderlines on the imposition (legacy.single_product) bring their
--      own manifests: mapping.spec_unit_manifest already resolved which xbom
--      lines apply to each orderline — api options, material mapping,
--      defaults, composite codes, the most specific line winning. Redoing
--      that here gave a second, different answer (single codes only, so the
--      80 composite imposition lines never matched); now there is one
--   2. the imposition's lines are the scope 'imposition' lines of those
--      manifests, one per (imposition, option_code) — the sheet is imposed
--      once whatever sits on it, so nothing per orderline survives
--   3. the lines are evaluated against the sheet the way the orderline
--      manifest evaluates against the product: in formula_level order, the
--      variables carried from line to line (the fold below), width and height
--      from legacy.nest in centimetres, amount from legacy.nest, the numeric
--      constants of the line's item (catalog.item item_json and its params —
--      that is where standard_print_speed_cm2_sec lives) and of the xbom row
--      underneath. Every left-hand name of every formula starts at 0, because
--      the evaluator raises on an unknown variable instead of reading 0
--   4. (12 Sep 2026) the rows are folded into legacy.nest.manifest_json: the
--      imposition group of the sheet (legacy.get_imposition_group over its
--      option codes), its item code paths, and one entry per production
--      step. The step and the machines of a row come from
--      catalog.item_group_resource: the item of the xbom row belongs to an
--      item group, the group names the machines (resource paths) that can do
--      its work, and the third label of such a path is the step. A row whose
--      item group names no machine is the sheet itself (or has no capability
--      mapping yet) and stays out of steps[]. The candidate machines of a step
--      are the paths of that step under the same site and line as the nest's
--      production line (site.tenant.abb, relation.production_line.line_type),
--      every path of the step when the line is unknown. The planning reads
--      steps[] to make the step items and their dependencies
--      (docs/plan-planning-schema.md §3.2).
--
-- print-method and cutting-method are multi_select in catalog.library_option,
-- so one imposition can legitimately carry several method lines — each is a
-- pass over the sheet. They are kept, not collapsed: the manifest is a list of
-- passes and the consumer sums production_impact_per_unit * amount over the
-- rows. A later formula_level subtracts what the earlier levels already
-- stored (print_impact, neon_impact travel along), so nested method totals
-- never count twice — see docs/formula-impact-per-step.md.
drop function if exists legacy.create_imposition_unit_manifest(bigint[]);

create function legacy.create_imposition_unit_manifest(p_imposition_ids bigint[])
	returns TABLE(imposition_id bigint, row_count bigint)
	language plpgsql
as $$
#variable_conflict use_column
BEGIN
    DELETE FROM legacy.imposition_unit_manifest m
    WHERE m.imposition_id = ANY (p_imposition_ids);

    RETURN QUERY
    WITH RECURSIVE ol AS (
        SELECT DISTINCT sp.nest_id::bigint AS imposition_id, sp.production_orderline_id
        FROM legacy.single_product sp
        WHERE sp.nest_id = ANY (p_imposition_ids)
          AND sp.production_orderline_id IS NOT NULL
    ),
    -- the lines of the sheet: the imposition-scope lines of the orderline
    -- manifests on it, one per (imposition, option_code). The item is a
    -- fallback only: older manifests carry null on the print-method lines
    -- (the xbom got those items later), so the xbom row decides below
    line AS (
        SELECT o.imposition_id, m.option_code, max(m.item_code) AS item_code
        FROM ol o
        JOIN mapping.spec_unit_manifest m
             ON m.production_orderline_id = o.production_orderline_id
            AND m.scope = 'imposition'
        GROUP BY o.imposition_id, m.option_code
    ),
    -- the xbom row behind each line: formula, constants, provenance. Its item
    -- is the one whose params the formula reads (standard_print_speed_cm2_sec
    -- lives on PRINT-METHOD-*), so it wins over the manifest snapshot
    xline AS (
        SELECT l.imposition_id, l.option_code,
               coalesce(x.item_code, l.item_code) AS item_code,
               x.xbom_id, x.formula_code, x.param_json, x.config_json,
               coalesce(x.sort_order, 0) AS sort_order
        FROM line l
        LEFT JOIN catalog.xbom x
               ON x.option_code = l.option_code
              AND x.scope = 'imposition'
              AND x.version_status = 'active'
    ),
    -- the formula version that applies now, ordered by level
    applying AS (
        SELECT gf.formula_code, gf.formula_json, gf.formula_level
        FROM catalog.get_formula((SELECT array_agg(DISTINCT x.formula_code)
                                  FROM xline x
                                  WHERE x.formula_code IS NOT NULL)) gf
    ),
    row_formula AS (
        SELECT x.*, a.formula_json, a.formula_level,
               -- the order of the fold: level, then xbom_id; lines without a
               -- formula get a place too, so they simply pass the variables on
               row_number() OVER (PARTITION BY x.imposition_id
                                  ORDER BY a.formula_level NULLS FIRST, x.xbom_id) AS rn,
               -- the constants of this line: the item, its params, then the
               -- xbom row. Numbers only, the evaluator refuses text
               coalesce((SELECT jsonb_object_agg(e.key, e.value)
                         FROM jsonb_each(ci.item_json) e
                         WHERE jsonb_typeof(e.value) = 'number'), '{}'::jsonb)
               || coalesce((SELECT jsonb_object_agg(e.key, e.value)
                            FROM jsonb_each(ci.item_json -> 'params') e
                            WHERE jsonb_typeof(e.value) = 'number'), '{}'::jsonb)
               || coalesce((SELECT jsonb_object_agg(e.key, e.value)
                            FROM jsonb_each(x.param_json) e
                            WHERE jsonb_typeof(e.value) = 'number'), '{}'::jsonb) AS row_params
        FROM xline x
        LEFT JOIN applying a ON a.formula_code = x.formula_code
        LEFT JOIN catalog.item ci ON ci.item_code = x.item_code
    ),
    -- the start values per sheet: its size in centimetres, its amount, and 0
    -- for every name that stands left of an = in a formula that will run
    seed AS (
        SELECT rf.imposition_id,
               jsonb_build_object('width',  coalesce(n.width, 0),
                                  'height', coalesce(n.height, 0),
                                  'amount', coalesce(n.amount, 1))
               || coalesce((SELECT jsonb_object_agg(trim(split_part(ln.value, '=', 1)), 0)
                            FROM row_formula rf2
                            CROSS JOIN LATERAL jsonb_array_elements_text(rf2.formula_json) ln
                            WHERE rf2.imposition_id = rf.imposition_id), '{}'::jsonb) AS vars
        FROM (SELECT DISTINCT imposition_id FROM row_formula) rf
        JOIN legacy.nest n ON n.nest_id = rf.imposition_id
    ),
    -- the fold: line by line, the variables travel along. A line without a
    -- formula leaves them untouched and only sets its own result to 0, so the
    -- previous line's result does not linger
    fold AS (
        SELECT rf.imposition_id, rf.rn,
               CASE WHEN rf.formula_json IS NULL
                    THEN s.vars || jsonb_build_object('production_impact_per_unit', 0)
                    ELSE public.evaluate_many_nas(rf.formula_json, s.vars || rf.row_params)
               END AS vars
        FROM row_formula rf
        JOIN seed s ON s.imposition_id = rf.imposition_id
        WHERE rf.rn = 1

        UNION ALL

        SELECT rf.imposition_id, rf.rn,
               CASE WHEN rf.formula_json IS NULL
                    THEN f.vars || jsonb_build_object('production_impact_per_unit', 0)
                    ELSE public.evaluate_many_nas(rf.formula_json, f.vars || rf.row_params)
               END
        FROM fold f
        JOIN row_formula rf ON rf.imposition_id = f.imposition_id AND rf.rn = f.rn + 1
    ),
    inserted AS (
        INSERT INTO legacy.imposition_unit_manifest
            (imposition_id, xbom_id, option_code, item_code, amount,
             param_json, config_json, production_impact_per_unit, sort_order)
        SELECT rf.imposition_id, rf.xbom_id, rf.option_code, rf.item_code,
               (s.vars ->> 'amount')::integer,
               -- the xbom constants plus the variables the line was evaluated
               -- with, so the number can be recomputed without the nest
               coalesce(rf.param_json, '{}'::jsonb) || rf.row_params
                   || jsonb_build_object('width',  s.vars -> 'width',
                                         'height', s.vars -> 'height',
                                         'amount', s.vars -> 'amount'),
               coalesce(rf.config_json, '{}'::jsonb),
               coalesce(round((fd.vars ->> 'production_impact_per_unit')::numeric)::integer, 0),
               rf.sort_order
        FROM row_formula rf
        JOIN seed s ON s.imposition_id = rf.imposition_id
        JOIN fold fd ON fd.imposition_id = rf.imposition_id AND fd.rn = rf.rn
        ON CONFLICT ON CONSTRAINT imposition_unit_manifest_uq DO UPDATE
            SET xbom_id                    = EXCLUDED.xbom_id,
                item_code                  = EXCLUDED.item_code,
                amount                     = EXCLUDED.amount,
                param_json                 = EXCLUDED.param_json,
                config_json                = EXCLUDED.config_json,
                production_impact_per_unit = EXCLUDED.production_impact_per_unit,
                sort_order                 = EXCLUDED.sort_order,
                updated_at                 = now()
        RETURNING imposition_id
    )
    SELECT i.imposition_id, count(*) AS row_count
    FROM inserted i
    GROUP BY i.imposition_id;

    -- ── the fold into legacy.nest.manifest_json ───────────────────────────
    -- Every requested nest is written, also one without rows: its manifest
    -- becomes null, so a stale manifest never survives a re-nest.
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
        SELECT n.nest_id,
               CASE WHEN t.abb IS NOT NULL AND pl.line_type IS NOT NULL
                    THEN text2ltree(t.abb || '.' || pl.line_type) END AS site_line
        FROM legacy.nest n
        LEFT JOIN relation.production_line pl ON pl.line_id = (n.nest_json ->> 'production_line_id')::integer
        LEFT JOIN site.tenant t ON t.tenant_id = pl.tenant_id
        WHERE n.nest_id = ANY (p_imposition_ids)
    ),
    row_step AS (
        -- the steps of each row: the item of the row belongs to an item group,
        -- the group names its machines (catalog.item_group_resource), the
        -- third label of a machine path is the step. Only the machines on the
        -- nest's site and line count when the line is known. A row can name
        -- several steps (a group with print and cut machines); a row without
        -- a mapping names none
        SELECT m.imposition_id, m.option_code, m.production_impact_per_unit, m.config_json,
               igr.step, igr.resource_path
        FROM legacy.imposition_unit_manifest m
        JOIN nest_line nl ON nl.nest_id = m.imposition_id
        LEFT JOIN catalog.item i ON i.item_code = m.item_code
        LEFT JOIN catalog.item_group_resource igr
               ON igr.item_group_code = i.item_group_code
              AND (nl.site_line IS NULL OR subpath(igr.resource_path, 0, 2) = nl.site_line)
        WHERE m.imposition_id = ANY (p_imposition_ids)
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
        SELECT m.imposition_id,
               legacy.get_imposition_group(array_agg(DISTINCT m.option_code)) AS imposition_group_id
        FROM legacy.imposition_unit_manifest m
        WHERE m.imposition_id = ANY (p_imposition_ids)
        GROUP BY m.imposition_id
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
    LEFT JOIN legacy.imposition_group ig ON ig.imposition_group_id = g.imposition_group_id
    LEFT JOIN step_agg sa ON sa.imposition_id = nl.nest_id
    WHERE n.nest_id = nl.nest_id;
END;
$$;

alter function legacy.create_imposition_unit_manifest(bigint[]) owner to xfw3;

COMMIT;

-- ============ backfill: nests of the last 30 days ============
DO $backfill$
DECLARE
    v_ids    bigint[];
    v_offset integer := 0;
    v_total  integer;
    v_done   integer := 0;
BEGIN
    SELECT count(*) INTO v_total
    FROM legacy.nest n
    WHERE n.nested_at >= current_date - 30;
    RAISE NOTICE 'nest manifest backfill: % nests', v_total;

    LOOP
        SELECT array_agg(x.nest_id) INTO v_ids
        FROM (SELECT n.nest_id
              FROM legacy.nest n
              WHERE n.nested_at >= current_date - 30
              ORDER BY n.nest_id
              OFFSET v_offset LIMIT 500) x;
        EXIT WHEN v_ids IS NULL;

        PERFORM legacy.create_imposition_unit_manifest(v_ids);
        v_done   := v_done + cardinality(v_ids);
        v_offset := v_offset + 500;
        RAISE NOTICE 'nest manifest backfill: % of %', v_done, v_total;
    END LOOP;
END
$backfill$;

-- ============ check ============
-- expected: manifests > 0, with_steps close to manifests once item_group_resource
-- has rows for the item groups; steps_without_resource is the number of (nest, step)
-- pairs with no active machine of that step on the nest's site and line
SELECT count(*) FILTER (WHERE n.manifest_json IS NOT NULL)                              AS manifests,
       count(*) FILTER (WHERE jsonb_array_length(n.manifest_json -> 'steps') > 0)       AS with_steps,
       count(*)                                                                          AS nests,
       (SELECT count(*)
        FROM legacy.nest n2
        CROSS JOIN LATERAL jsonb_array_elements(n2.manifest_json -> 'steps') s
        WHERE n2.nested_at >= current_date - 30
          AND jsonb_array_length(s -> 'resource_paths') = 0)                            AS steps_without_resource
FROM legacy.nest n
WHERE n.nested_at >= current_date - 30;

-- one recent manifest to look at
SELECT n.nest_id, n.nested_at, jsonb_pretty(n.manifest_json)
FROM legacy.nest n
WHERE n.manifest_json IS NOT NULL AND jsonb_array_length(n.manifest_json -> 'steps') > 0
ORDER BY n.nested_at DESC
LIMIT 1;
