-- Step 2 of docs/plan-batch-lane-item.md: the writers. Run after
-- sql/update_batch_lane_item_schema.sql (step 1). Urgent part: since step 1
-- action.lane.step and resource_path are not null, so every writer that
-- makes a lane failed on a new machine-day -- crud_object (the hub),
-- crud_lane_item (a copy on a fresh lane), generate_plan and
-- generate_production_plan. They all write the two columns now.
--
-- 1. action.crud_lane_item_event: the release from the board (status
--    released; a released item without a time takes the release moment) and
--    its data_table row, so a button can post to it.
-- 2. legacy.crud_nest: a nest lands on the item released last before it was
--    nested (no_split and a planner move win), in the row of its batch on
--    that item, the null row without one; rows left empty go; the first nest
--    marks the item nested. No more 'nest' items, no more set writes.
-- 3. action.sync_pv2_batch_items: one row per pv2 item with a batch, the
--    nests pv2 batched on it; no batch, no row; the old extra items go.
-- 4. action.crud_object: lane with step and path; no set delete (cascade).
-- 5. action.crud_lane_item: lane with step and path (resource_path in data
--    for a fresh lane), a copy is the next instance on its lane.
-- 6. mock.generate_plan, mock.generate_production_plan: lanes with step and
--    path, the instance of the pattern row on the item.
-- The readers still read action.imposition_lane_item until step 3, so until
-- then the boards show the old sets; the new rows fill from here on.
BEGIN;

-- ============ sql/action/crud_lane_item_event.sql ============
-- The status history of a lane item (docs/plan-batch-lane-item.md): the
-- planner releases an item to the nesting software, legacy.crud_nest marks
-- it nested when its first nest lands. Append-only: one row per change, the
-- latest row is the status; the vocabulary is action.lookup
-- lookup_lane_item_status (plan, released, nested). One element per event:
--   {"track_by": 1, "data": {"lane_item_id": 8842, "status": "released",
--                            "moved_by": 12, "moved_at": "2026-09-09T13:00:00+02:00"}}
-- moved_at defaults to now, moved_by (the contact) may be null. There is no
-- crud: an event is only ever added.
--
-- A released item without a time of its own takes the release moment as its
-- start_offset_in_seconds (seconds since the local midnight of its lane
-- date, kept inside the day), so it has a moment before its nests arrive:
-- a nest lands on the item released last before it was nested.
drop function if exists action.crud_lane_item_event(jsonb, boolean);

create function action.crud_lane_item_event(p_param_json jsonb, p_no_results boolean DEFAULT false) returns TABLE(param_id integer, track_by integer, lane_item_event_id bigint, lane_item_id bigint, status text, moved_at timestamp with time zone)
	language sql
as $$
    WITH payload AS (
        SELECT row_number() OVER (ORDER BY coalesce((t.element ->> 'track_by')::integer, 0))::integer AS param_id,
               coalesce((t.element ->> 'track_by')::integer, 0) AS track_by,
               te.lane_item_id, te.status, te.moved_by,
               coalesce(te.moved_at, now()) AS moved_at
        FROM jsonb_array_elements(p_param_json) AS t(element)
        CROSS JOIN LATERAL jsonb_to_record(coalesce(t.element -> 'data', '{}'::jsonb)) AS te(
            lane_item_id bigint, status text, moved_by integer, moved_at timestamp with time zone)
    ),
    inserted AS (
        INSERT INTO action.lane_item_event (lane_item_id, status, moved_at, moved_by)
        SELECT p.lane_item_id, p.status, p.moved_at, p.moved_by
        FROM payload p
        ORDER BY p.param_id
        RETURNING lane_item_event_id, lane_item_id, status, moved_at
    ),
    -- the release moment becomes the time of an item without one
    timed AS (
        UPDATE action.lane_item li
        SET start_offset_in_seconds = least(86399, greatest(0,
                extract(epoch FROM (p.moved_at AT TIME ZONE 'Europe/Amsterdam') - l.lane_date::timestamp)::integer))
        FROM payload p, action.lane l
        WHERE p.status = 'released'
          AND li.lane_item_id = p.lane_item_id
          AND l.lane_id = li.lane_id
          AND li.start_offset_in_seconds IS NULL
        RETURNING li.lane_item_id
    )
    SELECT p.param_id, p.track_by, i.lane_item_event_id, i.lane_item_id, i.status, i.moved_at
    FROM payload p
    JOIN inserted i ON i.lane_item_id = p.lane_item_id AND i.status = p.status AND i.moved_at = p.moved_at
    WHERE NOT p_no_results
    ORDER BY p.param_id;
$$;

alter function action.crud_lane_item_event(jsonb, boolean) owner to xfw3;


INSERT INTO site.data_table (data_table, query, stored_proc, description, data_table_json, do_cache)
VALUES ('crud_lane_item_event', NULL, 'action.crud_lane_item_event',
        'lane item status events: release to nesting, nested', NULL, false)
ON CONFLICT (data_table) DO UPDATE SET stored_proc = EXCLUDED.stored_proc;

-- ============ sql/legacy/crud_nest.sql ============
-- same signature, dropped first so the script re-runs
drop function if exists legacy.crud_nest(jsonb, boolean);

create function legacy.crud_nest(p_param_json jsonb, p_no_results boolean DEFAULT false) returns TABLE(param_id integer, track_by integer, crud text, domain_id integer, batch_id bigint, nest_id bigint, nest_counter integer, reproduced_counter integer, nest_name text, amount integer, width numeric, height numeric, nest_json jsonb, sort_order integer, status jsonb, possible_states bigint, possible_multiple_states bigint)
	language plpgsql
as $$
#variable_conflict use_column
DECLARE
    last_updated_at timestamp;
    rec             record;
    v_batch_uid     bigint;
