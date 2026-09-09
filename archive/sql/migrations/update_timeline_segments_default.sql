-- ============================================================
-- production.get_timeline_view_segments (7 sep): p_look_back and p_look_ahead
-- default to -1, the whole view, instead of 0; and a new column day_offset,
-- the day of a segment relative to the day of p_until (-1 the day before, 0
-- that day, 1 the day after) — the offsets count from midnight of day 0, so a
-- segment of the evening before carries a negative offset and day_offset -1.
-- The time scale of 75, 76 and 81 names it as day_offset_field. The return
-- type changes: recycle the hub afterwards.
-- ============================================================

BEGIN;

drop function if exists production.get_timeline_view_segments(text, timestamp with time zone, integer, integer, integer[]);

create function production.get_timeline_view_segments(p_code text, p_until timestamp with time zone DEFAULT now(), p_look_back integer DEFAULT -1, p_look_ahead integer DEFAULT -1, p_tenant_ids integer[] DEFAULT NULL::integer[]) returns TABLE(code text, i18n jsonb, class_names jsonb, "time" time with time zone, duration_in_seconds integer, segment_size_in_seconds integer, start_offset_in_seconds integer, end_offset_in_seconds integer, sort_order integer, is_current boolean, day_offset integer, date date, start_at timestamp with time zone, end_at timestamp with time zone)
	language plpgsql
as $$
#variable_conflict use_column
DECLARE
    v_view jsonb;
    v_size integer;
    v_ref  date;
    v_min  integer;
    v_max  integer;
BEGIN
    SELECT v.value
    INTO v_view
    FROM production.lookup l
             CROSS JOIN LATERAL jsonb_array_elements(l.lookup_json) AS v(value)
    WHERE l.lookup = 'lookup_timeline_views'
      AND v.value ->> 'code' = p_code;

    IF v_view IS NULL THEN
        RETURN;
    END IF;

    -- Segment size lives on the VIEW level, directly under the code: one
    -- uniform column width for the whole view. Null means every segment
    -- keeps its own duration as its size, so widths vary per column.
    v_size := (v_view ->> 'segment_size_in_seconds')::integer;

    v_ref := (p_until AT TIME ZONE current_setting('TimeZone'))::date;

    -- first and last day the segments reach, relative to the day of p_until
    SELECT least(min(x.day_offset + x.start_sec / 86400), 0),
           greatest(max(x.day_offset + (x.start_sec + x.duration - 1) / 86400), 0)
    INTO v_min, v_max
    FROM jsonb_array_elements(v_view -> 'segments') AS s(value)
             CROSS JOIN LATERAL (
                 SELECT coalesce((s.value ->> 'day_offset')::integer, 0)          AS day_offset,
                        extract(epoch FROM (s.value ->> 'time')::timetz)::integer AS start_sec,
                        (s.value ->> 'duration_in_seconds')::integer              AS duration
                 ) x;

    RETURN QUERY
    WITH included AS NOT MATERIALIZED (
        -- a date excluded here does not exist on the axis at all
        SELECT d.date
        FROM action.dates d
        WHERE NOT (coalesce((v_view ->> 'exclude_weekend')::boolean, false)
                       AND d.is_weekend)
          AND NOT (coalesce((v_view ->> 'exclude_mandatory_day_off')::boolean, false)
                       AND (coalesce(p_tenant_ids, d.tenants_mandatory_day_off) <@ d.tenants_mandatory_day_off and d.tenants_mandatory_day_off <> '{}'))
    ),
    day AS (
        -- day_index 0 is the first included day on or after p_until, so an excluded day moves forward
        SELECT date,
               row_number() OVER (ORDER BY date)::integer - 1 + v_min AS day_index
        FROM ((SELECT date FROM included WHERE date <  v_ref ORDER BY date DESC LIMIT -v_min)
              UNION ALL
              (SELECT date FROM included WHERE date >= v_ref ORDER BY date      LIMIT v_max + 1)) d
    ),
    sub AS (
        -- every segment cut into sub segments of the view's segment size;
        -- without one, the segment stays whole (size = its own duration)
        SELECT s.value -> 'i18n'                                    AS i18n,
               s.value -> 'class_names'                             AS class_names,
               s.ordinality::integer                                AS segment_order,
               x.day_offset,
               least(x.size, x.duration - g.i * x.size)             AS duration_in_seconds,
               -- 86400 only places a sub segment on a date, every other length comes from the data
               x.day_offset + (x.start_sec + g.i * x.size) / 86400  AS day_index,
               '00:00:00+00'::timetz
                   + make_interval(secs => (x.start_sec + g.i * x.size) % 86400) AS "time"
        FROM jsonb_array_elements(v_view -> 'segments') WITH ORDINALITY AS s(value, ordinality)
                 CROSS JOIN LATERAL (
                     SELECT coalesce((s.value ->> 'day_offset')::integer, 0)          AS day_offset,
                            extract(epoch FROM (s.value ->> 'time')::timetz)::integer AS start_sec,
                            (s.value ->> 'duration_in_seconds')::integer              AS duration,
                            coalesce(v_size,
                                     (s.value ->> 'duration_in_seconds')::integer)    AS size
                     ) x
                 CROSS JOIN LATERAL generate_series(
                     0, ceil(x.duration::numeric / x.size)::integer - 1) AS g(i)
    ),
    instance AS (
        SELECT sub.*,
               d.date,
               d.date + sub."time"                                                    AS start_at,
               d.date + sub."time" + make_interval(secs => sub.duration_in_seconds)   AS end_at,
               row_number() OVER (ORDER BY sub.day_index, sub."time", sub.segment_order)::integer AS sort_order
        FROM sub
                 JOIN day d ON d.day_index = sub.day_index
    ),
    mark AS (
        -- sort_order runs with start_at, so the first segment not yet ended is the one to land on
        SELECT min(sort_order) FILTER (WHERE end_at > p_until) AS anchor_order,
               min(sort_order) FILTER (WHERE end_at > now())   AS current_order
        FROM instance
    )
    SELECT p_code,
           n.i18n,
           n.class_names,
           n."time",
           n.duration_in_seconds,
           -- the real column width: the view's uniform size, or this
           -- sub segment's own duration when the view sets none
           coalesce(v_size, n.duration_in_seconds),
           n.day_index * 86400 + extract(epoch FROM n."time")::integer,
           n.day_index * 86400 + extract(epoch FROM n."time")::integer + n.duration_in_seconds,
           n.sort_order - m.anchor_order + 1,
           n.sort_order IS NOT DISTINCT FROM m.current_order,
           -- the day of the segment relative to the day of p_until: -1 the day
           -- before, 0 that day, 1 the day after — the offsets count from day 0
           n.day_index,
           n.date,
           n.start_at,
           n.end_at
    FROM instance n
             CROSS JOIN mark m
    WHERE (p_look_back  = -1 OR n.sort_order >= m.anchor_order - p_look_back)
      AND (p_look_ahead = -1 OR n.sort_order <= m.anchor_order + p_look_ahead)
    ORDER BY n.sort_order;
END;
$$;

alter function production.get_timeline_view_segments(text, timestamp with time zone, integer, integer, integer[]) owner to xfw3;


COMMIT;

-- check: the nest time scale for a day, segments per day_offset
SELECT day_offset, count(*) AS segments, min(start_offset_in_seconds) AS first_offset, max(end_offset_in_seconds) AS last_offset
FROM production.get_timeline_view_segments(p_code => 'nest-time-scale', p_until => '2026-09-07'::timestamptz)
GROUP BY day_offset ORDER BY day_offset;
