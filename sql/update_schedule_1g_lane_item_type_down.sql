-- Rollback of step 1g (sql/update_schedule_1g_lane_item_type.sql): the kind
-- back on the lane, off the item.
--
-- Put the two reads back as well, from the repo at the commit before 1g:
--   sql/schedule/get_schedule_lane.sql
--   sql/schedule/get_schedule_lane_items.sql

BEGIN;

ALTER TABLE schedule.lane
    ADD COLUMN lane_type text DEFAULT 'plan' NOT NULL;

-- a lane takes the kind of its items back; a lane whose items disagree would
-- have needed two lanes, so this says so instead of picking one
DO $$
DECLARE
    v_mixed integer;
BEGIN
    SELECT count(*) INTO v_mixed
    FROM (SELECT lane_id FROM schedule.lane_item
          GROUP BY lane_id HAVING count(DISTINCT lane_item_type) > 1) m;

    IF v_mixed > 0 THEN
        RAISE EXCEPTION 'lanes with items of more than one kind: % -- split them first, nothing changed', v_mixed;
    END IF;
END $$;

UPDATE schedule.lane l
SET lane_type = i.lane_item_type
FROM (SELECT DISTINCT lane_id, lane_item_type FROM schedule.lane_item) i
WHERE i.lane_id = l.lane_id;

ALTER TABLE schedule.lane
    DROP CONSTRAINT lane_plan_id_lane_date_step_resource_path_key;

ALTER TABLE schedule.lane
    ADD CONSTRAINT lane_plan_id_lane_date_step_resource_path_lane_type_key
        UNIQUE (plan_id, lane_date, step, resource_path, lane_type);

COMMENT ON TABLE schedule.lane IS 'One step on one resource_path on one day, of one lane_type (plan, progress, actual). Unique per plan, day, step, path and type; the items on it are schedule.lane_item and share its type.';

DROP INDEX IF EXISTS schedule.uq_schedule_lane_item_material_moment;

CREATE UNIQUE INDEX uq_schedule_lane_item_material_moment
    ON schedule.lane_item (lane_id, (data_json ->> 'material_id'), (data_json ->> 'nest_moment_code'))
    WHERE data_json ? 'material_id';

ALTER TABLE schedule.lane_item
    DROP COLUMN lane_item_type;

COMMENT ON TABLE schedule.lane_item IS 'The block of work on a lane. data_json says what: material or imposition group, nest moment, batches with nests, selected orderlines, summary. Null data_json = inherited along lane_item_dependency. History and status live in schedule.lane_item_event; the kind (plan, progress, actual) is the lane''s lane_type.';

COMMIT;