BEGIN
    CREATE TEMP TABLE param_table ON COMMIT DROP AS
    SELECT
        row_number() OVER ()::integer     AS param_id,
        COALESCE(te.track_by, 0)          AS track_by,
        te.crud,
        te.domain_id,
        te.batch_id,
        te.nest_id,
        COALESCE(te.nest_counter, 1)      AS nest_counter,
        COALESCE(te.reproduced_counter, 0) AS reproduced_counter,
        te.nest_name,
        te.amount,
        te.width::numeric(10,1)           AS width,
        te.height::numeric(10,1)          AS height,
        t.element                         AS nest_json,
        te.sort_order,
        te.status,
        te.possible_states,
        te.possible_multiple_states,
        te.nest_date,
        te.updated_at
    FROM jsonb_array_elements(p_param_json) AS t(element)
    CROSS JOIN LATERAL jsonb_to_record(t.element) AS te(
        track_by                 integer,
        crud                     text,
        domain_id                integer,
        batch_id                 bigint,
        nest_id                  bigint,
        nest_counter             integer,
        reproduced_counter       integer,
        nest_name                text,
        amount                   integer,
        width                    numeric,
        height                   numeric,
        sort_order               integer,
        status                   jsonb,
        possible_states          bigint,
        possible_multiple_states bigint,
        nest_date                timestamptz,
        updated_at               timestamptz
    );

    FOR rec IN
        SELECT * FROM param_table pt ORDER BY pt.updated_at ASC NULLS FIRST
    LOOP
        SELECT b.batch_uid INTO v_batch_uid
        FROM legacy.batch b
        WHERE b.batch_id = rec.batch_id;

        -- create, merge and update are one upsert: an update of a nest that
        -- is not here yet (a backfill, or the update overtook the create)
        -- inserts it instead of touching nothing. The fields an update may
        -- not carry keep their value.
        IF rec.crud IN ('create', 'merge', 'update') THEN
            INSERT INTO legacy.nest (
                batch_uid, domain_id, nest_id, nest_counter, reproduced_counter,
                nest_name, amount, width, height, nest_json, sort_order,
                status_json, possible_states, possible_multiple_states, nested_at, updated_at
            ) VALUES (
                v_batch_uid, COALESCE(rec.domain_id, 1), rec.nest_id, rec.nest_counter, rec.reproduced_counter,
                rec.nest_name, rec.amount, rec.width, rec.height,
                -- never insert a bare NULL into nest_json
                COALESCE(rec.nest_json, '{}'::jsonb),
                rec.sort_order,
                rec.status, rec.possible_states, rec.possible_multiple_states, rec.nest_date, rec.updated_at
            )
            ON CONFLICT ON CONSTRAINT uq_nest_id DO UPDATE
                SET batch_uid                = EXCLUDED.batch_uid,
                    nest_name                = COALESCE(EXCLUDED.nest_name, legacy.nest.nest_name),
                    amount                   = COALESCE(EXCLUDED.amount, legacy.nest.amount),
                    width                    = COALESCE(EXCLUDED.width, legacy.nest.width),
                    height                   = COALESCE(EXCLUDED.height, legacy.nest.height),
                    -- merge instead of replace: keys not present in the incoming
                    -- payload (e.g. commercial_waste_percentage, which is
                    -- computed elsewhere and not part of this event) are kept.
                    -- Incoming keys still win over existing ones on conflict.
                    nest_json                = COALESCE(legacy.nest.nest_json, '{}'::jsonb)
                                                || COALESCE(EXCLUDED.nest_json, '{}'::jsonb),
                    sort_order               = EXCLUDED.sort_order,
                    status_json              = EXCLUDED.status_json,
                    possible_states          = EXCLUDED.possible_states,
                    possible_multiple_states = EXCLUDED.possible_multiple_states,
                    nested_at                = EXCLUDED.nested_at,
                    updated_at               = EXCLUDED.updated_at;
        END IF;

        IF rec.crud IN ('create', 'merge') THEN
            -- insert into legacy.nest_log when a nest is created (initial 'ripped' entry, full amount)
            INSERT INTO legacy.nest_log
                (nest_id, from_status_sequence, to_status_sequence, amount, remaining_impact_delta, resource_uids, moved_at)
            SELECT
                n.nest_id,
                NULL,
                l.sequence,
                n.amount,
                NULL,
                '{}'::text[],
                now()
            FROM legacy.nest n,
                 relation.lookup rl,
                 jsonb_to_recordset(rl.lookup_json) AS l(step text, sequence int)
            WHERE n.nest_id = rec.nest_id
              AND rl.lookup = 'lookup_step_category'
              AND l.step = 'ripped';
        END IF;
    END LOOP;

    -- The single products of a nest may arrive before the nest (their sync
    -- runs ahead of the nest sync, and a backfill of the nests is slower):
    -- they carry no nest_amount yet and the nest has no commercial waste.
    -- Complete them now that the nest is here.
    UPDATE legacy.single_product sp
    SET single_product_json = COALESCE(sp.single_product_json, '{}'::jsonb)
                              || jsonb_build_object('nest_amount', n.amount)
    FROM legacy.nest n
    WHERE n.nest_id = sp.nest_id
      AND n.amount IS NOT NULL
      AND sp.single_product_json ->> 'nest_amount' IS NULL
      AND n.nest_id IN (SELECT pt.nest_id FROM param_table pt
                        WHERE pt.crud IN ('create', 'merge', 'update'));

    PERFORM legacy.update_nest_commercial_waste(
        array(SELECT DISTINCT pt.nest_id
              FROM param_table pt
              WHERE pt.crud IN ('create', 'merge', 'update')
                AND pt.nest_id IS NOT NULL));

    UPDATE legacy.nest n
    SET batch_uid = b.batch_uid
    FROM legacy.batch b
    WHERE n.batch_uid IS NULL
      AND b.batch_id = (n.nest_json ->> 'batch_id')::integer;

    -- ── nest → lane item (docs/plan-batch-lane-item.md) ──────────────────
    -- The material lane of a nest: the newest material-resource-plan of its
    -- nested_at date and the line type of its production line, the lane of
    -- its material (imposition_group_id is the alias) whose pattern item was
    -- stamped from that production line. The item on that lane, in this
    -- order: the no_split item that already holds the nest's batch (a
    -- no_split item keeps its whole batch); where the nest sits today (a
    -- planner move stays); else the item released last at or before
    -- nested_at (action.lane_item_event). An item that was never released
    -- receives no nests: the nest waits for the backfill.
    CREATE TEMP TABLE nest_link ON COMMIT DROP AS
    WITH payload AS (
        SELECT DISTINCT pt.nest_id,
               (n.nest_json ->> 'material_id')::integer        AS material_id,
               (n.nest_json ->> 'production_line_id')::integer AS production_line_id,
               (n.nested_at AT TIME ZONE 'Europe/Amsterdam')::date AS plan_date,
               n.nested_at,
               lower(COALESCE(n.nest_json ->> 'status', '')) LIKE 'cancel%' AS is_cancelled,
               n.batch_id::bigint                              AS batch_id
        FROM param_table pt
        JOIN legacy.nest n ON n.nest_id = pt.nest_id
        WHERE pt.crud IN ('create', 'merge', 'update')
    ),
    placed AS (
        SELECT p.*, lane.lane_id
        FROM payload p
        LEFT JOIN relation.production_line prl ON prl.line_id = p.production_line_id
        LEFT JOIN LATERAL (
            SELECT ap.plan_id
            FROM action.plan ap
            WHERE ap.plan_date = p.plan_date
              AND ap.type = 'material-resource-plan'
              AND (prl.line_type IS NULL OR ap.line_type = prl.line_type)
            ORDER BY ap.plan_id DESC
            LIMIT 1
        ) tp ON true
        LEFT JOIN LATERAL (
            -- the lane of the nest material on that plan; the line of a lane
            -- sits on the pattern row its pattern item was stamped from
            SELECT igl.lane_id
            FROM action.plan_lane apl
            JOIN action.imposition_group_lane igl ON igl.lane_id = apl.lane_id
            JOIN action.lane_item li2 ON li2.lane_id = igl.lane_id AND li2.source = 'material-plan'
            JOIN mock.material_impose_plan mip
              ON mip.material_impose_plan_id = nullif(split_part(li2.source_ref, ':', 1), '')::bigint
            WHERE apl.plan_id = tp.plan_id
              AND igl.imposition_group_id = p.material_id
              AND mip.production_line_id = p.production_line_id
            ORDER BY apl.sort_order
            LIMIT 1
        ) lane ON true
    )
    SELECT pl.nest_id, pl.nested_at, pl.is_cancelled, pl.batch_id,
           coalesce(ns.lane_item_id, cur.lane_item_id, rel.lane_item_id) AS lane_item_id
    FROM placed pl
    LEFT JOIN LATERAL (
        SELECT li.lane_item_id
        FROM action.lane_item li
        JOIN action.batch_lane_item b ON b.lane_item_id = li.lane_item_id
        WHERE li.lane_id = pl.lane_id AND li.no_split
          AND pl.batch_id IS NOT NULL AND b.batch_id = pl.batch_id
        ORDER BY li.instance, li.lane_item_id
        LIMIT 1
    ) ns ON true
    LEFT JOIN LATERAL (
        SELECT b.lane_item_id
        FROM action.batch_lane_item b
        WHERE b.step = 'impose' AND b.nest_ids @> array[pl.nest_id]
        LIMIT 1
    ) cur ON true
    LEFT JOIN LATERAL (
        SELECT e.lane_item_id
        FROM action.lane_item_event e
        JOIN action.lane_item li ON li.lane_item_id = e.lane_item_id
        WHERE li.lane_id = pl.lane_id AND li.type = 'plan'
          AND e.status = 'released' AND e.moved_at <= pl.nested_at
        ORDER BY e.moved_at DESC, e.lane_item_event_id DESC
        LIMIT 1
    ) rel ON true;

    -- ── the batch rows (docs/plan-batch-lane-item.md) ────────────────────
    -- A payload nest leaves every impose row that is not its target row
    -- (another item, another batch, or cancelled), joins the row of its batch
    -- on its item -- the null row for a nest without a batch -- and rows left
    -- empty disappear. Two inserts: the unique key of the batch rows is
    -- (lane_item_id, batch_id), that of the null rows the partial index.
    UPDATE action.batch_lane_item b
    SET nest_ids = coalesce((SELECT array_agg(x ORDER BY x)
                             FROM unnest(b.nest_ids) AS x
                             WHERE NOT EXISTS (SELECT 1 FROM nest_link ns
                                               WHERE ns.nest_id = x
                                                 AND (ns.is_cancelled
                                                      OR ns.lane_item_id IS DISTINCT FROM b.lane_item_id
                                                      OR ns.batch_id IS DISTINCT FROM b.batch_id))),
                            '{}'::bigint[])
    WHERE b.step = 'impose'
      AND b.nest_ids && (SELECT array_agg(ns.nest_id) FROM nest_link ns);

    INSERT INTO action.batch_lane_item (lane_item_id, lane_id, step, batch_id, nest_ids)
    SELECT ns.lane_item_id, li.lane_id, l.step, ns.batch_id,
           array_agg(ns.nest_id ORDER BY ns.nest_id)
    FROM nest_link ns
    JOIN action.lane_item li ON li.lane_item_id = ns.lane_item_id
    JOIN action.lane l ON l.lane_id = li.lane_id
    WHERE NOT ns.is_cancelled AND ns.batch_id IS NOT NULL
    GROUP BY ns.lane_item_id, li.lane_id, l.step, ns.batch_id
    ON CONFLICT (lane_item_id, batch_id) DO UPDATE
        SET nest_ids = (SELECT array_agg(DISTINCT x ORDER BY x)
                        FROM unnest(action.batch_lane_item.nest_ids || EXCLUDED.nest_ids) AS x);

    INSERT INTO action.batch_lane_item (lane_item_id, lane_id, step, batch_id, nest_ids)
    SELECT ns.lane_item_id, li.lane_id, l.step, NULL,
           array_agg(ns.nest_id ORDER BY ns.nest_id)
    FROM nest_link ns
    JOIN action.lane_item li ON li.lane_item_id = ns.lane_item_id
    JOIN action.lane l ON l.lane_id = li.lane_id
    WHERE NOT ns.is_cancelled AND ns.batch_id IS NULL
    GROUP BY ns.lane_item_id, li.lane_id, l.step
    ON CONFLICT (lane_item_id) WHERE batch_id IS NULL DO UPDATE
        SET nest_ids = (SELECT array_agg(DISTINCT x ORDER BY x)
                        FROM unnest(action.batch_lane_item.nest_ids || EXCLUDED.nest_ids) AS x);

    DELETE FROM action.batch_lane_item b
    WHERE b.step = 'impose' AND b.nest_ids = '{}'::bigint[];

    -- the first nest on an item marks it nested (action.lane_item_event)
    INSERT INTO action.lane_item_event (lane_item_id, status, moved_at)
    SELECT ns.lane_item_id, 'nested', min(ns.nested_at)
    FROM nest_link ns
    WHERE NOT ns.is_cancelled AND ns.lane_item_id IS NOT NULL
      AND NOT EXISTS (SELECT 1 FROM action.lane_item_event e
                      WHERE e.lane_item_id = ns.lane_item_id AND e.status = 'nested')
    GROUP BY ns.lane_item_id;

    -- ── imposition → unit manifest ────────────────────────────────────
    -- What the imposition is made of, snapshotted from the orderline
    -- manifests it holds (legacy.single_product is the bridge). Rebuilt for
    -- every nest in this payload, so a re-nest or a merge refreshes it.
    -- Cancelled nests keep their manifest: it records what was imposed, not
    -- what is still planned — the lane link above is what disappears.
    PERFORM legacy.create_imposition_unit_manifest(
        array(SELECT DISTINCT pt.nest_id
              FROM param_table pt
              WHERE pt.crud IN ('create', 'merge', 'update')
                AND pt.nest_id IS NOT NULL));

    SELECT MAX(pt.updated_at) INTO last_updated_at
    FROM param_table pt;

    IF last_updated_at IS NOT NULL THEN
        UPDATE mapping.persistent_vars
        SET value = last_updated_at - INTERVAL '2 minutes'
        WHERE key = 'last_nest_updated_at';
    END IF;

    IF NOT p_no_results THEN
        RETURN QUERY
        SELECT pt.param_id, pt.track_by, pt.crud, pt.domain_id,
               pt.batch_id, pt.nest_id, pt.nest_counter, pt.reproduced_counter,
               pt.nest_name, pt.amount, pt.width, pt.height, pt.nest_json,
               pt.sort_order, pt.status, pt.possible_states, pt.possible_multiple_states
        FROM param_table pt
        ORDER BY pt.param_id;
    END IF;
