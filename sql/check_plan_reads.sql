-- Read-only checks after deploying the plan reads (2026-09-04), see
-- docs/plan-lanes-boards.md "performance". Run each block on its own.

-- 1. get_impose_plan works again (it failed with "column
--    na.production_impact_in_seconds does not exist" while the live
--    aggregate was the version without that column); expected: rows > 0
SELECT count(*) AS impose_plan_rows,
       count(*) FILTER (WHERE duration_in_seconds > 900) AS rows_above_floor
FROM mock.get_impose_plan(now(), 'print', 'sheet', NULL, 0, 0, 1);

-- 2. server-side times; expected roughly: lanes material today <= 25 ms
--    (was 135), print_schedule <= 300 ms (was 465-545), interval <= 1 ms
--    (was 5-9)
EXPLAIN (ANALYZE, SUMMARY)
SELECT * FROM action.get_plan_lanes(now(), 'print', 'sheet', NULL, true, 'material-resource-plan', NULL);

EXPLAIN (ANALYZE, SUMMARY)
SELECT * FROM mock.get_print_schedule(now(), 'sheet', NULL, false);

EXPLAIN (ANALYZE, SUMMARY)
SELECT * FROM action.get_interval_dates('2026-08-03', current_date, 2, 10, false, false, 0, NULL);

-- 3. the interval function returns what it always did: every second
--    workday from the anchor, the first on or after today; expected: five
--    dates, all Mondays/Wednesdays/... at two-workday spacing
SELECT * FROM action.get_interval_dates('2026-08-03', current_date, 2, 10, false, false, 0, NULL);

-- 4. the manifest of a recent nest with a print line; expected: one row
--    per option code, the print-method row with an impact in seconds
--    (width x height / 222.2 for standard print)
SELECT m.imposition_id, m.option_code, m.item_code, m.amount,
       m.production_impact_per_unit,
       m.param_json ->> 'width' AS width_cm, m.param_json ->> 'height' AS height_cm
FROM legacy.imposition_unit_manifest m
WHERE m.imposition_id = (SELECT max(imposition_id) FROM legacy.imposition_unit_manifest
                         WHERE option_code LIKE 'print-method.%')
ORDER BY m.sort_order, m.option_code;

-- 5. the forecast reader uses the new index; expected: "Index Only Scan
--    using ix_component_specs_production_date" in the plan
EXPLAIN (ANALYZE, SUMMARY)
SELECT * FROM mock.get_production_forecast_material(current_date, 33, 'sheet');
