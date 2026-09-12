-- The items of the schedule boards (docs/plan-planning-schema.md §4): one row
-- per plan item on the lanes whose day is in view. Step 1 serves the stored
-- plan rows; the derived progress and actual rows follow when the boards move
-- over (step 3), p_types is in place for them.
--
-- Per row:
--   data_json    the item's own data_json, or the one it inherits from its
--                predecessors (schedule.get_lane_item_data); is_inherited says
--                which
--   status       the status of the newest event of the item (lane_item_event),
--                'plan' when it has none yet, and the moment of that event
--   summary      the work of the item, computed here and never stale: the
--                nests in data_json.batches when there are any, else the open
--                work of data_json.selection (material and line) on the lane
--                day -- one action.get_lane_item_work call per day in view,
--                the fold board 76 uses. count, amount, sqm, rework_count,
--                rework_sqm, production_impact (seconds). Null for an item
--                without batches and without selection.
--   class_names  the type's classes (lookup_lane_item_type), then the item's
--                (data_json.class_names), then the work's
--   lag_formula  the active action.formula of 'lag-<p_view_code>': the rules
--                the board chains items with, yielding lag (seconds); [] when
--                no version applies
--
-- p_from and p_until are the days in view, both included; inside they are one
-- datemultirange, so a p_dates datemultirange can replace the pair without a
-- change below. Timing is in seconds, no unit in a key.
drop function if exists schedule.get_lane_items(date, date, text, integer[], text[], text[], text, integer);

create function schedule.get_lane_items(p_from date DEFAULT current_date, p_until date DEFAULT current_date, p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_steps text[] DEFAULT NULL::text[], p_types text[] DEFAULT NULL::text[], p_view_code text DEFAULT 'nest-time-scale'::text, p_domain_id integer DEFAULT 1)
    returns TABLE(plan_id bigint, lane_id bigint, lane_date date, step text, resource_path ltree, lane_item_id bigint, lane_item_type text, type_json jsonb, sort_order numeric, start_offset integer, duration integer, production_impact_per_unit numeric, status text, status_at timestamp with time zone, is_inherited boolean, data_json jsonb, class_names text[], summary jsonb, lag_formula jsonb)
    stable
    language plpgsql
as $$
#variable_conflict use_column
DECLARE
    v_zone constant text := 'Europe/Amsterdam';
    v_dates      datemultirange;
    v_lag        jsonb;