END;
$$;

alter function legacy.crud_nest(jsonb, boolean) owner to xfw3;



-- ============ sql/action/sync_pv2_batch_items.sql ============
-- The batch row of the pv2 items (docs/plan-batch-lane-item.md). A plannable
-- item of pv2 (action.object, type 'batch') is one lane item: source 'pv2',
-- source_ref <plannable_item_id>. It carries one row in
-- action.batch_lane_item: its batch, with the nests pv2 batched on it
-- (batched_amounts). An item without a batch is an empty slot (repair,
-- maintenance, test) and carries no row. The row is replaced as a whole:
-- the pv2 planning is the source of truth here, not history.
--
-- The chain runs per batch: a coater/laminator item of batch B follows the
-- printer item of B, a cutter item of B the coater/laminator of B, else the
-- printer of B. Edges of the items are replaced as a whole too.
--
-- The extra items of the old rule (source_ref <plannable_item_id>:<batch>,
-- one per other batch a nest was booked on) are removed when their main
-- item passes here; their rows and edges cascade.
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
    -- the items, their batch and the nests pv2 batched on them
    CREATE TEMP TABLE pv2_item ON COMMIT DROP AS
    SELECT li.lane_item_id, li.lane_id, l.step,
           o.batch_id::bigint                 AS batch_id,
           o.action_json ->> 'machine_type'   AS machine_type,
           coalesce((SELECT array_agg(DISTINCT (ba.value ->> 'nest_id')::bigint)
                     FROM jsonb_array_elements(coalesce(o.action_json -> 'data' -> 'batched_amounts', '[]'::jsonb)) AS ba(value)
                     WHERE (ba.value ->> 'nest_id') IS NOT NULL),
                    '{}'::bigint[])           AS nest_ids
    FROM action.object o
    JOIN action.lane_item li ON li.source = 'pv2' AND li.source_ref = o.action_json ->> 'plannable_item_id'
    JOIN action.lane l ON l.lane_id = li.lane_id
    WHERE (o.action_json ->> 'plannable_item_id')::bigint = ANY (p_plannable_item_ids);

    -- the extra items of the old rule
    DELETE FROM action.lane_item li
    WHERE li.source = 'pv2'
      AND li.source_ref LIKE '%:%'
      AND split_part(li.source_ref, ':', 1)::bigint = ANY (p_plannable_item_ids);

    -- one row per item with a batch, replaced as a whole
    DELETE FROM action.batch_lane_item b
    WHERE b.lane_item_id IN (SELECT pi.lane_item_id FROM pv2_item pi);

    INSERT INTO action.batch_lane_item (lane_item_id, lane_id, step, batch_id, nest_ids)
    SELECT pi.lane_item_id, pi.lane_id, pi.step, pi.batch_id, pi.nest_ids
    FROM pv2_item pi
    WHERE pi.batch_id IS NOT NULL;

    -- the chain per batch: edges of the items replaced as a whole
    DELETE FROM action.lane_item_dependency d
    WHERE d.to_lane_item_id IN (SELECT pi.lane_item_id FROM pv2_item pi);

    INSERT INTO action.lane_item_dependency (from_lane_item_id, to_lane_item_id)
    SELECT parent.lane_item_id, pi.lane_item_id
    FROM pv2_item pi
    CROSS JOIN LATERAL (
        -- the item of batch B one step earlier
        SELECT p.lane_item_id
        FROM action.object o
        JOIN action.lane_item p
          ON p.source = 'pv2' AND p.source_ref = o.action_json ->> 'plannable_item_id'
        WHERE o.batch_id = pi.batch_id
          AND (   (pi.machine_type IN ('coater', 'laminator') AND o.action_json ->> 'machine_type' = 'printer')
               OR (pi.machine_type = 'cutter' AND o.action_json ->> 'machine_type' IN ('coater', 'laminator', 'printer')))
        ORDER BY CASE WHEN o.action_json ->> 'machine_type' IN ('coater', 'laminator') THEN 0 ELSE 1 END,
                 o.action_id DESC
        LIMIT 1
    ) parent
    WHERE pi.batch_id IS NOT NULL
      AND pi.machine_type IN ('coater', 'laminator', 'cutter')
    ON CONFLICT DO NOTHING;

    SELECT count(*) INTO v_items FROM pv2_item;
    RETURN v_items;
