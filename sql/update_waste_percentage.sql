-- waste_factor -> waste_percentage in legacy.imposition_group.rules_json, and
-- imposition_sqm recomputed from the format (docs/schedule-base.md §4.2).
--
--   imposition_sqm = (1 - waste_percentage) * width * max_height / 10000
--
-- width and max_height are in cm (the unit contract: dimensions in cm), the
-- key says the result is m2, hence the / 10000. What is stored today is the
-- gross format without the waste: 150.1 x 305.1 gave 4.58, which is exactly
-- 150.1 * 305.1 / 10000. The waste is in it now, so every value drops.
--
-- The value of waste_percentage is the value waste_factor had: a fraction
-- between 0 and 1. Only the name changes -- mapping.get_production_orderline_manifest
-- reads it as (1 - it) * 100 for the fill percentage, which stays right.
--
-- Run in this order, in one window:
--   1. this script
--   2. sql/action/get_plan_lanes_imposition_group.sql   (the key in param_json)
--   3. sql/mapping/get_production_orderline_manifest.sql (the fill percentage)
-- Both readers are already on the new name in the repo; until they are
-- replaced they read a key that no longer exists and give null.
--
-- Rollback: sql/update_waste_percentage_down.sql

BEGIN;

-- ── backup, for the rollback ─────────────────────────────────────────────
CREATE TABLE legacy.imposition_group_rules_backup_20260916 AS
SELECT g.tenant_id, g.imposition_group_id, g.rules_json
FROM legacy.imposition_group g
WHERE jsonb_typeof(g.rules_json -> 'waste') = 'array';

ALTER TABLE legacy.imposition_group_rules_backup_20260916 OWNER TO xfw3;

-- ── guard: a waste entry without the three keys stops the whole script ───
DO $$
DECLARE
    v_incomplete integer;
BEGIN
    SELECT count(*) INTO v_incomplete
    FROM legacy.imposition_group g
    CROSS JOIN LATERAL jsonb_array_elements(coalesce(g.rules_json -> 'waste', '[]'::jsonb)) f
    WHERE NOT (f.value ? 'waste_factor' AND f.value ? 'width' AND f.value ? 'max_height');

    IF v_incomplete > 0 THEN
        RAISE EXCEPTION 'waste entries without waste_factor, width or max_height: % -- nothing changed', v_incomplete;
    END IF;
END $$;

-- ── the rename and the new imposition_sqm ────────────────────────────────
-- Every other key of an entry is kept, the order of the array is kept.
UPDATE legacy.imposition_group g
SET rules_json = jsonb_set(g.rules_json, '{waste}', w.waste)
FROM (
    SELECT g2.tenant_id,
           g2.imposition_group_id,
           jsonb_agg(
               (f.value - 'waste_factor')
               || jsonb_build_object(
                      'waste_percentage', (f.value ->> 'waste_factor')::numeric,
                      'imposition_sqm',
                      round((1 - (f.value ->> 'waste_factor')::numeric)
                            * (f.value ->> 'width')::numeric
                            * (f.value ->> 'max_height')::numeric / 10000, 2))
               ORDER BY f.ordinality) AS waste
    FROM legacy.imposition_group g2
    CROSS JOIN LATERAL jsonb_array_elements(g2.rules_json -> 'waste')
        WITH ORDINALITY AS f(value, ordinality)
    WHERE jsonb_typeof(g2.rules_json -> 'waste') = 'array'
    GROUP BY g2.tenant_id, g2.imposition_group_id
) w
WHERE (g.tenant_id, g.imposition_group_id) = (w.tenant_id, w.imposition_group_id);

-- ── check 1: no waste_factor left, every entry has waste_percentage ──────
SELECT count(*) FILTER (WHERE f.value ? 'waste_factor')     AS left_on_old_name,
       count(*) FILTER (WHERE f.value ? 'waste_percentage') AS on_new_name,
       count(*)                                             AS waste_entries,
       count(*) FILTER (WHERE (f.value ->> 'waste_percentage')::numeric NOT BETWEEN 0 AND 1)
                                                            AS outside_zero_one
FROM legacy.imposition_group g
CROSS JOIN LATERAL jsonb_array_elements(coalesce(g.rules_json -> 'waste', '[]'::jsonb)) f;

-- ── check 2: the new against the old value, largest change first ─────────
SELECT g.tenant_id, g.imposition_group_id,
       (f.value ->> 'width')::numeric            AS width,
       (f.value ->> 'max_height')::numeric       AS max_height,
       (f.value ->> 'waste_percentage')::numeric AS waste_percentage,
       (b.value ->> 'imposition_sqm')::numeric   AS was_sqm,
       (f.value ->> 'imposition_sqm')::numeric   AS is_sqm
FROM legacy.imposition_group g
CROSS JOIN LATERAL jsonb_array_elements(g.rules_json -> 'waste') WITH ORDINALITY AS f(value, ord)
JOIN legacy.imposition_group_rules_backup_20260916 bk
  ON (bk.tenant_id, bk.imposition_group_id) = (g.tenant_id, g.imposition_group_id)
CROSS JOIN LATERAL jsonb_array_elements(bk.rules_json -> 'waste') WITH ORDINALITY AS b(value, ord)
WHERE b.ord = f.ord
ORDER BY (b.value ->> 'imposition_sqm')::numeric - (f.value ->> 'imposition_sqm')::numeric DESC
LIMIT 20;

COMMIT;
