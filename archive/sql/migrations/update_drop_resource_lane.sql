-- action.resource_lane goes (docs/plan-batch-lane-item.md, the last of step 3):
-- the lane carries step and resource_path itself since the schema step, and
-- every writer filled both. A machine lane is now "a lane without an
-- imposition_group_lane row"; that matters because a group lane carries the
-- path of the impose machine (site.line.impose.width) as well. Five functions
-- move to the lane: action.crud_object, mock.generate_plan and
-- mock.generate_production_plan stop writing the second row,
-- action.get_plan_lanes_resource and action.get_resource_plan read the path
-- from the lane. The check first: it stops when a path differs between the
-- two tables or a function outside these five still names resource_lane.
-- Mirror: sql/action/resource_lane.sql moved to archive/sql/action/.

DO $$
DECLARE
    v_mismatch bigint;
    v_fn text;
BEGIN
    SELECT count(*) INTO v_mismatch
    FROM action.resource_lane rl
    JOIN action.lane l USING (lane_id)
    WHERE rl.resource_path <> l.resource_path;
    IF v_mismatch > 0 THEN
        RAISE EXCEPTION '% resource_lane rows differ from their lane', v_mismatch;
    END IF;
    SELECT string_agg(n.nspname || '.' || p.proname, ', ') INTO v_fn
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE p.prosrc ~* '\maction\.resource_lane\M'
      AND n.nspname || '.' || p.proname NOT IN ('action.crud_object', 'mock.generate_plan', 'mock.generate_production_plan',
                                               'action.get_plan_lanes_resource', 'action.get_resource_plan');
    IF v_fn IS NOT NULL THEN
        RAISE EXCEPTION 'still on resource_lane: %', v_fn;
    END IF;
END $$;

BEGIN;

-- ============ sql/action/crud_object.sql ============
create or replace function action.crud_object(p_param_json jsonb, p_no_results boolean DEFAULT false) returns jsonb
	language plpgsql
as $$
DECLARE
    result          jsonb;
    last_updated_at timestamp;
