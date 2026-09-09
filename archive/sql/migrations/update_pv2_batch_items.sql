-- ============================================================
-- Stap 3b, pv2-deel (docs/plan-lane-model.md): één batch per lane_item ook
-- voor de items van action.crud_object. De regel staat in
-- action.sync_pv2_batch_items; crud_object roept hem aan na zijn upsert in
-- plaats van zijn eigen set- en ketenblokken. Daarna de backfill: dezelfde
-- functie over de plannable items waarvan een nest op een andere (niet-lege)
-- batch staat dan het item.
-- ============================================================

BEGIN;

-- One batch per lane item for the pv2 planning (docs/plan-lane-model.md,
-- stap 3b). A plannable item of pv2 (action.object, type 'batch') is one lane
-- item: source 'pv2', source_ref <plannable_item_id>. Its batched_amounts name
-- the nests; when legacy.nest meanwhile books a nest on another batch, that
-- nest may not stay on the item of the other batch. A nest without a batch
-- yet (nests are made first and batched later) counts as the item's own. A
-- nest on another batch gets its own item next to the main one: source 'pv2',
-- source_ref <plannable_item_id>:<batch>, same lane and start, the block's
-- duration shared by nest count (the main item keeps its share). Extra items
-- whose batch left are removed again.
--
-- Sets and edges of the main and extra items are replaced as a whole, the
-- way crud_object did for the main item: the pv2 planning is the source of
-- truth here, not history. The chain runs per batch: a coater/laminator item
-- of batch B follows the printer item of batch B, a cutter item of batch B
-- follows the coater/laminator of B, else the printer of B — where "the item
-- of batch B" is the extra item <id>:<B> when the parent object holds B as an
-- extra, else its main item.
--
-- Called by action.crud_object after its upsert (for the payload's items) and
-- by the backfill (for every item). Set-based, no loop.
drop function if exists action.sync_pv2_batch_items(bigint[]);

create function action.sync_pv2_batch_items(p_plannable_item_ids bigint[]) returns integer
	language plpgsql
as $$
#variable_conflict use_column
DECLARE
    v_items integer;
BEGIN
    -- every nest of every item, with the batch legacy.nest books it on
    CREATE TEMP TABLE pv2_nest ON COMMIT DROP AS
    SELECT (o.action_json ->> 'plannable_item_id')                AS source_ref,
           coalesce(o.batch_id, 0)                                 AS item_batch,
           o.action_json ->> 'machine_type'                        AS machine_type,
           GREATEST(COALESCE(EXTRACT(EPOCH FROM ((o.action_json ->> 'end_date')::timestamp
                                                 - (o.action_json ->> 'start_date')::timestamp))::integer, 0), 0)
                                                                   AS block_duration,
           (ba.value ->> 'nest_id')::bigint                        AS nest_id,
           (ba.value ->> 'sequence')::numeric                      AS sequence,
           -- a nest without a batch yet belongs to the item's batch (nests are
           -- made first and batched later); only a nest on another batch leaves
           coalesce(n.batch_id, o.batch_id, 0)                     AS batch_key
    FROM action.object o
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(o.action_json -> 'data' -> 'batched_amounts', '[]'::jsonb)) AS ba(value)
    JOIN legacy.nest n ON n.nest_id = (ba.value ->> 'nest_id')::bigint
    WHERE (o.action_json ->> 'plannable_item_id')::bigint = ANY (p_plannable_item_ids)
      AND (ba.value ->> 'nest_id') IS NOT NULL;

    -- per (item, batch) the lane item it belongs to: the main item for the
    -- item's own batch (also when none of the nests is on it any more), an
    -- extra item per other batch
    CREATE TEMP TABLE pv2_item ON COMMIT DROP AS
    WITH batch AS (
        SELECT source_ref, item_batch AS batch_key FROM pv2_nest
        UNION
        SELECT source_ref, batch_key FROM pv2_nest
    ),
    cnt AS (
        SELECT source_ref, batch_key, count(*) AS nests FROM pv2_nest GROUP BY 1, 2
    ),
    total AS (
        SELECT source_ref, count(*) AS all_nests, max(block_duration) AS block_duration, max(item_batch) AS item_batch
        FROM pv2_nest GROUP BY 1
    )
    SELECT b.source_ref, b.batch_key,
           CASE WHEN b.batch_key = t.item_batch THEN b.source_ref
                ELSE b.source_ref || ':' || b.batch_key END               AS item_ref,
           coalesce(c.nests, 0)                                          AS nests,
           t.all_nests,
           round(t.block_duration::numeric * coalesce(c.nests, 0) / nullif(t.all_nests, 0))::integer AS duration_in_seconds,
           main.lane_item_id                                             AS main_item_id,
           main.lane_id, main.sort_order AS main_sort_order,
           main.start_offset_in_seconds, main.is_pinned
    FROM batch b
    JOIN total t ON t.source_ref = b.source_ref
    LEFT JOIN cnt c ON c.source_ref = b.source_ref AND c.batch_key = b.batch_key
    JOIN action.lane_item main ON main.source = 'pv2' AND main.source_ref = b.source_ref;

    -- the extra items, next to the main item in its lane
    INSERT INTO action.lane_item AS li
        (lane_id, sort_order, start_offset_in_seconds, duration_in_seconds,
         is_pinned, no_split, level, source, source_ref)
    SELECT pi.lane_id,
           pi.main_sort_order + row_number() OVER (PARTITION BY pi.source_ref ORDER BY pi.batch_key),
           pi.start_offset_in_seconds, pi.duration_in_seconds, pi.is_pinned, true, 0, 'pv2', pi.item_ref
    FROM pv2_item pi
    WHERE pi.item_ref <> pi.source_ref
    ON CONFLICT (source, source_ref) DO UPDATE SET
        lane_id                 = EXCLUDED.lane_id,
        sort_order              = EXCLUDED.sort_order,
        start_offset_in_seconds = EXCLUDED.start_offset_in_seconds,
        duration_in_seconds     = EXCLUDED.duration_in_seconds,
        is_pinned               = EXCLUDED.is_pinned;

    -- the main item keeps its share of the block
    UPDATE action.lane_item li
    SET duration_in_seconds = pi.duration_in_seconds
    FROM pv2_item pi
    WHERE pi.item_ref = pi.source_ref
      AND li.lane_item_id = pi.main_item_id
      AND li.duration_in_seconds IS DISTINCT FROM pi.duration_in_seconds;

    -- extra items whose batch left: their sets, edges (cascade) and the item
    DELETE FROM action.imposition_lane_item x
    USING action.lane_item li
    WHERE x.lane_item_id = li.lane_item_id
      AND li.source = 'pv2'
      AND split_part(li.source_ref, ':', 1)::bigint = ANY (p_plannable_item_ids)
      AND li.source_ref LIKE '%:%'
      AND NOT EXISTS (SELECT 1 FROM pv2_item pi WHERE pi.item_ref = li.source_ref);

    DELETE FROM action.lane_item li
    WHERE li.source = 'pv2'
      AND split_part(li.source_ref, ':', 1)::bigint = ANY (p_plannable_item_ids)
      AND li.source_ref LIKE '%:%'
      AND NOT EXISTS (SELECT 1 FROM pv2_item pi WHERE pi.item_ref = li.source_ref);

    -- the sets of main and extra items, replaced as a whole
    DELETE FROM action.imposition_lane_item x
    USING action.lane_item li
    WHERE x.lane_item_id = li.lane_item_id
      AND li.source = 'pv2'
      AND split_part(li.source_ref, ':', 1)::bigint = ANY (p_plannable_item_ids);

    INSERT INTO action.imposition_lane_item (imposition_id, lane_item_id, sort_order)
    SELECT DISTINCT ON (pn.nest_id, li.lane_item_id)
           pn.nest_id, li.lane_item_id, pn.sequence
    FROM pv2_nest pn
    JOIN pv2_item pi ON pi.source_ref = pn.source_ref AND pi.batch_key = pn.batch_key
    JOIN action.lane_item li ON li.source = 'pv2' AND li.source_ref = pi.item_ref
    ORDER BY pn.nest_id, li.lane_item_id, pn.sequence;

    -- the chain per batch: edges of main and extra items replaced as a whole
    DELETE FROM action.lane_item_dependency d
    USING action.lane_item li
    WHERE d.to_lane_item_id = li.lane_item_id
      AND li.source = 'pv2'
      AND split_part(li.source_ref, ':', 1)::bigint = ANY (p_plannable_item_ids);

    INSERT INTO action.lane_item_dependency (from_lane_item_id, to_lane_item_id)
    SELECT parent.lane_item_id, child.lane_item_id
    FROM pv2_item pi
    JOIN pv2_nest pn0 ON pn0.source_ref = pi.source_ref
    JOIN action.lane_item child ON child.source = 'pv2' AND child.source_ref = pi.item_ref
    CROSS JOIN LATERAL (
        -- the object of batch B one step earlier, and its item that holds B:
        -- the extra item <id>:<B> when B is an extra there, else the main item
        SELECT p.lane_item_id
        FROM action.object o
        JOIN action.lane_item p
          ON p.source = 'pv2'
         AND p.source_ref = CASE WHEN coalesce(o.batch_id, 0) = pi.batch_key
                                 THEN o.action_json ->> 'plannable_item_id'
                                 ELSE (o.action_json ->> 'plannable_item_id') || ':' || pi.batch_key END
        WHERE (o.batch_id = pi.batch_key
               OR EXISTS (SELECT 1 FROM action.lane_item e
                          WHERE e.source = 'pv2'
                            AND e.source_ref = (o.action_json ->> 'plannable_item_id') || ':' || pi.batch_key))
          AND (   (pn0.machine_type IN ('coater', 'laminator') AND o.action_json ->> 'machine_type' = 'printer')
               OR (pn0.machine_type = 'cutter' AND o.action_json ->> 'machine_type' IN ('coater', 'laminator', 'printer')))
        ORDER BY CASE WHEN o.action_json ->> 'machine_type' IN ('coater', 'laminator') THEN 0 ELSE 1 END,
                 o.action_id DESC
        LIMIT 1
    ) parent
    WHERE pi.nests > 0
      AND pi.batch_key <> 0
      AND pn0.machine_type IN ('coater', 'laminator', 'cutter')
      AND pn0.nest_id = (SELECT min(x.nest_id) FROM pv2_nest x WHERE x.source_ref = pi.source_ref)
    ON CONFLICT DO NOTHING;

    SELECT count(*) INTO v_items FROM pv2_item;
    RETURN v_items;
