-- ============================================================
-- Backfill after stap 3b (sql/update_nest_batch_items.sql). Two things the
-- old lookup in legacy.crud_nest got wrong, both put right here:
--   1. 1.338 nests (24 aug - 4 sep) sit on the material lane of the other
--      production line: the first lane of the material won, whatever the line;
--   2. 229 of the 389 material-plan items mix batches (up to 17 per item);
--      the rule is one batch per lane item.
-- Per material lane: the nests of its own day, material and production line,
-- grouped by batch (coalesce(batch_id, 0)). The batch of the earliest nest
-- keeps the pattern item; every other batch gets an item source 'nest',
-- source_ref <lane_id>:<batch> (created here when missing, no time of its
-- own, no_split). Every item whose set changes gets its set written anew
-- (append-only); an item left empty gets the explicit empty set.
-- Only nests that already sit on a material-plan item of that day are
-- redistributed; nothing is attached that was never attached. A nest whose
-- line has no lane of its material that day stays on the lane it sits on.
-- Ran 5 sep 13:07 with a bug in "changed" (see below): the gaining items got
-- no set; sql/repair_nest_lane_item_sets.sql put that right on 6 sep.
-- Run the read-only check, the DO block, then the check again. Expected after:
-- 102 misplaced (the nests that keep their lane because their line has none
-- of that material that day), 0 mixed. Dry run 5 sep: 594 batch items to
-- create, 233 items rewritten, 1.278 set rows, 7.198 nests before and after.
-- ============================================================

-- check; expected before: 1338 misplaced, 229 mixed — after: 102, 0
WITH cur AS (
    SELECT x.lane_item_id, x.imposition_id
    FROM action.imposition_lane_item x
    JOIN action.lane_item li ON li.lane_item_id = x.lane_item_id
    WHERE li.source IN ('material-plan', 'nest')
      AND x.imposition_id IS NOT NULL
      AND x.moved_at = (SELECT max(y.moved_at) FROM action.imposition_lane_item y WHERE y.lane_item_id = x.lane_item_id)
)
SELECT (SELECT count(*)
        FROM cur c
        JOIN action.lane_item li ON li.lane_item_id = c.lane_item_id
        JOIN action.lane_item pat ON pat.lane_id = li.lane_id AND pat.source = 'material-plan'
        JOIN mock.material_impose_plan m ON m.material_impose_plan_id = split_part(pat.source_ref, ':', 1)::bigint
        JOIN legacy.nest n ON n.nest_id = c.imposition_id
        WHERE (n.nest_json ->> 'production_line_id')::int <> m.production_line_id) AS misplaced_nests,
       (SELECT count(*) FROM (SELECT c.lane_item_id
                              FROM cur c JOIN legacy.nest n ON n.nest_id = c.imposition_id
                              GROUP BY c.lane_item_id
                              HAVING count(DISTINCT coalesce(n.batch_id, 0)) > 1) s) AS mixed_items;

DO $$
DECLARE
    v_items integer; v_rows integer;
