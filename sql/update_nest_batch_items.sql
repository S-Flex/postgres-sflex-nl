-- ============================================================
-- Stap 3b van docs/plan-lane-model.md: één batch per lane_item, plus de
-- hernoeming is_fixed_group -> fixed_group.
-- legacy.crud_nest picks the item of a nest per (lane, batch): the item whose
-- current set carries the batch, else an item without nests (the pattern item
-- first), else a new item (source 'nest', source_ref <lane_id>:<batch>, no time
-- of its own). The lane itself is chosen per material AND production line
-- (fix of 5 sep). action.get_plan_lanes shows batch items as moments, taking
-- material, line, tenant and resource from the lane's pattern item;
-- action.crud_lane_item writes through to the pattern only from a pattern item.
-- Rename: lane_item.is_fixed_group -> fixed_group (it is the delivery class,
-- text, not a boolean), the key in lookup_nest_moments, and the output column
-- of get_plan_lanes, get_impose_plan and get_production_plan. The data_groups
-- 75, 76, 78, 81 follow in sql/update_data_group_partial.sql (fixed_group,
-- fixed_group_field); the frontend reads fixed_group_field from now on.
-- Run sql/backfill_nest_lane_items.sql afterwards.
-- ============================================================

BEGIN;

-- 1. the rename
alter table action.lane_item rename column is_fixed_group to fixed_group;
comment on column action.lane_item.fixed_group is 'The delivery class (lookup_nest_moments.fixed_group) this moment is fixed to, null for a filler; only a fixed group or a pinned item carries a time of its own.';

update production.lookup l
set lookup_json = (select jsonb_agg((e.value - 'is_fixed_group')
                                    || case when e.value ? 'is_fixed_group'
                                            then jsonb_build_object('fixed_group', e.value -> 'is_fixed_group')
                                            else '{}'::jsonb end
                                    order by e.ord)
                   from jsonb_array_elements(l.lookup_json) with ordinality as e(value, ord))
where l.lookup = 'lookup_nest_moments'
  and l.lookup_json::text like '%is_fixed_group%';

-- 2. the functions
drop function if exists legacy.crud_nest(jsonb, boolean);
create function legacy.crud_nest(p_param_json jsonb, p_no_results boolean DEFAULT false) returns TABLE(param_id integer, track_by integer, crud text, domain_id integer, batch_id bigint, nest_id bigint, nest_counter integer, reproduced_counter integer, nest_name text, amount integer, width numeric, height numeric, nest_json jsonb, sort_order integer, status jsonb, possible_states bigint, possible_multiple_states bigint)
	language plpgsql
as $$
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
        -- the batch each level-0 item on those lanes carries today; null = no nests
        SELECT li.lane_item_id, li.lane_id, li.sort_order, li.source,
               (SELECT coalesce(n.batch_id, 0)
                FROM action.get_lane_item_impositions(li.lane_item_id) x
                JOIN legacy.nest n ON n.nest_id = x.imposition_id
                LIMIT 1) AS batch_key
        FROM action.lane_item li
        WHERE li.level = 0
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
        (lane_id, sort_order, start_offset_in_seconds, no_split, level, source, source_ref)
    SELECT bi.lane_id,
           (SELECT coalesce(max(li.sort_order), 0) FROM action.lane_item li WHERE li.lane_id = bi.lane_id)
             + 1000 * row_number() OVER (PARTITION BY bi.lane_id ORDER BY bi.batch_key),
           NULL, true, 0, 'nest', bi.lane_id || ':' || bi.batch_key
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
        SELECT lane_item_id, imposition_id, sort_order FROM kept
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