BEGIN
    -- ============================================================
    -- normalize every payload element into one set. resource_uid is
    -- never sent directly by the caller — only the pv2 resource_id is —
    -- so it is resolved here via relation.resource.pv2_id.
    -- ============================================================
    CREATE TEMP TABLE param_table ON COMMIT DROP AS
    SELECT
        (el ->> 'plannable_item_id')::integer                          AS plannable_item_id,
        el ->> 'crud'                                                   AS crud,
        (el ->> 'domain_id')::integer                                   AS domain_id,
        (el ->> 'company_id')::integer                                  AS company_id,
        (el ->> 'contact_id')::integer                                  AS contact_id,
        (el ->> 'team_id')::bigint                                      AS team_id,
        (el ->> 'section_id')::integer                                  AS section_id,
        (el ->> 'batch_id')::integer                                    AS batch_id,
        el ->> 'machine_type'                                            AS machine_type,
        res.resource_uid,
        COALESCE((el ->> 'is_fixed_offset')::boolean, false)             AS is_fixed_offset,
        (el ->> 'deleted_at') IS NOT NULL                                AS is_delete,
        jsonb_set(el, '{data}', (el ->> 'data')::jsonb, true)            AS action_json,
        (el ->> 'updated_at')::timestamp AT TIME ZONE 'Europe/Amsterdam' AS updated_at
    FROM jsonb_array_elements(p_param_json) AS el
    LEFT JOIN relation.resource res
           ON res.resource_json ->> 'pv2_id' = el ->> 'resource_id';

    -- ============================================================
    -- deletes: rows flagged with deleted_at
    -- ============================================================
    DELETE FROM action.object o
    USING param_table pt
    WHERE pt.crud = 'merge'
      AND pt.is_delete
      AND (o.action_json ->> 'plannable_item_id')::integer = pt.plannable_item_id;

    -- ============================================================
    -- upserts: rank continues from the existing count per
    -- resource_uid + day, then increments per row in updated_at order —
    -- same convention as generate_planning_objects. IS NOT DISTINCT FROM
    -- (instead of =) so rows without a resource_uid are grouped and
    -- ranked correctly instead of each restarting at 0.
    -- offset_in_seconds is always computed from start_at relative to
    -- 06:00 Amsterdam of that day — the canonical planning time field —
    -- never taken from the payload. Everything written through crud_object
    -- is atomic by definition, so is_atomic is hardcoded true.
    -- ============================================================
    WITH existing_rank AS (
        SELECT
            o.resource_uid,
            (o.start_at AT TIME ZONE 'Europe/Amsterdam')::date AS day,
            count(*)                                            AS cnt
        FROM action.object o
        WHERE o.parent_action_id IS NULL
        GROUP BY 1, 2
    ),
    batch_rows AS (
        SELECT
            pt.*,
            (pt.action_json ->> 'start_date')::timestamp AT TIME ZONE 'Europe/Amsterdam' AS start_at_local,
            ((pt.action_json ->> 'start_date')::timestamp AT TIME ZONE 'Europe/Amsterdam')::date AS day
        FROM param_table pt
        WHERE pt.crud = 'merge' AND NOT pt.is_delete
    ),
    ranked AS (
        SELECT
            br.*,
            EXTRACT(EPOCH FROM (br.start_at_local - (br.day + time '06:00')))::integer AS offset_in_seconds,
            row_number() OVER (
                PARTITION BY br.resource_uid, br.day
                ORDER BY br.updated_at NULLS FIRST
            ) AS batch_seq
        FROM batch_rows br
    )
    INSERT INTO action.object (
        domain_id, company_id, contact_id, team_id, section_id,
        action_json, start_at, end_at, batch_id,
        resource_uid, resource_plan_rank, is_fixed_offset, offset_in_seconds, is_atomic
    )
    SELECT
        r.domain_id, r.company_id, r.contact_id, r.team_id, r.section_id,
        r.action_json,
        r.start_at_local,
        (r.action_json ->> 'end_date')::timestamp AT TIME ZONE 'Europe/Amsterdam',
        r.batch_id,
        r.resource_uid,
        (COALESCE(er.cnt, 0) + r.batch_seq) * 1000,
        r.is_fixed_offset,
        r.offset_in_seconds,
        true
    FROM ranked r
    LEFT JOIN existing_rank er
           ON er.resource_uid IS NOT DISTINCT FROM r.resource_uid
          AND er.day          IS NOT DISTINCT FROM r.day
    ON CONFLICT (((action_json->>'plannable_item_id')::integer))
    DO UPDATE SET
        action_json        = EXCLUDED.action_json,
        start_at           = EXCLUDED.start_at,
        end_at             = EXCLUDED.end_at,
        batch_id           = EXCLUDED.batch_id,
        resource_uid       = EXCLUDED.resource_uid,
        resource_plan_rank = EXCLUDED.resource_plan_rank,
        is_fixed_offset    = EXCLUDED.is_fixed_offset,
        offset_in_seconds  = EXCLUDED.offset_in_seconds,
        is_atomic          = true;

    -- ============================================================
    -- resolve parent_action_id now that every row in this batch
    -- (parents included, regardless of arrival order) exists.
    -- chain: printer is root; coater/laminator is child of printer;
    -- cutter is child of coater/laminator if one exists for the batch,
    -- else child of printer
    -- ============================================================
    UPDATE action.object o
    SET parent_action_id = parent.action_id
    FROM param_table pt
    CROSS JOIN LATERAL (
        SELECT p.action_id
        FROM action.object p
        WHERE p.batch_id = pt.batch_id
          AND (
              (pt.machine_type IN ('coater', 'laminator') AND (p.action_json ->> 'machine_type') = 'printer')
              OR (pt.machine_type = 'cutter' AND (p.action_json ->> 'machine_type') IN ('coater', 'laminator'))
          )
        ORDER BY p.action_id DESC
        LIMIT 1
    ) parent
    WHERE pt.crud = 'merge'
      AND NOT pt.is_delete
      AND pt.batch_id IS NOT NULL
      AND pt.machine_type IN ('coater', 'laminator', 'cutter')
      AND (o.action_json ->> 'plannable_item_id')::integer = pt.plannable_item_id;

    -- cutter fallback: no coater/laminator sibling found for this batch,
    -- so fall back to the printer directly
    UPDATE action.object o
    SET parent_action_id = printer.action_id
    FROM param_table pt
    CROSS JOIN LATERAL (
        SELECT p.action_id
        FROM action.object p
        WHERE p.batch_id = pt.batch_id
          AND (p.action_json ->> 'machine_type') = 'printer'
        ORDER BY p.action_id DESC
        LIMIT 1
    ) printer
    WHERE pt.crud = 'merge'
      AND NOT pt.is_delete
      AND pt.batch_id IS NOT NULL
      AND pt.machine_type = 'cutter'
      AND o.parent_action_id IS NULL
      AND (o.action_json ->> 'plannable_item_id')::integer = pt.plannable_item_id;

    -- ============================================================
    -- the new plan model: the same items as action.plan -> lane ->
    -- lane_item (type plan), with their nests and dependencies. One
    -- production plan per day and line type covering every step in the
    -- payload; one lane per resource (its resource_path); one lane_item
    -- per plannable item, found again on the next payload through
    -- (source 'pv2', source_ref plannable_item_id). Only type 'batch'
    -- items are planning items; batch-reserved / batch-initiated are not.
    -- Items whose resource has no resource_path yet cannot get a lane and
    -- are skipped until it has one.
    -- ============================================================
    CREATE TEMP TABLE new_item ON COMMIT DROP AS
    SELECT pt.plannable_item_id,
           pt.plannable_item_id::text                                              AS source_ref,
           pt.batch_id,
           pt.machine_type,
           r.resource_path,
           r.step,
           -- the plan's line type is the ORDER's, from the batch; a machine can
           -- physically stand in another department (a foil order on a printer
           -- in the sheet hall still belongs to the foil plan)
           coalesce(bpl.line_type, pl.line_type) as line_type,
           pl.line_type                              as physical_line_type,
           ((pt.action_json ->> 'start_date')::timestamp AT TIME ZONE 'Europe/Amsterdam')                     AS start_at,
           -- start_date is Amsterdam local time; its date IS the plan date.
           -- No AT TIME ZONE here: the date cast would run in the session
           -- timezone (GMT) and shift items starting just after midnight
           -- to the previous day, blowing the 0..86399 offset check.
           ((pt.action_json ->> 'start_date')::timestamp)::date                                                AS plan_date,
           (pt.action_json ->> 'start_date')::timestamp                                                        AS start_local,
           (pt.action_json ->> 'end_date')::timestamp                                                          AS end_local,
           pt.is_fixed_offset,
           pt.action_json -> 'data' -> 'batched_amounts'                                                       AS batched_amounts
    FROM param_table pt
    JOIN relation.resource r          ON r.resource_uid = pt.resource_uid
    JOIN relation.production_line pl  ON pl.line_id = r.line_id
    LEFT JOIN legacy.batch b          ON b.batch_id = pt.batch_id
    LEFT JOIN relation.production_line bpl ON bpl.line_id = (b.batch_json ->> 'production_line_id')::integer
    WHERE pt.crud = 'merge'
      AND NOT pt.is_delete
      AND COALESCE(pt.action_json ->> 'type', 'batch') = 'batch'
      AND r.resource_path IS NOT NULL
      AND (pt.action_json ->> 'start_date') IS NOT NULL;

    -- deletes: the item; its batch row and its edges cascade
    DELETE FROM action.lane_item li
    USING param_table pt
    WHERE li.source = 'pv2' AND li.source_ref = pt.plannable_item_id::text
      AND pt.crud = 'merge' AND pt.is_delete;

    -- the day's production plan per line type: the newest one, or a new one
    -- (the material-resource-plan is calendar-driven and created in
    -- site.refresh_derived_data, ahead of the plannable items)
    INSERT INTO action.plan (plan_date, steps, type, line_type)
    SELECT d.plan_date, array_agg(DISTINCT d.step ORDER BY d.step), 'production-plan', d.line_type
    FROM (SELECT ni.plan_date, ni.step, ni.line_type FROM new_item ni
          UNION ALL
          SELECT ni.plan_date, ni.step, ni.physical_line_type FROM new_item ni
          WHERE ni.physical_line_type IS DISTINCT FROM ni.line_type) d
    WHERE NOT EXISTS (SELECT 1 FROM action.plan p
                      WHERE p.plan_date = d.plan_date AND p.type = 'production-plan'
                        AND p.line_type IS NOT DISTINCT FROM d.line_type)
    GROUP BY d.plan_date, d.line_type;

    -- and every step of the payload in the plan's steps
    UPDATE action.plan p
    SET steps = (SELECT array_agg(DISTINCT s ORDER BY s)
                 FROM unnest(p.steps || x.steps) AS s)
    FROM (SELECT d.plan_date, d.line_type, array_agg(DISTINCT d.step) AS steps
          FROM (SELECT ni.plan_date, ni.step, ni.line_type FROM new_item ni
                UNION ALL
                SELECT ni.plan_date, ni.step, ni.physical_line_type FROM new_item ni
                WHERE ni.physical_line_type IS DISTINCT FROM ni.line_type) d
          GROUP BY d.plan_date, d.line_type) x
    WHERE p.plan_id = (SELECT p2.plan_id FROM action.plan p2
                       WHERE p2.plan_date = x.plan_date AND p2.type = 'production-plan'
                         AND p2.line_type IS NOT DISTINCT FROM x.line_type
                       ORDER BY p2.plan_id DESC LIMIT 1)
      AND NOT (p.steps @> x.steps);

    -- the machine-day lane of every item, created once: a lane is the
    -- machine's day when it carries the machine's path and no imposition
    -- group (a group lane can carry the path of the impose machine)
    INSERT INTO action.lane (lane_date, step, resource_path)
    SELECT DISTINCT ni.plan_date, ni.step, ni.resource_path
    FROM new_item ni
    WHERE NOT EXISTS (SELECT 1
                      FROM action.lane l
                      WHERE l.lane_date = ni.plan_date AND l.resource_path = ni.resource_path
                        AND NOT EXISTS (SELECT 1 FROM action.imposition_group_lane gl WHERE gl.lane_id = l.lane_id));

    -- the plan and the lane of every item, resolved once
    CREATE TEMP TABLE item_plan ON COMMIT DROP AS
    SELECT d.*,
           (SELECT l.lane_id FROM action.lane l
            WHERE l.lane_date = d.plan_date AND l.resource_path = d.resource_path
              AND NOT EXISTS (SELECT 1 FROM action.imposition_group_lane gl WHERE gl.lane_id = l.lane_id)
            ORDER BY l.lane_id LIMIT 1) AS lane_id,
           (SELECT p.plan_id FROM action.plan p
            WHERE p.plan_date = d.plan_date AND p.type = 'production-plan'
              AND p.line_type IS NOT DISTINCT FROM d.line_type
            ORDER BY p.plan_id DESC LIMIT 1) AS plan_id,
           CASE WHEN d.physical_line_type IS DISTINCT FROM d.line_type THEN
           (SELECT p.plan_id FROM action.plan p
            WHERE p.plan_date = d.plan_date AND p.type = 'production-plan'
              AND p.line_type IS NOT DISTINCT FROM d.physical_line_type
            ORDER BY p.plan_id DESC LIMIT 1) END AS physical_plan_id
    FROM new_item d;

    -- the lane hung under the order's plan AND the physical department's
    -- plan, so both boards see the machine's full occupation
    INSERT INTO action.plan_lane (plan_id, lane_id, sort_order)
    SELECT x.plan_id, x.lane_id,
           COALESCE((SELECT max(pl2.sort_order) FROM action.plan_lane pl2 WHERE pl2.plan_id = x.plan_id), 0)
             + row_number() OVER (PARTITION BY x.plan_id ORDER BY x.lane_id)
    FROM (SELECT ip.plan_id, ip.lane_id FROM item_plan ip
          UNION
          SELECT ip.physical_plan_id, ip.lane_id FROM item_plan ip
          WHERE ip.physical_plan_id IS NOT NULL) x
    WHERE NOT EXISTS (SELECT 1 FROM action.plan_lane pl3
                      WHERE pl3.plan_id = x.plan_id AND pl3.lane_id = x.lane_id);

    -- an item may move to another lane (another printer, another day). Its
    -- batch rows carry the lane in their key (batch_lane_item (lane_item_id,
    -- lane_id) references lane_item) and would refuse the move; they are
    -- replaced as a whole by sync_pv2_batch_items below, so they go first
    DELETE FROM action.batch_lane_item b
    USING action.lane_item li, item_plan ip
    WHERE b.lane_item_id = li.lane_item_id
      AND li.source = 'pv2'
      AND li.source_ref = ip.source_ref;

    -- the items: offset in seconds since the plan date's local midnight,
    -- duration from the pv2 end, pinned when pv2 fixes the offset, never
    -- split. sort_order is a placeholder here; the lanes are renumbered
    -- below (it is unique per lane).
    INSERT INTO action.lane_item AS li
        (lane_id, sort_order, start_offset_in_seconds, duration_in_seconds,
         is_pinned, no_split, type, source, source_ref)
    SELECT ip.lane_id,
           -1 * ip.plannable_item_id,
           EXTRACT(EPOCH FROM (ip.start_local - ip.plan_date::timestamp))::integer,
           GREATEST(COALESCE(EXTRACT(EPOCH FROM (ip.end_local - ip.start_local))::integer, 0), 0),
           ip.is_fixed_offset, true, 'plan', 'pv2', ip.source_ref
    FROM item_plan ip
    ON CONFLICT (source, source_ref) DO UPDATE SET
        lane_id                 = EXCLUDED.lane_id,
        sort_order              = EXCLUDED.sort_order,
        start_offset_in_seconds = EXCLUDED.start_offset_in_seconds,
        duration_in_seconds     = EXCLUDED.duration_in_seconds,
        is_pinned               = EXCLUDED.is_pinned;

    -- renumber every touched lane by start, in two steps so the unique
    -- (lane_id, sort_order) never collides on the way
    UPDATE action.lane_item li
    SET sort_order = -1 * li.lane_item_id
    WHERE li.type = 'plan'
      AND li.lane_id IN (SELECT DISTINCT ip.lane_id FROM item_plan ip);

    UPDATE action.lane_item li
    SET sort_order = x.rank * 1000
    FROM (SELECT li2.lane_item_id,
                 row_number() OVER (PARTITION BY li2.lane_id
                                    ORDER BY li2.start_offset_in_seconds, li2.lane_item_id) AS rank
          FROM action.lane_item li2
          WHERE li2.type = 'plan'
            AND li2.lane_id IN (SELECT DISTINCT ip.lane_id FROM item_plan ip)) x
    WHERE li.lane_item_id = x.lane_item_id;

    -- the batch row and the chain of the items: one row per item with a
    -- batch, the nests pv2 batched on it, edges per batch. One place for that
    -- rule, shared with the backfill (docs/plan-batch-lane-item.md)
    PERFORM action.sync_pv2_batch_items(array(SELECT ip.plannable_item_id FROM item_plan ip));

    -- ============================================================
    -- fill print_production_unit_id in legacy.batch if it is still null
    -- ============================================================
    UPDATE legacy.batch b
    SET batch_json = jsonb_set(
        b.batch_json,
        '{print_production_unit_id}',
        to_jsonb((pt.action_json ->> 'resource_id')::int)
    )
    FROM param_table pt
    WHERE pt.crud = 'merge'
      AND NOT pt.is_delete
      AND (pt.action_json ->> 'machine_type') = 'printer'
      AND (pt.action_json ->> 'resource_id') IS NOT NULL
      AND pt.batch_id IS NOT NULL
      AND b.batch_id = pt.batch_id
      AND (b.batch_json ->> 'print_production_unit_id') IS NULL;

    SELECT MAX(pt.updated_at) INTO last_updated_at
    FROM param_table pt;

    IF last_updated_at IS NOT NULL THEN
        UPDATE mapping.persistent_vars
        SET value = last_updated_at - INTERVAL '2 minutes'
        WHERE key = 'last_plannable_item_updated_at';
    END IF;

    IF p_no_results THEN
        RETURN '[]'::jsonb;
    END IF;

    SELECT jsonb_agg(to_jsonb(pt.*))
    INTO result
    FROM param_table pt;

    RETURN COALESCE(result, '[]'::jsonb);
