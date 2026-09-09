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
    v_pv2_items     bigint[];
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

        IF rec.crud IN ('create','merge') THEN
            INSERT INTO legacy.nest (
                batch_uid, domain_id, nest_id, nest_counter, reproduced_counter,
                nest_name, amount, width, height, nest_json, sort_order,
                status_json, possible_states, possible_multiple_states, nested_at, updated_at
            ) VALUES (
                v_batch_uid, rec.domain_id, rec.nest_id, rec.nest_counter, rec.reproduced_counter,
                rec.nest_name, rec.amount, rec.width, rec.height,
                -- never insert a bare NULL into nest_json
                COALESCE(rec.nest_json, '{}'::jsonb),
                rec.sort_order,
                rec.status, rec.possible_states, rec.possible_multiple_states, rec.nest_date, rec.updated_at
            )
            ON CONFLICT ON CONSTRAINT uq_nest_id DO UPDATE
                SET batch_uid                = EXCLUDED.batch_uid,
                    nest_name                = EXCLUDED.nest_name,
                    amount                   = EXCLUDED.amount,
                    width                    = EXCLUDED.width,
                    height                   = EXCLUDED.height,
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

        ELSIF rec.crud = 'update' THEN
            UPDATE legacy.nest n
            SET
                batch_uid                = v_batch_uid,
                -- merge instead of replace, same reasoning as the create/merge branch above
                nest_json                = COALESCE(n.nest_json, '{}'::jsonb)
                                            || COALESCE(rec.nest_json, '{}'::jsonb),
                sort_order               = rec.sort_order,
                status_json              = rec.status,
                possible_states          = rec.possible_states,
                possible_multiple_states = rec.possible_multiple_states,
                nested_at                = rec.nest_date,
                updated_at               = rec.updated_at
            WHERE n.nest_id = rec.nest_id;
        END IF;
    END LOOP;

    UPDATE legacy.nest n
    SET batch_uid = b.batch_uid
    FROM legacy.batch b
    WHERE n.batch_uid IS NULL
      AND b.batch_id = (n.nest_json ->> 'batch_id')::integer;

    -- ── nest → lane item (docs/nest-planning-lane-items.md §3) ─────────
    -- Every nest hangs on a lane item of the material-resource-plan of its
    -- day: plan → plan_lane → lane (the material lane) → lane_item. The
    -- item picked is the latest one starting at or before the nest moment
    -- (the stamped items are 0-duration moments, so a covering-window match
    -- would never hit), else the first of the day. Durations are never
    -- stored here: the boards derive them at read time — nests from
    -- width × height × sum(amount), the future from the aggregate and the
    -- material sizes in line_json.specs.
    CREATE TEMP TABLE nest_link ON COMMIT DROP AS
    WITH payload AS (
        SELECT pt.nest_id, pt.sort_order,
               (n.nest_json ->> 'material_id')::integer        AS material_id,
               (n.nest_json ->> 'production_line_id')::integer AS production_line_id,
               (COALESCE(pt.nest_date, n.nested_at) AT TIME ZONE 'Europe/Amsterdam')::date AS plan_date,
               extract(epoch FROM (COALESCE(pt.nest_date, n.nested_at) AT TIME ZONE 'Europe/Amsterdam')::time)::integer AS nest_seconds,
               lower(COALESCE(n.nest_json ->> 'status', '')) LIKE 'cancel%' AS is_cancelled,
               -- one batch per lane item; a nest without a batch is its own group
               coalesce(n.batch_id, 0) AS batch_key
        FROM param_table pt
        JOIN legacy.nest n ON n.nest_id = pt.nest_id
        WHERE pt.crud IN ('create', 'merge', 'update')
    )
    SELECT p.nest_id, p.sort_order, p.nest_seconds, p.is_cancelled, p.batch_key,
           lane.lane_id
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
        -- the lane of the nest material on that plan: the group lane.
        -- imposition_group_id acts as an alias of material_id for now (the
        -- groups were seeded 1:1 from the material ids); later the nests
        -- resolve their real imposition group here.
        -- The plan carries both tenants, so a material has one lane per
        -- production line; the line of the nest decides which one. The line
        -- of a lane sits on the pattern row its item was stamped from
        -- (source_ref = <material_impose_plan_id>:<date>). Before this, the
        -- first lane won and 1.338 nests of the other line landed on the
        -- wrong tenant's item (24 aug - 4 sep).
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
    ) lane ON true;

    -- ── one batch per lane item (docs/plan-lane-model.md stap 3b) ────────
    -- Per (lane, batch) one item: the item whose current set carries the
    -- batch; else an item without nests (the pattern item first, then by
    -- sort_order), handed out one per batch; else a new item, source 'nest',
    -- source_ref <lane_id>:<batch>, no time of its own (a filler the client
    -- chains), no_split. A nest that gets its batch later moves from the
    -- null-batch item to the batch item through the set write below.
    CREATE TEMP TABLE batch_item ON COMMIT DROP AS
    WITH need AS (
        SELECT DISTINCT ns.lane_id, ns.batch_key
        FROM nest_link ns
        WHERE ns.lane_id IS NOT NULL AND NOT ns.is_cancelled
    ),
    item_batch AS (
        -- the batch each plan item on those lanes carries today, the payload
        -- nests not counted: they are placed anew below. Counted, a nest that
        -- just got its batch made its own item look like the item of that
        -- batch, so it stayed put and the item mixed two batches (6 sep).
        -- null = no other nests
        SELECT li.lane_item_id, li.lane_id, li.sort_order, li.source,
               (SELECT coalesce(n.batch_id, 0)
                FROM action.get_lane_item_impositions(li.lane_item_id) x
                JOIN legacy.nest n ON n.nest_id = x.imposition_id
                WHERE x.imposition_id NOT IN (SELECT ns.nest_id FROM nest_link ns)
                LIMIT 1) AS batch_key
        FROM action.lane_item li
        WHERE li.type = 'plan'
          AND li.lane_id IN (SELECT nd.lane_id FROM need nd)
    ),
    by_batch AS (
        SELECT nd.lane_id, nd.batch_key, min(ib.lane_item_id) AS lane_item_id
        FROM need nd
        JOIN item_batch ib ON ib.lane_id = nd.lane_id AND ib.batch_key = nd.batch_key
        GROUP BY nd.lane_id, nd.batch_key
    ),
    free_item AS (
        SELECT ib.lane_id, ib.lane_item_id,
               row_number() OVER (PARTITION BY ib.lane_id
                                  ORDER BY (ib.source = 'material-plan') DESC, ib.sort_order, ib.lane_item_id) AS rn
        FROM item_batch ib
        WHERE ib.batch_key IS NULL
    ),
    needs_item AS (
        SELECT nd.lane_id, nd.batch_key,
               row_number() OVER (PARTITION BY nd.lane_id ORDER BY nd.batch_key) AS rn
        FROM need nd
        WHERE NOT EXISTS (SELECT 1 FROM by_batch bb
                          WHERE bb.lane_id = nd.lane_id AND bb.batch_key = nd.batch_key)
    )
    SELECT bb.lane_id, bb.batch_key, bb.lane_item_id
    FROM by_batch bb
    UNION ALL
    SELECT ni.lane_id, ni.batch_key, fi.lane_item_id
    FROM needs_item ni
    LEFT JOIN free_item fi ON fi.lane_id = ni.lane_id AND fi.rn = ni.rn;

    -- the batches without an item get one, behind the existing items of the lane
    INSERT INTO action.lane_item
        (lane_id, sort_order, start_offset_in_seconds, no_split, type, source, source_ref)
    SELECT bi.lane_id,
           -- behind the pattern item of the lane, inside the gap of 100 the pattern
           -- rows leave: the order is unique per plan, not only per lane (the
           -- material boards order within the tenant, across lanes)
           coalesce((SELECT pat.sort_order FROM action.lane_item pat
                     WHERE pat.lane_id = bi.lane_id AND pat.source = 'material-plan'
                     ORDER BY pat.sort_order LIMIT 1),
                    (SELECT coalesce(max(li.sort_order), 0) FROM action.lane_item li WHERE li.lane_id = bi.lane_id))
             + (SELECT count(*) FROM action.lane_item li WHERE li.lane_id = bi.lane_id AND li.source = 'nest')
             + row_number() OVER (PARTITION BY bi.lane_id ORDER BY bi.batch_key),
           NULL, true, 'plan', 'nest', bi.lane_id || ':' || bi.batch_key
    FROM batch_item bi
    WHERE bi.lane_item_id IS NULL
    ON CONFLICT ON CONSTRAINT lane_item_source_ref_uq DO NOTHING;

    UPDATE batch_item bi
    SET lane_item_id = li.lane_item_id
    FROM action.lane_item li
    WHERE bi.lane_item_id IS NULL
      AND li.source = 'nest' AND li.source_ref = bi.lane_id || ':' || bi.batch_key;

    -- a new item carries the group of its lane, like a pattern item does
    INSERT INTO action.imposition_group_lane_item (imposition_group_id, lane_item_id)
    SELECT igl.imposition_group_id, bi.lane_item_id
    FROM batch_item bi
    JOIN action.imposition_group_lane igl ON igl.lane_id = bi.lane_id
    WHERE NOT EXISTS (SELECT 1 FROM action.imposition_group_lane_item g WHERE g.lane_item_id = bi.lane_item_id)
    ON CONFLICT DO NOTHING;

    -- The material-lane sets are append-only (docs/plan-lane-model.md stap
    -- 2): every item a payload nest leaves or joins gets its set written
    -- anew — the current set minus the payload nests, plus the payload nests
    -- that land on it. An item left without impositions gets the explicit
    -- empty set (one row, imposition_id null), so it does not fall back to
    -- inheriting. The pv2 machine links belong to action.crud_object and
    -- stay untouched. Cancelled nests only leave. No plan or lane for the
    -- day: no link, never an invented lane — the backfill catches it later.
    WITH target AS (
        SELECT ns.nest_id, ns.sort_order, bi.lane_item_id
        FROM nest_link ns
        JOIN batch_item bi ON bi.lane_id = ns.lane_id AND bi.batch_key = ns.batch_key
        WHERE NOT ns.is_cancelled
          AND bi.lane_item_id IS NOT NULL
    ),
    -- the material-lane items that hold a payload nest today, plus the
    -- items the payload lands on
    touched AS (
        SELECT DISTINCT i.lane_item_id
        FROM action.imposition_lane_item i
        JOIN action.lane_item li ON li.lane_item_id = i.lane_item_id
        WHERE li.source IN ('material-plan', 'nest')
          AND i.imposition_id IN (SELECT ns.nest_id FROM nest_link ns)
          AND i.moved_at = (SELECT max(x.moved_at) FROM action.imposition_lane_item x
                            WHERE x.lane_item_id = i.lane_item_id)
        UNION
        SELECT t.lane_item_id FROM target t
    ),
    -- the current set of those items, without the payload nests
    kept AS (
        SELECT i.lane_item_id, i.imposition_id, i.sort_order
        FROM action.imposition_lane_item i
        JOIN touched t ON t.lane_item_id = i.lane_item_id
        WHERE i.imposition_id IS NOT NULL
          AND i.imposition_id NOT IN (SELECT ns.nest_id FROM nest_link ns)
          AND i.moved_at = (SELECT max(x.moved_at) FROM action.imposition_lane_item x
                            WHERE x.lane_item_id = i.lane_item_id)
    ),
    new_set AS (
        SELECT k.lane_item_id, k.imposition_id, k.sort_order FROM kept k
        UNION ALL
        SELECT t.lane_item_id, t.nest_id, t.sort_order FROM target t
    )
    INSERT INTO action.imposition_lane_item (lane_item_id, imposition_id, sort_order)
    SELECT n.lane_item_id, n.imposition_id, n.sort_order
    FROM new_set n
    UNION ALL
    SELECT t.lane_item_id, NULL, NULL
    FROM touched t
    WHERE NOT EXISTS (SELECT 1 FROM new_set n WHERE n.lane_item_id = t.lane_item_id);

    -- ── pv2 items (docs/plan-lane-model.md stap 3b) ──────────────────
    -- A nest that gets its batch here may sit on a pv2 item of another
    -- batch; action.sync_pv2_batch_items moves it to the extra item of that
    -- batch (a nest without a batch counts as the item's own). Called for
    -- the plannable items whose current set holds a payload nest.
    v_pv2_items := array(
        SELECT DISTINCT split_part(li.source_ref, ':', 1)::bigint
        FROM action.imposition_lane_item i
        JOIN action.lane_item li ON li.lane_item_id = i.lane_item_id
        WHERE li.source = 'pv2'
          AND i.imposition_id IN (SELECT ns.nest_id FROM nest_link ns));
    IF cardinality(v_pv2_items) > 0 THEN
        PERFORM action.sync_pv2_batch_items(v_pv2_items);
    END IF;

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

