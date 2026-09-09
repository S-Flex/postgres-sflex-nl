-- ============================================================
-- Backfill production_impact_per_unit on mapping.spec_unit_manifest.
--
-- Order of play:
--   1. run sql/mapping/create_spec_unit_manifest.sql (drops itself) — the
--      builder now evaluates param_json.formula of the xbom row into
--      production_impact_per_unit (variables per orderline: width, height,
--      amount, unit_sqm, sqm, plus the numeric keys of param_json);
--   2. put the formulas on the xbom rows (print-method.*, cutting-method.*):
--      "formula": ["production_impact_per_unit=..."] — last line wins;
--   3. test on a handful of orderlines:
--        select * from mapping.create_spec_unit_manifest(array[<ids>]);
--        select production_orderline_id, option_code, production_impact_per_unit
--        from mapping.spec_unit_manifest
--        where production_orderline_id = any (array[<ids>]) order by 1, 2;
--   4. run this backfill: every OPEN orderline is re-resolved, so the boards
--      get their impacts; historical orderlines follow whenever needed.
-- ============================================================

DO $$
DECLARE
    v_ids  integer[];
    v_last integer := 0;
    v_done integer := 0;
BEGIN
    LOOP
        SELECT array_agg(b.production_orderline_id ORDER BY b.production_orderline_id)
        INTO   v_ids
        FROM (
            SELECT cs.production_orderline_id
            FROM mapping.component_specs cs
            WHERE cs.is_open
              AND cs.production_orderline_id > v_last
            ORDER BY cs.production_orderline_id
            LIMIT 5000
        ) b;

        EXIT WHEN v_ids IS NULL;

        PERFORM mapping.create_spec_unit_manifest(v_ids);

        v_last := v_ids[array_upper(v_ids, 1)];
        v_done := v_done + cardinality(v_ids);
        RAISE NOTICE 'impact backfill: % orderlines done (up to %)', v_done, v_last;
    END LOOP;
END $$;

-- verify: open orderlines with an impact
SELECT count(distinct m.production_orderline_id) AS orderlines_with_impact,
       round(avg(m.production_impact_per_unit), 1) AS avg_impact_per_unit_row
FROM mapping.spec_unit_manifest m
JOIN mapping.component_specs cs USING (production_orderline_id)
WHERE cs.is_open AND m.production_impact_per_unit > 0;