END;
$$;

alter function action.sync_pv2_batch_items(bigint[]) owner to xfw3;


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
        SELECT DISTINCT ip.plan_date, ip.resource_path, ip.step
        FROM item_plan ip
        WHERE NOT EXISTS (SELECT 1
                          FROM action.lane l
                          JOIN action.resource_lane rl ON rl.lane_id = l.lane_id
                          WHERE l.lane_date = ip.plan_date AND rl.resource_path = ip.resource_path)
    ),
    with_id AS (
        SELECT m.plan_date, m.resource_path, m.step,
               nextval(pg_get_serial_sequence('action.lane', 'lane_id')) AS lane_id
        FROM missing m
    ),
    -- a lane is one resource on one day: its step and path live on the lane
    new_lane AS (
        INSERT INTO action.lane (lane_id, lane_date, step, resource_path)
        OVERRIDING SYSTEM VALUE
        SELECT w.lane_id, w.plan_date, w.step, w.resource_path FROM with_id w
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
         is_pinned, no_split, type, source, source_ref)
    SELECT l.lane_id,
           -1 * ip.plannable_item_id,
           EXTRACT(EPOCH FROM (ip.start_local - ip.plan_date::timestamp))::integer,
           GREATEST(COALESCE(EXTRACT(EPOCH FROM (ip.end_local - ip.start_local))::integer, 0), 0),
           ip.is_fixed_offset, true, 'plan', 'pv2', ip.source_ref
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
    WHERE li.type = 'plan'
      AND li.lane_id IN (SELECT DISTINCT l.lane_id FROM item_plan ip
                         JOIN action.resource_lane rl ON rl.resource_path = ip.resource_path
    JOIN action.lane l ON l.lane_id = rl.lane_id AND l.lane_date = ip.plan_date);

    UPDATE action.lane_item li
    SET sort_order = x.rank * 1000
    FROM (SELECT li2.lane_item_id,
                 row_number() OVER (PARTITION BY li2.lane_id
                                    ORDER BY li2.start_offset_in_seconds, li2.lane_item_id) AS rank
          FROM action.lane_item li2
          WHERE li2.type = 'plan'
            AND li2.lane_id IN (SELECT DISTINCT l.lane_id FROM item_plan ip
                                JOIN action.resource_lane rl ON rl.resource_path = ip.resource_path
    JOIN action.lane l ON l.lane_id = rl.lane_id AND l.lane_date = ip.plan_date)) x
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



