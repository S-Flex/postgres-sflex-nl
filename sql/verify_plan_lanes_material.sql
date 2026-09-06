-- Read-only. Walks the impose board chain for one material and shows where a
-- row would drop out. Replace 480/481, 'print', 'sheet' as needed.
--
--   plan            -> action.plan (newest of the day, type material-resource-plan)
--   lane_item       -> action.plan_lane + action.lane_item (source 'material-plan')
--   source_ref      -> mock.material_impose_plan (the weekly pattern)
--   schedule        -> mock.material_print_schedule (delivery class + interval)
--   get_plan_lanes  -> the label read
--   get_impose_plan -> the board read (adds the orderline aggregate)

-- 1. the weekly pattern: is there a row for today's weekday?
SELECT material_id, weekday, step, production_line_id, tenant_id, sort_order,
       resource_path::text, start_offset_in_seconds, is_pinned
FROM mock.material_impose_plan
WHERE material_id IN (480, 481)
  AND weekday = extract(dow FROM current_date)::smallint + 1
ORDER BY material_id;

-- 2. delivery class and interval. delivery_hours must match a "code" in
--    production.lookup_nest_moments to become a fixed group.
SELECT DISTINCT mps.material_id, mps.material_name, mps.line, mps.delivery_hours,
       mps.interval_start_date, coalesce(nullif(mps.interval_days, 0), 1) AS interval_days
FROM mock.material_print_schedule mps
WHERE mps.material_id IN (480, 481);

-- 3. is the material in today's plan at all?
WITH the_plan AS (
    SELECT plan_id FROM action.plan
    WHERE plan_date = current_date AND 'print' = ANY (steps)
      AND type = 'material-resource-plan' AND line_type = 'sheet'
    ORDER BY plan_id DESC LIMIT 1
)
SELECT m.material_id, li.lane_item_id, li.lane_id, pl.sort_order,
       igli.imposition_group_id
FROM the_plan tp
JOIN action.plan_lane pl USING (plan_id)
JOIN action.lane_item li ON li.lane_id = pl.lane_id AND li.type = 'plan'
LEFT JOIN action.imposition_group_lane_item igli ON igli.lane_item_id = li.lane_item_id
LEFT JOIN mock.material_impose_plan m
       ON m.material_impose_plan_id = nullif(split_part(li.source_ref, ':', 1), '')::bigint
WHERE li.source = 'material-plan' AND m.material_id IN (480, 481)
ORDER BY m.material_id;

-- 4. does the label read serve it, and does the interval filter drop it?
SELECT 'starting_today=true' AS mode, material_id, delivery_hours, fixed_group,
       start_offset_in_seconds, lane_item_id
FROM action.get_plan_lanes(now(), 'print', 'sheet', NULL, true)
WHERE material_id IN (480, 481)
UNION ALL
SELECT 'starting_today=false', material_id, delivery_hours, fixed_group,
       start_offset_in_seconds, lane_item_id
FROM action.get_plan_lanes(now(), 'print', 'sheet', NULL, false)
WHERE material_id IN (480, 481)
ORDER BY 1, 2;

-- 5. the board read. orderline_count 0 means the row is there but has no work.
SELECT material_id, material_name, delivery_hours, fixed_group,
       start_offset_in_seconds, duration_in_seconds,
       orderline_count, sqm, nest_count, nest_ids
FROM mock.get_impose_plan(now(), 'print', 'sheet')
WHERE material_id IN (480, 481)
ORDER BY material_id;

-- 6. why the count is 0: the open lines, their status sequence and nest date.
--    The board counts sequences 225,290,300,350,400,450 and, with
--    p_look_back_days / p_look_ahead_days at 0, only nest_date = today.
SELECT cs.material_id, cs.internal_status_code, ist.sequence,
       (cs.nest_date AT TIME ZONE 'Europe/Amsterdam')::date AS nest_date,
       cs.production_date::date AS production_date,
       count(*) AS lines,
       ist.sequence = ANY (ARRAY[225,290,300,350,400,450]) AS sequence_counts,
       (cs.nest_date AT TIME ZONE 'Europe/Amsterdam')::date = current_date AS nests_today
FROM mapping.component_specs cs
JOIN mapping.internal_status ist
  ON ist.code = cs.internal_status_code AND ist.domain_id = cs.domain_id
WHERE cs.material_id IN (480, 481) AND cs.domain_id = 1 AND cs.is_open = true
GROUP BY 1, 2, 3, 4, 5
ORDER BY cs.material_id, 4;
