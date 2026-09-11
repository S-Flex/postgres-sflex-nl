-- Board 75 back to an axis from day 0: the frontend draws no cards on an axis
-- that starts before day 0 (10 Sep 2026), so the look-back segment leaves the
-- print-day-scale view. The overdue work stands on day 0 as delayed cards
-- (mock.get_print_schedule). Mirror: json/lookup/production/lookup_timeline_views.json.
BEGIN;

UPDATE production.lookup l
SET lookup_json = (SELECT jsonb_agg(CASE WHEN e.value ->> 'code' = 'print-day-scale'
                                         THEN jsonb_set(e.value, '{segments}', '[{"time":"00:00:00","day_offset":0,"duration_in_seconds":864000}]'::jsonb)
                                         ELSE e.value END ORDER BY e.ord)
                   FROM jsonb_array_elements(l.lookup_json) WITH ORDINALITY AS e(value, ord))
WHERE l.lookup = 'lookup_timeline_views';

COMMIT;

-- check: days 0 .. 9
SELECT min(day_offset) AS first_day, max(day_offset) AS last_day
FROM production.get_timeline_view_segments(p_code => 'print-day-scale', p_look_back => -1, p_look_ahead => -1);
