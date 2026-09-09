-- ============================================================
-- Repair after sql/backfill_nest_lane_items.sql (run 5 sep 13:07). Its
-- "changed" set mixed EXCEPT and UNION without parentheses; SQL reads that
-- left to right, so only items that LOST a nest counted as changed. The 233
-- pattern items that lost nests were rewritten with their reduced set, but the
-- 594 batch items and 93 pattern items that only GAINED nests never got a set:
-- 5.202 of the 7.198 nests dropped off the material lanes (they still sit on
-- their pv2 items and in the migration rows of 5 sep 11:30).
-- This puts them back with the same rule: from the pre-backfill sets (the
-- oldest set row of every pattern item), every nest that is not on a
-- material-lane item today goes to the lane of its own line and material that
-- day (else the lane it sat on), and there to the batch item <lane>:<batch> when
-- it exists, else the pattern item. Nothing that crud_nest placed since is
-- touched: a nest in a current set stays. Sets are written append-only.
-- Dry run 6 sep: 594 batch items get 4.477 rows, 93 pattern items get 725
-- rows, no item ends up with two batches.
-- ============================================================

-- check; expected before: 1996 nests, 594 batch items without a set
-- after: 7198 nests, 0 batch items without a set, 0 mixed
WITH cur AS (
    SELECT x.lane_item_id, x.imposition_id
    FROM action.imposition_lane_item x
    JOIN action.lane_item li ON li.lane_item_id = x.lane_item_id
    WHERE li.source IN ('material-plan', 'nest') AND x.imposition_id IS NOT NULL
      AND x.moved_at = (SELECT max(y.moved_at) FROM action.imposition_lane_item y WHERE y.lane_item_id = x.lane_item_id)
)
SELECT (SELECT count(*) FROM cur) AS nests_on_material_lanes,
       (SELECT count(*) FROM action.lane_item li WHERE li.source = 'nest'
          AND NOT EXISTS (SELECT 1 FROM action.imposition_lane_item x WHERE x.lane_item_id = li.lane_item_id)) AS batch_items_without_set,
       (SELECT count(*) FROM (SELECT c.lane_item_id FROM cur c JOIN legacy.nest n ON n.nest_id = c.imposition_id
                              GROUP BY c.lane_item_id HAVING count(DISTINCT coalesce(n.batch_id, 0)) > 1) s) AS mixed_items;

DO $$
DECLARE
    v_rows integer; v_items integer;
BEGIN
    CREATE TEMP TABLE rp_lane ON COMMIT DROP AS
    SELECT l.lane_id, l.lane_date, pat.lane_item_id AS pattern_item_id, m.material_id, m.production_line_id
    FROM action.lane l
    JOIN action.lane_item pat ON pat.lane_id = l.lane_id AND pat.source = 'material-plan'
    JOIN mock.material_impose_plan m ON m.material_impose_plan_id = split_part(pat.source_ref, ':', 1)::bigint;

    -- the sets as they were before the backfill: the oldest set row of every pattern item
    CREATE TEMP TABLE rp_snapshot ON COMMIT DROP AS
    SELECT DISTINCT bl.lane_id AS current_lane_id, bl.lane_date, x.imposition_id, x.sort_order
    FROM action.imposition_lane_item x
    JOIN action.lane_item li ON li.lane_item_id = x.lane_item_id
    JOIN rp_lane bl ON bl.lane_id = li.lane_id
    WHERE li.source = 'material-plan' AND x.imposition_id IS NOT NULL
      AND x.moved_at = (SELECT min(y.moved_at) FROM action.imposition_lane_item y WHERE y.lane_item_id = x.lane_item_id);

    -- a nest in a current set of a material-lane item stays where it is
    CREATE TEMP TABLE rp_placed ON COMMIT DROP AS
    SELECT x.lane_item_id, x.imposition_id
    FROM action.imposition_lane_item x
    JOIN action.lane_item li ON li.lane_item_id = x.lane_item_id
    WHERE li.source IN ('material-plan', 'nest') AND x.imposition_id IS NOT NULL
      AND x.moved_at = (SELECT max(y.moved_at) FROM action.imposition_lane_item y WHERE y.lane_item_id = x.lane_item_id);

    -- the rest goes to the lane of its own line, else the lane it sat on, and
    -- there to the batch item when it exists, else the pattern item
    CREATE TEMP TABLE rp_target ON COMMIT DROP AS
    SELECT coalesce(ni.lane_item_id, bl.pattern_item_id) AS lane_item_id, w.imposition_id, min(w.sort_order) AS sort_order
    FROM (SELECT coalesce(own.lane_id, s.current_lane_id) AS lane_id, s.imposition_id, coalesce(n.batch_id, 0) AS batch_key, s.sort_order
          FROM rp_snapshot s
          JOIN legacy.nest n ON n.nest_id = s.imposition_id
          LEFT JOIN rp_lane own ON own.lane_date = s.lane_date
                               AND own.material_id = (n.nest_json ->> 'material_id')::int
                               AND own.production_line_id = (n.nest_json ->> 'production_line_id')::int
          WHERE lower(coalesce(n.nest_json ->> 'status', '')) NOT LIKE 'cancel%'
            AND NOT EXISTS (SELECT 1 FROM rp_placed p WHERE p.imposition_id = s.imposition_id)) w
    JOIN rp_lane bl ON bl.lane_id = w.lane_id
    LEFT JOIN action.lane_item ni ON ni.source = 'nest' AND ni.source_ref = w.lane_id || ':' || w.batch_key
    GROUP BY 1, 2;

    -- every target item gets its set written anew: what it holds today plus what comes back
    INSERT INTO action.imposition_lane_item (lane_item_id, imposition_id, sort_order)
    SELECT t.lane_item_id, t.imposition_id, t.sort_order FROM rp_target t
    UNION ALL
    SELECT p.lane_item_id, p.imposition_id, NULL
    FROM rp_placed p
    WHERE p.lane_item_id IN (SELECT DISTINCT lane_item_id FROM rp_target)
      AND NOT EXISTS (SELECT 1 FROM rp_target t WHERE t.lane_item_id = p.lane_item_id AND t.imposition_id = p.imposition_id);
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    SELECT count(DISTINCT lane_item_id) INTO v_items FROM rp_target;

    RAISE NOTICE 'items rewritten: %, set rows written: %', v_items, v_rows;
END $$;
