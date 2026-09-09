-- ============================================================
-- Eén rij per materiaal op de materiaalborden (6 sep). Na stap 3b toonden
-- get_plan_lanes en get_impose_plan ook de batch-items van een lane als rij
-- (5 sep sheet: 102 rijen voor 46 materialen). De borden tonen het materiaal
-- als één rij: get_plan_lanes geeft per lane alleen het patroon-item,
-- get_impose_plan telt de nests van alle items van de lane bij elkaar op die
-- rij. De batch-items blijven in het model (één batch per item, voor de
-- resourcekant en crud_nest), ze zijn alleen geen rij meer op 75 en 76.
-- ============================================================

BEGIN;

-- One read for the lanes (labels) of every plan board: print_schedule,
-- impose_plan, resource_plan and whatever
-- follows. Moved from mock to action: the lane model lives here.
--
-- Two modes, switched by p_steps:
--   * p_steps null — material lanes: one row per lane (its pattern item) of
--     the newest plan of the day (p_plan_type), reached through
--     lane_item.source_ref (<material_impose_plan_id>:<date>), plus the
--     tenant noop windows. One row per material: the batch items of a lane
--     are not rows here. Feeds print_schedule and impose_plan
--     (imposition_group_id is the material_id alias until the xbom groups
--     arrive).
--   * p_steps set, or p_plan_type 'production-plan' — resource lanes: one row
--     per resource whose step is in the list, line via path position 1,
--     tenant via path position 0 (the site abb). For a 'production-plan' the
--     day's plans are the source: per step the newest plan that covers it,
--     only resources with a lane in those plans, lane_id and
--     plan_lane.sort_order ride along; p_steps null = every step planned that
--     day (the resource board, get_resource_plan, reads the same). For other
--     plan types (impose: the material plan has no resource lanes) every
--     resource of the steps is a lane, lane_id null.
--
-- The offset rule: only a fixed group (coalesce(item, class moment from
-- lookup_nest_moments)) or a pinned item (its own offset) carries
-- start_offset_in_seconds. Every other item is a filler and serves null —
-- the client chains fillers itself (chain_scope), a moved-but-unpinned item
-- springs back on refresh.
--
-- Duration is not computed here. The row carries the formula of its resource
-- and the variables, and the board evaluates — otherwise a drag to another
-- resource could not change the duration. The chaining offset
-- (next_start_offset_in_seconds) belongs to the resource:
-- resource_json.next_start_lag_in_seconds; the connector mechanism replaces
-- this column later.
drop function if exists mock.get_plan_lanes(timestamp with time zone, text, text, integer[], boolean, text);
drop function if exists action.get_plan_lanes(timestamp with time zone, text, text, integer[], boolean, text);
drop function if exists action.get_plan_lanes(timestamp with time zone, text, text, integer[], boolean, text, text[]);

create function action.get_plan_lanes(p_until timestamp with time zone DEFAULT now(), p_step text DEFAULT 'print'::text, p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_only_starting_today boolean DEFAULT false, p_plan_type text DEFAULT 'material-resource-plan'::text, p_steps text[] DEFAULT NULL::text[]) returns TABLE(imposition_group_id integer, material_id integer, material_name text, production_line_id integer, tenant_id integer, tenant_name text, resource_path ltree, resource_uid text, resource_name text, delivery_hours integer, min_delivery_hours integer, sort_order numeric, param_json jsonb, formula jsonb, data jsonb, fixed_group text, is_pinned boolean, start_offset_in_seconds integer, next_start_offset_in_seconds integer, lane_item_id bigint, lane_id bigint)
	stable
	language plpgsql
as $$
#variable_conflict use_column
DECLARE
    v_date  date;
    v_fixed jsonb;
