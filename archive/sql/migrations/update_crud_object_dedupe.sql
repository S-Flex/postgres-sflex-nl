-- action.crud_object: one row per plannable_item_id in the batch. A pv2 sync
-- carried item 216070 twice on 15 Sep 2026 and the upsert failed with
-- "ON CONFLICT DO UPDATE command cannot affect row a second time"
-- (sync_plannable_items down). The payload is now deduplicated when it is
-- normalised: the last element of an item in the batch wins; the rest of the
-- function is unchanged. Rerunnable (create or replace).
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
    -- One row per plannable_item_id: a sync can carry the same item twice
    -- (moved twice, deleted and re-added); the last element of the batch is
    -- its newest state, and one INSERT ... ON CONFLICT may not touch a row
    -- twice ("cannot affect row a second time", 15 Sep 2026).
    -- ============================================================
    CREATE TEMP TABLE param_table ON COMMIT DROP AS
    SELECT DISTINCT ON ((el ->> 'plannable_item_id')::integer)
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
    FROM jsonb_array_elements(p_param_json) WITH ORDINALITY AS e(el, ordinality)
    LEFT JOIN relation.resource res
           ON res.resource_json ->> 'pv2_id' = el ->> 'resource_id'
    ORDER BY (el ->> 'plannable_item_id')::integer, e.ordinality DESC;

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

COMMIT;

-- expected: true
SELECT (pg_get_functiondef(p.oid) LIKE '%DISTINCT ON ((el ->> ''plannable_item_id'')::integer)%') AS deduplicated
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'action' AND p.proname = 'crud_object';