BEGIN
    v_dates := datemultirange(daterange(least(p_from, p_until), greatest(p_from, p_until), '[]'));

    -- the lag rules of this view, the version that applies now
    SELECT gf.formula_json INTO v_lag
    FROM action.get_formula(array['lag-' || p_view_code]) gf
    LIMIT 1;
    v_lag := coalesce(v_lag, '[]'::jsonb);

    RETURN QUERY
    WITH lane AS (
        SELECT p.plan_id, l.lane_id, l.lane_date, l.step, l.resource_path
        FROM schedule.lane l
        JOIN schedule.plan p ON p.plan_id = l.plan_id
        LEFT JOIN site.tenant t ON t.abb = ltree2text(subpath(l.resource_path, 0, 1))
        WHERE l.lane_date <@ v_dates
          AND (p_line_type IS NULL OR p.line_type = p_line_type)
          AND (p_steps IS NULL OR l.step = ANY (p_steps))
          AND (p_tenant_ids IS NULL OR t.tenant_id = ANY (p_tenant_ids))
    ),
    type_row AS (
        SELECT e.value ->> 'type' AS lane_item_type, e.value AS type_json
        FROM action.lookup lk
        CROSS JOIN LATERAL jsonb_array_elements(lk.lookup_json) AS e(value)
        WHERE lk.lookup = 'lookup_lane_item_type'
    ),
    item AS (
        SELECT ln.plan_id, ln.lane_id, ln.lane_date, ln.step, ln.resource_path,
               li.lane_item_id, li.lane_item_type, li.sort_order,
               li.start_offset, li.duration, li.production_impact_per_unit,
               li.data_json IS NULL AS is_inherited,
               coalesce(li.data_json, schedule.get_lane_item_data(li.lane_item_id)) AS data_json
        FROM schedule.lane_item li
        JOIN lane ln ON ln.lane_id = li.lane_id
        WHERE li.lane_item_type = 'plan'
          AND (p_types IS NULL OR li.lane_item_type = ANY (p_types))
    ),
    -- the nests of an item: every nest_id of every batch object
    item_nests AS (
        SELECT i.lane_item_id,
               (SELECT array_agg(DISTINCT x.value::bigint)
                FROM jsonb_array_elements(coalesce(i.data_json -> 'batches', '[]'::jsonb)) AS b
                CROSS JOIN LATERAL jsonb_array_elements_text(coalesce(b.value -> 'nest_ids', '[]'::jsonb)) AS x(value)) AS nest_ids
        FROM item i
    ),
    -- one work call per day in view: nests set = the work of those nests,
    -- nests null = the open work of the selection on that day
    work_scope AS (
        SELECT i.lane_date,
               jsonb_agg(jsonb_build_object(
                   'lane_item_id',       i.lane_item_id,
                   'nest_ids',           to_jsonb(n.nest_ids),
                   'material_id',        (i.data_json -> 'selection' ->> 'material_id')::integer,
                   'production_line_id', (i.data_json -> 'selection' ->> 'production_line_id')::integer,
                   'resource_path',      ltree2text(i.resource_path),
                   'param_json',         production.get_setting_numbers(
                                             production.get_resource_setting(i.resource_path,
                                                                             (i.data_json ->> 'imposition_group_id')::integer)))) AS scope_json
        FROM item i
        JOIN item_nests n ON n.lane_item_id = i.lane_item_id
        WHERE n.nest_ids IS NOT NULL
           OR (i.data_json -> 'selection' ->> 'material_id') IS NOT NULL
        GROUP BY i.lane_date
    ),
    work AS (
        SELECT w.lane_item_id, w.orderline_count, w.amount, w.sqm, w.rework_count, w.rework_sqm,
               w.production_impact_in_seconds, w.class_names AS work_class_names
        FROM work_scope ws
        CROSS JOIN LATERAL action.get_lane_item_work(
            p_until      := (ws.lane_date + time '12:00') AT TIME ZONE v_zone,
            p_scope_json := ws.scope_json,
            p_date_type  := 'nest',
            p_tenant_ids := p_tenant_ids,
            p_domain_id  := p_domain_id) w
    )
    SELECT i.plan_id, i.lane_id, i.lane_date, i.step, i.resource_path,
           i.lane_item_id, i.lane_item_type, tr.type_json,
           i.sort_order, i.start_offset, i.duration, i.production_impact_per_unit,
           coalesce(ev.status, 'plan'), ev.moved_at,
           i.is_inherited, i.data_json,
           (SELECT array_agg(c) FROM (
                SELECT jsonb_array_elements_text(coalesce(tr.type_json -> 'class_names', '[]'::jsonb)) AS c
                UNION ALL
                SELECT jsonb_array_elements_text(coalesce(i.data_json -> 'class_names', '[]'::jsonb))
                UNION ALL
                SELECT unnest(coalesce(w.work_class_names, '{}'::text[]))) AS cls),
           CASE WHEN w.lane_item_id IS NOT NULL THEN
                jsonb_build_object('count',             w.orderline_count,
                                   'amount',            w.amount,
                                   'sqm',               w.sqm,
                                   'rework_count',      w.rework_count,
                                   'rework_sqm',        w.rework_sqm,
                                   'production_impact', w.production_impact_in_seconds)
           END,
           v_lag
    FROM item i
    LEFT JOIN type_row tr ON tr.lane_item_type = i.lane_item_type
    LEFT JOIN LATERAL (
        SELECT e.status, e.moved_at
        FROM schedule.lane_item_event e
        WHERE e.lane_item_id = i.lane_item_id
        ORDER BY e.moved_at DESC, e.lane_item_event_id DESC
        LIMIT 1
    ) ev ON true
    LEFT JOIN work w ON w.lane_item_id = i.lane_item_id
    ORDER BY i.lane_date, i.lane_id, i.sort_order;
END;
$$;

alter function schedule.get_lane_items(date, date, text, integer[], text[], text[], text, integer) owner to xfw3;
