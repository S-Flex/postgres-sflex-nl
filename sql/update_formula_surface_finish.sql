-- The formula surface-finish-delivery read has_surface_coating while the xbom
-- rows that carry it (surface-finish.*, scope imposition) provide the constant
-- as has_surface_finish: the evaluator raised "Unknown variable" and
-- legacy.crud_nest failed on every nest with a surface finish (11 Sep 2026).
-- The formula follows the xbom, the option set is surface-finish.
BEGIN;

UPDATE catalog.formula
SET formula_json = replace(formula_json::text, 'has_surface_coating', 'has_surface_finish')::jsonb
WHERE formula_code = 'surface-finish-delivery'
  AND formula_json::text LIKE '%has_surface_coating%';

COMMIT;

-- check: the formula, and one manifest rebuilt for a nest with a finish
SELECT formula_code, version, version_status, formula_json
FROM catalog.formula
WHERE formula_code = 'surface-finish-delivery';

-- the nests of today whose orderlines carry a surface finish, to rebuild:
--   SELECT legacy.create_imposition_unit_manifest(array_agg(DISTINCT sp.nest_id))
--   FROM legacy.single_product sp
--   JOIN mapping.spec_unit_manifest m ON m.production_orderline_id = sp.production_orderline_id
--   WHERE m.option_code LIKE 'surface-finish.%' AND sp.nest_id IN (
--       SELECT nest_id FROM legacy.nest WHERE nested_at >= current_date);
