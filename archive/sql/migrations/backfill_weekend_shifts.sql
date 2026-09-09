-- ============================================================
-- Weekend shifts and the OEE aggregate (7 sep). log.state_shift_agg has rows
-- for every weekend day, but the weekend window in action.dates.shift_json is
-- one shift 08:00-17:00, while the machines run on saturdays until about
-- 21:00 (log.data, last 8 weeks: 27 h of production between 17:00 and 21:00,
-- a third of the saturday work outside the window; 5 sep: 90 h produced,
-- 61 h inside the window). Weekdays have 06:00-15:00 and 15:00-00:00.
-- This script sets the weekend window to one shift 06:00-22:00 — the hours
-- the data shows work in — for every weekend day from the first with data
-- (13 jun) on, future days included, and rebuilds the aggregate for the
-- weekend days that have passed (log.upsert_state_shift_agg, one date at a
-- time: delete + insert per date, the same run as the daily refresh).
-- The window is the variable at the top of the DO block: change it there
-- before running when HR says otherwise. Production between 00:00 and 05:00
-- on saturday (the friday night crew running on) stays outside every window,
-- as it does on weekdays; that is a shift question, not this script's.
-- Run the check, the DO block, the check again.
-- ============================================================

-- check: producing hours in the aggregate against the measured production per weekend day
SELECT d.date, d.shift_json::text AS shifts,
       (SELECT round(sum(a.duration_seconds) / 3600, 1) FROM log.state_shift_agg a WHERE a.shift_date = d.date AND a.state = 'producing') AS agg_producing_h,
       (SELECT round(sum(x.production_time_seconds) / 3600, 1) FROM log.data x WHERE (x.start_at AT TIME ZONE 'Europe/Amsterdam')::date = d.date) AS data_produced_h
FROM action.dates d
WHERE d.is_weekend AND d.date BETWEEN '2026-06-13' AND current_date
ORDER BY 1;

DO $$
DECLARE
    -- the weekend window; one shift, start and end as on the weekdays' rows
    v_weekend_shift constant jsonb := '[{"start_time": "06:00", "end_time": "22:00"}]';
    v_from          constant date  := '2026-06-13';
    v_days   integer := 0;
    v_rows   integer := 0;
    v_n      integer;
    r record;
BEGIN
    UPDATE action.dates d
    SET shift_json = v_weekend_shift
    WHERE d.is_weekend AND d.date >= v_from
      AND d.shift_json IS DISTINCT FROM v_weekend_shift;
    GET DIAGNOSTICS v_days = ROW_COUNT;

    FOR r IN
        SELECT d.date FROM action.dates d
        WHERE d.is_weekend AND d.date >= v_from AND d.date <= current_date
        ORDER BY d.date
    LOOP
        v_n := log.upsert_state_shift_agg(r.date);
        v_rows := v_rows + coalesce(v_n, 0);
    END LOOP;

    RAISE NOTICE 'weekend days given the window: %, aggregate rows rebuilt: %', v_days, v_rows;
END $$;