END;
$$;

alter function action.crud_object(jsonb, boolean) owner to xfw3;

-- ============ sql/mock/generate_plan.sql ============
-- the return column follows the schedule, so the old signature goes first
drop function if exists mock.generate_plan(date, text, text);

-- Stamps the day plan of a step from mock.material_print_schedule: the plan
-- (type material-resource-plan), one material lane per schedule row of the
-- line whose interval (interval_start_date, interval_days through
-- action.get_interval_dates) says p_date is a production day and that names
-- an impose path, with one item per nest moment code of the row
-- (lane_item.nest_moment_code; instance 0, 1, 2 in moment order,
-- production.get_nest_moment_instances), and one resource lane per impose
-- machine the rows name (resource_path), so the resource board reads the same
-- items per machine (get_resource_plan). The material items stay on their
-- material lanes; the resource lane carries no items of its own. A row
-- without an impose path has no lane yet. The plan is made even when the line
-- has no rows, so the daily refresh (site.refresh_derived_data) does not make
-- it again. A stamped day is the truth from then on: a move on the board
-- changes the item, not the schedule.
create function mock.generate_plan(p_date date, p_step text, p_line_type text) returns TABLE(plan_id bigint, lane_id bigint, material_print_schedule_id bigint)
	language sql
as $$
    WITH schedule AS (
        SELECT mps.material_print_schedule_id, mps.material_id, mps.production_line_id,
               mps.tenant_id, mps.resource_path, mps.nest_moment_codes,
               coalesce(mps.sort_order, 1000000 + mps.material_print_schedule_id) AS sort_order,
               row_number() OVER (ORDER BY coalesce(mps.sort_order, 1000000 + mps.material_print_schedule_id),
                                           mps.material_print_schedule_id) AS rn
        FROM mock.material_print_schedule mps
        WHERE mps.line = p_line_type
          AND mps.resource_path IS NOT NULL
          AND coalesce(cardinality(mps.nest_moment_codes), 0) > 0
          -- p_date is a production day of the row: the anchor is the first
          -- workday of its tenant at or after interval_start_date (the same
          -- rule as the lanes read)
          AND EXISTS (
                SELECT 1
                FROM action.get_interval_dates(
                         (SELECT min(d.date)
                          FROM action.dates d
                          WHERE d.date >= coalesce(mps.interval_start_date, p_date)
                            AND d.is_weekend = false
                            AND NOT (array[mps.tenant_id] <@ d.tenants_mandatory_day_off
                                     AND d.tenants_mandatory_day_off <> '{}')),
                         p_date, coalesce(nullif(mps.interval_days, 0), 1), 1,
                         false, false, 0, array[mps.tenant_id]) AS i(interval_date)
                WHERE i.interval_date = p_date)
    ),
    -- the machines the rows name: one machine lane each. One lane per
    -- machine per day: a lane of the date with the machine's path and no
    -- imposition group is reused, the others are made below
    resource AS (
        SELECT r.resource_path, ml.lane_id AS existing_lane_id
        FROM (SELECT DISTINCT s.resource_path FROM schedule s) r
        LEFT JOIN LATERAL (
            SELECT l.lane_id
            FROM action.lane l
            WHERE l.resource_path = r.resource_path AND l.lane_date = p_date
              AND NOT EXISTS (SELECT 1 FROM action.imposition_group_lane gl WHERE gl.lane_id = l.lane_id)
            ORDER BY l.lane_id LIMIT 1
        ) ml ON true
    ),
    numbered_resource AS (
        SELECT r.resource_path, row_number() OVER (ORDER BY r.resource_path) AS rn
        FROM resource r
        WHERE r.existing_lane_id IS NULL
    ),
    new_plan AS (
        -- tenant_ids: the tenants that run this line_type
        INSERT INTO action.plan (plan_date, steps, type, line_type, tenant_ids)
        SELECT p_date, array[p_step], 'material-resource-plan', p_line_type,
               (SELECT array_agg(DISTINCT pl.tenant_id ORDER BY pl.tenant_id)
                       FILTER (WHERE pl.tenant_id IS NOT NULL)
                FROM relation.production_line pl
                WHERE pl.line_type = p_line_type)
        RETURNING plan_id
    ),
    -- group lanes: one fresh lane per schedule row, with the imposition group
    -- of the row on it (imposition_group_lane; the group ids were seeded 1:1
    -- from the material ids). The lane carries its step and its impose path
    -- (site.line.impose.width)
    new_lane AS (
        INSERT INTO action.lane (lane_date, step, resource_path)
        SELECT p_date, p_step, subpath(s.resource_path, 0, 4)
        FROM schedule s
        ORDER BY s.rn
        RETURNING lane_id
    ),
    numbered_lane AS (
        SELECT nl.lane_id, row_number() OVER (ORDER BY nl.lane_id) AS rn FROM new_lane nl
    ),
    new_group_lane AS (
        INSERT INTO action.imposition_group_lane (lane_id, imposition_group_id)
        SELECT nl.lane_id, s.material_id
        FROM numbered_lane nl
        JOIN schedule s USING (rn)
        WHERE s.material_id IS NOT NULL
        RETURNING lane_id
    ),
    new_plan_lane AS (
        INSERT INTO action.plan_lane (plan_id, lane_id, sort_order)
        SELECT np.plan_id, nl.lane_id, s.sort_order
        FROM numbered_lane nl
        JOIN schedule s USING (rn)
        CROSS JOIN new_plan np
        RETURNING plan_id, lane_id, sort_order
    ),
    -- machine lanes: one fresh lane per machine without one; in the plan's
    -- order they follow the material lanes (plan_lane.sort_order is unique
    -- per plan)
    new_resource_lane AS (
        INSERT INTO action.lane (lane_date, step, resource_path)
        SELECT p_date, p_step, r.resource_path
        FROM numbered_resource r
        ORDER BY r.rn
        RETURNING lane_id, resource_path
    ),
    new_resource_plan_lane AS (
        INSERT INTO action.plan_lane (plan_id, lane_id, sort_order)
        SELECT np.plan_id, x.lane_id,
               coalesce((SELECT max(s.sort_order) FROM schedule s), 0) + 1000 + row_number() OVER (ORDER BY x.resource_path)
        FROM (SELECT nl.lane_id, nl.resource_path
              FROM new_resource_lane nl
              UNION ALL
              SELECT r.existing_lane_id, r.resource_path
              FROM resource r
              WHERE r.existing_lane_id IS NOT NULL) x
        CROSS JOIN new_plan np
        RETURNING lane_id
    ),
    -- the items: one per nest moment of the row, in moment order. No time of
    -- its own yet (the lanes read serves the moment of its class), not pinned;
    -- the ref names the schedule row, the day and the instance, so the item is
    -- found again (unique (source, source_ref))
    new_lane_item AS (
        INSERT INTO action.lane_item
            (lane_id, sort_order, start_offset_in_seconds, is_pinned,
             no_split, type, source, source_ref, instance, nest_moment_code)
        SELECT nl.lane_id, s.sort_order + m.instance, NULL, false, true, 'plan',
               'material-plan', s.material_print_schedule_id || ':' || p_date || ':' || m.instance,
               m.instance, m.nest_moment_code
        FROM numbered_lane nl
        JOIN schedule s USING (rn)
        CROSS JOIN LATERAL production.get_nest_moment_instances(s.nest_moment_codes) AS m
        RETURNING lane_item_id, lane_id
    ),
    -- the imposition group of the item (the group ids were seeded 1:1 from
    -- the material ids)
    new_imposition_group_lane_item AS (
        INSERT INTO action.imposition_group_lane_item (imposition_group_id, lane_item_id)
        SELECT s.material_id, nli.lane_item_id
        FROM new_lane_item nli
        JOIN numbered_lane nl ON nl.lane_id = nli.lane_id
        JOIN schedule s USING (rn)
        WHERE s.material_id IS NOT NULL
        RETURNING lane_item_id
    )
    -- The inserts above always run: a data-modifying CTE executes,
    -- referenced or not.
    SELECT (SELECT plan_id FROM new_plan), nl.lane_id, s.material_print_schedule_id
    FROM numbered_lane nl
    JOIN schedule s USING (rn);
