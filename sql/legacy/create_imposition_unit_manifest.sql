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
END;
$$;

alter function legacy.create_imposition_unit_manifest(bigint[]) owner to xfw3;
