-- Step 1e: schedule.lookup (docs/schedule-base.md §3).
--
-- The schedule schema gets its own lookup table, same shape as action.lookup,
-- and the three lane item lookups are copied into it unchanged. Nothing else
-- moves: action.lookup keeps its rows, and every reader (action, mock and the
-- schedule reads) keeps reading action.lookup until a later step switches it.
--
-- Rollback: sql/update_schedule_1e_lookup_down.sql

BEGIN;

-- ── the table ────────────────────────────────────────────────────────────
CREATE TABLE schedule.lookup
(
	lookup text not null
		constraint pk_schedule_lookup
			primary key,
	lookup_json jsonb
);

COMMENT ON TABLE schedule.lookup IS 'The lookups of the schedule schema, same shape as action.lookup: the lookup name as key, the content as a jsonb array in lookup_json. The content lives in the repo as json/lookup/schedule/<lookup>.json.';

ALTER TABLE schedule.lookup OWNER TO xfw3;

-- ── the three rows, copied as they are ───────────────────────────────────
INSERT INTO schedule.lookup (lookup, lookup_json)
SELECT lk.lookup, lk.lookup_json
FROM action.lookup lk
WHERE lk.lookup IN ('lookup_lane_item_type',
                    'lookup_lane_item_status',
                    'lookup_lane_item_event_type');

-- ── what landed: three rows, 3 / 3 / 9 entries ───────────────────────────
SELECT lk.lookup, jsonb_array_length(lk.lookup_json) AS entries
FROM schedule.lookup lk
ORDER BY lk.lookup;

COMMIT;
