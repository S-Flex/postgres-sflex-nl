create function mock.get_resource_plan_batch(p_line_type text DEFAULT NULL::text, p_from timestamp with time zone DEFAULT NULL::timestamp with time zone, p_until timestamp with time zone DEFAULT now()) returns TABLE(action_id integer, line text, resource_uids text[], state jsonb, group_state jsonb, layout_name text, type text, name text, nest_name text, job_name text, page_number integer, batch_id integer, batch_name text, data jsonb, start_at timestamp with time zone, offset_in_seconds integer, next_trigger_type text, just_in_time boolean, param_json jsonb, formula jsonb, resource_plan_rank numeric, is_fixed_offset boolean, is_atomic boolean, parent_action_id integer, material_id integer, step text)
	stable
	language plpgsql
as $$
#variable_conflict use_column
DECLARE
    v_lookup_json        jsonb;
    v_step_category_json jsonb;
    v_group_state_json   jsonb;
    v_formula_json       jsonb;
    v_teams_json         jsonb;
BEGIN
    IF p_until IS NULL THEN
        p_until := ((COALESCE(p_from::date, CURRENT_DATE) + 1)::timestamp AT TIME ZONE 'Europe/Amsterdam');
    END IF;

    IF p_from IS NULL THEN
        p_from := (COALESCE(p_until::date, CURRENT_DATE)::timestamp + interval '6 hours') AT TIME ZONE 'Europe/Amsterdam';
    END IF;

    SELECT lk.lookup_json INTO v_lookup_json
      FROM relation.lookup lk WHERE lk.lookup = 'lookup_resource_state';

    SELECT lk.lookup_json INTO v_group_state_json
      FROM relation.lookup lk WHERE lk.lookup = 'lookup_resource_group_state';

    SELECT lk.lookup_json INTO v_step_category_json
      FROM relation.lookup lk WHERE lk.lookup = 'lookup_step_category';

    SELECT lk.lookup_json INTO v_teams_json
      FROM relation.lookup lk WHERE lk.lookup = 'lookup_production_teams';

    v_formula_json := jsonb_build_array(
        'is_locked=offset_in_seconds<current_offset_in_seconds?1:0',
        'batch_duration=standard_production_impact/speed_factor',
        'first_item_duration=first_item_standard_production_impact/speed_factor',
        'duration_in_seconds=batch_duration'
    );

    RETURN QUERY
    WITH resolved AS (
        SELECT
            o.action_id,
            o.resource_uid,
            o.action_json,
            o.start_at,
            o.offset_in_seconds,
            o.standard_production_impact,
            o.resource_plan_rank,
            o.is_fixed_offset,
            o.is_atomic,
            o.parent_action_id,
            (o.action_json ->> 'batch_id')::integer AS batch_id,
            (o.action_json -> 'data' ->> 'material_id')::integer AS material_id,
            (o.action_json -> 'data' ->> 'first_item_standard_production_impact')::integer
                AS first_item_standard_production_impact,
            o.action_json ->> 'name' AS batch_name,
            -- data-provided duration (e.g. for maintenance, which has no
            -- standard_production_impact) — used as a fallback before the
            -- hard 3600 default in param_json below.
            (o.action_json -> 'data' ->> 'duration_in_seconds')::numeric AS duration_in_seconds,
            (SELECT s.value
             FROM jsonb_array_elements(v_lookup_json)        AS ss(value),
                  jsonb_array_elements(ss.value -> 'states') AS s(value)
             WHERE s.value ->> 'code' = COALESCE(
                 NULLIF(o.action_json ->> 'status', ''),
                 o.action_json ->> 'type',
                 'batch')
             LIMIT 1)                               AS state
        FROM mock.object o
    ),
    lines AS (
        SELECT DISTINCT pl.line_id
        FROM relation.production_line pl
        WHERE pl.line_type = p_line_type
    ),
    -- Per resource_uid + material_id, the rank of the FIRST batch-reserved
    -- action. Only that specific action may carry plan-alert/plan-warning/
    -- plan-signal/plan-info; every other action (including later
    -- batch-reserved instances of the same combination) has them stripped.
    first_reserved AS (
        SELECT resource_uid, material_id, MIN(resource_plan_rank) AS first_rank
        FROM resolved
        WHERE resolved.action_json ->> 'type' = 'batch-reserved'
        GROUP BY resource_uid, material_id
    ),
    -- Aggregate is called once per distinct line_id, not once per row.
    mat_agg AS (
        SELECT l.line_id, a.*
        FROM lines l
        CROSS JOIN LATERAL mock.get_material_planning_aggregate(l.line_id) a
    ),
    step_order AS (
        SELECT
            sc.value ->> 'step'          AS step,
            (sc.value ->> 'order')::int  AS step_order
        FROM jsonb_array_elements(v_step_category_json) AS sc(value)
    )
    SELECT
        rs.action_id,
        pl.line,
        ARRAY[res.resource_uid],
        -- Replace the single 'class_name' key with a 'class_names' array,
        -- combining the state's own class name with the material aggregate's.
        -- plan-warning/plan-alert/plan-signal/plan-info are only kept on the
        -- FIRST batch-reserved action per resource_uid + material_id — every
        -- other action (later batch-reserved instances, batch-initiated,
        -- breaks, maintenance) has them stripped.
        COALESCE(rs.state, '{}'::jsonb)
            - 'class_name'
            || jsonb_build_object(
                'class_names',
                to_jsonb(array_remove(
                    ARRAY(
                        SELECT DISTINCT x
                        FROM unnest(
                            array_cat(
                                ARRAY[rs.state ->> 'class_name'],
                                COALESCE(ma.class_name, ARRAY[]::text[])
                            )
                        ) AS x
                        WHERE NOT (
                            NOT (
                                rs.action_json ->> 'type' = 'batch-reserved'
                                AND rs.resource_plan_rank = fr.first_rank
                            )
                            AND x IN ('plan-warning', 'plan-alert', 'plan-signal', 'plan-info')
                        )
                    ),
                    NULL
                ))
            ) AS state,
        (SELECT gs.value
         FROM jsonb_array_elements(v_group_state_json) AS gs(value)
         WHERE gs.value ->> 'code' = rs.state ->> 'group'
         LIMIT 1),
        res.resource_json ->> 'layout_name',
        res.resource_json ->> 'type',
        res.resource_json ->> 'name',
        NULL::text,
        NULL::text,
        NULL::integer,
        rs.batch_id,
        rs.batch_name,
        -- Enrich data with a material_summary block from the aggregate,
        -- the day/night team codes for this resource_uid, and the line's
        -- break_times (used client-side for duration/interruption calculations).
        COALESCE(rs.action_json -> 'data', '{}'::jsonb)
            || jsonb_build_object(
                'material_summary',
                CASE WHEN ma.material_id IS NOT NULL THEN
                    jsonb_build_object(
                        'ready_to_nest_count',          ma.ready_to_nest_count,
                        'ready_to_nest_product_amount',  ma.ready_to_nest_product_amount,
                        'ready_to_nest_sqm',             ma.ready_to_nest_sqm,
                        'needs_dtp_count',                ma.needs_dtp_count,
                        'needs_dtp_product_amount',       ma.needs_dtp_product_amount,
                        'needs_dtp_sqm',                  ma.needs_dtp_sqm,
                        'rework_lines_count',              ma.rework_lines_count,
                        'rework_amount',                   ma.rework_amount,
                        'rework_sqm',                      ma.rework_sqm
                    )
                ELSE NULL
                END
            )
            || CASE WHEN (res.resource_json ->> 'has_break_times')::boolean IS TRUE
                    THEN jsonb_build_object('break_times', pl.line_json -> 'break_times')
                    ELSE '{}'::jsonb
               END
            || jsonb_build_object(
                'shifts',
                (SELECT jsonb_build_object('first', t.value ->> 'day_shift', 'second', t.value ->> 'night_shift')
                 FROM jsonb_array_elements(v_teams_json) AS t(value)
                 WHERE t.value ->> 'resource_uid' = res.resource_uid
                 LIMIT 1)
            ) AS data,
        rs.start_at,
        rs.offset_in_seconds,
        res.resource_json ->> 'next_trigger_type',
        (res.resource_json ->> 'just_in_time')::boolean,
        jsonb_build_object(
            'standard_production_impact',               coalesce(rs.standard_production_impact, rs.duration_in_seconds, 3600),
            'speed_factor',                             mock.get_resource_speed_factor(rs.material_id, res.resource_uid),
            'first_item_standard_production_impact',    coalesce(rs.first_item_standard_production_impact, 3600),
            'fixed_lag_duration',                       (res.resource_json ->> 'fixed_lag_duration')::numeric
        ) || COALESCE(pfm.param_json, '{}'::jsonb) AS param_json,
        v_formula_json,
        rs.resource_plan_rank,
        rs.is_fixed_offset,
        rs.is_atomic,
        rs.parent_action_id,
        rs.material_id,
        res.step
    FROM relation.resource        res
    JOIN relation.production_line pl  ON pl.line_id = res.line_id
    LEFT JOIN resolved            rs  ON rs.resource_uid = res.resource_uid
                                     AND rs.start_at >= p_from
                                     AND rs.start_at <  p_until
    LEFT JOIN mat_agg              ma ON ma.line_id = pl.line_id
                                     AND ma.material_id = rs.material_id
    LEFT JOIN first_reserved       fr ON fr.resource_uid = res.resource_uid
                                     AND fr.material_id = rs.material_id
    LEFT JOIN step_order            so ON so.step = res.step
    LEFT JOIN log.production_forecast_material pfm
                                       ON pfm.production_line_id = pl.line_id
                                      AND pfm.material_id        = rs.material_id
                                      AND pfm.date                = (rs.start_at AT TIME ZONE 'Europe/Amsterdam')::date
    WHERE pl.line_type = p_line_type AND res.step IS NOT NULL
    ORDER BY pl.line_id, so.step_order, res.resource_json ->> 'pv2_order', rs.start_at;
END;
$$;

alter function mock.get_resource_plan_batch(text, timestamp with time zone, timestamp with time zone) owner to xfw3;