$$;

alter function mock.generate_plan(date, text, text) owner to xfw3;

-- ============ sql/mock/generate_production_plan.sql ============
drop function if exists mock.generate_production_plan(date, text, text);

create function mock.generate_production_plan(p_date date, p_step text DEFAULT 'print'::text, p_line_type text DEFAULT 'sheet'::text) returns TABLE(plan_id bigint, lane_id bigint, sort_order numeric)
	language plpgsql
as $$
#variable_conflict use_column
declare
    v_plan_id bigint;
begin
    -- A production plan for one day and one step. Lanes are machine-days:
    -- created once per machine per day, then hung under this plan; a lane
    -- another plan already made is reused (archive/docs/plan-production-schedule.md).
    insert into action.plan (plan_date, steps, type, line_type)
    values (p_date, array[p_step], 'production-plan', p_line_type)
    returning plan_id into v_plan_id;

    -- ensure the machine-day lane of every active resource of the step: a
    -- lane of the date with the machine's path and no imposition group
    insert into action.lane (lane_date, step, resource_path)
    select p_date, r.step, r.resource_path
    from relation.resource r
    join relation.production_line pl on pl.line_id = r.line_id
    where r.active and r.resource_path is not null
      and r.step = p_step and pl.line_type = p_line_type
      and not exists (select 1
                      from action.lane l
                      where l.lane_date = p_date and l.resource_path = r.resource_path
                        and not exists (select 1 from action.imposition_group_lane gl where gl.lane_id = l.lane_id));

    -- hang them under the plan, in the order the resources carry
    return query
    insert into action.plan_lane (plan_id, lane_id, sort_order)
    select v_plan_id, l.lane_id,
           row_number() over (order by (r.resource_json ->> 'pv2_order')::numeric nulls last, r.resource_name)::numeric
    from relation.resource r
    join relation.production_line pl on pl.line_id = r.line_id
    join action.lane l on l.resource_path = r.resource_path and l.lane_date = p_date
                      and not exists (select 1 from action.imposition_group_lane gl where gl.lane_id = l.lane_id)
    where r.active and r.resource_path is not null
      and r.step = p_step and pl.line_type = p_line_type
    returning plan_id, lane_id, sort_order;
end;
$$;

alter function mock.generate_production_plan(date, text, text) owner to xfw3;

-- ============ sql/action/get_plan_lanes_resource.sql ============
-- One read for the resource lanes (labels) of the plan boards: resource_plan
-- (81) and whatever follows. One row per lane of a plan of the day, so one row
-- per machine that is planned: the lane carries the resource's path and the
-- step of that resource has to be a step planned that day. A group lane
-- (action.imposition_group_lane) is no row here, also when it carries the path
-- of the impose machine.
--
-- p_steps null = every step planned that day, whatever the type of the plan:
-- the production plans and the impose plan (material-resource-plan) both name
-- their machines as resource lanes, so per step and type the newest plan of the
-- day wins.
--
-- The material lanes are action.get_plan_lanes_imposition_group. p_steps here
-- names the steps whose resources are lanes; p_step there names the step of the
-- plan to read — two different questions, so two reads.
--
-- A lane has no time of its own: the items bring the times (action.get_resource_plan).
create function action.get_plan_lanes_resource(p_until timestamp with time zone DEFAULT now(), p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_steps text[] DEFAULT NULL::text[]) returns TABLE(tenant_id integer, tenant_name text, step text, resource_path ltree, resource_uid text, resource_name text, sort_order numeric, param_json jsonb, formula jsonb, next_start_offset_in_seconds integer, lane_id bigint)
	stable
	language plpgsql
as $$
#variable_conflict use_column
DECLARE
    v_date date;