BEGIN
    v_date := (p_until AT TIME ZONE current_setting('TimeZone'))::date;

    -- resource mode: one lane per resource of the steps
    IF p_steps IS NOT NULL OR p_plan_type = 'production-plan' THEN
        RETURN QUERY
        WITH tenant AS (
            SELECT (v.value ->> 'tenant_id')::integer AS tenant_id,
                   v.value ->> 'name'                 AS tenant_name,
                   v.value ->> 'abb'                  AS abb
            FROM relation.lookup lk
            CROSS JOIN LATERAL jsonb_array_elements(lk.lookup_json) AS v(value)
            WHERE lk.lookup = 'lookup_tenants'
        ),
        wanted_step AS (
            -- the steps asked, else every step a plan of the day carries
            SELECT DISTINCT s.step
            FROM action.plan p
            CROSS JOIN LATERAL unnest(p.steps) AS s(step)
            WHERE p.plan_date = v_date AND p.type = p_plan_type
              AND (p_line_type IS NULL OR p.line_type = p_line_type)
              AND (p_steps IS NULL OR s.step = ANY (p_steps))
        ),
        the_plan AS (
            -- per step the newest plan of this date, type and line type
            SELECT DISTINCT ON (ws.step) ws.step, p.plan_id
            FROM wanted_step ws
            JOIN action.plan p ON ws.step = ANY (p.steps)
            WHERE p.plan_date = v_date AND p.type = p_plan_type
              AND (p_line_type IS NULL OR p.line_type = p_line_type)
            ORDER BY ws.step, p.plan_id DESC
        ),
        plan_lane AS (
            -- the machine-day lanes of those plans; a group lane has no row here
            SELECT DISTINCT ON (rl.lane_id) rl.lane_id, pl.sort_order, rl.resource_path
            FROM the_plan tp
            JOIN action.plan_lane pl USING (plan_id)
            JOIN action.resource_lane rl ON rl.lane_id = pl.lane_id
            ORDER BY rl.lane_id, tp.plan_id DESC
        )
        SELECT NULL::integer, NULL::integer, NULL::text, NULL::integer,
               t.tenant_id, t.tenant_name,
               r.resource_path, r.resource_uid, r.resource_name,
               NULL::integer, NULL::integer,
               pl.sort_order,
               -- the resource constants the board evaluates with; numbers
               -- only — evaluate_many_nas rejects strings
               coalesce((SELECT jsonb_object_agg(e.key, e.value)
                         FROM jsonb_each(rs.setting_json) e
                         WHERE jsonb_typeof(e.value) = 'number'), '{}'::jsonb),
               coalesce(rs.setting_json -> 'formula', '[]'::jsonb),
               '{}'::jsonb,
               NULL::text, false,
               -- a lane has no time of its own; the items bring the times
               NULL::integer,
               (r.resource_json ->> 'next_start_lag_in_seconds')::integer,
               NULL::bigint, pl.lane_id
        FROM relation.resource r
        LEFT JOIN plan_lane pl ON pl.resource_path = r.resource_path
        LEFT JOIN LATERAL (
            SELECT s.setting_json FROM production.resource_setting s
            WHERE r.resource_path <@ s.resource_path
            ORDER BY nlevel(s.resource_path) DESC, s.moved_at DESC LIMIT 1
        ) rs ON true
        LEFT JOIN tenant t ON t.abb = ltree2text(subpath(r.resource_path, 0, 1))
        WHERE r.step = ANY (coalesce(p_steps, (SELECT array_agg(ws.step) FROM wanted_step ws)))
          AND (p_line_type IS NULL OR ltree2text(subpath(r.resource_path, 1, 1)) = p_line_type)
          -- a production plan names its lanes; other plan types have no
          -- resource lanes, so every resource of the steps is a lane
          AND (p_plan_type <> 'production-plan' OR pl.lane_id IS NOT NULL)
          AND (p_tenant_ids IS NULL OR t.tenant_id = ANY (p_tenant_ids))
        ORDER BY t.tenant_id, pl.sort_order NULLS LAST, r.resource_path;
        RETURN;
    END IF;

    -- The default schedule per delivery class: the group label and the moment
    -- the class starts at. A schedule is a template, so this is where a lane
    -- item gets its first time; once the planner moves the item, the item
    -- wins (see the coalesce below).
    SELECT coalesce(jsonb_object_agg(
               v.value ->> 'code',
               jsonb_build_object(
                   'group',  v.value ->> 'fixed_group',
                   'offset', v.value #> '{nest_moments,0,nest_time,start_offset_in_seconds}')),
           '{}'::jsonb)
    INTO v_fixed
    FROM production.lookup l
    CROSS JOIN LATERAL jsonb_array_elements(l.lookup_json) AS v(value)
    WHERE l.lookup = 'lookup_nest_moments'
      AND (v.value ->> 'fixed_group' IS NOT NULL
           OR v.value #>> '{nest_moments,0,nest_time,start_offset_in_seconds}' IS NOT NULL);

    RETURN QUERY
    WITH the_plan AS (
        -- the newest plan of this date, step, type and line type wins
        SELECT plan_id
        FROM action.plan
        WHERE plan_date = v_date AND p_step = ANY (steps)
          AND type = p_plan_type
          AND (p_line_type IS NULL OR line_type = p_line_type)
        ORDER BY plan_id DESC
        LIMIT 1
    ),
    tenant AS (
        SELECT (v.value ->> 'tenant_id')::integer AS tenant_id,
               v.value ->> 'name'                 AS tenant_name
        FROM relation.lookup lk
        CROSS JOIN LATERAL jsonb_array_elements(lk.lookup_json) AS v(value)
        WHERE lk.lookup = 'lookup_tenants'
    ),
    item AS (
        -- one row per lane: its pattern item (source_ref is
        -- <material_impose_plan_id>:<date>). The batch items of the lane
        -- (source 'nest', one per extra batch) are not rows on the material
        -- boards: the boards aggregate the lane, the nests of all its items
        -- are read together (get_impose_plan). The batch items exist for the
        -- resource side, one batch per item.
        SELECT l.lane_id, li.lane_item_id, li.sort_order, li.is_pinned,
               li.start_offset_in_seconds,
               igli.imposition_group_id,
               nullif(split_part(li.source_ref, ':', 1), '')::bigint AS material_impose_plan_id
        FROM the_plan tp
        JOIN action.plan_lane l USING (plan_id)
        JOIN action.lane_item li ON li.lane_id = l.lane_id AND li.type = 'plan'
        LEFT JOIN action.imposition_group_lane_item igli ON igli.lane_item_id = li.lane_item_id
        WHERE li.source = 'material-plan'
    ),
    -- one interval check per distinct (start, days) pair of the plan's own
    -- materials instead of one per row: a check costs ~7 ms in
    -- get_interval_dates, so per row it was hundreds of milliseconds. The
    -- extra (null, 1) pair covers materials without a schedule row.
    --
    -- p_tenant_ids goes into get_interval_dates as well, not only into the
    -- anchor below: without it the day-off test there falls back to
    -- coalesce(null, tenants_mandatory_day_off) <@ tenants_mandatory_day_off,
    -- which is always true, so one tenant's day off dropped a working day for
    -- every tenant and shifted the interval for all of them.
    -- MATERIALIZED: referenced once, so the planner would inline it into the
    -- EXISTS below and run the interval check per material row (65 x 4000
    -- buffers) instead of once per pair (16 x)
    allowed_interval AS MATERIALIZED (
        SELECT s.interval_start_date, s.interval_days
        FROM (SELECT DISTINCT mps.interval_start_date,
                     coalesce(nullif(mps.interval_days, 0), 1) AS interval_days
              FROM item i
              JOIN mock.material_impose_plan m ON m.material_impose_plan_id = i.material_impose_plan_id
              JOIN mock.material_print_schedule mps
                   ON mps.material_id = m.material_id
                  AND mps.production_line_id = m.production_line_id
                  AND mps.tenant_id = m.tenant_id
              UNION
              SELECT NULL::date, 1) s
        WHERE NOT p_only_starting_today
           OR EXISTS (
                  SELECT 1
                  FROM action.get_interval_dates(
                           (SELECT min(d.date)
                            FROM action.dates d
                            WHERE d.date >= coalesce(s.interval_start_date, v_date)
                              AND d.is_weekend = false
                              AND NOT (coalesce(p_tenant_ids, d.tenants_mandatory_day_off) <@ d.tenants_mandatory_day_off and d.tenants_mandatory_day_off <> '{}')),
                           v_date, s.interval_days, 1, false, false, 0,
                           p_tenant_ids) AS i(interval_date)
                  WHERE i.interval_date = v_date)
    ),
    material_row AS (
        SELECT i.imposition_group_id,
               -- alias: the group id is the material id until the xbom groups arrive
               coalesce(m.material_id, i.imposition_group_id) AS material_id,
               mps.material_name, m.production_line_id,
               m.tenant_id, t.tenant_name,
               m.resource_path, r.resource_uid, r.resource_name,
               mps.delivery_hours, mps.min_delivery_hours, i.sort_order,
               -- the variables the board evaluates with: the resource
               -- constants, the format of the group, and the work itself.
               -- Numbers only — evaluate_many_nas rejects strings.
               coalesce((SELECT jsonb_object_agg(e.key, e.value)
                         FROM jsonb_each(rs.setting_json) e
                         WHERE jsonb_typeof(e.value) = 'number'), '{}'::jsonb)
               || coalesce(w.format_json, '{}'::jsonb)
               || jsonb_build_object('specs', coalesce(mpl.line_json -> 'specs', '[]'::jsonb))
                                                       AS param_json,
               coalesce(rs.setting_json -> 'formula', '[]'::jsonb) AS formula,
               -- every impose resource the item may be dragged to, with its
               -- own constants, so the duration follows the gesture
               jsonb_build_object('valid_resources', coalesce((
                   SELECT jsonb_agg(jsonb_build_object('resource_path', vr.resource_path::text,
                                                       'resource_name', vr.resource_name)
                                    || coalesce((SELECT jsonb_object_agg(e.key, e.value)
                                                 FROM jsonb_each(vrs.setting_json) e
                                                 WHERE jsonb_typeof(e.value) = 'number'), '{}'::jsonb)
                                    ORDER BY vr.resource_path)
                   FROM relation.resource vr
                   LEFT JOIN LATERAL (
                       SELECT s.setting_json FROM production.resource_setting s
                       WHERE vr.resource_path <@ s.resource_path
                       ORDER BY nlevel(s.resource_path) DESC, s.moved_at DESC LIMIT 1
                   ) vrs ON true
                   WHERE vr.resource_path ~ '*.impose.*'
                     AND subpath(vr.resource_path, 0, 2) = subpath(m.resource_path, 0, 2)
               ), '[]'::jsonb))                        AS data,
               v_fixed -> mps.delivery_hours::text ->> 'group' AS fixed_group,
               -- the mutable truth lives on the lane item
               i.is_pinned,
               -- only a fixed group (class moment as default) or a pinned
               -- item has a time of its own; every other item is a filler
               -- and serves null — the client chains fillers itself
               CASE WHEN v_fixed -> mps.delivery_hours::text ->> 'group' IS NOT NULL
                    THEN coalesce(i.start_offset_in_seconds,
                                  (v_fixed -> mps.delivery_hours::text ->> 'offset')::integer)
                    WHEN i.is_pinned THEN i.start_offset_in_seconds
               END                                     AS start_offset_in_seconds,
               -- the chaining offset belongs to the resource; the connector
               -- mechanism replaces this column later
               (r.resource_json ->> 'next_start_lag_in_seconds')::integer
                                                       AS next_start_offset_in_seconds,
               i.lane_item_id, i.lane_id
        FROM item i
        LEFT JOIN mock.material_impose_plan m ON m.material_impose_plan_id = i.material_impose_plan_id
        LEFT JOIN relation.resource r ON r.resource_path = m.resource_path
        -- the speed setting of that resource for that group
        LEFT JOIN LATERAL (
            SELECT s.setting_json FROM production.resource_setting s
            WHERE m.resource_path <@ s.resource_path
              AND (s.imposition_group_id IS NULL OR s.imposition_group_id = i.imposition_group_id)
            ORDER BY nlevel(s.resource_path) DESC,
                     (s.imposition_group_id IS NOT NULL) DESC,
                     s.moved_at DESC
            LIMIT 1
        ) rs ON true
        -- the format of the group: waste and imposition size, first entry that
        -- matches the material width of the resource path
        LEFT JOIN LATERAL (
            SELECT jsonb_build_object(
                       'waste_factor',   (f.value ->> 'waste_factor')::numeric,
                       'imposition_sqm', (f.value ->> 'imposition_sqm')::numeric) AS format_json
            FROM catalog.imposition_group g
            CROSS JOIN LATERAL jsonb_array_elements(coalesce(g.imposition_group_json -> 'waste', '[]'::jsonb)) f
            WHERE g.imposition_group_id = i.imposition_group_id
            ORDER BY (f.value ->> 'width')::numeric DESC
            LIMIT 1
        ) w ON true
        LEFT JOIN mock.material_print_schedule mps
               ON mps.material_id = m.material_id
              AND mps.production_line_id = m.production_line_id
              AND mps.tenant_id = m.tenant_id
        LEFT JOIN mapping.material_production_line mpl
               ON mpl.material_id = m.material_id
              AND mpl.production_line_id = m.production_line_id
        LEFT JOIN tenant t ON t.tenant_id = m.tenant_id
        WHERE (p_tenant_ids IS NULL OR m.tenant_id = ANY (p_tenant_ids))
          -- only materials whose interval says the plan date is a production day
          AND (NOT p_only_starting_today OR EXISTS (
                   SELECT 1 FROM allowed_interval ai
                   WHERE ai.interval_start_date IS NOT DISTINCT FROM mps.interval_start_date
                     AND ai.interval_days = coalesce(nullif(mps.interval_days, 0), 1)))
    )
    SELECT * FROM material_row
    UNION ALL
    -- one row per tenant noop window, newest per slot; removed time the client
    -- lays the timeline around (column names and types come from the first branch)
    SELECT NULL, NULL, NULL, NULL, s.tenant_id, t.tenant_name, NULL, NULL, NULL, NULL, NULL, NULL,
           -- a noop has no formula, so its duration is already in param_json:
           -- the board reads param_json.duration_in_seconds for every row
           jsonb_build_object('specs', '[]'::jsonb,
                              'duration_in_seconds', s.duration_in_seconds),
           '[]'::jsonb, '{}'::jsonb, 'noop', false,
           s.start_offset_in_seconds, s.duration_in_seconds, NULL::bigint, NULL::bigint
    FROM (
        SELECT DISTINCT ON (n.rule_path, n.weekday, n.start_offset_in_seconds)
               n.rule_path::integer AS tenant_id,
               n.start_offset_in_seconds, n.duration_in_seconds
        FROM action.non_working_times n
        WHERE n.type = 'noop'
          AND n.rule_path NOT LIKE '%.%'
          AND n.rule_path IN (SELECT DISTINCT mr.tenant_id::text FROM material_row mr)
          AND (n.weekday IS NULL OR n.weekday = extract(dow FROM v_date)::smallint + 1)
        ORDER BY n.rule_path, n.weekday, n.start_offset_in_seconds,
                 n.non_working_time_id DESC
    ) s
    LEFT JOIN tenant t ON t.tenant_id = s.tenant_id
    WHERE s.duration_in_seconds > 0
    ORDER BY tenant_id, sort_order;
END;
$$;

alter function action.get_plan_lanes(timestamp with time zone, text, text, integer[], boolean, text, text[]) owner to xfw3;

-- renamed from mock.get_nest_schedule (via get_imposition_plan); impose is
-- the step, imposition the object it produces
drop function if exists mock.get_nest_schedule(timestamp with time zone, text, text, integer[], boolean, integer, integer, integer);
drop function if exists mock.get_nest_schedule(timestamp with time zone, text, text, integer[], integer, integer, integer);
drop function if exists mock.get_imposition_plan(timestamp with time zone, text, text, integer[], integer, integer, integer);
drop function if exists mock.get_impose_plan(timestamp with time zone, text, text, integer[], boolean, integer, integer, integer);
drop function if exists mock.get_impose_plan(timestamp with time zone, text, text, integer[], integer, integer, integer);

create function mock.get_impose_plan(p_until timestamp with time zone DEFAULT now(), p_step text DEFAULT 'print'::text, p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_look_back_days integer DEFAULT 0, p_look_ahead_days integer DEFAULT 0, p_domain_id integer DEFAULT 1) returns TABLE(material_id integer, material_name text, production_line_id integer, tenant_id integer, tenant_name text, production_company_id integer, resource_uid text, resource_name text, resource_path ltree, delivery_hours integer, min_delivery_hours integer, sort_order numeric, param_json jsonb, formula jsonb, data jsonb, fixed_group text, is_pinned boolean, start_offset_in_seconds integer, next_start_offset_in_seconds integer, duration_in_seconds integer, nest_date date, orderline_count integer, product_amount numeric, part_amount integer, amount numeric, sqm numeric, forecast_sqm numeric, rework_count integer, rework_sqm numeric, impact_json jsonb, gross_sqm numeric, part_status_json jsonb, nest_ids bigint[], nest_count integer, seconds_to_logistics_date integer, class_names text[], unit_class_names text[], lane_item_id bigint, lane_id bigint)
	stable
	language plpgsql
as $$
#variable_conflict use_column
declare
    v_date date := (p_until at time zone current_setting('TimeZone'))::date;
    -- at or below this sequence an orderline is not on a nest yet; only that
    -- work counts on a material row without planned nests
    v_max_status_sequence constant integer := 450;
    v_status_sequences integer[];
    -- a lane item is never shorter than this, whatever the sqm say
    v_min_duration_in_seconds  constant integer := 900;
begin
    -- the statuses live in mapping.internal_status, not in code
    select array_agg(distinct s.sequence) into v_status_sequences
    from mapping.internal_status s
    where s.domain_id = p_domain_id and s.sequence <= v_max_status_sequence;

    return query
    with base as (
        select b.material_id, b.material_name, b.production_line_id,
               b.tenant_id, b.tenant_name, b.resource_uid, b.resource_name,
               -- the row's own resource: valid_resources.resource_field reads it
               b.resource_path,
               b.delivery_hours, b.min_delivery_hours, b.sort_order,
               b.param_json, b.formula, b.data, b.fixed_group, b.is_pinned,
               b.start_offset_in_seconds, b.next_start_offset_in_seconds,
               b.lane_item_id, b.lane_id
        -- only the materials whose interval (action.get_interval_dates on
        -- interval_start_date and interval_days) says the plan date is a
        -- production day; the rest of the plan stays out of the nest board
        from action.get_plan_lanes(
                 p_until, p_step, p_line_type, p_tenant_ids, p_only_starting_today => true) b
    ),
    tenant as (
        select (v.value ->> 'tenant_id')::integer             as tenant_id,
               (v.value ->> 'production_company_id')::integer as production_company_id
        from relation.lookup lk
        cross join lateral jsonb_array_elements(lk.lookup_json) as v(value)
        where lk.lookup = 'lookup_tenants'
    ),
    the_plan as (
        -- the newest plan of this date, step and line type wins
        select plan_id
        from action.plan
        where plan_date = v_date and p_step = any (steps)
          and type = 'material-resource-plan'
          and (p_line_type is null or line_type = p_line_type)
        order by plan_id desc
        limit 1
    ),
    lane_nest as (
        -- the nests hung on the lane of this row: the sets of all its plan
        -- items together (the pattern item and the batch items, one batch per
        -- item), keyed on the row's item. The reader gives the current set of
        -- every item, inherited or own
        select b2.lane_item_id, array_agg(distinct x.imposition_id) as nest_ids
        from (select distinct lane_item_id, lane_id from base where lane_item_id is not null) b2
        join action.lane_item li on li.lane_id = b2.lane_id and li.type = 'plan'
        cross join lateral action.get_lane_item_impositions(li.lane_item_id) x
        group by b2.lane_item_id
    ),
    -- One aggregate call for all rows without lane nests, and one per distinct
    -- nest set for the rest, instead of one call per row: the detail behind
    -- the aggregate is the expensive part and it costs the same for one
    -- material as for fifty. Window rows are matched back on material and
    -- line; nest rows on material alone (see row_data).
    window_agg as (
        select a.*
        from mapping.get_production_orderline_aggregate(
                 p_from             => p_until,
                 p_date_type        => 'nest',
                 p_look_back_days   => p_look_back_days,
                 p_look_ahead_days  => p_look_ahead_days,
                 -- empty, not null: null would mean every material
                 p_material_ids     => coalesce((select array_agg(distinct b.material_id)
                                                 from base b
                                                 left join lane_nest ln on ln.lane_item_id = b.lane_item_id
                                                 where b.material_id is not null and ln.nest_ids is null),
                                                '{}'::integer[]),
                 p_tenant_ids       => (select array_agg(distinct b.tenant_id) from base b),
                 p_status_sequences => v_status_sequences,
                 p_is_open          => true,
                 p_domain_id        => p_domain_id) a
    ),
    nest_agg as (
        -- the nests decide the scope here; the material of the owning item
        -- narrows the call — the rows are matched back on material anyway,
        -- and without the filter every call drags the forecast of every
        -- material along (hundreds of discarded rows per set)
        select ns.nest_ids as lane_nest_ids, a.*
        from (select ln.nest_ids, array_agg(distinct b.material_id) as material_ids
              from lane_nest ln
              join base b on b.lane_item_id = ln.lane_item_id
              where b.material_id is not null
              group by ln.nest_ids) ns
        cross join lateral mapping.get_production_orderline_aggregate(
                 p_from             => p_until,
                 p_date_type        => 'nest',
                 p_nest_ids         => ns.nest_ids,
                 p_material_ids     => ns.material_ids,
                 p_tenant_ids       => (select array_agg(distinct b.tenant_id) from base b),
                 -- a planned nest set counts all its work whatever the
                 -- status; the class names carry the state instead
                 p_status_sequences => null,
                 p_is_open          => null,
                 p_domain_id        => p_domain_id) a
    ),
    row_data as (
        select b.*, ln.nest_ids,
               o.orderline_count, o.product_amount, o.part_amount, o.amount,
               o.sqm, o.forecast_sqm, o.rework_count, o.rework_sqm, o.impact_json, o.gross_sqm,
               o.specs_json, o.part_status_json, o.seconds_to_logistics_date,
               o.class_names, o.unit_class_names, o.production_impact_in_seconds
        from base b
        left join lane_nest ln on ln.lane_item_id = b.lane_item_id
        -- the work of this material on this line, every delivery class summed:
        -- the moment collects all open work of its material. A past moment
        -- carries impositions and gets the real work of that nest set instead;
        -- a second moment of the same material shows the same numbers — a
        -- duplicate is a planning moment, not a split of the work.
        left join lateral (
            with agg as (
                select na.orderline_count, na.product_amount, na.part_amount, na.amount,
                       na.sqm, na.forecast_sqm, na.rework_count, na.rework_sqm, na.impact_json, na.gross_sqm,
                       na.specs_json, na.part_status_json, na.seconds_to_logistics_date,
                       na.class_names, na.unit_class_names, na.production_impact_in_seconds
                from nest_agg na
                where ln.nest_ids is not null
                  and na.lane_nest_ids = ln.nest_ids
                  -- the nests decide the work, not the line: an orderline
                  -- nested here can carry another line (rerouted work), and
                  -- the forecast-only rows of the material stay out
                  and na.material_id = b.material_id
                  and na.orderline_count > 0
                union all
                select wa.orderline_count, wa.product_amount, wa.part_amount, wa.amount,
                       wa.sqm, wa.forecast_sqm, wa.rework_count, wa.rework_sqm, wa.impact_json, wa.gross_sqm,
                       wa.specs_json, wa.part_status_json, wa.seconds_to_logistics_date,
                       wa.class_names, wa.unit_class_names, wa.production_impact_in_seconds
                from window_agg wa
                where ln.nest_ids is null
                  and wa.material_id = b.material_id
                  and wa.production_line_id = b.production_line_id
            )
            select sum(a.orderline_count)::integer as orderline_count,
                   sum(a.product_amount)           as product_amount,
                   sum(a.part_amount)::integer     as part_amount,
                   sum(a.amount)                   as amount,
                   sum(a.sqm)                      as sqm,
                   sum(a.forecast_sqm)             as forecast_sqm,
                   sum(a.rework_count)::integer    as rework_count,
                   sum(a.rework_sqm)               as rework_sqm,
                   jsonb_build_object(
                       'count',         sum((a.impact_json ->> 'count')::integer),
                       'amount',        sum((a.impact_json ->> 'amount')::numeric),
                       'sqm',           round(sum((a.impact_json ->> 'sqm')::numeric), 2),
                       'rework_count',  sum((a.impact_json ->> 'rework_count')::integer),
                       'rework_amount', sum((a.impact_json ->> 'rework_amount')::numeric),
                       'rework_sqm',    round(sum((a.impact_json ->> 'rework_sqm')::numeric), 2)) as impact_json,
                   sum(a.gross_sqm)                as gross_sqm,
                   -- the specs are a material property, identical on every class row
                   (array_agg(a.specs_json) filter (where a.specs_json is not null))[1] as specs_json,
                   -- the part statuses of all classes, summed per status
                   (select jsonb_agg(jsonb_build_object(
                               'sequence', x.sequence, 'internal_status_code', x.internal_status_code,
                               'class_names', x.class_names, 'i18n', x.i18n, 'amount', x.amount)
                            order by x.sequence)
                    from (select (e.value ->> 'sequence')::integer   as sequence,
                                 e.value ->> 'internal_status_code'  as internal_status_code,
                                 e.value -> 'class_names'            as class_names,
                                 e.value -> 'i18n'                   as i18n,
                                 sum((e.value ->> 'amount')::numeric) as amount
                          from agg a2
                          cross join lateral jsonb_array_elements(a2.part_status_json) as e(value)
                          group by 1, 2, 3, 4) x)  as part_status_json,
                   min(a.seconds_to_logistics_date) as seconds_to_logistics_date,
                   sum(a.production_impact_in_seconds)::integer as production_impact_in_seconds,
                   (select array_agg(distinct c order by c)
                    from agg a3 cross join lateral unnest(a3.class_names) as c)      as class_names,
                   (select array_agg(distinct c order by c)
                    from agg a4 cross join lateral unnest(a4.unit_class_names) as c) as unit_class_names
            from agg a
            having count(*) > 0
        ) o on true
    )
    select r.material_id, r.material_name, r.production_line_id,
           r.tenant_id, r.tenant_name, t.production_company_id, r.resource_uid, r.resource_name,
           r.resource_path,
           r.delivery_hours, r.min_delivery_hours, r.sort_order,
           -- the sizes with what the gross sqm needs of each, and the print
           -- time of the row at both speeds
           jsonb_set(r.param_json, '{specs}', coalesce(r.specs_json, r.param_json -> 'specs'))
           -- net_sqm is what the formula needs; the resource constants, the
           -- waste and the imposition size already ride along from
           -- get_plan_lanes, so the board can evaluate the duration itself
           || jsonb_build_object('net_sqm', coalesce(r.sqm, 0)) as param_json,
           r.formula, r.data,
           r.fixed_group, r.is_pinned,
           r.start_offset_in_seconds, r.next_start_offset_in_seconds,
           -- noop rows keep their window duration; a material row lasts the
           -- standard production impact of its orderlines (from the
           -- manifests), never shorter than the floor. The machine formula
           -- in param_json stays for the resource board (78).
           case when r.material_id is null then r.next_start_offset_in_seconds
                else greatest(coalesce(r.production_impact_in_seconds, 0),
                              v_min_duration_in_seconds)
           end as duration_in_seconds,
           -- the day the row's orderlines nest: the plan date of the board
           v_date as nest_date,
           r.orderline_count, r.product_amount, r.part_amount, r.amount,
           r.sqm, r.forecast_sqm, r.rework_count, r.rework_sqm, r.impact_json, r.gross_sqm,
           coalesce(r.part_status_json, '[]'::jsonb),
           -- the nests of the lane items, not the ones the orderlines sit on
           coalesce(r.nest_ids, '{}'::bigint[]),
           coalesce(cardinality(r.nest_ids), 0),
           r.seconds_to_logistics_date,
           coalesce(r.class_names, '{}'::text[]),
           coalesce(r.unit_class_names, '{}'::text[]),
           r.lane_item_id, r.lane_id
    from row_data r
    left join tenant t on t.tenant_id = r.tenant_id
    order by r.tenant_id, r.sort_order;
end;
$$;

alter function mock.get_impose_plan(timestamp with time zone, text, text, integer[], integer, integer, integer) owner to xfw3;

-- the board query is planned per call and inlines the aggregate; JIT compiling
-- it costs seconds and never pays back
alter function mock.get_impose_plan(timestamp with time zone, text, text, integer[], integer, integer, integer) set jit = off;

COMMIT;

-- check 1: one row per material; expected on 5 sep sheet: 46 rows (44 materials
-- + 2 noop windows), 46 labels
SELECT (SELECT count(*) FROM mock.get_impose_plan(p_until => '2026-09-05T00:00:00+02:00', p_step => 'print', p_line_type => 'sheet', p_tenant_ids => array[1, 2])) AS rows_76,
       (SELECT count(DISTINCT (tenant_id, material_id)) FROM mock.get_impose_plan(p_until => '2026-09-05T00:00:00+02:00', p_step => 'print', p_line_type => 'sheet', p_tenant_ids => array[1, 2])) AS materials_76,
       (SELECT count(*) FROM action.get_plan_lanes(p_until => '2026-09-05T00:00:00+02:00', p_step => 'print', p_line_type => 'sheet', p_tenant_ids => array[1, 2], p_only_starting_today => true)) AS labels;

-- check 2: no nest lost in the aggregation; expected: the same number as the
-- distinct nests on all plan items of those lanes (5 sep sheet: 783 and 783)
SELECT sum(nest_count) AS nests_on_rows,
       (SELECT count(DISTINCT x.imposition_id)
        FROM mock.get_impose_plan(p_until => '2026-09-05T00:00:00+02:00', p_step => 'print', p_line_type => 'sheet', p_tenant_ids => array[1, 2]) r
        JOIN action.lane_item li ON li.lane_id = r.lane_id AND li.type = 'plan'
        CROSS JOIN LATERAL action.get_lane_item_impositions(li.lane_item_id) x) AS nests_on_lanes
FROM mock.get_impose_plan(p_until => '2026-09-05T00:00:00+02:00', p_step => 'print', p_line_type => 'sheet', p_tenant_ids => array[1, 2]);
