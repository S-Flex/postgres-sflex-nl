-- What hangs on a lane item: the work of its scope as one row, with the lists
-- the plan boards show. This is the fold both boards kept their own copy of
-- (mock.get_impose_plan, action.get_resource_plan), in one place.
--
-- One entry in p_scope_json per row a board draws:
--   [{"lane_item_id": 8842, "nest_ids": [12,13,14], "material_id": 480,
--     "production_line_id": 5, "resource_path": "dk.sheet.impose.320",
--     "param_json": {"waste_percentage": 0.22, "imposition_sqm": 4.58}}]
-- nest_ids null asks for the open work of that material on that line in the day
-- window (narrowed to the moment window p_from_at .. p_until_at when the caller
-- gives one); nest_ids set asks for the work of those nests whatever its status --
-- there the class names carry the state. resource_path and param_json come from
-- the lane read, so the format of the group stays in one place. Board 76 gives
-- one entry per lane (the nests of all its items together), board 81 one entry
-- per item (its own nests).
--
-- The reads: at most two calls to mapping.get_production_orderline_detail --
-- one for every nest in play at once (a nest hangs on one lane item, so the
-- rows map back without ambiguity) and one window call for the entries without
-- nests. Every breakdown below is a group by over that one result, instead of
-- one aggregate call per nest set.
--
-- The lists:
--   set_json      the row's own list: one entry per batch (with nests, set
--                 'batch'; the nests without a batch are batch 0) or per status
--                 (without, set 'orders'). One shape either way, "set" says which, and
--                 part_status_json rides along per entry for the distribution
--                 bar. sort_order orders the list.
--   manifest_json one entry per manifest of the work, each with items: per
--                 batch, or per nest date and unit class (the work imposed all
--                 together, or the small and the big orders apart: three groups
--                 that add up to the total).
--   step_json     per step of the work -- the scope of a manifest row is its
--                 step -- the manifest seconds plus the fastest and the slowest
--                 machine of that step.
--
-- Time comes as min and max, not as one number: the row keeps evaluating its
-- own duration on the board (a drag to another machine has to change it), and
-- min/max are that same formula run over the candidate machines of the step --
-- every resource of that step under the same site and line type as the row's
-- own resource, the same rule as valid_resources on the lane read. A step whose
-- machines carry no formula falls back to the manifest seconds and reports no
-- min/max.
--
-- A batch divides an orderline by the pieces on its nests (nest_json.amount),
-- so an orderline on nests in two batches counts once, split over the two.
drop function if exists action.get_lane_item_work(timestamp with time zone, jsonb, text, integer[], integer, integer, integer, numeric, integer[], integer);
drop function if exists action.get_lane_item_work(timestamp with time zone, jsonb, text, integer[], integer, integer, integer, numeric, integer[], integer, timestamp with time zone, timestamp with time zone);

create function action.get_lane_item_work(p_until timestamp with time zone DEFAULT now(), p_scope_json jsonb DEFAULT '[]'::jsonb, p_date_type text DEFAULT 'nest'::text, p_status_sequences integer[] DEFAULT NULL::integer[], p_look_back_days integer DEFAULT 0, p_look_ahead_days integer DEFAULT 0, p_threshold integer DEFAULT 1, p_waste_percentage numeric DEFAULT 20, p_tenant_ids integer[] DEFAULT NULL::integer[], p_domain_id integer DEFAULT 1, p_from_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_until_at timestamp with time zone DEFAULT NULL::timestamp with time zone) returns TABLE(lane_item_id bigint, material_id integer, material_name text, orderline_count integer, product_amount numeric, part_amount integer, amount numeric, sqm numeric, forecast_sqm numeric, rework_count integer, rework_sqm numeric, gross_sqm numeric, impact_json jsonb, part_status_json jsonb, specs_json jsonb, min_delivery_hours integer, seconds_to_logistics_date integer, production_impact_in_seconds integer, production_seconds_min integer, production_seconds_max integer, batch_count integer, class_names text[], unit_class_names text[], delivery_hours_json jsonb, step_json jsonb, set_json jsonb, manifest_json jsonb)
	stable
	language plpgsql
as $$
#variable_conflict use_column
DECLARE
    v_zone constant text := 'Europe/Amsterdam';
