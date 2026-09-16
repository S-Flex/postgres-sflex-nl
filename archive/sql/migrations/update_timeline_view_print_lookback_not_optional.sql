-- Test and fallback for board 75: the look-back segment of print-day-scale
-- stays (two workdays before p_until) but is no longer optional. With
-- is_optional true the board showed only the cards inside the optional
-- segments and hid the rest (10 Sep 2026); with false it shows the two days
-- always. Set it back to true once the frontend hides an empty optional
-- segment instead of the cards outside it (sql/update_timeline_view_print_lookback.sql).
BEGIN;

UPDATE production.lookup l
SET lookup_json = (SELECT jsonb_agg(CASE WHEN e.value ->> 'code' = 'print-day-scale'
                                         THEN jsonb_set(e.value, '{segments}',
                                                        (SELECT jsonb_agg(s.value - 'is_optional' ORDER BY s.ord)
                                                         FROM jsonb_array_elements(e.value -> 'segments') WITH ORDINALITY AS s(value, ord)))
                                         ELSE e.value END ORDER BY e.ord)
                   FROM jsonb_array_elements(l.lookup_json) WITH ORDINALITY AS e(value, ord))
WHERE l.lookup = 'lookup_timeline_views';

COMMIT;

-- check: days -2 .. 9, none optional
SELECT day_offset, date, is_optional
FROM production.get_timeline_view_segments(p_code => 'print-day-scale', p_look_back => -1, p_look_ahead => -1)
ORDER BY day_offset;