-- ============ sql/action/crud_lane_item.sql ============
drop function if exists action.crud_lane_item(jsonb, boolean);

create function action.crud_lane_item(p_param_json jsonb, p_no_results boolean DEFAULT false) returns TABLE(param_id integer, track_by integer, crud text, lane_item_id bigint, lane_id bigint, material_impose_plan_id bigint)
	language sql
as $$
    -- The client mutations of the planning boards, on lane_item level: the
    -- stored_proc of the data tables get_impose_plan and
    -- get_plan_lanes_imposition_group. One element per mutation:
    --   {"crud": "update", "track_by": 1,
    --    "data": {"lane_item_id": 8842, "start_offset_in_seconds": 43200,
    --             "sort_order": 20450, "is_pinned": true}}
    -- crud is create, update or delete; track_by is the order of the
    -- mutations in the batch and comes back on the result row; data carries
    -- the properties: lane_item_id (update, delete, the source of a copy),
    -- start_offset_in_seconds, sort_order, is_pinned, and for a create lane_id,
    -- plan_id, imposition_group_id and, for a copy that needs a fresh lane,
    -- resource_path (the impose path of the lane, site.line.impose.width; a
    -- copy on an existing lane takes the lane's). A property left out of
    -- data keeps its value. A copy is the next instance of the moment on its
    -- lane (lane_item.instance). Every mutation writes through to mock.material_impose_plan, so
    -- re-stamping a plan reproduces what the planner did:
    --   update — move/pin/sort: the item and its pattern row
    --   create — an extra moment: a new pattern row with the next instance,
    --            plus the lane and the item it stamps to
    --   delete — the moment, its impositions and its pattern row
    --
    -- Set-based throughout: ids are drawn from the sequences up front, so a
    -- created row can be paired back to its payload row without a temp table.
    WITH payload AS (
        SELECT row_number() OVER (ORDER BY coalesce((t.element ->> 'track_by')::integer, 0))::integer AS param_id,
               coalesce((t.element ->> 'track_by')::integer, 0) AS track_by,
               t.element ->> 'crud'                             AS crud,
               te.lane_item_id, te.lane_id, te.plan_id,
               te.start_offset_in_seconds, te.sort_order, te.is_pinned,
               te.imposition_group_id, te.resource_path
        FROM jsonb_array_elements(p_param_json) AS t(element)
        CROSS JOIN LATERAL jsonb_to_record(coalesce(t.element -> 'data', '{}'::jsonb)) AS te(
            lane_item_id bigint, lane_id bigint, plan_id bigint,
            start_offset_in_seconds integer, sort_order numeric,
            is_pinned boolean, imposition_group_id integer, resource_path ltree)
    ),
    -- what an update or a copy starts from: the item, its lane and the
    -- pattern row it was stamped from (source_ref is <mrp_id>:<date>)
    source AS (
        SELECT p.param_id,
               li.lane_item_id, li.lane_id, li.sort_order, li.start_offset_in_seconds,
               li.is_pinned, li.duration_in_seconds,
               l.lane_date, l.resource_path,
               -- only a pattern item has a pattern row; a batch item (source
               -- 'nest', source_ref <lane_id>:<batch>) writes nothing through
               CASE WHEN li.source = 'material-plan'
                    THEN nullif(split_part(li.source_ref, ':', 1), '')::bigint END AS material_impose_plan_id,
               igli.imposition_group_id
        FROM payload p
        JOIN action.lane_item li ON li.lane_item_id = p.lane_item_id
        JOIN action.lane l       ON l.lane_id = li.lane_id
        LEFT JOIN action.imposition_group_lane_item igli ON igli.lane_item_id = li.lane_item_id
    ),
    -- ── update ────────────────────────────────────────────────────────────
    updated_item AS (
        UPDATE action.lane_item li
        SET sort_order              = coalesce(p.sort_order, li.sort_order),
            start_offset_in_seconds = coalesce(p.start_offset_in_seconds, li.start_offset_in_seconds),
            is_pinned               = coalesce(p.is_pinned, li.is_pinned)
        FROM payload p
        WHERE p.crud = 'update' AND li.lane_item_id = p.lane_item_id
        RETURNING li.lane_item_id, li.lane_id
    ),
    updated_pattern AS (
        -- the write-through: the same move on the template
        UPDATE mock.material_impose_plan m
        SET sort_order              = coalesce(p.sort_order, m.sort_order),
            start_offset_in_seconds = coalesce(p.start_offset_in_seconds, m.start_offset_in_seconds),
            is_pinned               = coalesce(p.is_pinned, m.is_pinned),
            moved_at                = now()
        FROM payload p
        JOIN source s ON s.param_id = p.param_id
        WHERE p.crud = 'update' AND m.material_impose_plan_id = s.material_impose_plan_id
        RETURNING m.material_impose_plan_id
    ),
    -- ── create ────────────────────────────────────────────────────────────
    -- ids up front: the pattern row, the lane (only for a copy that needs its
    -- own lane) and the item itself
    new_id AS (
        SELECT p.param_id, p.track_by, p.plan_id, p.sort_order, p.is_pinned,
               p.start_offset_in_seconds, p.lane_id AS given_lane_id,
               coalesce(p.imposition_group_id, s.imposition_group_id) AS imposition_group_id,
               coalesce(p.resource_path, s.resource_path)             AS resource_path,
               s.material_impose_plan_id AS from_pattern_id,
               s.lane_id                 AS from_lane_id,
               nextval('mock.material_resource_plan_material_resource_plan_id_seq') AS new_pattern_id,
               nextval('action.lane_item_lane_item_id_seq')                          AS new_lane_item_id,
               CASE WHEN p.lane_id IS NULL AND s.lane_id IS NULL
                    THEN nextval('action.lane_lane_id_seq') END                      AS new_lane_id
        FROM payload p
        LEFT JOIN source s ON s.param_id = p.param_id
        WHERE p.crud = 'create'
    ),
    target AS (
        SELECT n.*,
               coalesce(n.given_lane_id, n.from_lane_id, n.new_lane_id) AS lane_id,
               coalesce(pl.plan_date, l.lane_date)                      AS lane_date
        FROM new_id n
        LEFT JOIN action.plan pl ON pl.plan_id = n.plan_id
        LEFT JOIN action.lane l  ON l.lane_id = coalesce(n.given_lane_id, n.from_lane_id)
    ),
    -- a fresh lane is an impose lane on the path given, else the source's
    new_lane AS (
        INSERT INTO action.lane (lane_id, lane_date, step, resource_path)
        OVERRIDING SYSTEM VALUE
        SELECT t.new_lane_id, t.lane_date, 'impose', t.resource_path
        FROM target t WHERE t.new_lane_id IS NOT NULL
        RETURNING lane_id
    ),
    -- a fresh lane on a material board is a group lane
    new_group_lane AS (
        INSERT INTO action.imposition_group_lane (lane_id, imposition_group_id)
        SELECT t.new_lane_id, t.imposition_group_id
        FROM target t WHERE t.new_lane_id IS NOT NULL AND t.imposition_group_id IS NOT NULL
        RETURNING lane_id
    ),
    new_plan_lane AS (
        INSERT INTO action.plan_lane (plan_id, lane_id, sort_order)
        SELECT t.plan_id, t.new_lane_id,
               coalesce(t.sort_order,
                        (SELECT coalesce(max(pl2.sort_order), 0) + 1000
                         FROM action.plan_lane pl2 WHERE pl2.plan_id = t.plan_id))
        FROM target t WHERE t.new_lane_id IS NOT NULL AND t.plan_id IS NOT NULL
        RETURNING lane_id
    ),
    -- the new pattern row: the copy of the source row with the next instance
    new_pattern AS (
        INSERT INTO mock.material_impose_plan
            (material_impose_plan_id, weekday, step, resource_path, sort_order,
             material_id, instance, production_line_id, tenant_id,
             start_offset_in_seconds, is_pinned)
        OVERRIDING SYSTEM VALUE
        SELECT t.new_pattern_id, m.weekday, m.step, m.resource_path,
               coalesce(t.sort_order, m.sort_order), m.material_id,
               -- the next repeat of this moment in its own lane
               (SELECT coalesce(max(m2.instance), 0) + 1
                FROM mock.material_impose_plan m2
                WHERE m2.weekday = m.weekday AND m2.step = m.step
                  AND m2.resource_path IS NOT DISTINCT FROM m.resource_path
                  AND m2.material_id IS NOT DISTINCT FROM m.material_id),
               m.production_line_id, m.tenant_id,
               coalesce(t.start_offset_in_seconds, m.start_offset_in_seconds),
               coalesce(t.is_pinned, m.is_pinned)
        FROM target t
        JOIN mock.material_impose_plan m ON m.material_impose_plan_id = t.from_pattern_id
        RETURNING material_impose_plan_id
    ),
    new_item AS (
        INSERT INTO action.lane_item
            (lane_item_id, lane_id, sort_order, start_offset_in_seconds,
             duration_in_seconds, is_pinned, no_split, type, source, source_ref, instance)
        OVERRIDING SYSTEM VALUE
        SELECT t.new_lane_item_id, t.lane_id,
               -- no rank from the client: append behind the lane, spread so a
               -- batch never collides on the unique (lane_id, sort_order)
               coalesce(t.sort_order,
                        (SELECT coalesce(max(li2.sort_order), 0)
                         FROM action.lane_item li2 WHERE li2.lane_id = t.lane_id)
                        + 1000 * row_number() OVER (ORDER BY t.param_id)),
               coalesce(t.start_offset_in_seconds, 0), 0,
               coalesce(t.is_pinned, false), true, 'plan',
               'material-plan',
               -- same shape generate_plan stamps, so the item stays idempotent
               t.new_pattern_id || ':' || t.lane_date,
               -- the next repeat of the moment on its lane
               (SELECT coalesce(max(li3.instance), -1)
                FROM action.lane_item li3 WHERE li3.lane_id = t.lane_id AND li3.type = 'plan')
               + row_number() OVER (PARTITION BY t.lane_id ORDER BY t.param_id)
        FROM target t
        WHERE t.lane_id IS NOT NULL
        RETURNING lane_item_id, lane_id
    ),
    new_group_link AS (
        INSERT INTO action.imposition_group_lane_item (imposition_group_id, lane_item_id)
        SELECT t.imposition_group_id, t.new_lane_item_id
        FROM target t
        WHERE t.imposition_group_id IS NOT NULL AND t.lane_id IS NOT NULL
        ON CONFLICT DO NOTHING
        RETURNING lane_item_id
    ),
    -- ── delete ────────────────────────────────────────────────────────────
    deleted_link AS (
        DELETE FROM action.imposition_lane_item x
        USING payload p
        WHERE p.crud = 'delete' AND x.lane_item_id = p.lane_item_id
        RETURNING x.lane_item_id
    ),
    deleted_item AS (
        DELETE FROM action.lane_item li
        USING payload p
        WHERE p.crud = 'delete' AND li.lane_item_id = p.lane_item_id
        RETURNING li.lane_item_id
    ),
    deleted_pattern AS (
        -- without this the moment returns at the next stamp
        DELETE FROM mock.material_impose_plan m
        USING payload p
        JOIN source s ON s.param_id = p.param_id
        WHERE p.crud = 'delete' AND m.material_impose_plan_id = s.material_impose_plan_id
        RETURNING m.material_impose_plan_id
    )
    SELECT p.param_id, p.track_by, p.crud,
           coalesce(t.new_lane_item_id, p.lane_item_id),
           coalesce(t.lane_id, p.lane_id),
           coalesce(t.new_pattern_id, s.material_impose_plan_id)
    FROM payload p
    LEFT JOIN target t ON t.param_id = p.param_id
    LEFT JOIN source s ON s.param_id = p.param_id
    WHERE NOT p_no_results
    ORDER BY p.param_id;
$$;

alter function action.crud_lane_item(jsonb, boolean) owner to xfw3;


-- ============ sql/mock/generate_plan.sql ============
-- the output column follows the renamed table, so the old signature goes first
drop function if exists mock.generate_plan(date, text, text);

-- Stamps the day plan of a step from the weekly pattern (mock.material_impose_plan):
-- the plan (type material-resource-plan), one material lane per pattern row
-- with its pattern item, and one resource lane per machine the pattern rows
-- name (resource_path), so the resource board reads the same items per
-- machine (get_resource_plan, stap 7c). The material items stay on their
-- material lanes; the resource lane carries no items of its own.
create function mock.generate_plan(p_date date, p_step text, p_line_type text) returns TABLE(plan_id bigint, lane_id bigint, material_impose_plan_id bigint)
	language sql
as $$
    WITH pattern AS (
        SELECT DISTINCT ON (m.sort_order)
               m.material_impose_plan_id, m.sort_order, m.material_id,
               m.start_offset_in_seconds, m.is_pinned, m.resource_path, m.instance
        FROM mock.material_impose_plan m
        WHERE m.weekday = extract(dow FROM p_date)::smallint + 1
          AND m.step = p_step
          AND m.production_line_id IN (
                SELECT DISTINCT production_line_id
                FROM mock.material_print_schedule
                WHERE line = p_line_type)
        ORDER BY m.sort_order, m.moved_at DESC, m.material_impose_plan_id DESC
    ),
    numbered_pattern AS (
        SELECT p.*, row_number() OVER (ORDER BY p.sort_order) AS rn FROM pattern p
    ),
    -- the machines the pattern names: one resource lane each. One lane per
    -- machine per day (resource_lane): a lane that already exists for the
    -- date is reused, the others are made below
    resource AS (
        SELECT r.resource_path, rl.lane_id AS existing_lane_id
        FROM (SELECT DISTINCT p.resource_path FROM pattern p WHERE p.resource_path IS NOT NULL) r
        LEFT JOIN LATERAL (
            SELECT rl.lane_id
            FROM action.resource_lane rl
            JOIN action.lane l ON l.lane_id = rl.lane_id
            WHERE rl.resource_path = r.resource_path AND l.lane_date = p_date
            ORDER BY rl.lane_id LIMIT 1
        ) rl ON true
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
    -- group lanes: one fresh lane per pattern row, with the imposition group
    -- of the row on it (imposition_group_lane); the group ids were seeded 1:1
    -- from the material ids
    -- the lane carries its step and its impose path (site.line.impose.width)
    new_lane AS (
        INSERT INTO action.lane (lane_date, step, resource_path)
        SELECT p_date, p_step, subpath(p.resource_path, 0, 4)
        FROM numbered_pattern p
        ORDER BY p.rn
        RETURNING lane_id
    ),
    numbered_lane AS (
        SELECT nl.lane_id, row_number() OVER (ORDER BY nl.lane_id) AS rn FROM new_lane nl
    ),
    new_group_lane AS (
        INSERT INTO action.imposition_group_lane (lane_id, imposition_group_id)
        SELECT nl.lane_id, p.material_id
        FROM numbered_lane nl
        JOIN numbered_pattern p USING (rn)
        WHERE p.material_id IS NOT NULL
        RETURNING lane_id
    ),
    new_plan_lane AS (
        INSERT INTO action.plan_lane (plan_id, lane_id, sort_order)
        SELECT np.plan_id, nl.lane_id, p.sort_order
        FROM numbered_lane nl
        JOIN numbered_pattern p USING (rn)
        CROSS JOIN new_plan np
        RETURNING plan_id, lane_id, sort_order
    ),
    -- resource lanes: one fresh lane per machine without one; in the plan's
    -- order they follow the material lanes (plan_lane.sort_order is unique
    -- per plan)
    new_resource_lane_row AS (
        INSERT INTO action.lane (lane_date, step, resource_path)
        SELECT p_date, p_step, r.resource_path
        FROM numbered_resource r
        ORDER BY r.rn
        RETURNING lane_id
    ),
    numbered_resource_lane AS (
        SELECT nl.lane_id, row_number() OVER (ORDER BY nl.lane_id) AS rn FROM new_resource_lane_row nl
    ),
    new_resource_lane AS (
        INSERT INTO action.resource_lane (lane_id, resource_path)
        SELECT nl.lane_id, r.resource_path
        FROM numbered_resource_lane nl
        JOIN numbered_resource r USING (rn)
        RETURNING lane_id
    ),
    new_resource_plan_lane AS (
        INSERT INTO action.plan_lane (plan_id, lane_id, sort_order)
        SELECT np.plan_id, x.lane_id,
               coalesce((SELECT max(p.sort_order) FROM pattern p), 0) + 1000 + row_number() OVER (ORDER BY x.resource_path)
        FROM (SELECT nl.lane_id, r.resource_path
              FROM numbered_resource_lane nl
              JOIN numbered_resource r USING (rn)
              UNION ALL
              SELECT r.existing_lane_id, r.resource_path
              FROM resource r
              WHERE r.existing_lane_id IS NOT NULL) x
        CROSS JOIN new_plan np
        RETURNING lane_id
    ),
    -- one slot per lane, stamped from the pattern row: the planned moment
    -- the client moves, pins and copies. The pattern stays the template.
    new_lane_item AS (
        INSERT INTO action.lane_item
            (lane_id, sort_order, start_offset_in_seconds, is_pinned,
             no_split, type, source, source_ref, instance)
        SELECT nl.lane_id, p.sort_order, p.start_offset_in_seconds,
               coalesce(p.is_pinned, false), true, 'plan',
               'material-plan', p.material_impose_plan_id || ':' || p_date,
               p.instance
        FROM numbered_lane nl
        JOIN numbered_pattern p USING (rn)
        RETURNING lane_item_id, lane_id
    ),
    -- the imposition group of the slot, on the item (the group ids were
    -- seeded 1:1 from the material ids)
    new_imposition_group_lane_item AS (
        INSERT INTO action.imposition_group_lane_item (imposition_group_id, lane_item_id)
        SELECT p.material_id, nli.lane_item_id
        FROM new_lane_item nli
        JOIN numbered_lane nl ON nl.lane_id = nli.lane_id
        JOIN numbered_pattern p USING (rn)
        WHERE p.material_id IS NOT NULL
        RETURNING lane_item_id
    )
    -- No lane-to-pattern table any more: action.lane_item.source_ref carries
    -- <material_impose_plan_id>:<date>, so the link is on the item itself.
    -- The inserts above still run — a data-modifying CTE always executes,
    -- referenced or not.
    SELECT (SELECT plan_id FROM new_plan), npl.lane_id, p.material_impose_plan_id
    FROM new_plan_lane npl
    JOIN numbered_pattern p ON p.sort_order = npl.sort_order;
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

    -- ensure the machine-day lane of every active resource of the step: the
    -- lane and its resource_lane row, ids drawn up front so the two inserts
    -- pair without a temp table
    with missing as (
        select r.resource_path, r.step,
               nextval(pg_get_serial_sequence('action.lane', 'lane_id')) as lane_id
        from relation.resource r
        join relation.production_line pl on pl.line_id = r.line_id
        where r.active and r.resource_path is not null
          and r.step = p_step and pl.line_type = p_line_type
          and not exists (select 1
                          from action.lane l
                          join action.resource_lane rl on rl.lane_id = l.lane_id
                          where l.lane_date = p_date and rl.resource_path = r.resource_path)
    ),
    new_lane as (
        insert into action.lane (lane_id, lane_date, step, resource_path)
        overriding system value
        select m.lane_id, p_date, m.step, m.resource_path from missing m
        returning lane_id
    )
    insert into action.resource_lane (lane_id, resource_path)
    select m.lane_id, m.resource_path from missing m;

    -- hang them under the plan, in the order the resources carry
    return query
    insert into action.plan_lane (plan_id, lane_id, sort_order)
    select v_plan_id, l.lane_id,
           row_number() over (order by (r.resource_json ->> 'pv2_order')::numeric nulls last, r.resource_name)::numeric
    from relation.resource r
    join relation.production_line pl on pl.line_id = r.line_id
    join action.resource_lane rl on rl.resource_path = r.resource_path
    join action.lane l on l.lane_id = rl.lane_id and l.lane_date = p_date
    where r.active and r.resource_path is not null
      and r.step = p_step and pl.line_type = p_line_type
    returning plan_id, lane_id, sort_order;
end;
$$;

alter function mock.generate_production_plan(date, text, text) owner to xfw3;


COMMIT;

-- check: the writers compile against the new columns; expected one row each
SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE (n.nspname, p.proname) IN (('action', 'crud_lane_item_event'), ('legacy', 'crud_nest'),
                                 ('action', 'sync_pv2_batch_items'), ('action', 'crud_object'),
                                 ('action', 'crud_lane_item'), ('mock', 'generate_plan'),
                                 ('mock', 'generate_production_plan'))
ORDER BY 1;