END;
$$;

alter function action.sync_pv2_batch_items(bigint[]) owner to xfw3;

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
    -- lane_item (level 0), with their nests and dependencies. One
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

    -- deletes: the item, its nests and its edges (edges cascade)
    DELETE FROM action.imposition_lane_item nli
    USING action.lane_item li, param_table pt
    WHERE nli.lane_item_id = li.lane_item_id
      AND li.source = 'pv2' AND li.source_ref = pt.plannable_item_id::text
      AND pt.crud = 'merge' AND pt.is_delete;

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

    -- the plan of every item, resolved once
    CREATE TEMP TABLE item_plan ON COMMIT DROP AS
    SELECT d.*,
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

    -- the machine-day lane of every item, created once, then hung under
    -- the order's plan AND the physical department's plan, so both boards
    -- see the machine's full occupation
    WITH missing AS (
        SELECT DISTINCT ip.plan_date, ip.resource_path
        FROM item_plan ip
        WHERE NOT EXISTS (SELECT 1
                          FROM action.lane l
                          JOIN action.resource_lane rl ON rl.lane_id = l.lane_id
                          WHERE l.lane_date = ip.plan_date AND rl.resource_path = ip.resource_path)
    ),
    with_id AS (
        SELECT m.plan_date, m.resource_path,
               nextval(pg_get_serial_sequence('action.lane', 'lane_id')) AS lane_id
        FROM missing m
    ),
    new_lane AS (
        INSERT INTO action.lane (lane_id, lane_date)
        OVERRIDING SYSTEM VALUE
        SELECT w.lane_id, w.plan_date FROM with_id w
        RETURNING lane_id
    )
    INSERT INTO action.resource_lane (lane_id, resource_path)
    SELECT w.lane_id, w.resource_path FROM with_id w;

    INSERT INTO action.plan_lane (plan_id, lane_id, sort_order)
    SELECT x.plan_id, x.lane_id,
           COALESCE((SELECT max(pl2.sort_order) FROM action.plan_lane pl2 WHERE pl2.plan_id = x.plan_id), 0)
             + row_number() OVER (PARTITION BY x.plan_id ORDER BY x.lane_id)
    FROM (SELECT DISTINCT pp.plan_id, l.lane_id
          FROM (SELECT ip.plan_id, ip.plan_date, ip.resource_path FROM item_plan ip
                UNION
                SELECT ip.physical_plan_id, ip.plan_date, ip.resource_path FROM item_plan ip
                WHERE ip.physical_plan_id IS NOT NULL) pp
          JOIN action.resource_lane rl ON rl.resource_path = pp.resource_path
          JOIN action.lane l ON l.lane_id = rl.lane_id AND l.lane_date = pp.plan_date) x
    WHERE NOT EXISTS (SELECT 1 FROM action.plan_lane pl3
                      WHERE pl3.plan_id = x.plan_id AND pl3.lane_id = x.lane_id);

    -- the items: offset in seconds since the plan date's local midnight,
    -- duration from the pv2 end, pinned when pv2 fixes the offset, never
    -- split. sort_order is a placeholder here; the lanes are renumbered
    -- below (it is unique per lane).
    INSERT INTO action.lane_item AS li
        (lane_id, sort_order, start_offset_in_seconds, duration_in_seconds,
         is_pinned, no_split, level, source, source_ref)
    SELECT l.lane_id,
           -1 * ip.plannable_item_id,
           EXTRACT(EPOCH FROM (ip.start_local - ip.plan_date::timestamp))::integer,
           GREATEST(COALESCE(EXTRACT(EPOCH FROM (ip.end_local - ip.start_local))::integer, 0), 0),
           ip.is_fixed_offset, true, 0, 'pv2', ip.source_ref
    FROM item_plan ip
    JOIN action.resource_lane rl ON rl.resource_path = ip.resource_path
    JOIN action.lane l ON l.lane_id = rl.lane_id AND l.lane_date = ip.plan_date
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
    WHERE li.level = 0
      AND li.lane_id IN (SELECT DISTINCT l.lane_id FROM item_plan ip
                         JOIN action.resource_lane rl ON rl.resource_path = ip.resource_path
    JOIN action.lane l ON l.lane_id = rl.lane_id AND l.lane_date = ip.plan_date);

    UPDATE action.lane_item li
    SET sort_order = x.rank * 1000
    FROM (SELECT li2.lane_item_id,
                 row_number() OVER (PARTITION BY li2.lane_id
                                    ORDER BY li2.start_offset_in_seconds, li2.lane_item_id) AS rank
          FROM action.lane_item li2
          WHERE li2.level = 0
            AND li2.lane_id IN (SELECT DISTINCT l.lane_id FROM item_plan ip
                                JOIN action.resource_lane rl ON rl.resource_path = ip.resource_path
    JOIN action.lane l ON l.lane_id = rl.lane_id AND l.lane_date = ip.plan_date)) x
    WHERE li.lane_item_id = x.lane_item_id;

    -- the nests and the chain of the items, one batch per lane item: the
    -- main item holds the nests of the item's batch, a nest that legacy.nest
    -- meanwhile books on another batch gets an extra item next to it, and the
    -- edges run per batch. One place for that rule, shared with the backfill
    -- (docs/plan-lane-model.md stap 3b)
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

