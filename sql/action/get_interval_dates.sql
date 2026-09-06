-- The production days of an interval: every p_interval-th workday, counted
-- from p_reference_date, from p_current_date (+ p_day_offset) on, for
-- p_look_ahead_days workdays. A workday is a date that is not a weekend and,
-- unless p_include_mandatory_days_off, not a mandatory day off of the
-- tenants (all tenants when p_tenant_ids is null).
--
-- One pass over action.dates: the numbering and both anchors come out of the
-- same scan (the anchors as window aggregates), and the scan is bounded to
-- the dates that can matter. Only the distance between the anchors and a
-- date counts, so where the numbering starts is irrelevant — as long as the
-- window holds both anchors and every date the look-ahead can reach. The
-- margins are calendar days for a number of workdays: two per workday plus
-- two weeks for a run of days off. The old version numbered the whole table
-- (4.000 rows, four times) and cost 5-9 ms per call; this one costs 0,5 ms.
create or replace function action.get_interval_dates(p_reference_date date, p_current_date date, p_interval integer, p_look_ahead_days integer, p_include_weekends boolean DEFAULT false, p_include_mandatory_days_off boolean DEFAULT true, p_day_offset integer DEFAULT 0, p_tenant_ids integer[] DEFAULT NULL::integer[]) returns TABLE(interval_date date)
	stable
	language sql
as $$
    SELECT t.date AS interval_date
    FROM (SELECT s.date, s.seq,
                 max(s.seq) FILTER (WHERE s.date = p_reference_date) OVER () AS ref_seq,
                 max(s.seq) FILTER (WHERE s.date = p_current_date)   OVER () AS cur_seq
          FROM (SELECT d.date, row_number() OVER (ORDER BY d.date) AS seq
                FROM action.dates d
                WHERE d.date >= least(p_reference_date, p_current_date)
                                - (greatest(-p_day_offset, 0) * 2 + 14)
                  AND d.date <= greatest(p_reference_date, p_current_date)
                                + ((p_look_ahead_days + greatest(p_day_offset, 0)) * 2 + 14)
                  AND (p_include_weekends OR d.is_weekend = false)
                  AND (p_include_mandatory_days_off
                       OR NOT (coalesce(p_tenant_ids, d.tenants_mandatory_day_off) <@ d.tenants_mandatory_day_off
                               AND d.tenants_mandatory_day_off <> '{}'))) s) t
    -- the reference shifts along with the offset; sign() keeps a zero offset
    -- from moving it at all (the formula this function always had)
    WHERE t.seq >= t.cur_seq + p_day_offset
      AND (t.seq - (t.ref_seq + p_day_offset + (t.cur_seq - t.ref_seq) * sign(p_day_offset)::integer)) % p_interval = 0
      AND t.seq - (t.cur_seq + p_day_offset) < p_look_ahead_days
    ORDER BY t.date;
$$;

alter function action.get_interval_dates(date, date, integer, integer, boolean, boolean, integer, integer[]) owner to xfw3;