BEGIN
    RETURN QUERY
    WITH scope AS (
        -- jsonb_build_object turns a SQL null into a JSON null, and that is a
        -- scalar: every key is read through jsonb_typeof, so an entry without
        -- nests or without variables is a window entry instead of an error
        SELECT (e.value ->> 'lane_item_id')::bigint        AS lane_item_id,
               CASE WHEN jsonb_typeof(e.value -> 'nest_ids') = 'array'
                    THEN (SELECT array_agg(n::bigint)
                          FROM jsonb_array_elements_text(e.value -> 'nest_ids') AS n)
               END                                         AS nest_ids,
               (e.value ->> 'material_id')::integer        AS material_id,
               (e.value ->> 'production_line_id')::integer AS production_line_id,
               (e.value ->> 'resource_path')::ltree        AS resource_path,
               CASE WHEN jsonb_typeof(e.value -> 'param_json') = 'object'
                    THEN e.value -> 'param_json' ELSE '{}'::jsonb
               END                                         AS param_json
        FROM jsonb_array_elements(p_scope_json) AS e(value)
    ),
    -- the nests of every entry at once. An empty array is an empty scope, not
    -- "every nest", so a board without nested rows reads nothing here
    nest_detail AS MATERIALIZED (
        SELECT d.*
        FROM mapping.get_production_orderline_detail(
                 p_date             => p_until,
                 p_date_type        => p_date_type,
                 p_nest_ids         => coalesce((SELECT array_agg(DISTINCT n)
                                                 FROM scope s, unnest(s.nest_ids) n),
                                                '{}'::bigint[]),
                 p_material_ids     => coalesce((SELECT array_agg(DISTINCT s.material_id)
                                                 FROM scope s
                                                 WHERE s.nest_ids IS NOT NULL
                                                   AND s.material_id IS NOT NULL),
                                                '{}'::integer[]),
                 -- a planned nest set counts all its work whatever the status
                 p_status_sequences => NULL,
                 p_is_open          => NULL,
                 p_threshold        => p_threshold,
                 p_tenant_ids       => p_tenant_ids,
                 p_domain_id        => p_domain_id) d
    ),
    -- the open work of the materials of the entries without nests, in the day
    -- window, or in the moment window when the caller gives one; matched back
    -- on material and line
    window_detail AS MATERIALIZED (
        SELECT d.*
        FROM mapping.get_production_orderline_detail(
                 p_date             => p_until,
                 p_date_type        => p_date_type,
                 p_look_back_days   => p_look_back_days,
                 p_look_ahead_days  => p_look_ahead_days,
                 p_from_at          => p_from_at,
                 p_until_at         => p_until_at,
                 p_material_ids     => coalesce((SELECT array_agg(DISTINCT s.material_id)
                                                 FROM scope s
                                                 WHERE s.nest_ids IS NULL
                                                   AND s.material_id IS NOT NULL),
                                                '{}'::integer[]),
                 p_status_sequences => p_status_sequences,
                 p_is_open          => true,
                 p_threshold        => p_threshold,
                 p_tenant_ids       => p_tenant_ids,
                 p_domain_id        => p_domain_id) d
    ),
    -- one row per lane item and orderline, whichever scope it came from
    work AS (
        SELECT s.lane_item_id, s.nest_ids AS scope_nest_ids, s.material_id AS scope_material_id,
               s.resource_path, s.param_json,
               d.production_orderline_id, d.material_id, d.material_name, d.production_line_id,
               d.product_amount, d.part_amount, d.sqm, d.delivery_hours,
               d.status_sequence, d.internal_status_code, d.status_title, d.status_level,
               d.part_status_json, d.nest_date, d.logistics_at, d.nest_json,
               d.impact_json, d.class_names, d.unit_class_names,
               d.manifest_json, d.production_impact_in_seconds, d.impact_scope_json
        FROM nest_detail d
        JOIN scope s ON s.nest_ids && d.nest_ids
                    -- the nests decide the work, but the material of the row has
                    -- the last word: work of another material nested here
                    -- belongs to that material's own row
                    AND (s.material_id IS NULL OR s.material_id = d.material_id)
        UNION ALL
        SELECT s.lane_item_id, s.nest_ids, s.material_id, s.resource_path, s.param_json,
               d.production_orderline_id, d.material_id, d.material_name, d.production_line_id,
               d.product_amount, d.part_amount, d.sqm, d.delivery_hours,
               d.status_sequence, d.internal_status_code, d.status_title, d.status_level,
               d.part_status_json, d.nest_date, d.logistics_at, d.nest_json,
               d.impact_json, d.class_names, d.unit_class_names,
               d.manifest_json, d.production_impact_in_seconds, d.impact_scope_json
        FROM window_detail d
        JOIN scope s ON s.nest_ids IS NULL
                    AND s.material_id = d.material_id
                    AND s.production_line_id = d.production_line_id
    ),
    -- the batch of the work: the pieces of the orderline on the nests of that
    -- batch against its pieces on all the nests of this row
    work_batch AS (
        SELECT w.lane_item_id, w.production_orderline_id,
               coalesce((n.value ->> 'batch_id')::integer, 0)            AS batch_id,
               count(DISTINCT (n.value ->> 'nest_id')::bigint)::integer  AS nest_count,
               sum((n.value ->> 'amount')::numeric)                      AS batch_amount
        FROM work w
        CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(w.nest_json) = 'array'
                                                     THEN w.nest_json ELSE '[]'::jsonb END) AS n(value)
        WHERE w.scope_nest_ids IS NOT NULL
          AND (n.value ->> 'nest_id')::bigint = ANY (w.scope_nest_ids)
        GROUP BY 1, 2, 3
    ),
    work_batch_share AS (
        SELECT b.lane_item_id, b.production_orderline_id, b.batch_id, b.nest_count,
               b.batch_amount / nullif(sum(b.batch_amount) OVER (
                   PARTITION BY b.lane_item_id, b.production_orderline_id), 0) AS share
        FROM work_batch b
    ),
    -- one key per entry of the row's list, so the numbers, the part statuses
    -- and the class names of that entry are grouped the same way
    work_set AS (
        SELECT w.lane_item_id,
               coalesce('batch:' || b.batch_id, 'orders:' || w.status_sequence) AS set_key,
               b.batch_id, b.nest_count, coalesce(b.share, 1) AS share,
               w.production_orderline_id, w.sqm, w.part_status_json, w.class_names,
               w.status_sequence, w.internal_status_code, w.status_title, w.status_level,
               (w.impact_json ->> 'rework_count')::integer AS rework_count,
               (w.impact_json ->> 'rework_sqm')::numeric   AS rework_sqm
        FROM work w
        LEFT JOIN work_batch_share b ON b.lane_item_id = w.lane_item_id
                                    AND b.production_orderline_id = w.production_orderline_id
    ),
    total AS (
        SELECT w.lane_item_id,
               -- the material of the work when it is one; a mixed set has none
               CASE WHEN count(DISTINCT w.material_id) = 1 THEN min(w.material_id) END   AS material_id,
               CASE WHEN count(DISTINCT w.material_id) = 1 THEN min(w.material_name) END AS material_name,
               count(*)::integer                                          AS orderline_count,
               sum(w.product_amount)                                      AS product_amount,
               sum(w.part_amount)::integer                                AS part_amount,
               sum(greatest(w.part_amount, w.product_amount))             AS amount,
               round(sum(w.sqm), 2)                                       AS sqm,
               sum((w.impact_json ->> 'rework_count')::integer)::integer   AS rework_count,
               sum((w.impact_json ->> 'rework_amount')::numeric)          AS rework_amount,
               round(sum((w.impact_json ->> 'rework_sqm')::numeric), 2)    AS rework_sqm,
               -- the shortest delivery time in the work itself, not the setting
               min(w.delivery_hours)                                      AS min_delivery_hours,
               -- how much time the tightest orderline still has
               floor(extract(epoch FROM (min(w.logistics_at)
                                         - (p_until AT TIME ZONE v_zone))))::integer
                                                                          AS seconds_to_logistics_date,
               sum(w.production_impact_in_seconds)::integer                AS production_impact_in_seconds
        FROM work w
        GROUP BY w.lane_item_id
    ),
    total_class AS (
        SELECT x.lane_item_id,
               array_agg(DISTINCT x.class_name ORDER BY x.class_name)
                   FILTER (WHERE x.kind = 'class')      AS class_names,
               array_agg(DISTINCT x.class_name ORDER BY x.class_name)
                   FILTER (WHERE x.kind = 'unit')       AS unit_class_names
        FROM (
            SELECT w.lane_item_id, 'class' AS kind, c AS class_name
            FROM work w CROSS JOIN LATERAL unnest(coalesce(w.class_names, '{}'::text[])) c
            UNION ALL
            SELECT w.lane_item_id, 'unit', c
            FROM work w CROSS JOIN LATERAL unnest(coalesce(w.unit_class_names, '{}'::text[])) c
        ) x
        GROUP BY x.lane_item_id
    ),
    -- the work per delivery class of the row: a board that counts the time of
    -- one class only (the width of a nest row) picks its class here
    total_delivery AS (
        SELECT d.lane_item_id,
               jsonb_object_agg(d.delivery_hours::text, jsonb_build_object(
                   'orderline_count',              d.orderline_count,
                   'sqm',                          d.sqm,
                   'production_impact_in_seconds', d.production_impact_in_seconds))
                   AS delivery_hours_json
        FROM (SELECT w.lane_item_id, w.delivery_hours,
                     count(*)::integer                            AS orderline_count,
                     round(sum(w.sqm), 2)                          AS sqm,
                     sum(w.production_impact_in_seconds)::integer  AS production_impact_in_seconds
              FROM work w
              WHERE w.delivery_hours IS NOT NULL
              GROUP BY 1, 2) d
        GROUP BY d.lane_item_id
    ),
    -- the part statuses of the whole row, summed per status
    total_part AS (
        SELECT p.lane_item_id,
               jsonb_agg(jsonb_build_object(
                   'sequence', p.sequence, 'internal_status_code', p.internal_status_code,
                   'class_names', p.class_names, 'i18n', p.i18n, 'amount', p.amount)
                   ORDER BY p.sequence) AS part_status_json
        FROM (SELECT w.lane_item_id,
                     (e.value ->> 'sequence')::integer               AS sequence,
                     e.value ->> 'internal_status_code'              AS internal_status_code,
                     e.value -> 'class_names'                        AS class_names,
                     e.value -> 'i18n'                               AS i18n,
                     round(sum((e.value ->> 'amount')::numeric), 2)  AS amount
              FROM work w
              CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(w.part_status_json) = 'array'
                                                        THEN w.part_status_json ELSE '[]'::jsonb END) AS e(value)
              GROUP BY 1, 2, 3, 4, 5) p
        GROUP BY p.lane_item_id
    ),
    -- the manifest seconds per step of the work: the scope of a manifest row is
    -- its step
    step_seconds AS (
        SELECT w.lane_item_id, e.key AS step,
               round(sum((e.value #>> '{}')::numeric))::integer AS manifest_seconds
        FROM work w
        CROSS JOIN LATERAL jsonb_each(CASE WHEN jsonb_typeof(w.impact_scope_json) = 'object'
                                    THEN w.impact_scope_json ELSE '{}'::jsonb END) e
        GROUP BY 1, 2
    ),
    -- the candidate machines of that step: same site, same line type as the
    -- row's own resource
    candidate AS (
        SELECT ss.lane_item_id, ss.step, r.resource_path, rset.setting_json
        FROM step_seconds ss
        JOIN scope s ON s.lane_item_id = ss.lane_item_id AND s.resource_path IS NOT NULL
        JOIN relation.resource r
          ON r.step = ss.step
         AND subpath(r.resource_path, 0, 2) = subpath(s.resource_path, 0, 2)
        CROSS JOIN LATERAL (
            SELECT production.get_resource_setting(r.resource_path, s.material_id) AS setting_json
        ) rset
    ),
    -- One evaluation per machine and variable set, never per row: the formula of
    -- the machine over the work of the row. The two machines it picks are the
    -- ones the sub-rows are evaluated with as well.
    row_candidate AS MATERIALIZED (
        SELECT c.lane_item_id, c.step, c.resource_path,
               (ev.result ->> 'duration_in_seconds')::numeric AS seconds
        FROM candidate c
        JOIN total t ON t.lane_item_id = c.lane_item_id
        JOIN scope s ON s.lane_item_id = c.lane_item_id
        CROSS JOIN LATERAL (
            SELECT public.evaluate_many_nas(
                       coalesce(c.setting_json -> 'formula', '[]'::jsonb),
                       production.get_setting_numbers(s.param_json)
                       || production.get_setting_numbers(c.setting_json)
                       || jsonb_build_object('net_sqm', coalesce(t.sqm, 0))) AS result
        ) ev
    ),
    row_step AS (
        SELECT rc.lane_item_id, rc.step,
               round(min(rc.seconds))::integer AS seconds_min,
               round(max(rc.seconds))::integer AS seconds_max,
               (array_agg(rc.resource_path ORDER BY rc.seconds)
                    FILTER (WHERE rc.seconds IS NOT NULL))[1]      AS min_path,
               (array_agg(rc.resource_path ORDER BY rc.seconds DESC)
                    FILTER (WHERE rc.seconds IS NOT NULL))[1]      AS max_path
        FROM row_candidate rc
        GROUP BY 1, 2
    ),
    -- the sub-list of a manifest group: per batch when the row has nests, else
    -- per nest date and unit class: the group an orderline is imposed with (all
    -- together, or the small and the big orders apart). An orderline without a
    -- unit class goes with everything
    sub AS (
        SELECT w.lane_item_id, CASE WHEN jsonb_typeof(w.manifest_json) = 'object'
                    THEN w.manifest_json ELSE '{}'::jsonb END AS manifest,
               'batch'::text                       AS set_kind,
               b.batch_id::numeric                AS sort_order,
               b.batch_id,
               NULL::date                          AS nest_date,
               'units-all'::text                         AS unit_class,
               sum(b.nest_count)::integer          AS nest_count,
               round(sum(w.sqm * b.share), 2)      AS sqm,
               count(DISTINCT w.production_orderline_id)::integer AS orderline_count
        FROM work w
        JOIN work_batch_share b ON b.lane_item_id = w.lane_item_id
                               AND b.production_orderline_id = w.production_orderline_id
        GROUP BY 1, 2, 4, 5
        UNION ALL
        SELECT w.lane_item_id, CASE WHEN jsonb_typeof(w.manifest_json) = 'object'
                                    THEN w.manifest_json ELSE '{}'::jsonb END,
               'nest-date',
               -- the day, and behind it the unit class, so the list sorts by
               -- date with the joint group in front of the two threshold groups
               extract(epoch FROM w.nest_date)
                   + CASE u.unit_class WHEN 'units-all' THEN 0
                                       WHEN 'units-lte-threshold' THEN 1 ELSE 2 END,
               NULL::integer, w.nest_date, u.unit_class,
               NULL::integer,
               round(sum(w.sqm), 2),
               count(DISTINCT w.production_orderline_id)::integer
        FROM work w
        CROSS JOIN LATERAL unnest(coalesce(nullif(w.unit_class_names, '{}'::text[]), array['units-all'])) AS u(unit_class)
        WHERE w.scope_nest_ids IS NULL
        GROUP BY 1, 2, 4, 6, 7
    ),
    -- the same two machines per step, now over the work of the sub-row
    sub_step AS (
        SELECT sb.lane_item_id, sb.manifest, sb.set_kind, sb.batch_id, sb.nest_date, sb.unit_class,
               jsonb_object_agg(x.step, jsonb_build_object(
                   'seconds_min', x.seconds_min,
                   'seconds_max', x.seconds_max)) AS step_json
        FROM sub sb
        CROSS JOIN LATERAL (
            SELECT rs.step,
                   round(min(ev.seconds))::integer AS seconds_min,
                   round(max(ev.seconds))::integer AS seconds_max
            FROM row_step rs
            JOIN scope s ON s.lane_item_id = sb.lane_item_id
            CROSS JOIN LATERAL unnest(array_remove(array[rs.min_path, rs.max_path], NULL)) AS p(resource_path)
            CROSS JOIN LATERAL (
                SELECT production.get_resource_setting(p.resource_path, s.material_id) AS setting_json
            ) rset
            CROSS JOIN LATERAL (
                SELECT (public.evaluate_many_nas(
                            coalesce(rset.setting_json -> 'formula', '[]'::jsonb),
                            production.get_setting_numbers(s.param_json)
                            || production.get_setting_numbers(rset.setting_json)
                            || jsonb_build_object('net_sqm', coalesce(sb.sqm, 0)))
                        ->> 'duration_in_seconds')::numeric AS seconds
            ) ev
            WHERE rs.lane_item_id = sb.lane_item_id
            GROUP BY rs.step
        ) x
        GROUP BY 1, 2, 3, 4, 5, 6
    ),
    -- the unit classes as the boards name them (mapping.lookup /
    -- lookup_unit_class: code, order, i18n with title and abb)
    unit_class AS (
        SELECT u.value ->> 'code' AS code, u.value AS unit_class_json
        FROM mapping.lookup lk
        CROSS JOIN LATERAL jsonb_array_elements(lk.lookup_json) AS u(value)
        WHERE lk.lookup = 'lookup_unit_class'
    ),
    -- one entry per manifest of the work, with its sub-list
    manifest_row AS (
        SELECT sb.lane_item_id, sb.manifest,
               -- the unit classes are disjoint groups of the work, so the total
               -- is their sum
               round(sum(sb.sqm), 2)                    AS sqm,
               sum(sb.orderline_count)::integer         AS orderline_count,
               jsonb_agg(jsonb_build_object(
                   'set',             sb.set_kind,
                   'sort_order',      sb.sort_order,
                   'batch_id',       sb.batch_id,
                   'nest_date',       sb.nest_date,
                   'unit_class',      sb.unit_class,
                   'unit_class_json', uc.unit_class_json,
                   'nest_count',      sb.nest_count,
                   'orderline_count', sb.orderline_count,
                   'sqm',             sb.sqm,
                   'step_json',       coalesce(ss.step_json, '{}'::jsonb))
                   ORDER BY sb.sort_order) AS items
        FROM sub sb
        LEFT JOIN unit_class uc ON uc.code = sb.unit_class
        LEFT JOIN sub_step ss
               ON ss.lane_item_id = sb.lane_item_id
              AND ss.manifest     = sb.manifest
              AND ss.set_kind     = sb.set_kind
              AND ss.batch_id IS NOT DISTINCT FROM sb.batch_id
              AND ss.nest_date IS NOT DISTINCT FROM sb.nest_date
              AND ss.unit_class   = sb.unit_class
        GROUP BY 1, 2
    ),
    -- the row's own list: per batch with nests (set 'batch'), per status
    -- without (set 'orders')
    set_row AS (
        SELECT ws.lane_item_id, ws.set_key, 'batch'::text AS set_kind,
               ws.batch_id::numeric                              AS sort_order,
               ws.batch_id,
               ws.batch_id::text                                 AS title,
               NULL::jsonb                                        AS i18n,
               NULL::integer                                      AS sequence,
               NULL::text                                         AS internal_status_code,
               NULL::text                                         AS level,
               sum(ws.nest_count)::integer                        AS nest_count,
               count(DISTINCT ws.production_orderline_id)::integer AS orderline_count,
               round(sum(ws.rework_count * ws.share))::integer     AS rework_count,
               round(sum(ws.sqm * ws.share), 2)                   AS sqm,
               round(sum(ws.rework_sqm * ws.share), 2)            AS rework_sqm
        FROM work_set ws
        WHERE ws.batch_id IS NOT NULL
        GROUP BY 1, 2, 4, 5
        UNION ALL
        -- the i18n and the colour of a status live in mapping.internal_status
        SELECT ws.lane_item_id, ws.set_key, 'orders',
               ws.status_sequence::numeric,
               NULL::integer,
               ws.status_title,
               si.i18n,
               ws.status_sequence,
               ws.internal_status_code,
               ws.status_level,
               NULL::integer,
               count(*)::integer,
               sum(ws.rework_count)::integer,
               round(sum(ws.sqm), 2),
               round(sum(ws.rework_sqm), 2)
        FROM work_set ws
        LEFT JOIN mapping.internal_status si
               ON si.code = ws.internal_status_code AND si.domain_id = p_domain_id
        WHERE ws.batch_id IS NULL
        GROUP BY 1, 2, 4, 6, 7, 8, 9, 10
    ),
    -- the class names per entry of that list
    set_class AS (
        SELECT x.lane_item_id, x.set_key,
               array_agg(DISTINCT x.class_name ORDER BY x.class_name) AS class_names
        FROM (SELECT ws.lane_item_id, ws.set_key, c AS class_name
              FROM work_set ws
              CROSS JOIN LATERAL unnest(coalesce(ws.class_names, '{}'::text[])) c) x
        GROUP BY 1, 2
    ),
    -- the forecast of the materials on the board, over the same day window as
    -- the work: one number per material and line, the same on every row of
    -- that material
    forecast AS (
        SELECT f.material_id, f.production_line_id, sum(f.forecast_sqm) AS forecast_sqm
        FROM action.get_date_window(p_until, p_look_back_days, p_look_ahead_days,
                                    true, true, p_tenant_ids) win
        JOIN log.production_forecast_material f
          ON f.date >= win.from_date AND f.date < win.until_date
        WHERE EXISTS (SELECT 1 FROM scope s
                      WHERE s.material_id = f.material_id
                        AND s.production_line_id = f.production_line_id)
          AND (p_tenant_ids IS NULL
               OR EXISTS (SELECT 1 FROM site.tenant t
                          WHERE t.production_company_id = f.production_company_id
                            AND t.tenant_id = ANY (p_tenant_ids)))
        GROUP BY 1, 2
    ),
    -- the part statuses per entry, so the distribution bar reads them straight
    -- from the row it draws
    set_part AS (
        SELECT p.lane_item_id, p.set_key,
               jsonb_agg(jsonb_build_object(
                   'sequence', p.sequence, 'internal_status_code', p.internal_status_code,
                   'class_names', p.class_names, 'i18n', p.i18n, 'amount', p.amount)
                   ORDER BY p.sequence) AS part_status_json
        FROM (SELECT ws.lane_item_id, ws.set_key,
                     (e.value ->> 'sequence')::integer  AS sequence,
                     e.value ->> 'internal_status_code' AS internal_status_code,
                     e.value -> 'class_names'           AS class_names,
                     e.value -> 'i18n'                  AS i18n,
                     round(sum((e.value ->> 'amount')::numeric * ws.share), 2) AS amount
              FROM work_set ws
              CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(ws.part_status_json) = 'array'
                                                           THEN ws.part_status_json ELSE '[]'::jsonb END) AS e(value)
              GROUP BY 1, 2, 3, 4, 5, 6) p
        GROUP BY p.lane_item_id, p.set_key
    )
    SELECT s.lane_item_id,
           coalesce(t.material_id, s.material_id) AS material_id, t.material_name,
           t.orderline_count, t.product_amount, t.part_amount, t.amount,
           t.sqm, round(coalesce(fc.forecast_sqm, 0), 2)             AS forecast_sqm,
           t.rework_count, t.rework_sqm,
           g.gross_sqm,
           -- the one shape every overview sums
           jsonb_build_object(
               'count',         t.orderline_count,
               'amount',        t.product_amount,
               'sqm',           t.sqm,
               'rework_count',  t.rework_count,
               'rework_amount', t.rework_amount,
               'rework_sqm',    t.rework_sqm)                        AS impact_json,
           coalesce(tp.part_status_json, '[]'::jsonb)                AS part_status_json,
           -- one entry per size of the material with what the gross sqm needs
           -- of it: sheets for a sheet material, metres for a roll (sizes in
           -- cm). The sizes and the media type ride along in param_json from
           -- the lane read; the rule is the aggregate's
           (SELECT coalesce(jsonb_agg(sp.value || jsonb_build_object('amount',
                       CASE (s.param_json ->> 'material_media_type_id')::integer
                            WHEN 1 THEN ceil(g.gross_sqm / nullif((sp.value ->> 'width')::numeric
                                                                * (sp.value ->> 'height')::numeric / 10000, 0))
                            WHEN 3 THEN ceil(g.gross_sqm / nullif((sp.value ->> 'width')::numeric / 100, 0))
                       END) ORDER BY sp.ord), '[]'::jsonb)
            FROM jsonb_array_elements(CASE WHEN jsonb_typeof(s.param_json -> 'specs') = 'array'
                                           THEN s.param_json -> 'specs' ELSE '[]'::jsonb END)
                 WITH ORDINALITY AS sp(value, ord))                  AS specs_json,
           t.min_delivery_hours, t.seconds_to_logistics_date,
           t.production_impact_in_seconds,
           -- the production time of the whole work: per step the fastest and
           -- the slowest machine, the manifest seconds where a step has none
           sj.production_seconds_min, sj.production_seconds_max,
           coalesce(bc.batch_count, 0)                               AS batch_count,
           coalesce(tc.class_names, '{}'::text[])                    AS class_names,
           coalesce(tc.unit_class_names, '{}'::text[])               AS unit_class_names,
           coalesce(td.delivery_hours_json, '{}'::jsonb)             AS delivery_hours_json,
           coalesce(sj.step_json, '{}'::jsonb)                       AS step_json,
           coalesce(sr.set_json, '[]'::jsonb)                        AS set_json,
           coalesce(mr.manifest_json, '[]'::jsonb)                   AS manifest_json
    FROM scope s
    LEFT JOIN total t ON t.lane_item_id = s.lane_item_id
    LEFT JOIN total_part  tp ON tp.lane_item_id = s.lane_item_id
    LEFT JOIN total_class tc ON tc.lane_item_id = s.lane_item_id
    LEFT JOIN total_delivery td ON td.lane_item_id = s.lane_item_id
    LEFT JOIN forecast    fc ON fc.material_id = s.material_id
                            AND fc.production_line_id = s.production_line_id
    -- computed from the rounded values, so the size adds up with the sqm and
    -- the rework sqm next to it; without work the forecast carries it
    CROSS JOIN LATERAL (
        SELECT CASE WHEN coalesce(t.sqm, 0) + coalesce(t.rework_sqm, 0) > 0
                    THEN round((coalesce(t.sqm, 0) + coalesce(t.rework_sqm, 0))
                               * (1 + p_waste_percentage / 100), 2)
                    ELSE round(coalesce(fc.forecast_sqm, 0)
                               * (1 + p_waste_percentage / 100), 2)
               END AS gross_sqm
    ) g
    LEFT JOIN LATERAL (
        SELECT count(DISTINCT b.batch_id)::integer AS batch_count
        FROM work_batch_share b
        WHERE b.lane_item_id = s.lane_item_id
    ) bc ON true
    LEFT JOIN LATERAL (
        SELECT sum(coalesce(rs.seconds_min, ss.manifest_seconds))::integer AS production_seconds_min,
               sum(coalesce(rs.seconds_max, ss.manifest_seconds))::integer AS production_seconds_max,
               jsonb_object_agg(ss.step, jsonb_build_object(
                   'manifest_seconds',  ss.manifest_seconds,
                   'seconds_min',       rs.seconds_min,
                   'seconds_max',       rs.seconds_max,
                   'min_resource_path', rs.min_path::text,
                   'max_resource_path', rs.max_path::text))          AS step_json
        FROM step_seconds ss
        LEFT JOIN row_step rs ON rs.lane_item_id = ss.lane_item_id AND rs.step = ss.step
        WHERE ss.lane_item_id = s.lane_item_id
    ) sj ON true
    LEFT JOIN LATERAL (
        SELECT jsonb_agg(jsonb_build_object(
                   'set',                  srw.set_kind,
                   'sort_order',           srw.sort_order,
                   'title',                srw.title,
                   'i18n',                 srw.i18n,
                   'sequence',             srw.sequence,
                   'internal_status_code', srw.internal_status_code,
                   'level',                srw.level,
                   'batch_id',            srw.batch_id,
                   'nest_count',           srw.nest_count,
                   'orderline_count',      srw.orderline_count,
                   'rework_count',         srw.rework_count,
                   'sqm',                  srw.sqm,
                   'rework_sqm',           srw.rework_sqm,
                   'class_names',          to_jsonb(coalesce(sc.class_names, '{}'::text[])),
                   'part_status_json',     coalesce(sp.part_status_json, '[]'::jsonb))
                   ORDER BY srw.sort_order) AS set_json
        FROM set_row srw
        LEFT JOIN set_class sc ON sc.lane_item_id = srw.lane_item_id AND sc.set_key = srw.set_key
        LEFT JOIN set_part  sp ON sp.lane_item_id = srw.lane_item_id AND sp.set_key = srw.set_key
        WHERE srw.lane_item_id = s.lane_item_id
    ) sr ON true
    LEFT JOIN LATERAL (
        SELECT jsonb_agg(jsonb_build_object(
                   'manifest',        m.manifest,
                   'i18n',            m.i18n,
                   'sqm',             m.sqm,
                   'orderline_count', m.orderline_count,
                   'items',           m.items)
                   ORDER BY m.sqm DESC) AS manifest_json
        FROM (
            SELECT mrw.manifest, mrw.sqm, mrw.orderline_count, mrw.items,
                   -- one title per language: the abb of every scope of the
                   -- manifest, joined, so title_field can read i18n
                   (SELECT jsonb_object_agg(l.lang, jsonb_build_object('abb', l.abb))
                    FROM (SELECT lg.key AS lang,
                                 string_agg(nullif(lg.value ->> 'abb', ''), ', ' ORDER BY sc.key) AS abb
                          FROM jsonb_each(mrw.manifest) sc
                          CROSS JOIN LATERAL jsonb_each(CASE WHEN jsonb_typeof(sc.value -> 'i18n') = 'object'
                                                             THEN sc.value -> 'i18n' ELSE '{}'::jsonb END) lg
                          GROUP BY lg.key) l
                    WHERE l.abb IS NOT NULL)                        AS i18n
            FROM manifest_row mrw
            WHERE mrw.lane_item_id = s.lane_item_id
        ) m
    ) mr ON true
    ORDER BY s.lane_item_id;
END;
$$;

alter function action.get_lane_item_work(timestamp with time zone, jsonb, text, integer[], integer, integer, integer, numeric, integer[], integer, timestamp with time zone, timestamp with time zone) owner to xfw3;
