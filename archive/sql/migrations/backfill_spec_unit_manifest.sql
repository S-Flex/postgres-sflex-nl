-- Rebuild mapping.spec_unit_manifest for the orderlines of the last two
-- months. mapping.create_spec_unit_manifest is delete-insert per orderline, so
-- running it again is idempotent; it also rewrites
-- component_specs.manifest_json in the same pass.
--
-- The scope is production_date (the window the boards read). Swap it for
-- cs.order_date to scope on when the order came in.

-- 1. how much work it is
SELECT count(*)                    AS orderlines,
       min(cs.production_date)::date AS from_date,
       max(cs.production_date)::date AS to_date
FROM mapping.component_specs cs
WHERE cs.production_date >= (current_date - interval '2 months')::date;

-- 2. the rebuild. In a DO block and in batches: a per-row SELECT of a writing
-- function gets cut off by the client's paging, and RAISE NOTICE shows how far
-- it got.
DO $$
DECLARE
    v_from constant date := (current_date - interval '2 months')::date;
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
            WHERE cs.production_date >= v_from
              AND cs.production_orderline_id > v_last
            ORDER BY cs.production_orderline_id
            LIMIT 5000
        ) b;

        EXIT WHEN v_ids IS NULL;

        PERFORM mapping.create_spec_unit_manifest(v_ids);

        v_last := v_ids[array_upper(v_ids, 1)];
        v_done := v_done + cardinality(v_ids);
        RAISE NOTICE 'spec unit manifest: % orderlines done (up to %)', v_done, v_last;
    END LOOP;
END $$;

-- 3. verify: manifest rows and impact per orderline in that window
SELECT count(DISTINCT m.production_orderline_id) AS orderlines_with_rows,
       count(*)                                  AS manifest_rows,
       count(*) FILTER (WHERE m.production_impact_per_unit > 0) AS rows_with_impact,
       count(DISTINCT cs.production_orderline_id) FILTER (WHERE cs.manifest_json IS NULL)
                                                  AS orderlines_without_manifest_json
FROM mapping.component_specs cs
LEFT JOIN mapping.spec_unit_manifest m USING (production_orderline_id)
WHERE cs.production_date >= (current_date - interval '2 months')::date;
