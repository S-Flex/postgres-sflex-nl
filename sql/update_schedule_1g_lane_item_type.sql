-- Step 1g: the kind of the work moves from the lane to the item
-- (docs/schedule-base.md §3).
--
-- schedule.lane.lane_type (plan, progress, actual) becomes
-- schedule.lane_item.lane_item_type. A lane is then one step on one resource
-- on one day and nothing more, and one lane carries every kind, so the board
-- draws plan, progress and actual on the same axis.
--
-- The two reads follow: get_schedule_lane loses lane_type, type_json and
-- p_types; get_schedule_lane_items returns lane_item_type and filters p_types
-- on the item. Both signatures change, so both are dropped and recreated.
--
-- Run in this order, in one window:
--   1. this script
--   2. sql/schedule/get_schedule_lane.sql
--   3. sql/schedule/get_schedule_lane_items.sql
--
-- Rollback: sql/update_schedule_1g_lane_item_type_down.sql

BEGIN;

-- ── the item gets the kind ───────────────────────────────────────────────
ALTER TABLE schedule.lane_item
    ADD COLUMN lane_item_type text DEFAULT 'plan' NOT NULL;

COMMENT ON COLUMN schedule.lane_item.lane_item_type IS 'The kind of the row, from action.lookup / lookup_lane_item_type: plan = what is planned, progress = what is left of it, actual = what the resource did. One lane carries every kind; the board draws them on the same axis.';

-- the kind an item has today is the kind of its lane
UPDATE schedule.lane_item li
SET lane_item_type = l.lane_type
FROM schedule.lane l
WHERE l.lane_id = li.lane_id
  AND l.lane_type <> li.lane_item_type;

-- the upsert key of generate_day gets the kind: one item per material and
-- nest moment per kind on a lane
DROP INDEX IF EXISTS schedule.uq_schedule_lane_item_material_moment;

CREATE UNIQUE INDEX uq_schedule_lane_item_material_moment
    ON schedule.lane_item (lane_id, lane_item_type, (data_json ->> 'material_id'), (data_json ->> 'nest_moment_code'))
    WHERE data_json ? 'material_id';

-- ── the lane loses the kind ──────────────────────────────────────────────
-- Two lanes that differed only in lane_type would collide on the narrower
-- key; there are none while only plan lanes exist, and this says so.
DO $$
DECLARE
    v_collisions integer;
BEGIN
    SELECT count(*) INTO v_collisions
    FROM (SELECT plan_id, lane_date, step, resource_path
          FROM schedule.lane
          GROUP BY plan_id, lane_date, step, resource_path
          HAVING count(*) > 1) c;

    IF v_collisions > 0 THEN
        RAISE EXCEPTION 'lanes that differ only in lane_type: % -- merge them first, nothing changed', v_collisions;
    END IF;
END $$;

-- the unique constraint by its own name, whatever postgres called it:
-- schedule.lane has exactly one
DO $$
DECLARE
    v_name text;
BEGIN
    SELECT con.conname INTO v_name
    FROM pg_constraint con
    WHERE con.conrelid = 'schedule.lane'::regclass
      AND con.contype = 'u';

    EXECUTE format('ALTER TABLE schedule.lane DROP CONSTRAINT %I', v_name);
END $$;

ALTER TABLE schedule.lane
    ADD CONSTRAINT lane_plan_id_lane_date_step_resource_path_key
        UNIQUE (plan_id, lane_date, step, resource_path);

ALTER TABLE schedule.lane
    DROP COLUMN lane_type;

COMMENT ON TABLE schedule.lane IS 'One step on one resource_path on one day. Unique per plan, day, step and path; the items on it are schedule.lane_item, each with its own lane_item_type (plan, progress, actual).';

COMMENT ON TABLE schedule.lane_item IS 'The block of work on a lane. data_json says what: material or imposition group, nest moment, batches with nests, selected orderlines, summary. Null data_json = inherited along lane_item_dependency. History and status live in schedule.lane_item_event; the kind (plan, progress, actual) is the item''s own lane_item_type.';

-- ── the leads live in the catalog again ──────────────────────────────────
-- Per resource_path, so every step has its own: impose, print and cut differ.
COMMENT ON COLUMN catalog.item_group_resource.item_group_json IS 'The tenant''s overrides of catalog.item_group.item_group_json for this resource, and the setup and teardown seconds of the work on it: lead_in / lead_out, per resource_path and so per step. {} when none.';

COMMENT ON COLUMN schedule.lane_item.lead_in IS 'Setup seconds before the work, stamped from catalog.item_group_resource.item_group_json of the work''s item groups on the resource of the lane.';

COMMENT ON COLUMN schedule.lane_item.lead_out IS 'Teardown seconds after the work, stamped from catalog.item_group_resource.item_group_json of the work''s item groups on the resource of the lane.';

-- ── check: the column is gone, every item has a kind ─────────────────────
SELECT (SELECT count(*) FROM schedule.lane)      AS lanes,
       (SELECT count(*) FROM schedule.lane_item) AS lane_items,
       (SELECT count(*) FROM schedule.lane_item WHERE lane_item_type = 'plan') AS plan_items,
       (SELECT count(*) FROM information_schema.columns
        WHERE table_schema = 'schedule' AND table_name = 'lane' AND column_name = 'lane_type') AS lane_type_left;

COMMIT;
