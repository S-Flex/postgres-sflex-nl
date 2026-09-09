-- Step 1 of docs/plan-batch-lane-item.md: the schema. Additive only -- the
-- old set table, its reader and the pattern table stay until the readers
-- moved (step 3), so the boards keep working in between.
--
-- 1. action.lane gets step and resource_path: the lane is one resource on one
--    day, whatever board shows it. Resource lanes take both from
--    action.resource_lane (the step is the label of the path that is a step of
--    lookup_step_category: the current paths carry site.line.step, 39 old
--    lanes site.step.line). Group lanes take the impose path of the pattern
--    row their pattern item was stamped from, cut to site.line.impose.width
--    (91 pattern rows carry the full machine path), and step impose.
-- 2. action.lane_item gets instance (the repeat of a material moment on its
--    lane, from the pattern row) and the composite key the new table points at.
-- 3. action.lane_item_event gets moved_by; the status vocabulary is
--    action.lookup lookup_lane_item_status (plan, released, nested).
-- 4. action.batch_lane_item (sql/action/batch_lane_item.sql).
BEGIN;

-- ── 1. lane: step + resource_path ─────────────────────────────────────
ALTER TABLE action.lane
    ADD COLUMN IF NOT EXISTS step text,
    ADD COLUMN IF NOT EXISTS resource_path ltree;

COMMENT ON COLUMN action.lane.step IS 'The step this lane plans (print, cut, impose, ...): vocabulary relation.lookup lookup_step_category. A lane is one resource on one day, so one step.';
COMMENT ON COLUMN action.lane.resource_path IS 'The resource of the lane: the machine (docs/resource-path.md), or site.line.impose.width for an imposition group lane.';

-- resource lanes: the path as is, the step the first label that is a step
UPDATE action.lane l
SET resource_path = rl.resource_path,
    step = (SELECT u.lbl
            FROM unnest(string_to_array(rl.resource_path::text, '.')) WITH ORDINALITY AS u(lbl, pos)
            WHERE u.lbl IN (SELECT s.step
                            FROM relation.lookup lk
                            CROSS JOIN LATERAL jsonb_to_recordset(lk.lookup_json) AS s(step text)
                            WHERE lk.lookup = 'lookup_step_category')
            ORDER BY u.pos
            LIMIT 1)
FROM action.resource_lane rl
WHERE rl.lane_id = l.lane_id;

-- group lanes: the impose path of the pattern row, cut to four labels
UPDATE action.lane l
SET resource_path = subpath(m.resource_path, 0, 4),
    step = 'impose'
FROM action.imposition_group_lane igl
JOIN action.lane_item li
  ON li.lane_id = igl.lane_id AND li.source = 'material-plan'
JOIN mock.material_impose_plan m
  ON m.material_impose_plan_id = nullif(split_part(li.source_ref, ':', 1), '')::bigint
WHERE l.lane_id = igl.lane_id;

-- every lane has both, or the script stops here
DO $$
DECLARE
    v_missing integer;
BEGIN
    SELECT count(*) INTO v_missing
    FROM action.lane
    WHERE step IS NULL OR resource_path IS NULL;
    IF v_missing > 0 THEN
        RAISE EXCEPTION '% lanes without step or resource_path', v_missing;
    END IF;
END $$;

ALTER TABLE action.lane
    ALTER COLUMN step SET NOT NULL,
    ALTER COLUMN resource_path SET NOT NULL,
    -- backs the composite foreign key of batch_lane_item
    ADD CONSTRAINT lane_lane_id_step_uq UNIQUE (lane_id, step);

CREATE INDEX IF NOT EXISTS idx_lane_resource_path
    ON action.lane (resource_path);
CREATE INDEX IF NOT EXISTS idx_lane_resource_path_gist
    ON action.lane USING gist (resource_path);
CREATE INDEX IF NOT EXISTS idx_lane_step
    ON action.lane (step);

-- ── 2. lane_item: instance + composite key ────────────────────────────
ALTER TABLE action.lane_item
    ADD COLUMN IF NOT EXISTS instance integer DEFAULT 0 NOT NULL,
    -- backs the composite foreign key of batch_lane_item
    ADD CONSTRAINT lane_item_lane_item_id_lane_id_uq UNIQUE (lane_item_id, lane_id);

COMMENT ON COLUMN action.lane_item.instance IS 'The repeat of a material moment on its lane: 0 the first moment of the day, 1 the second, ... A nest lands on the instance released last before it was nested.';

-- the instance of the pattern row the item was stamped from (all 0 today)
UPDATE action.lane_item li
SET instance = m.instance
FROM mock.material_impose_plan m
WHERE li.source = 'material-plan'
  AND m.material_impose_plan_id = nullif(split_part(li.source_ref, ':', 1), '')::bigint
  AND li.instance IS DISTINCT FROM m.instance;

