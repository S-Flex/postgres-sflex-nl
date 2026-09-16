-- The nest moments of a material are the rows on board 75: the codes of its
-- lane items (stamped by mock.generate_plan). mock.material_print_schedule
-- .nest_moment_codes is set to exactly those codes, in lookup order, for
-- every schedule row that has items from today on (65 sheet rows, 964 codes
-- down to 179 on 10 Sep 2026). The cards of mock.get_print_schedule map their
-- production_hours onto these codes, so every card finds its row. A row
-- without items keeps its codes.
BEGIN;

WITH nm AS (
    SELECT v.value ->> 'code' AS code, v.ord
    FROM production.lookup l
    CROSS JOIN LATERAL jsonb_array_elements(l.lookup_json) WITH ORDINALITY AS v(value, ord)
    WHERE l.lookup = 'lookup_nest_moments'
),
item_code AS (
    SELECT nullif(split_part(li.source_ref, ':', 1), '')::bigint AS material_print_schedule_id,
           li.nest_moment_code
    FROM action.lane_item li
    JOIN action.lane l ON l.lane_id = li.lane_id
    WHERE li.source = 'material-plan'
      AND li.nest_moment_code IS NOT NULL
      AND l.lane_date >= current_date
    GROUP BY 1, 2
),
codes AS (
    SELECT i.material_print_schedule_id,
           array_agg(i.nest_moment_code ORDER BY nm.ord) AS nest_moment_codes
    FROM item_code i
    JOIN nm ON nm.code = i.nest_moment_code
    GROUP BY 1
)
UPDATE mock.material_print_schedule mps
SET nest_moment_codes = c.nest_moment_codes
FROM codes c
WHERE mps.material_print_schedule_id = c.material_print_schedule_id
  AND mps.nest_moment_codes IS DISTINCT FROM c.nest_moment_codes;

COMMIT;

-- check: every card of the sheet board has a row
SELECT count(*) AS cards,
       count(*) FILTER (WHERE EXISTS (
           SELECT 1
           FROM action.get_plan_lanes_imposition_group(p_line_type => 'sheet', p_view_code => 'print-day-scale', p_only_starting_today => false) l
           WHERE l.tenant_id = c.tenant_id AND l.material_id = c.material_id AND l.nest_moment_code = c.nest_moment_code)) AS with_row
FROM mock.get_print_schedule(p_line_type => 'sheet', p_tenant_ids => ARRAY[1, 2], p_lookback_days => 2) c;

SELECT material_name, tenant_id, nest_moment_codes
FROM mock.material_print_schedule
WHERE line = 'sheet'
ORDER BY material_name, tenant_id;
