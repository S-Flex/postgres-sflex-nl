-- Sheet nests are as large as their sheet (15 Sep 2026): on a production line
-- where the material has material_media_type_id 1 (mapping.material_production_line
-- line_json), legacy.nest.width and height are the material_width and
-- material_height of nest_json, not the nested area.
--   1. legacy.crud_nest takes them from the payload from now on (a child
--      imposition group looks at its parent's mapping).
--   2. the table: every sheet nest that differs is set, per production line,
--      with a notice per line.
-- The preview at the top shows how many nests differ today.
-- Rollback: sql/update_nest_sheet_size_down.sql (the function; the sizes are not restored).

-- ============ preview ============
SELECT pl.line, count(*) AS nests_to_change,
       min((n.nested_at AT TIME ZONE 'Europe/Amsterdam')::date) AS first_day,
       max((n.nested_at AT TIME ZONE 'Europe/Amsterdam')::date) AS last_day
FROM legacy.nest n
JOIN mapping.material_production_line m
  ON m.production_line_id = (n.nest_json ->> 'production_line_id')::integer
LEFT JOIN legacy.imposition_group g ON g.parent_imposition_group_id = m.material_id
JOIN relation.production_line pl ON pl.line_id = m.production_line_id
WHERE m.line_json ->> 'material_media_type_id' = '1'
  AND (n.nest_json ->> 'material_id')::integer IN (m.material_id, g.imposition_group_id)
  AND n.nest_json ->> 'material_width' IS NOT NULL
  AND n.nest_json ->> 'material_height' IS NOT NULL
  AND (n.width  IS DISTINCT FROM (n.nest_json ->> 'material_width')::numeric(10,1)
    OR n.height IS DISTINCT FROM (n.nest_json ->> 'material_height')::numeric(10,1))
GROUP BY pl.line
ORDER BY pl.line;

BEGIN;

-- ============ sql/legacy/crud_nest.sql ============
-- same signature, dropped first so the script re-runs
-- A sheet nest (material_media_type_id 1 on the material's production line,
-- mapping.material_production_line.line_json) is as large as its sheet: width
-- and height take material_width and material_height of the payload, not the
-- nested area (15 Sep 2026; sql/update_nest_sheet_size.sql backfilled the table).
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
        CASE WHEN mpl.line_json ->> 'material_media_type_id' = '1' AND t.element ->> 'material_width' IS NOT NULL
             THEN (t.element ->> 'material_width')::numeric
             ELSE te.width END::numeric(10,1)  AS width,
        CASE WHEN mpl.line_json ->> 'material_media_type_id' = '1' AND t.element ->> 'material_height' IS NOT NULL
             THEN (t.element ->> 'material_height')::numeric
             ELSE te.height END::numeric(10,1) AS height,
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
    )
    -- the material on the nest's production line: the material itself, else
    -- the parent of a child imposition group
    LEFT JOIN legacy.imposition_group g
           ON g.imposition_group_id = (t.element ->> 'material_id')::integer
    LEFT JOIN LATERAL (
        SELECT m.line_json
        FROM mapping.material_production_line m
        WHERE m.production_line_id = (t.element ->> 'production_line_id')::integer
          AND m.material_id IN ((t.element ->> 'material_id')::integer, g.parent_imposition_group_id)
        ORDER BY (m.material_id = (t.element ->> 'material_id')::integer) DESC
        LIMIT 1
    ) mpl ON true;

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
            -- sits on the schedule row its items were stamped from
            -- (source_ref <material_print_schedule_id>:<date>:<instance>)
            SELECT igl.lane_id
            FROM action.plan_lane apl
            JOIN action.imposition_group_lane igl ON igl.lane_id = apl.lane_id
            JOIN action.lane_item li2 ON li2.lane_id = igl.lane_id AND li2.source = 'material-plan'
            JOIN mock.material_print_schedule mps
              ON mps.material_print_schedule_id = nullif(split_part(li2.source_ref, ':', 1), '')::bigint
            WHERE apl.plan_id = tp.plan_id
              AND igl.imposition_group_id = p.material_id
              AND mps.production_line_id = p.production_line_id
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
        -- items released at the same moment (the midnight release of the
        -- testing phase): the first moment of the day takes the nests
        ORDER BY e.moved_at DESC, li.instance, e.lane_item_event_id DESC
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

-- ============ the table: every sheet nest as large as its sheet ============
-- expected: the number of nests changed, per production line
DO $do$
DECLARE
    v_line record;
    v_rows integer;
BEGIN
    FOR v_line IN
        SELECT DISTINCT m.production_line_id, pl.line
        FROM mapping.material_production_line m
        JOIN relation.production_line pl ON pl.line_id = m.production_line_id
        WHERE m.line_json ->> 'material_media_type_id' = '1'
        ORDER BY pl.line
    LOOP
        UPDATE legacy.nest n
        SET width  = (n.nest_json ->> 'material_width')::numeric(10,1),
            height = (n.nest_json ->> 'material_height')::numeric(10,1)
        FROM mapping.material_production_line m
        LEFT JOIN legacy.imposition_group g ON g.parent_imposition_group_id = m.material_id
        WHERE m.production_line_id = v_line.production_line_id
          AND m.line_json ->> 'material_media_type_id' = '1'
          AND (n.nest_json ->> 'production_line_id')::integer = m.production_line_id
          AND (n.nest_json ->> 'material_id')::integer IN (m.material_id, g.imposition_group_id)
          AND n.nest_json ->> 'material_width' IS NOT NULL
          AND n.nest_json ->> 'material_height' IS NOT NULL
          AND (n.width  IS DISTINCT FROM (n.nest_json ->> 'material_width')::numeric(10,1)
            OR n.height IS DISTINCT FROM (n.nest_json ->> 'material_height')::numeric(10,1));
        GET DIAGNOSTICS v_rows = ROW_COUNT;
        RAISE NOTICE 'nest sheet size % : % nests', v_line.line, v_rows;
    END LOOP;
END
$do$;

COMMIT;

-- expected: no sheet nest left whose size differs from its sheet
SELECT count(*) AS still_different
FROM legacy.nest n
JOIN mapping.material_production_line m
  ON m.production_line_id = (n.nest_json ->> 'production_line_id')::integer
LEFT JOIN legacy.imposition_group g ON g.parent_imposition_group_id = m.material_id
WHERE m.line_json ->> 'material_media_type_id' = '1'
  AND (n.nest_json ->> 'material_id')::integer IN (m.material_id, g.imposition_group_id)
  AND n.nest_json ->> 'material_width' IS NOT NULL
  AND (n.width  IS DISTINCT FROM (n.nest_json ->> 'material_width')::numeric(10,1)
    OR n.height IS DISTINCT FROM (n.nest_json ->> 'material_height')::numeric(10,1));