BEGIN
    -- every material lane with its pattern item, day, material and line
    CREATE TEMP TABLE bf_lane ON COMMIT DROP AS
    SELECT l.lane_id, l.lane_date, pat.lane_item_id AS pattern_item_id,
           m.material_id, m.production_line_id
    FROM action.lane l
    JOIN action.lane_item pat ON pat.lane_id = l.lane_id AND pat.source = 'material-plan'
    JOIN mock.material_impose_plan m ON m.material_impose_plan_id = split_part(pat.source_ref, ':', 1)::bigint;

    -- the nests attached to any material lane of a day, and the lane they belong on
    CREATE TEMP TABLE bf_wanted ON COMMIT DROP AS
    WITH attached AS (
        SELECT DISTINCT bl.lane_id AS current_lane_id, bl.lane_date, x.imposition_id, x.sort_order
        FROM action.imposition_lane_item x
        JOIN action.lane_item li ON li.lane_item_id = x.lane_item_id
        JOIN bf_lane bl ON bl.lane_id = li.lane_id
        WHERE li.source IN ('material-plan', 'nest')
          AND x.imposition_id IS NOT NULL
          AND x.moved_at = (SELECT max(y.moved_at) FROM action.imposition_lane_item y WHERE y.lane_item_id = x.lane_item_id)
    )
    -- the lane of the nest's own line when that day has one, else the lane it
    -- sits on today (102 nests: a line without a lane of that material that day)
    SELECT coalesce(own.lane_id, a.current_lane_id) AS lane_id,
           a.imposition_id, coalesce(n.batch_id, 0) AS batch_key,
           min(a.sort_order) AS sort_order, n.nested_at
    FROM attached a
    JOIN legacy.nest n ON n.nest_id = a.imposition_id
    LEFT JOIN bf_lane own ON own.lane_date = a.lane_date
                         AND own.material_id = (n.nest_json ->> 'material_id')::int
                         AND own.production_line_id = (n.nest_json ->> 'production_line_id')::int
    WHERE lower(coalesce(n.nest_json ->> 'status', '')) NOT LIKE 'cancel%'
    GROUP BY coalesce(own.lane_id, a.current_lane_id), a.imposition_id, n.batch_id, n.nested_at;

    -- per (lane, batch) the item: the pattern item for the earliest batch,
    -- an existing batch item, or a new one
    CREATE TEMP TABLE bf_item ON COMMIT DROP AS
    WITH first_batch AS (
        SELECT DISTINCT ON (w.lane_id) w.lane_id, w.batch_key
        FROM bf_wanted w
        ORDER BY w.lane_id, w.nested_at, w.imposition_id
    ),
    need AS (SELECT DISTINCT lane_id, batch_key FROM bf_wanted)
    SELECT nd.lane_id, nd.batch_key,
           CASE WHEN fb.batch_key IS NOT NULL THEN bl.pattern_item_id
                ELSE (SELECT li.lane_item_id FROM action.lane_item li
                      WHERE li.source = 'nest' AND li.source_ref = nd.lane_id || ':' || nd.batch_key) END AS lane_item_id
    FROM need nd
    JOIN bf_lane bl ON bl.lane_id = nd.lane_id
    LEFT JOIN first_batch fb ON fb.lane_id = nd.lane_id AND fb.batch_key = nd.batch_key;

    INSERT INTO action.lane_item
        (lane_id, sort_order, start_offset_in_seconds, no_split, type, source, source_ref)
    SELECT bi.lane_id,
           -- behind the pattern item of the lane, inside the gap of 100 the pattern
           -- rows leave: the order is unique per plan, not only per lane (the
           -- material boards order within the tenant, across lanes)
           coalesce((SELECT pat.sort_order FROM action.lane_item pat
                     WHERE pat.lane_id = bi.lane_id AND pat.source = 'material-plan'
                     ORDER BY pat.sort_order LIMIT 1),
                    (SELECT coalesce(max(li.sort_order), 0) FROM action.lane_item li WHERE li.lane_id = bi.lane_id))
             + (SELECT count(*) FROM action.lane_item li WHERE li.lane_id = bi.lane_id AND li.source = 'nest')
             + row_number() OVER (PARTITION BY bi.lane_id ORDER BY bi.batch_key),
           NULL, true, 'plan', 'nest', bi.lane_id || ':' || bi.batch_key
    FROM bf_item bi
    WHERE bi.lane_item_id IS NULL
    ON CONFLICT ON CONSTRAINT lane_item_source_ref_uq DO NOTHING;
    GET DIAGNOSTICS v_items = ROW_COUNT;

    UPDATE bf_item bi
    SET lane_item_id = li.lane_item_id
    FROM action.lane_item li
    WHERE bi.lane_item_id IS NULL
      AND li.source = 'nest' AND li.source_ref = bi.lane_id || ':' || bi.batch_key;

    INSERT INTO action.imposition_group_lane_item (imposition_group_id, lane_item_id)
    SELECT bl.material_id, bi.lane_item_id
    FROM bf_item bi
    JOIN bf_lane bl ON bl.lane_id = bi.lane_id
    WHERE NOT EXISTS (SELECT 1 FROM action.imposition_group_lane_item g WHERE g.lane_item_id = bi.lane_item_id)
    ON CONFLICT DO NOTHING;

    -- the sets: every item on a material lane whose set changes is written anew
    WITH target AS (
        SELECT bi.lane_item_id, w.imposition_id, w.sort_order
        FROM bf_wanted w
        JOIN bf_item bi ON bi.lane_id = w.lane_id AND bi.batch_key = w.batch_key
    ),
    lane_items AS (
        SELECT li.lane_item_id
        FROM action.lane_item li
        JOIN bf_lane bl ON bl.lane_id = li.lane_id
        WHERE li.type = 'plan' AND li.source IN ('material-plan', 'nest')
    ),
    current_set AS (
        SELECT x.lane_item_id, x.imposition_id
        FROM action.imposition_lane_item x
        JOIN lane_items li ON li.lane_item_id = x.lane_item_id
        WHERE x.imposition_id IS NOT NULL
          AND x.moved_at = (SELECT max(y.moved_at) FROM action.imposition_lane_item y WHERE y.lane_item_id = x.lane_item_id)
    ),
    changed AS (
        -- both directions, each in its own parentheses: EXCEPT and UNION bind
        -- equally and left to right, so without them only the losing side
        -- counted (the bug of 5 sep, repaired by sql/repair_nest_lane_item_sets.sql)
        SELECT DISTINCT lane_item_id FROM (
            (SELECT lane_item_id, imposition_id FROM target
             EXCEPT SELECT lane_item_id, imposition_id FROM current_set)
            UNION
            (SELECT lane_item_id, imposition_id FROM current_set
             EXCEPT SELECT lane_item_id, imposition_id FROM target)) d
    ),
    ins AS (
        INSERT INTO action.imposition_lane_item (lane_item_id, imposition_id, sort_order)
        SELECT t.lane_item_id, t.imposition_id, t.sort_order
        FROM target t JOIN changed ch ON ch.lane_item_id = t.lane_item_id
        UNION ALL
        SELECT ch.lane_item_id, NULL, NULL
        FROM changed ch
        WHERE NOT EXISTS (SELECT 1 FROM target t WHERE t.lane_item_id = ch.lane_item_id)
        RETURNING lane_item_id
    )
    SELECT count(*) INTO v_rows FROM ins;

    RAISE NOTICE 'batch items created: %, set rows written: %', v_items, v_rows;
END $$;