-- backfill: the items whose nests mix batches, through the same function
DO $$
DECLARE
    v_ids bigint[]; v_n integer;
BEGIN
    SELECT array_agg(DISTINCT (o.action_json ->> 'plannable_item_id')::bigint)
    INTO v_ids
    FROM action.object o
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(o.action_json -> 'data' -> 'batched_amounts', '[]'::jsonb)) ba
    JOIN legacy.nest n ON n.nest_id = (ba.value ->> 'nest_id')::bigint
    JOIN action.lane_item li ON li.source = 'pv2' AND li.source_ref = o.action_json ->> 'plannable_item_id'
    WHERE n.batch_id IS NOT NULL AND n.batch_id <> coalesce(o.batch_id, 0);

    v_n := action.sync_pv2_batch_items(coalesce(v_ids, '{}'::bigint[]));
    RAISE NOTICE 'pv2 items synced: % plannable items, % (item, batch) rows', coalesce(cardinality(v_ids), 0), v_n;
END $$;

-- check 1: no pv2 item holds nests of two batches, and no nest sits on the
-- item of another batch; a nest without a batch yet counts as the item's own,
-- so only non-null batches are compared. Expected: 0 and 0
WITH item AS (
    SELECT li.lane_item_id,
           CASE WHEN li.source_ref LIKE '%:%' THEN split_part(li.source_ref, ':', 2)::bigint
                ELSE coalesce(o.batch_id, 0) END AS item_batch
    FROM action.lane_item li
    LEFT JOIN action.object o ON o.action_json ->> 'plannable_item_id' = li.source_ref
    WHERE li.source = 'pv2'
), cur AS (
    SELECT x.lane_item_id, x.imposition_id
    FROM action.imposition_lane_item x
    JOIN item i ON i.lane_item_id = x.lane_item_id
    WHERE x.imposition_id IS NOT NULL
      AND x.moved_at = (SELECT max(y.moved_at) FROM action.imposition_lane_item y WHERE y.lane_item_id = x.lane_item_id)
)
SELECT count(*) FILTER (WHERE batches > 1) AS pv2_items_with_2plus_batches,
       count(*) FILTER (WHERE foreign_nests > 0) AS pv2_items_with_foreign_nests
FROM (SELECT c.lane_item_id, count(DISTINCT n.batch_id) AS batches,
             count(*) FILTER (WHERE n.batch_id IS NOT NULL AND n.batch_id <> i.item_batch) AS foreign_nests
      FROM cur c JOIN item i ON i.lane_item_id = c.lane_item_id JOIN legacy.nest n ON n.nest_id = c.imposition_id
      GROUP BY c.lane_item_id) s;

-- check 2: the extra items next to the main items; expected on 5 sep: 48 extra
-- items, 0 without duration (main + extras sum to the block of the object)
SELECT count(*) AS extra_items,
       count(*) FILTER (WHERE duration_in_seconds IS NULL OR duration_in_seconds = 0) AS without_duration
FROM action.lane_item WHERE source = 'pv2' AND source_ref LIKE '%:%';

-- check 3: the production board still reads; expected: rows
SELECT count(*) AS rows FROM mock.get_production_plan('2026-09-04 10:00+02', 'print', 'sheet');
