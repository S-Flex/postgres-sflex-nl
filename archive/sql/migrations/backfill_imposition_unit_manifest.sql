-- ============================================================
-- Backfill legacy.imposition_unit_manifest for the nests of the last 60
-- days (the table was empty: the call in legacy.crud_nest was never
-- deployed and the old builder raised on every print line). Run AFTER
-- sql/legacy/create_imposition_unit_manifest.sql and
-- sql/legacy/crud_nest.sql, so new nests keep their manifest current.
--
-- A DO block, not a SELECT: a SELECT that writes per row is cut off by the
-- client's row paging after ~100 rows, with no error. Batches of 500 nests,
-- one NOTICE per batch and a total at the end.
-- ============================================================
DO $$
DECLARE
    v_since  constant timestamptz := now() - interval '60 days';
    v_ids    bigint[];
    v_last   bigint := 0;
    v_nests  integer := 0;
    v_rows   bigint := 0;
    v_batch  bigint;
BEGIN
    LOOP
        SELECT array_agg(n.nest_id ORDER BY n.nest_id)
        INTO   v_ids
        FROM (SELECT nest_id
              FROM legacy.nest
              WHERE nested_at >= v_since
                AND nest_id > v_last
              ORDER BY nest_id
              LIMIT 500) n;

        EXIT WHEN v_ids IS NULL;

        SELECT coalesce(sum(r.row_count), 0)
        INTO   v_batch
        FROM   legacy.create_imposition_unit_manifest(v_ids) r;

        v_nests := v_nests + cardinality(v_ids);
        v_rows  := v_rows + v_batch;
        v_last  := v_ids[cardinality(v_ids)];
        RAISE NOTICE 'up to nest % : % nests, % manifest rows', v_last, v_nests, v_rows;
    END LOOP;

    RAISE NOTICE 'done: % nests since %, % manifest rows', v_nests, v_since::date, v_rows;
END $$;

-- check: rows per option code and how many carry an impact; expected: the
-- print-method.* codes with impact > 0 on (nearly) every row
SELECT option_code, count(*) AS rows,
       count(*) FILTER (WHERE production_impact_per_unit > 0) AS with_impact,
       round(avg(production_impact_per_unit)) AS avg_impact_in_seconds
FROM legacy.imposition_unit_manifest
GROUP BY option_code
ORDER BY rows DESC
LIMIT 25;