BEGIN
    v_date := (p_until AT TIME ZONE current_setting('TimeZone'))::date;

    RETURN QUERY
    WITH the_plan AS (
        -- per step and plan type the newest plan of this date and line type
        SELECT DISTINCT ON (s.step, p.type) s.step, p.plan_id
        FROM action.plan p
        CROSS JOIN LATERAL unnest(p.steps) AS s(step)
        WHERE p.plan_date = v_date
          AND (p_line_type IS NULL OR p.line_type = p_line_type)
          AND (p_steps IS NULL OR s.step = ANY (p_steps))
        ORDER BY s.step, p.type, p.plan_id DESC
    ),
    lane AS (
        -- the machine lanes of those plans; a lane two plans share counts once,
        -- with the sort order of the newest
        SELECT DISTINCT ON (l.lane_id) l.lane_id, l.resource_path, pl.sort_order
        FROM the_plan tp
        JOIN action.plan_lane pl ON pl.plan_id = tp.plan_id
        JOIN action.lane l ON l.lane_id = pl.lane_id
        WHERE NOT EXISTS (SELECT 1 FROM action.imposition_group_lane gl WHERE gl.lane_id = l.lane_id)
        ORDER BY l.lane_id, tp.plan_id DESC
    )
    SELECT t.tenant_id, t.name, r.step,
           r.resource_path, r.resource_uid, r.resource_name,
           l.sort_order,
           -- the resource constants the board evaluates with
           production.get_setting_numbers(rs.setting_json),
           coalesce(rs.setting_json -> 'formula', '[]'::jsonb),
           -- the chaining offset belongs to the resource; the connector
           -- mechanism replaces this column later
           (r.resource_json ->> 'next_start_lag_in_seconds')::integer,
           l.lane_id
    FROM lane l
    JOIN relation.resource r ON r.resource_path = l.resource_path
    CROSS JOIN LATERAL (SELECT production.get_resource_setting(r.resource_path) AS setting_json) rs
    -- the site is position 0 of the path, the line type position 1
    LEFT JOIN site.tenant t ON t.abb = ltree2text(subpath(r.resource_path, 0, 1))
    -- the step of the resource itself has to be a step planned that day
    WHERE EXISTS (SELECT 1 FROM the_plan tp WHERE tp.step = r.step)
      AND (p_line_type IS NULL OR ltree2text(subpath(r.resource_path, 1, 1)) = p_line_type)
      AND (p_tenant_ids IS NULL OR t.tenant_id = ANY (p_tenant_ids))
    ORDER BY t.tenant_id, l.sort_order NULLS LAST, r.resource_path;
END;
$$;

alter function action.get_plan_lanes_resource(timestamp with time zone, text, integer[], text[]) owner to xfw3;

-- ============ sql/action/get_resource_plan.sql ============
-- The one item read of the resource board (docs/plan-lane-model.md, stap 7):
-- one row per lane item on the resource lanes of the day's plans — the
-- production plans, and the impose plan (material-resource-plan) whose
-- resource lanes are the impose machines and whose items are the material
-- items whose pattern names that machine (stap 7c) —
-- for the steps asked (p_steps null = every step planned that day), in three
-- kinds of rows, named by lane_item.type and action.lookup /
-- lookup_lane_item_type:
--   * plan     — the item as planned (stored); its nests from its batch rows
--                (action.batch_lane_item), the work of the set from the
--                orderline aggregate, whatever the status of the orderlines,
--                with the forecast of its material (forecast_sqm next to sqm);
--   * progress — what of that plan is still to do for the lane's step: the
--                orderline amounts below the step's done status
--                (lookup_step_category.sequence), as a share of the plan's
--                duration. Same lane_item_id and start, shrinks as work moves
--                on, gone when everything is done. Derived here, never stored;
--   * actual   — what the machine did, as items that partition the lane's
--                day: a run = the produced items of one batch in a row
--                (log.get_resource_produced; a nest without a batch is its
--                own run, a batch interrupted by another batch or by a gap
--                longer than lookup_lane_item_type.actual.gap_split_in_seconds
--                becomes two runs), and the stretches between runs. The state
--                blocks (log.get_resource_state) are the sub level of every
--                actual item: states_json holds them clipped to the item,
--                the state that fills most of the item names it (state_json,
--                class_names). No lane_item_id.
-- The plan row carries progress_json (done and remaining amounts, share) for
-- its tooltip; its state (state_json, class_names) is the least advanced
-- status of its nests, its sub level the part statuses (part_status_json).
-- type_json is the lookup node of the row's type; its class_names ride along
-- in class_names as well, so the board styles the kinds without code, and its
-- formula computes start_offset_in_seconds and duration_in_seconds from the
-- row's param_json (planned_start_offset_in_seconds,
-- production_impact_in_seconds, remaining_impact_in_seconds,
-- actual_start_offset_in_seconds, actual_duration_in_seconds) — the same
-- evaluate mechanism as board 76 uses per resource. The columns
-- start_offset_in_seconds and duration_in_seconds carry the same result for
-- readers without an evaluator. p_types filters the kinds (null = all).
--
-- Replaces mock.get_production_plan (81) and the resource mode of
-- mock.get_impose_plan (78). The labels come from action.get_plan_lanes_resource in
-- the resource read.
drop function if exists action.get_resource_plan(timestamp with time zone, text, integer[], text[], text[], integer);

create function action.get_resource_plan(p_until timestamp with time zone DEFAULT now(), p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_steps text[] DEFAULT NULL::text[], p_types text[] DEFAULT NULL::text[], p_domain_id integer DEFAULT 1)
    returns TABLE(tenant_id integer, tenant_name text, production_company_id integer, resource_uid text, resource_name text, resource_path ltree, lane_id bigint, step text, type text, type_json jsonb, lane_item_id bigint, sort_order numeric, is_pinned boolean, no_split boolean, fixed_group text, start_offset_in_seconds integer, duration_in_seconds integer, start_at timestamp with time zone, end_at timestamp with time zone, nest_ids bigint[], nest_count integer, batch_id integer, batch_name text, material_id integer, material_name text, impact_json jsonb, sqm numeric, forecast_sqm numeric, gross_sqm numeric, part_status_json jsonb, progress_json jsonb, state_json jsonb, group_state_json jsonb, states_json jsonb, class_names text[], param_json jsonb, min_delivery_hours integer, production_seconds_min integer, production_seconds_max integer, batch_count integer, delivery_hours_json jsonb, step_json jsonb, set_json jsonb, manifest_json jsonb)
    stable
    language plpgsql
    set jit = off
as $$
#variable_conflict use_column
declare
    v_zone constant text := 'Europe/Amsterdam';
    -- the plan date is the day of the viewed moment; the axis of the board is
    -- that day's local midnight, offsets are seconds since then
    v_date       date := (p_until at time zone 'Europe/Amsterdam')::date;
    v_day_start  timestamp with time zone;
    v_day_end    timestamp with time zone;
    -- print seconds per gross sqm at standard speed, and the shortest item; a lookup later
    v_standard_seconds_per_sqm constant numeric := 45;
    v_min_duration_in_seconds  constant integer := 900;
    -- legacy.nest width/height are in cm; a lookup later
    v_nest_size_per_sqm        constant numeric := 10000;
    v_state_lookup             jsonb;
    v_type_lookup              jsonb;
    -- a gap longer than this inside a batch splits its run in two
    v_gap_split_in_seconds     integer;
    -- at or below this sequence an orderline is not on a nest yet: the open
    -- work of a material item without nests (the same rule as get_impose_plan)
    v_max_status_sequence constant integer := 450;
    v_status_sequences         integer[];
