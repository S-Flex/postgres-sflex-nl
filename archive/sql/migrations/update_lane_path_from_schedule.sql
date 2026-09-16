-- The group lanes follow the schedule's path. A group lane carries the first
-- four labels of mock.material_print_schedule.resource_path
-- (site.line.impose.width), stamped by mock.generate_plan when the day plan
-- was made. The schedule moved from width 320 to 350 on 11 Sep 2026 and the
-- lanes kept 320: 284 lanes from today onward, 490 in the past. The lane is
-- linked to its schedule row through its items (source_ref
-- <material_print_schedule_id>:<date>:<instance>). The check first, then the
-- update of every lane whose path differs; the past ones as well, the width
-- was never 320.

-- check: the lanes that differ, per path pair (expect 320 -> 350 only)
SELECT l.resource_path::text AS lane_path, subpath(mps.resource_path, 0, 4)::text AS schedule_path,
       count(DISTINCT l.lane_id) AS lanes, min(l.lane_date) AS first_date, max(l.lane_date) AS last_date
FROM action.lane l
JOIN action.imposition_group_lane gl ON gl.lane_id = l.lane_id
JOIN action.lane_item li ON li.lane_id = l.lane_id AND li.source = 'material-plan'
JOIN mock.material_print_schedule mps ON mps.material_print_schedule_id = nullif(split_part(li.source_ref, ':', 1), '')::bigint
WHERE l.resource_path <> subpath(mps.resource_path, 0, 4)
GROUP BY 1, 2
ORDER BY 1, 2;

BEGIN;

UPDATE action.lane l
SET resource_path = x.schedule_path
FROM (SELECT DISTINCT li.lane_id, subpath(mps.resource_path, 0, 4) AS schedule_path
      FROM action.lane_item li
      JOIN action.imposition_group_lane gl ON gl.lane_id = li.lane_id
      JOIN mock.material_print_schedule mps ON mps.material_print_schedule_id = nullif(split_part(li.source_ref, ':', 1), '')::bigint
      WHERE li.source = 'material-plan'
        AND mps.resource_path IS NOT NULL) x
WHERE l.lane_id = x.lane_id
  AND l.resource_path <> x.schedule_path;

COMMIT;

-- check: nothing differs any more (expect 0)
SELECT count(*) AS lanes_differing
FROM action.lane l
JOIN action.imposition_group_lane gl ON gl.lane_id = l.lane_id
JOIN action.lane_item li ON li.lane_id = l.lane_id AND li.source = 'material-plan'
JOIN mock.material_print_schedule mps ON mps.material_print_schedule_id = nullif(split_part(li.source_ref, ':', 1), '')::bigint
WHERE l.resource_path <> subpath(mps.resource_path, 0, 4);
