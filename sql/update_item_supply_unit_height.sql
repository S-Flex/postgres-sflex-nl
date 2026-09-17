-- supply_unit_height on every spec of catalog.item.item_json
-- (docs/supply-handling.md).
--
--   supply_unit_height = min_height * supply_unit_amount
--
-- The total height in the supply unit, in cm: a roll length, or the number of
-- sheets times the sheet height. Stored, not computed at read time, so a
-- reader needs one key instead of two. Every other key of a spec is kept and
-- the order of the array is kept.
--
-- Run the three checks of sql/check_item_specs.sql first: this script only
-- adds a key, it does not repair a spec that is missing one.
--
-- Rollback: sql/update_item_supply_unit_height_down.sql

BEGIN;

-- ── backup, for the rollback ─────────────────────────────────────────────
CREATE TABLE catalog.item_json_backup_20260917 AS
SELECT i.item_id, i.item_json
FROM catalog.item i
WHERE jsonb_typeof(i.item_json -> 'specs') = 'array';

ALTER TABLE catalog.item_json_backup_20260917 OWNER TO xfw3;

-- ── guard: a spec without min_height or supply_unit_amount stops the run ─
DO $$
DECLARE
    v_incomplete integer;
BEGIN
    SELECT count(*) INTO v_incomplete
    FROM catalog.item i
    CROSS JOIN LATERAL jsonb_array_elements(coalesce(i.item_json -> 'specs', '[]'::jsonb)) e
    WHERE e.value ? 'width'                       -- a format spec, not another kind of entry
      AND NOT (e.value ? 'min_height' AND e.value ? 'supply_unit_amount');

    IF v_incomplete > 0 THEN
        RAISE EXCEPTION 'format specs without min_height or supply_unit_amount: % -- nothing changed', v_incomplete;
    END IF;
END $$;

-- ── the derived height ───────────────────────────────────────────────────
UPDATE catalog.item i
SET item_json = jsonb_set(i.item_json, '{specs}', s.specs)
FROM (
    SELECT i2.item_id,
           jsonb_agg(
               CASE WHEN e.value ? 'width'
                    THEN e.value || jsonb_build_object(
                             'supply_unit_height',
                             round((e.value ->> 'min_height')::numeric
                                   * (e.value ->> 'supply_unit_amount')::numeric, 2))
                    ELSE e.value
               END
               ORDER BY e.ord) AS specs
    FROM catalog.item i2
    CROSS JOIN LATERAL jsonb_array_elements(i2.item_json -> 'specs') WITH ORDINALITY AS e(value, ord)
    WHERE jsonb_typeof(i2.item_json -> 'specs') = 'array'
    GROUP BY i2.item_id
) s
WHERE s.item_id = i.item_id;

-- ── check 1: every format spec has the key now ───────────────────────────
SELECT count(*)                                                      AS format_specs,
       count(*) FILTER (WHERE e.value ? 'supply_unit_height')        AS with_height,
       count(*) FILTER (WHERE (e.value ->> 'supply_unit_height')::numeric IS NULL
                           OR (e.value ->> 'supply_unit_height')::numeric <= 0) AS zero_or_null
FROM catalog.item i
CROSS JOIN LATERAL jsonb_array_elements(coalesce(i.item_json -> 'specs', '[]'::jsonb)) e
WHERE e.value ? 'width';

-- ── check 2: per media type, so a roll can be eyeballed against a sheet ──
-- A sheet should read as sheets x sheet height; a roll as the roll length.
SELECT i.item_json ->> 'media_type'                          AS media_type,
       count(*)                                              AS format_specs,
       min((e.value ->> 'supply_unit_height')::numeric)       AS min_height_total,
       round(avg((e.value ->> 'supply_unit_height')::numeric), 1) AS avg_height_total,
       max((e.value ->> 'supply_unit_height')::numeric)       AS max_height_total
FROM catalog.item i
CROSS JOIN LATERAL jsonb_array_elements(coalesce(i.item_json -> 'specs', '[]'::jsonb)) e
WHERE e.value ? 'width'
GROUP BY i.item_json ->> 'media_type'
ORDER BY 1;

COMMIT;