drop function if exists action.get_plan_lanes(timestamp with time zone, text, text, integer[], boolean, text, text[]);
-- One read for the lanes (labels) of every plan board: print_schedule,
-- impose_plan, impose_resource_plan, production_resource_plan and whatever
-- follows. Moved from mock to action: the lane model lives here.
--
-- Two modes, switched by p_steps:
--   * p_steps null — material lanes: one row per planned moment of the
--     newest plan of the day (p_plan_type), reached through
--     lane_item.source_ref (<material_impose_plan_id>:<date>), plus the
--     tenant noop windows. Feeds print_schedule and impose_plan
--     (imposition_group_id is the material_id alias until the xbom groups
--     arrive).
--   * p_steps set — resource lanes: one row per resource whose step is in
--     the list, line via path position 1, tenant via path position 0 (the
--     site abb). For a 'production-plan' the day's plan is the source: only
--     resources with a lane in that plan, lane_id and plan_lane.sort_order
--     ride along. For other plan types (impose: the material plan has no
--     resource lanes) every resource of the steps is a lane, lane_id null.
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
    IF p_steps IS NOT NULL THEN
        RETURN QUERY
        WITH tenant AS (
            SELECT (v.value ->> 'tenant_id')::integer AS tenant_id,
                   v.value ->> 'name'                 AS tenant_name,
                   v.value ->> 'abb'                  AS abb
            FROM relation.lookup lk
            CROSS JOIN LATERAL jsonb_array_elements(lk.lookup_json) AS v(value)
            WHERE lk.lookup = 'lookup_tenants'
        ),
        the_plan AS (
            -- the newest plan of this date, step, type and line type wins
            SELECT plan_id
            FROM action.plan
            WHERE plan_date = v_date AND p_step = ANY (steps)
              AND type = p_plan_type
              AND (p_line_type IS NULL OR line_type = p_line_type)
            ORDER BY plan_id DESC
            LIMIT 1
        ),
        plan_lane AS (
            -- the machine-day lanes of the plan; a group lane has no row here
            SELECT rl.lane_id, pl.sort_order, rl.resource_path
            FROM the_plan tp
            JOIN action.plan_lane pl USING (plan_id)
            JOIN action.resource_lane rl ON rl.lane_id = pl.lane_id
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
        WHERE r.step = ANY (p_steps)
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
        -- one row per planned moment; an extra moment is simply another item
        SELECT l.lane_id, li.lane_item_id, li.sort_order, li.is_pinned,
               li.start_offset_in_seconds,
               igli.imposition_group_id,
               -- the pattern row the item was stamped from: source_ref is
               -- <material_impose_plan_id>:<date>. A batch item (source
               -- 'nest', one per extra batch on the lane) has no pattern row
               -- of its own and borrows the one of the lane's pattern item,
               -- so material, line, tenant and resource come out the same
               CASE WHEN li.source = 'material-plan'
                    THEN nullif(split_part(li.source_ref, ':', 1), '')::bigint
                    ELSE (SELECT nullif(split_part(sib.source_ref, ':', 1), '')::bigint
                          FROM action.lane_item sib
                          WHERE sib.lane_id = li.lane_id AND sib.source = 'material-plan'
                          ORDER BY sib.sort_order LIMIT 1)
               END AS material_impose_plan_id
        FROM the_plan tp
        JOIN action.plan_lane l USING (plan_id)
        JOIN action.lane_item li ON li.lane_id = l.lane_id AND li.level = 0
        LEFT JOIN action.imposition_group_lane_item igli ON igli.lane_item_id = li.lane_item_id
        WHERE li.source IN ('material-plan', 'nest')
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

drop function if exists action.crud_lane_item(jsonb, boolean);
create function action.crud_lane_item(p_param_json jsonb, p_no_results boolean DEFAULT false) returns TABLE(param_id integer, track_by integer, crud text, lane_item_id bigint, lane_id bigint, material_impose_plan_id bigint)
	language sql
as $$
    -- The client mutations of the planning boards, on lane_item level. Every
    -- mutation writes through to mock.material_impose_plan, so re-stamping a
    -- plan reproduces what the planner did:
    --   update — move/pin/sort: the item and its pattern row
    --   create — an extra moment: a new pattern row with the next instance,
    --            plus the lane and the item it stamps to
    --   delete — the moment, its impositions and its pattern row
    --
    -- Set-based throughout: ids are drawn from the sequences up front, so a
    -- created row can be paired back to its payload row without a temp table.
    WITH payload AS (
        SELECT row_number() OVER ()::integer AS param_id,
               coalesce(te.track_by, 0)      AS track_by,
               te.crud, te.lane_item_id, te.lane_id, te.plan_id,
               te.start_offset_in_seconds, te.sort_order, te.is_pinned,
               te.imposition_group_id
        FROM jsonb_array_elements(p_param_json) AS t(element)
        CROSS JOIN LATERAL jsonb_to_record(t.element) AS te(
            track_by integer, crud text, lane_item_id bigint, lane_id bigint,
            plan_id bigint, start_offset_in_seconds integer, sort_order numeric,
            is_pinned boolean, imposition_group_id integer)
    ),
    -- what an update or a copy starts from: the item, its lane and the
    -- pattern row it was stamped from (source_ref is <mrp_id>:<date>)
    source AS (
        SELECT p.param_id,
               li.lane_item_id, li.lane_id, li.sort_order, li.start_offset_in_seconds,
               li.is_pinned, li.duration_in_seconds,
               l.lane_date,
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
    new_lane AS (
        INSERT INTO action.lane (lane_id, lane_date)
        OVERRIDING SYSTEM VALUE
        SELECT t.new_lane_id, t.lane_date
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
             duration_in_seconds, is_pinned, no_split, level, source, source_ref)
        OVERRIDING SYSTEM VALUE
        SELECT t.new_lane_item_id, t.lane_id,
               -- no rank from the client: append behind the lane, spread so a
               -- batch never collides on the unique (lane_id, sort_order)
               coalesce(t.sort_order,
                        (SELECT coalesce(max(li2.sort_order), 0)
                         FROM action.lane_item li2 WHERE li2.lane_id = t.lane_id)
                        + 1000 * row_number() OVER (ORDER BY t.param_id)),
               coalesce(t.start_offset_in_seconds, 0), 0,
               coalesce(t.is_pinned, false), true, 0,
               'material-plan',
               -- same shape generate_plan stamps, so the item stays idempotent
               t.new_pattern_id || ':' || t.lane_date
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
        -- the nests hung on this planned moment, if any: per lane item,
        -- not per lane — every extra moment carries its own nests. The
        -- reader gives the current set, inherited or own
        select b2.lane_item_id, array_agg(distinct x.imposition_id) as nest_ids
        from (select distinct lane_item_id from base where lane_item_id is not null) b2
        cross join lateral action.get_lane_item_impositions(b2.lane_item_id) x
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

drop function if exists mock.get_production_plan(timestamp with time zone, text, text, integer[], integer);
-- Stap 0 of docs/plan-lane-model.md: this mirror was a draft
-- (get_production_schedule on a table nest_lane_item that never existed); it
-- is now the live definition, with one change (stap 2): the impositions of an
-- item come from action.get_lane_item_impositions (current set, inherited or
-- own) instead of a direct read of action.imposition_lane_item.
CREATE OR REPLACE FUNCTION mock.get_production_plan(p_until timestamp with time zone DEFAULT now(), p_step text DEFAULT 'print'::text, p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_domain_id integer DEFAULT 1)
 RETURNS TABLE(tenant_id integer, tenant_name text, production_company_id integer, resource_uid text, resource_name text, resource_path ltree, lane_id bigint, step text, level integer, lane_item_id bigint, sort_order numeric, is_pinned boolean, no_split boolean, fixed_group text, start_offset_in_seconds integer, duration_in_seconds integer, start_at timestamp with time zone, end_at timestamp with time zone, nest_ids bigint[], nest_count integer, batch_id integer, batch_name text, material_id integer, material_name text, impact_json jsonb, sqm numeric, gross_sqm numeric, part_status_json jsonb, state_json jsonb, group_state_json jsonb, class_names text[], param_json jsonb)
 LANGUAGE plpgsql
 STABLE
 SET jit TO 'off'
AS $function$
#variable_conflict use_column
declare
    v_zone constant text := 'Europe/Amsterdam';
    -- the plan date is the day of the viewed moment; the axis of the board is
    -- that day's local midnight, offsets are seconds since then
    v_date       date := (p_until at time zone 'Europe/Amsterdam')::date;
    v_day_start  timestamp with time zone;
    v_day_end    timestamp with time zone;
    -- the open steps the plan side counts; a lookup later
    v_status_sequences constant integer[] := array[225, 290, 300, 350, 400, 450];
    -- print seconds per gross sqm at standard speed, and the shortest item; a lookup later
    v_standard_seconds_per_sqm constant numeric := 45;
    v_min_duration_in_seconds  constant integer := 900;
    -- legacy.nest width/height are in cm; a lookup later
    v_nest_size_per_sqm        constant numeric := 10000;
    v_state_lookup             jsonb;
begin
    select lk.lookup_json into v_state_lookup
    from relation.lookup lk where lk.lookup = 'lookup_resource_state';

    v_day_start := v_date::timestamp at time zone v_zone;
    v_day_end   := (v_date + 1)::timestamp at time zone v_zone;

    return query
    with the_plan as (
        -- the newest production plan of the day that covers the step
        select p.plan_id
        from action.plan p
        where p.plan_date = v_date
          and p.type = 'production-plan'
          and p_step = any (p.steps)
          and (p_line_type is null or p.line_type = p_line_type)
        order by p.plan_id desc
        limit 1
    ),
    tenant as (
        select (v.value ->> 'tenant_id')::integer             as tenant_id,
               v.value ->> 'name'                             as tenant_name,
               v.value ->> 'abb'                              as abb,
               (v.value ->> 'production_company_id')::integer as production_company_id
        from relation.lookup lk
        cross join lateral jsonb_array_elements(lk.lookup_json) as v(value)
        where lk.lookup = 'lookup_tenants'
    ),
    -- one lane = one machine's day; the live resource is found on its
    -- path, the tenant through its production line. Which machines a plan
    -- shows says plan_lane (a foil plan can carry a printer from the sheet
    -- hall; both boards share the lane and see its full occupation).
    lane as (
        select l.lane_id, pl_l.sort_order, rl.resource_path,
               r.resource_uid, r.resource_name, r.step,
               t.tenant_id, t.tenant_name, t.production_company_id
        from the_plan tp
        join action.plan_lane pl_l on pl_l.plan_id = tp.plan_id
        join action.lane l on l.lane_id = pl_l.lane_id
        join action.resource_lane rl on rl.lane_id = l.lane_id
        join relation.resource r on r.resource_path = rl.resource_path
        -- the site is the first label of the path: the tenant's abb (dk, bh)
        left join tenant t on t.abb = ltree2text(subpath(rl.resource_path, 0, 1))
        where (p_tenant_ids is null or t.tenant_id = any (p_tenant_ids))
    ),
    -- planned items with the nests hung on them
    item as (
        select li.lane_item_id, li.lane_id, li.sort_order, li.is_pinned, li.no_split,
               li.fixed_group, li.start_offset_in_seconds, li.duration_in_seconds, li.level,
               (select array_agg(distinct x.imposition_id)
                from action.get_lane_item_impositions(li.lane_item_id) x) as nest_ids
        from action.lane_item li
        join lane on lane.lane_id = li.lane_id
        where li.level = 0
    ),
    -- what the nests of an item say: the batch, the run (amount x area) and
    -- the least advanced status, which names the item's state
    item_nest as (
        select i.lane_item_id,
               min(n.batch_id)                                                          as batch_id,
               min(b.batch_name)                                                        as batch_name,
               sum(coalesce(n.amount, 1) * coalesce(n.width, 0) * coalesce(n.height, 0)) / v_nest_size_per_sqm as run_sqm,
               (array_agg(n.nest_json ->> 'internal_status_code' order by ist.sequence nulls last))[1] as internal_status_code
        from item i
        cross join lateral action.get_lane_item_impositions(i.lane_item_id) nli
        join legacy.nest n on n.nest_id = nli.imposition_id
        left join legacy.batch b on b.batch_id = n.batch_id
        left join mapping.internal_status ist on ist.code = n.nest_json ->> 'internal_status_code' and ist.domain_id = p_domain_id
        group by i.lane_item_id
    ),
    -- one aggregate call per distinct nest set (rows per material of the set)
    agg_rows as materialized (
        -- the aggregate has a nest_ids column of its own, so the set the call
        -- was made for gets its own name
        select ns.nest_ids as lane_nest_ids, a.*
        from (select distinct i.nest_ids from item i where i.nest_ids is not null) ns
        cross join lateral mapping.get_production_orderline_aggregate(
                 p_from             => p_until,
                 p_date_type        => 'nest',
                 p_nest_ids         => ns.nest_ids,
                 p_status_sequences => v_status_sequences,
                 p_is_open          => true,
                 p_domain_id        => p_domain_id) a
    ),
    -- summed over the materials of the set; the material is named when the
    -- set has one, else null
    item_agg as (
        select r.lane_nest_ids as nest_ids,
               sum(r.orderline_count)::integer as orderline_count,
               sum(r.sqm)                      as sqm,
               sum(r.gross_sqm)                as gross_sqm,
               jsonb_build_object(
                   'count',         sum((r.impact_json ->> 'count')::integer),
                   'amount',        sum((r.impact_json ->> 'amount')::numeric),
                   'sqm',           round(sum((r.impact_json ->> 'sqm')::numeric), 2),
                   'rework_count',  sum((r.impact_json ->> 'rework_count')::integer),
                   'rework_amount', sum((r.impact_json ->> 'rework_amount')::numeric),
                   'rework_sqm',    round(sum((r.impact_json ->> 'rework_sqm')::numeric), 2)) as impact_json,
               case when count(distinct r.material_id) = 1 then min(r.material_id) end   as material_id,
               case when count(distinct r.material_id) = 1 then min(r.material_name) end as material_name,
               -- the part statuses of the whole set, summed per status
               (select jsonb_agg(jsonb_build_object(
                           'sequence', x.sequence, 'internal_status_code', x.internal_status_code,
                           'class_names', x.class_names, 'i18n', x.i18n, 'amount', x.amount)
                        order by x.sequence)
                from (select (e.value ->> 'sequence')::integer   as sequence,
                             e.value ->> 'internal_status_code'  as internal_status_code,
                             e.value -> 'class_names'            as class_names,
                             e.value -> 'i18n'                   as i18n,
                             sum((e.value ->> 'amount')::numeric) as amount
                      from agg_rows b
                      cross join lateral jsonb_array_elements(b.part_status_json) as e(value)
                      where b.lane_nest_ids = r.lane_nest_ids
                      group by 1, 2, 3, 4) x)                                          as part_status_json,
               (select array_agg(distinct c order by c)
                from agg_rows b cross join lateral unnest(b.class_names) as c
                where b.lane_nest_ids = r.lane_nest_ids)                                as class_names
        from agg_rows r
        group by r.lane_nest_ids
    ),
    -- realized: the state blocks and the produced items of the lanes'
    -- resources, up to the viewed moment (the log functions clip to now())
    realized_state as (
        select s.resource_uid, s.state, s.group_state, s.start_at,
               s.duration_seconds, s.data, s.nest_name
        from log.get_resource_state(
                 (select array_agg(l.resource_uid) from lane l), v_day_start, least(p_until, v_day_end), null) s
    ),
    realized_produced as (
        select r.resource_uid, r.state, r.group_state, r.start_at,
               r.duration_seconds, r.data, r.nest_name
        from log.get_resource_produced(
                 (select array_agg(l.resource_uid) from lane l), v_day_start, least(p_until, v_day_end), null) r
    )
    -- planned rows: the lane's primary resource names the row
    select l.tenant_id, l.tenant_name, l.production_company_id,
           l.resource_uid, l.resource_name, l.resource_path, l.lane_id, l.step,
           i.level, i.lane_item_id, i.sort_order, i.is_pinned, i.no_split, i.fixed_group,
           i.start_offset_in_seconds,
           -- pv2's duration when it sent one, else the print time of the run
           -- (nest area x amount) at the resource's speed, never shorter
           -- than the minimum
           case when i.duration_in_seconds > 0 then i.duration_in_seconds
                else greatest(ceil(coalesce(nf.run_sqm, 0) * v_standard_seconds_per_sqm
                                   / coalesce(nullif(mock.get_resource_speed_factor(ag.material_id, l.resource_uid), 0), 1))::integer,
                              v_min_duration_in_seconds) end,
           v_day_start + make_interval(secs => i.start_offset_in_seconds),
           null::timestamp with time zone,
           coalesce(i.nest_ids, '{}'::bigint[]),
           coalesce(cardinality(i.nest_ids), 0),
           nf.batch_id, nf.batch_name,
           ag.material_id, ag.material_name,
           ag.impact_json, ag.sqm, ag.gross_sqm,
           coalesce(ag.part_status_json, '[]'::jsonb),
           -- the state of a planned item is the least advanced status of its
           -- nests, from the same lookup the realized rows use
           (select st.value from jsonb_array_elements(v_state_lookup) as ss(value)
                                 cross join lateral jsonb_array_elements(ss.value -> 'states') as st(value)
             where st.value ->> 'code' = coalesce(nf.internal_status_code, 'batch') limit 1),
           (select ss.value - 'states' from jsonb_array_elements(v_state_lookup) as ss(value)
                                       cross join lateral jsonb_array_elements(ss.value -> 'states') as st(value)
             where st.value ->> 'code' = coalesce(nf.internal_status_code, 'batch') limit 1),
           coalesce(ag.class_names, '{}'::text[]),
           jsonb_build_object(
               'standard_production_impact_in_seconds', ceil(coalesce(nf.run_sqm, 0) * v_standard_seconds_per_sqm)::integer,
               'run_sqm',                                round(coalesce(nf.run_sqm, 0), 2),
               'speed_factor',                           mock.get_resource_speed_factor(ag.material_id, l.resource_uid),
               'orderline_count',                        ag.orderline_count)
    from item i
    join lane l on l.lane_id = i.lane_id
    left join item_nest nf on nf.lane_item_id = i.lane_item_id
    left join item_agg ag on ag.nest_ids = i.nest_ids

    union all
    -- realized: state blocks, named by the resource that ran
    select l.tenant_id, l.tenant_name, l.production_company_id,
           l.resource_uid, l.resource_name, l.resource_path, l.lane_id, l.step,
           1, null::bigint, null::numeric, false, false, null::text,
           extract(epoch from (rs.start_at - v_day_start))::integer,
           rs.duration_seconds::integer,
           rs.start_at,
           rs.start_at + make_interval(secs => rs.duration_seconds),
           '{}'::bigint[], 0,
           null::integer, null::text,
           null::integer, null::text,
           null::jsonb, null::numeric, null::numeric,
           '[]'::jsonb,
           rs.state, rs.group_state,
           array_remove(array[rs.state ->> 'class_name'], null),
           coalesce(rs.data, '{}'::jsonb)
    from realized_state rs
    join lane l on l.resource_uid = rs.resource_uid

    union all
    -- realized: produced items, named by the resource that ran
    select l.tenant_id, l.tenant_name, l.production_company_id,
           l.resource_uid, l.resource_name, l.resource_path, l.lane_id, l.step,
           1, null::bigint, null::numeric, false, false, null::text,
           extract(epoch from (rp.start_at - v_day_start))::integer,
           rp.duration_seconds::integer,
           rp.start_at,
           rp.start_at + make_interval(secs => coalesce(rp.duration_seconds, 0)),
           case when (rp.data ->> 'nest_id') is not null then array[(rp.data ->> 'nest_id')::bigint] else '{}'::bigint[] end,
           case when (rp.data ->> 'nest_id') is not null then 1 else 0 end,
           (rp.data ->> 'batch_id')::integer, null::text,
           null::integer, null::text,
           null::jsonb, null::numeric, null::numeric,
           '[]'::jsonb,
           rp.state, rp.group_state,
           array_remove(array[rp.state ->> 'class_name', 'realized-produced'], null),
           coalesce(rp.data, '{}'::jsonb) || jsonb_build_object('nest_name', rp.nest_name)
    from realized_produced rp
    join lane l on l.resource_uid = rp.resource_uid

    order by tenant_id, resource_path, level, start_offset_in_seconds, sort_order;
end;
$function$

alter function mock.get_production_plan(timestamp with time zone, text, text, integer[], integer) owner to xfw3;

COMMIT;

-- check 1: the labels of the material boards are unchanged until the backfill
-- runs (no batch items exist yet); expected: 67 and 48 rows on 2026-09-04,
-- with fixed_group filled on the class rows
SELECT count(*) AS labels_75, count(fixed_group) AS with_fixed_group FROM action.get_plan_lanes('2026-09-04 10:00+02', 'print', 'sheet', NULL, false, 'material-resource-plan', NULL);
SELECT count(*) AS labels_76, count(fixed_group) AS with_fixed_group FROM action.get_plan_lanes('2026-09-04 10:00+02', 'print', 'sheet', NULL, true, 'material-resource-plan', NULL);

-- check 2: nothing mentions the old name any more; expected: 0
SELECT count(*) AS functions_with_old_name
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE p.prokind = 'f' AND n.nspname IN ('action', 'mock', 'legacy', 'mapping', 'site')
  AND pg_get_functiondef(p.oid) LIKE '%is_fixed_group%';