begin
    select array_agg(distinct s.sequence) into v_status_sequences
    from mapping.internal_status s
    where s.domain_id = p_domain_id and s.sequence <= v_max_status_sequence;

    select lk.lookup_json into v_state_lookup
    from relation.lookup lk where lk.lookup = 'lookup_resource_state';

    select lk.lookup_json into v_type_lookup
    from action.lookup lk where lk.lookup = 'lookup_lane_item_type';

    select coalesce((t.value ->> 'gap_split_in_seconds')::integer, 900) into v_gap_split_in_seconds
    from jsonb_array_elements(coalesce(v_type_lookup, '[]'::jsonb)) as t(value)
    where t.value ->> 'type' = 'actual';
    v_gap_split_in_seconds := coalesce(v_gap_split_in_seconds, 900);

    v_day_start := v_date::timestamp at time zone v_zone;
    v_day_end   := (v_date + 1)::timestamp at time zone v_zone;

    return query
    with kind as (
        -- the three kinds of rows, with their lookup node
        select t.value ->> 'type'                                    as type,
               (t.value ->> 'sort_order')::integer                   as sort_order,
               t.value                                               as type_json,
               coalesce((select array_agg(c) from jsonb_array_elements_text(coalesce(t.value -> 'class_names', '[]'::jsonb)) c),
                        '{}'::text[])                                as class_names
        from jsonb_array_elements(coalesce(v_type_lookup, '[]'::jsonb)) as t(value)
    ),
    step_done as (
        -- per step the status at which its work is done
        select s.value ->> 'step'                 as step,
               (s.value ->> 'sequence')::integer  as done_sequence
        from relation.lookup lk
        cross join lateral jsonb_array_elements(lk.lookup_json) as s(value)
        where lk.lookup = 'lookup_step_category'
    ),
    tenant as (
        select t.tenant_id, t.name as tenant_name, t.abb, t.production_company_id
        from site.tenant t
    ),
    -- the steps asked, else every step a plan of the day carries: the
    -- production plans (print, coat, cut, ...) and the impose plan (the
    -- material-resource-plan, whose resource lanes are the impose machines)
    wanted_step as (
        select distinct s.step
        from action.plan p
        cross join lateral unnest(p.steps) as s(step)
        where p.plan_date = v_date
          and (p_line_type is null or p.line_type = p_line_type)
          and (p_steps is null or s.step = any (p_steps))
    ),
    the_plan as (
        -- per step and plan type the newest plan of the day that covers it
        select distinct on (ws.step, p.type) ws.step, p.plan_id
        from wanted_step ws
        join action.plan p on ws.step = any (p.steps)
        where p.plan_date = v_date
          and (p_line_type is null or p.line_type = p_line_type)
        order by ws.step, p.type, p.plan_id desc
    ),
    -- one lane = one machine's day (the lane's path, no imposition group on
    -- it), the machine's step names the lane's step; the tenant through the
    -- first label of the path (the site abb)
    lane as (
        select distinct on (l.lane_id)
               l.lane_id, pl_l.sort_order, l.resource_path,
               r.resource_uid, r.resource_name, r.step,
               t.tenant_id, t.tenant_name, t.production_company_id,
               sd.done_sequence
        from the_plan tp
        join action.plan_lane pl_l on pl_l.plan_id = tp.plan_id
        join action.lane l on l.lane_id = pl_l.lane_id
        join relation.resource r on r.resource_path = l.resource_path and r.step = tp.step
        left join step_done sd on sd.step = r.step
        left join tenant t on t.abb = ltree2text(subpath(l.resource_path, 0, 1))
        where not exists (select 1 from action.imposition_group_lane gl where gl.lane_id = l.lane_id)
          and (p_tenant_ids is null or t.tenant_id = any (p_tenant_ids))
        order by l.lane_id, tp.plan_id desc
    ),
    -- the material lanes of the impose plan, with the resource their pattern
    -- names and what the material boards derive per lane: material, line,
    -- fixed group and class time — the same read board 76 uses, so both
    -- boards agree on every item
    material_lane as (
        select b.lane_id, b.lane_item_id as pattern_item_id,
               b.material_id, b.material_name, b.production_line_id,
               b.resource_path, b.fixed_group, b.start_offset_in_seconds, b.param_json
        -- the day of p_until only: a resource board is one day, while the
        -- lanes read gives every day of its view
        from action.get_plan_lanes_imposition_group(
                 p_until, p_line_type => p_line_type, p_tenant_ids => p_tenant_ids,
                 p_only_starting_today => true) b
        where b.lane_id is not null
          and b.day_offset = 0
    ),
    -- planned items with the nests hung on them (their batch rows,
    -- action.batch_lane_item): the items on the lane itself (production
    -- plans), plus for an impose lane the items of every material lane whose
    -- pattern names its resource — the pattern items with the class time and
    -- fixed group of board 76, one per instance
    item as (
        select li.lane_item_id, li.lane_id, li.sort_order, li.is_pinned, li.no_split,
               li.fixed_group, li.start_offset_in_seconds, li.duration_in_seconds,
               null::integer as material_id, null::text as material_name, null::integer as production_line_id,
               '{}'::jsonb as param_json,
               (select array_agg(distinct x)
                from action.batch_lane_item bl
                cross join lateral unnest(bl.nest_ids) as x
                where bl.lane_item_id = li.lane_item_id) as nest_ids
        from action.lane_item li
        join lane on lane.lane_id = li.lane_id
        where li.type = 'plan'
        union all
        select li.lane_item_id, lane.lane_id, li.sort_order, li.is_pinned, li.no_split,
               case when li.lane_item_id = ml.pattern_item_id then ml.fixed_group end,
               case when li.lane_item_id = ml.pattern_item_id then ml.start_offset_in_seconds
                    else li.start_offset_in_seconds end,
               li.duration_in_seconds,
               ml.material_id, ml.material_name, ml.production_line_id,
               ml.param_json,
               (select array_agg(distinct x)
                from action.batch_lane_item bl
                cross join lateral unnest(bl.nest_ids) as x
                where bl.lane_item_id = li.lane_item_id)
        from lane
        join material_lane ml on ml.resource_path = lane.resource_path
        join action.lane_item li on li.lane_id = ml.lane_id and li.type = 'plan'
    ),
    -- what the nests of an item say: the batch, the run (amount x area), the
    -- materials, and the least advanced status, which names the item's state
    item_nest as (
        select i.lane_item_id,
               min(n.batch_id)                                                          as batch_id,
               min(b.batch_name)                                                        as batch_name,
               sum(coalesce(n.amount, 1) * coalesce(n.width, 0) * coalesce(n.height, 0)) / v_nest_size_per_sqm as run_sqm,
               array_agg(distinct (n.nest_json ->> 'material_id')::integer)
                   filter (where (n.nest_json ->> 'material_id') is not null)           as material_ids,
               (array_agg(n.nest_json ->> 'internal_status_code' order by ist.sequence nulls last))[1] as internal_status_code
        from item i
        cross join lateral unnest(coalesce(i.nest_ids, '{}'::bigint[])) as nid
        join legacy.nest n on n.nest_id = nid
        left join legacy.batch b on b.batch_id = n.batch_id
        left join mapping.internal_status ist on ist.code = n.nest_json ->> 'internal_status_code' and ist.domain_id = p_domain_id
        group by i.lane_item_id
    ),
    -- One read for the work of every item: action.get_lane_item_work takes the
    -- scope of each item (its own nests, else its material and line on the day)
    -- and gives back the totals plus the lists. Board 76 reads the same
    -- function, so both boards agree on every item.
    work as (
        select w.*
        from action.get_lane_item_work(
                 p_until            => p_until,
                 p_scope_json       => (select jsonb_agg(jsonb_build_object(
                                                   'lane_item_id',       i.lane_item_id,
                                                   'nest_ids',           i.nest_ids,
                                                   'material_id',        i.material_id,
                                                   'production_line_id', i.production_line_id,
                                                   'resource_path',      l.resource_path::text,
                                                   'param_json',         i.param_json))
                                        from item i
                                        join lane l on l.lane_id = i.lane_id
                                        where i.nest_ids is not null or i.material_id is not null),
                 p_date_type        => 'nest',
                 p_status_sequences => v_status_sequences,
                 p_look_back_days   => 0,
                 p_look_ahead_days  => 0,
                 p_tenant_ids       => p_tenant_ids,
                 p_domain_id        => p_domain_id) w
    ),
    -- the plan rows: the lane's resource names the row
    plan_row as (
        select l.tenant_id, l.tenant_name, l.production_company_id,
               l.resource_uid, l.resource_name, l.resource_path, l.lane_id, l.step,
               i.lane_item_id, i.sort_order, i.is_pinned, i.no_split, i.fixed_group,
               i.start_offset_in_seconds,
               -- pv2's duration when it sent one; a material item (impose) lasts
               -- the standard production impact of its work, from the nests or
               -- the open work, as on board 76; else the print time of the run
               -- (nest area x amount) at the resource's speed — never shorter
               -- than the minimum
               case when i.duration_in_seconds > 0 then i.duration_in_seconds
                    when i.material_id is not null
                         then greatest(coalesce(w.production_impact_in_seconds, 0),
                                       v_min_duration_in_seconds)
                    else greatest(ceil(coalesce(nf.run_sqm, 0) * v_standard_seconds_per_sqm
                                       / coalesce(nullif(mock.get_resource_speed_factor(w.material_id, l.resource_uid), 0), 1))::integer,
                                  v_min_duration_in_seconds) end                       as duration_in_seconds,
               coalesce(i.nest_ids, '{}'::bigint[])                                   as nest_ids,
               coalesce(cardinality(i.nest_ids), 0)                                    as nest_count,
               nf.batch_id, nf.batch_name,
               -- the material of the set, else of the material item itself; the
               -- work of the set, else the open work of the material
               coalesce(w.material_id, i.material_id)                                  as material_id,
               coalesce(w.material_name, i.material_name)                              as material_name,
               w.impact_json                                                           as impact_json,
               w.sqm                                                                   as sqm,
               w.forecast_sqm                                                          as forecast_sqm,
               w.gross_sqm                                                             as gross_sqm,
               coalesce(w.part_status_json, '[]'::jsonb)                               as part_status_json,
               -- the state of a planned item is the least advanced status of its
               -- nests, from the same lookup the actual rows use
               (select st.value from jsonb_array_elements(v_state_lookup) as ss(value)
                                     cross join lateral jsonb_array_elements(ss.value -> 'states') as st(value)
                 where st.value ->> 'code' = coalesce(nf.internal_status_code, 'batch') limit 1) as state_json,
               (select ss.value - 'states' from jsonb_array_elements(v_state_lookup) as ss(value)
                                           cross join lateral jsonb_array_elements(ss.value -> 'states') as st(value)
                 where st.value ->> 'code' = coalesce(nf.internal_status_code, 'batch') limit 1) as group_state_json,
               coalesce(w.class_names, '{}'::text[])                                   as class_names,
               jsonb_build_object(
                   'standard_production_impact_in_seconds', ceil(coalesce(nf.run_sqm, 0) * v_standard_seconds_per_sqm)::integer,
                   'run_sqm',                                round(coalesce(nf.run_sqm, 0), 2),
                   'speed_factor',                           mock.get_resource_speed_factor(coalesce(w.material_id, i.material_id), l.resource_uid),
                   'orderline_count',                        w.orderline_count) as param_json,
               -- what is done and what remains for the lane's step: the part
               -- amounts at or past the step's done status against the rest.
               -- Without orderline amounts nothing is known to be done
               coalesce(pr.done_amount, 0)                                             as done_amount,
               coalesce(pr.remaining_amount, 0)                                        as remaining_amount,
               case when coalesce(pr.done_amount, 0) + coalesce(pr.remaining_amount, 0) > 0
                    then coalesce(pr.remaining_amount, 0) / (coalesce(pr.done_amount, 0) + coalesce(pr.remaining_amount, 0))
                    else 1 end                                                         as remaining_share,
               -- what the work costs on the fastest and on the slowest machine of
               -- every step, the batches behind the item, and the lists
               w.min_delivery_hours, w.production_seconds_min, w.production_seconds_max,
               coalesce(w.batch_count, 0)                                              as batch_count,
               coalesce(w.delivery_hours_json, '{}'::jsonb)                            as delivery_hours_json,
               coalesce(w.step_json, '{}'::jsonb)                                      as step_json,
               coalesce(w.set_json, '[]'::jsonb)                                       as set_json,
               coalesce(w.manifest_json, '[]'::jsonb)                                  as manifest_json
        from item i
        join lane l on l.lane_id = i.lane_id
        left join item_nest nf on nf.lane_item_id = i.lane_item_id
        left join work w on w.lane_item_id = i.lane_item_id
        left join lateral (
            select sum((e.value ->> 'amount')::numeric) filter (where (e.value ->> 'sequence')::integer >= l.done_sequence) as done_amount,
                   sum((e.value ->> 'amount')::numeric) filter (where (e.value ->> 'sequence')::integer <  l.done_sequence) as remaining_amount
            from jsonb_array_elements(coalesce(w.part_status_json, '[]'::jsonb)) as e(value)
            where l.done_sequence is not null
        ) pr on true
    ),
    -- actual: the state blocks and the produced items of the lanes'
    -- resources, up to the viewed moment (the log functions clip to now());
    -- skipped altogether when the actual rows are not asked for
    actual_state as (
        select s.resource_uid, s.state, s.group_state, s.start_at,
               s.start_at + make_interval(secs => coalesce(s.duration_seconds, 0)) as end_at
        from log.get_resource_state(
                 (select array_agg(l.resource_uid) from lane l), v_day_start, least(p_until, v_day_end), null) s
        where (p_types is null or 'actual' = any (p_types))
          and coalesce(s.duration_seconds, 0) > 0
    ),
    produced as (
        select r.resource_uid, r.start_at,
               r.start_at + make_interval(secs => coalesce(r.duration_seconds, 0)) as end_at,
               coalesce(r.duration_seconds, 0)                                    as producing_seconds,
               r.batch_id, r.batch_name, r.nest_name,
               (select sum((m.value ->> 'value')::numeric)
                from jsonb_array_elements(coalesce(r.data -> 'metrics_json', '[]'::jsonb)) as m(value)
                where m.value ->> 'code' = 'area')                                 as area_sqm,
               -- what a run is keyed on: the batch, else the nest, else the row itself
               coalesce(r.batch_id::text, r.nest_name, 'row:' || r.start_at::text) as run_key
        from log.get_resource_produced(
                 (select array_agg(l.resource_uid) from lane l), v_day_start, least(p_until, v_day_end), null) r
        where p_types is null or 'actual' = any (p_types)
    ),
    -- a new run starts where the key changes or the gap since the previous
    -- item is longer than the split
    produced_break as (
        select p.*,
               case when p.run_key is distinct from lag(p.run_key) over w
                      or p.start_at - lag(p.end_at) over w > make_interval(secs => v_gap_split_in_seconds)
                    then 1 else 0 end as is_break
        from produced p
        window w as (partition by p.resource_uid order by p.start_at, p.end_at)
    ),
    produced_run as (
        select pb.*,
               sum(pb.is_break) over (partition by pb.resource_uid order by pb.start_at, pb.end_at rows unbounded preceding) as run_no
        from produced_break pb
    ),
    run as (
        select pr.resource_uid, pr.run_no,
               min(pr.start_at) as start_at, max(pr.end_at) as end_at,
               min(pr.batch_id) as batch_id, min(pr.batch_name) as batch_name,
               count(*)::integer as produced_count,
               sum(pr.producing_seconds)::integer as producing_seconds,
               sum(pr.area_sqm) as area_sqm,
               array_agg(distinct pr.nest_name) filter (where pr.nest_name is not null) as nest_names
        from produced_run pr
        group by pr.resource_uid, pr.run_no
    ),
    -- the log can overlap: an item of the next batch starts before the last
    -- item of this one ends; a run ends where the next run begins
    run_clipped as (
        select r.resource_uid, r.run_no, r.start_at,
               least(r.end_at, lead(r.start_at) over (partition by r.resource_uid order by r.start_at, r.run_no)) as end_at,
               r.batch_id, r.batch_name, r.produced_count, r.producing_seconds, r.area_sqm, r.nest_names
        from run r
    ),
    -- the stretches between runs, from the day start and up to the viewed
    -- moment; a lane without runs is one stretch
    stretch as (
        select r.resource_uid, r.end_at as start_at,
               lead(r.start_at) over (partition by r.resource_uid order by r.start_at) as end_at
        from run_clipped r
        union all
        select l.resource_uid, v_day_start,
               (select min(r.start_at) from run_clipped r where r.resource_uid = l.resource_uid)
        from lane l
    ),
    actual_item as (
        select r.resource_uid, r.start_at, r.end_at, true as is_run,
               r.batch_id, r.batch_name, r.produced_count, r.producing_seconds, r.area_sqm, r.nest_names
        from run_clipped r
        union all
        select s.resource_uid, s.start_at, coalesce(s.end_at, least(p_until, v_day_end)), false,
               null, null, 0, 0, null, null
        from stretch s
        where coalesce(s.end_at, least(p_until, v_day_end)) > s.start_at
    ),
    -- the sub level: the state blocks clipped to the item
    actual_segment as (
        select i.resource_uid, i.start_at as item_start,
               greatest(st.start_at, i.start_at) as start_at,
               least(st.end_at, i.end_at)        as end_at,
               st.state, st.group_state
        from actual_item i
        join actual_state st
          on st.resource_uid = i.resource_uid
         and st.start_at < i.end_at and st.end_at > i.start_at
    ),
    actual_row as (
        select i.*,
               extract(epoch from (i.start_at - v_day_start))::integer as start_offset_in_seconds,
               extract(epoch from (i.end_at - i.start_at))::integer    as duration_in_seconds,
               (select jsonb_agg(jsonb_build_object(
                           'start_offset_in_seconds', extract(epoch from (sg.start_at - v_day_start))::integer,
                           'duration_in_seconds',     extract(epoch from (sg.end_at - sg.start_at))::integer,
                           'class_names',             array_remove(array[sg.state ->> 'class_name'], null),
                           'state_json',              sg.state)
                        order by sg.start_at)
                from actual_segment sg
                where sg.resource_uid = i.resource_uid and sg.item_start = i.start_at) as states_json,
               -- the state that fills most of the item names it
               d.state as state_json, d.group_state as group_state_json
        from actual_item i
        left join lateral (
            select sg.state, sg.group_state
            from actual_segment sg
            where sg.resource_uid = i.resource_uid and sg.item_start = i.start_at
            group by sg.state, sg.group_state
            order by sum(extract(epoch from (sg.end_at - sg.start_at))) desc
            limit 1
        ) d on true
        -- a stretch without any state block is nothing to show
        where i.is_run or d.state is not null
    ),
    rows as (
        -- plan
        select p.tenant_id, p.tenant_name, p.production_company_id,
               p.resource_uid, p.resource_name, p.resource_path, p.lane_id, p.step,
               'plan'::text as type,
               p.lane_item_id, p.sort_order, p.is_pinned, p.no_split, p.fixed_group,
               p.start_offset_in_seconds, p.duration_in_seconds,
               v_day_start + make_interval(secs => p.start_offset_in_seconds) as start_at,
               null::timestamp with time zone                                 as end_at,
               p.nest_ids, p.nest_count, p.batch_id, p.batch_name,
               p.material_id, p.material_name, p.impact_json, p.sqm, p.forecast_sqm, p.gross_sqm,
               p.part_status_json,
               jsonb_build_object(
                   'done_amount',          p.done_amount,
                   'remaining_amount',     p.remaining_amount,
                   'remaining_percentage', round(p.remaining_share * 100, 1)) as progress_json,
               p.state_json, p.group_state_json, null::jsonb as states_json, p.class_names,
               -- the variables the formula of the kind runs over
               p.param_json || jsonb_build_object(
                   'planned_start_offset_in_seconds', p.start_offset_in_seconds,
                   'production_impact_in_seconds',    p.duration_in_seconds,
                   'remaining_impact_in_seconds',     round(p.duration_in_seconds * p.remaining_share)::integer) as param_json,
               p.min_delivery_hours, p.production_seconds_min, p.production_seconds_max,
               p.batch_count, p.delivery_hours_json, p.step_json, p.set_json, p.manifest_json
        from plan_row p

        union all
        -- progress: the remaining share of the plan, same item and start
        select p.tenant_id, p.tenant_name, p.production_company_id,
               p.resource_uid, p.resource_name, p.resource_path, p.lane_id, p.step,
               'progress'::text,
               p.lane_item_id, p.sort_order, p.is_pinned, p.no_split, p.fixed_group,
               p.start_offset_in_seconds,
               round(p.duration_in_seconds * p.remaining_share)::integer,
               v_day_start + make_interval(secs => p.start_offset_in_seconds),
               null::timestamp with time zone,
               p.nest_ids, p.nest_count, p.batch_id, p.batch_name,
               p.material_id, p.material_name, p.impact_json, p.sqm, p.forecast_sqm, p.gross_sqm,
               p.part_status_json,
               jsonb_build_object(
                   'done_amount',          p.done_amount,
                   'remaining_amount',     p.remaining_amount,
                   'remaining_percentage', round(p.remaining_share * 100, 1)),
               p.state_json, p.group_state_json, null::jsonb, p.class_names,
               p.param_json || jsonb_build_object(
                   'planned_start_offset_in_seconds', p.start_offset_in_seconds,
                   'production_impact_in_seconds',    p.duration_in_seconds,
                   'remaining_impact_in_seconds',     round(p.duration_in_seconds * p.remaining_share)::integer),
               p.min_delivery_hours, p.production_seconds_min, p.production_seconds_max,
               p.batch_count, p.delivery_hours_json, p.step_json, p.set_json, p.manifest_json
        from plan_row p
        where round(p.duration_in_seconds * p.remaining_share) > 0

        union all
        -- actual: the items of the lane's day, named by the resource that ran
        select l.tenant_id, l.tenant_name, l.production_company_id,
               l.resource_uid, l.resource_name, l.resource_path, l.lane_id, l.step,
               'actual'::text,
               null::bigint, null::numeric, false, false, null::text,
               a.start_offset_in_seconds, a.duration_in_seconds,
               a.start_at, a.end_at,
               coalesce((select array_agg(n.nest_id order by n.nest_id) from legacy.nest n where n.nest_name = any (a.nest_names)), '{}'::bigint[]),
               coalesce(cardinality(a.nest_names), 0),
               a.batch_id, a.batch_name,
               null::integer, null::text,
               null::jsonb, round(a.area_sqm, 2), null::numeric, null::numeric,
               '[]'::jsonb,
               null::jsonb,
               a.state_json, a.group_state_json, a.states_json,
               array_remove(array[a.state_json ->> 'class_name', case when a.is_run then 'actual-produced' end], null),
               jsonb_build_object(
                   'is_run',                          a.is_run,
                   'produced_count',                  a.produced_count,
                   'producing_in_seconds',            a.producing_seconds,
                   'actual_start_offset_in_seconds',  a.start_offset_in_seconds,
                   'actual_duration_in_seconds',      a.duration_in_seconds),
               null::integer, null::integer, null::integer,
               0, '{}'::jsonb, '{}'::jsonb, '[]'::jsonb, '[]'::jsonb
        from actual_row a
        join lane l on l.resource_uid = a.resource_uid
    )
    select r.tenant_id, r.tenant_name, r.production_company_id,
           r.resource_uid, r.resource_name, r.resource_path, r.lane_id, r.step,
           r.type, k.type_json,
           r.lane_item_id, r.sort_order, r.is_pinned, r.no_split, r.fixed_group,
           r.start_offset_in_seconds, r.duration_in_seconds, r.start_at, r.end_at,
           r.nest_ids, r.nest_count, r.batch_id, r.batch_name,
           r.material_id, r.material_name, r.impact_json, r.sqm, r.forecast_sqm, r.gross_sqm,
           r.part_status_json, r.progress_json, r.state_json, r.group_state_json, r.states_json,
           -- the class names of the kind ride along with the row's own
           (select array_agg(distinct c order by c)
            from unnest(r.class_names || coalesce(k.class_names, '{}'::text[])) as c) as class_names,
           r.param_json,
           r.min_delivery_hours, r.production_seconds_min, r.production_seconds_max,
           r.batch_count, r.delivery_hours_json, r.step_json, r.set_json, r.manifest_json
    from rows r
    left join kind k on k.type = r.type
    where p_types is null or r.type = any (p_types)
    order by r.tenant_id, r.resource_path, k.sort_order nulls last, r.start_offset_in_seconds, r.sort_order;
end;
$$;

alter function action.get_resource_plan(timestamp with time zone, text, integer[], text[], text[], integer) owner to xfw3;

-- the comments of the lane tables
comment on table action.lane is 'One strip of time on one day: the step and the path of what it plans. A machine-day carries the machine''s path; a group-day carries the impose path (site.line.impose.width) and an imposition_group_lane row. Which plans show the lane, and in what order, says plan_lane.';
comment on column action.lane.lane_date is 'The day of this strip of time. A lane is one machine-day or one group-day (imposition_group_lane); which plans show it says plan_lane.';
comment on table action.imposition_group_lane is 'The imposition group of a lane. A lane with this row is a group-day; a lane without it is a machine-day (its resource_path is the machine).';

DROP TABLE action.resource_lane;

COMMIT;

-- check: the machine lanes of today's boards, before and after the same
SELECT count(*) AS lanes, count(DISTINCT resource_path) AS machines
FROM action.get_plan_lanes_resource(now(), 'sheet');
SELECT count(*) AS rows FROM action.get_resource_plan(now(), 'sheet');