-- ── 3. lane_item_event: moved_by + the status vocabulary ──────────────
ALTER TABLE action.lane_item_event
    ADD COLUMN IF NOT EXISTS moved_by integer;

COMMENT ON TABLE action.lane_item_event IS 'The status history of a lane item, append-only: plan, released (to the nesting software), nested. The latest row is the status; vocabulary action.lookup lookup_lane_item_status.';
COMMENT ON COLUMN action.lane_item_event.moved_by IS 'The contact who moved the item to this status; null for the system and for rows from before it was recorded.';

INSERT INTO action.lookup (lookup, lookup_json)
VALUES ('lookup_lane_item_status', $lk$
[
  {
    "status": "plan",
    "i18n": {
      "de": { "title": "Plan" },
      "en": { "title": "Plan" },
      "es": { "title": "Plan" },
      "fr": { "title": "Plan" },
      "nl": { "title": "Plan" },
      "uk": { "title": "План" }
    },
    "sort_order": 0
  },
  {
    "status": "released",
    "i18n": {
      "de": { "title": "Freigegeben" },
      "en": { "title": "Released" },
      "es": { "title": "Liberado" },
      "fr": { "title": "Libéré" },
      "nl": { "title": "Vrijgegeven" },
      "uk": { "title": "Випущено" }
    },
    "sort_order": 1
  },
  {
    "status": "nested",
    "i18n": {
      "de": { "title": "Genestet" },
      "en": { "title": "Nested" },
      "es": { "title": "Anidado" },
      "fr": { "title": "Imbriqué" },
      "nl": { "title": "Genest" },
      "uk": { "title": "Розкладено" }
    },
    "sort_order": 2
  }
]
$lk$::jsonb)
ON CONFLICT (lookup) DO UPDATE SET lookup_json = EXCLUDED.lookup_json;

-- ── 4. batch_lane_item ────────────────────────────────────────────────
CREATE TABLE action.batch_lane_item
(
	batch_lane_item_id bigint generated always as identity
		primary key,
	lane_item_id bigint not null,
	lane_id bigint not null,
	step text not null,
	-- null = the nests of this item that have no batch yet
	batch_id bigint,
	nest_ids bigint[] default '{}'::bigint[] not null,
	foreign key (lane_item_id, lane_id) references action.lane_item (lane_item_id, lane_id)
		on delete cascade,
	foreign key (lane_id, step) references action.lane (lane_id, step),
	unique (lane_item_id, batch_id)
);

COMMENT ON TABLE action.batch_lane_item IS 'The nests of a lane item per batch: one row per batch on the item, batch_id null for the nests not batched yet (one such row per item), nest_ids the nests of the item''s own plan date. Impose items carry many batches, every other step one row, an empty pv2 slot none.';
COMMENT ON COLUMN action.batch_lane_item.lane_id IS 'Copy of lane_item.lane_id, held true by the composite foreign key; carries the uniqueness rules.';
COMMENT ON COLUMN action.batch_lane_item.step IS 'Copy of lane.step, held true by the composite foreign key; one row per item on every step but impose.';

ALTER TABLE action.batch_lane_item OWNER TO xfw3;

-- one null-batch row per item
CREATE UNIQUE INDEX batch_lane_item_one_null_batch_uq
    ON action.batch_lane_item (lane_item_id)
    WHERE batch_id IS NULL;

-- one batch per item on every step but impose
CREATE UNIQUE INDEX batch_lane_item_one_batch_outside_impose_uq
    ON action.batch_lane_item (lane_item_id)
    WHERE step <> 'impose';

CREATE INDEX idx_batch_lane_item_lane_id
    ON action.batch_lane_item (lane_id);
CREATE INDEX idx_batch_lane_item_batch_id
    ON action.batch_lane_item (batch_id);
-- which item holds a nest: nest_ids @> array[nest_id]
CREATE INDEX idx_batch_lane_item_nest_ids
    ON action.batch_lane_item USING gin (nest_ids);

COMMIT;

-- check: lanes per step and kind; expected: every lane has a step, impose = the group lanes (1.430) + 60 impose resource lanes
SELECT l.step,
       count(*) FILTER (WHERE igl.lane_id IS NOT NULL) AS group_lanes,
       count(*) FILTER (WHERE rl.lane_id IS NOT NULL)  AS resource_lanes,
       count(DISTINCT l.resource_path)                 AS paths
FROM action.lane l
LEFT JOIN action.imposition_group_lane igl ON igl.lane_id = l.lane_id
LEFT JOIN action.resource_lane rl ON rl.lane_id = l.lane_id
GROUP BY l.step
ORDER BY l.step;

-- check: the group lane paths are four labels; expected 0
SELECT count(*) AS group_lanes_not_four_labels
FROM action.lane l
JOIN action.imposition_group_lane igl ON igl.lane_id = l.lane_id
WHERE nlevel(l.resource_path) <> 4;
