-- ============================================================
-- Stap 0 + 2 van docs/plan-lane-model.md.
-- action.imposition_lane_item becomes append-only: own id, moved_at, nullable
-- imposition_id (one null row = the empty set), indexes on (lane_item_id,
-- moved_at desc) and imposition_id. The 38.792 existing rows become the first
-- set of their item (one shared moved_at). action.get_lane_item_impositions
-- reads the current set, inherited through lane_item_dependency when an item
-- has none of its own; action.crud_imposition_lane_item writes a set.
-- legacy.crud_nest appends the new sets of the items a nest leaves or joins;
-- mock.get_impose_plan and mock.get_production_plan read through the function.
-- action.crud_object (pv2) and action.crud_lane_item keep their delete +
-- insert: they replace the set of an item they own, which stays correct.
-- ============================================================

BEGIN;

-- 1. the table
ALTER TABLE action.imposition_lane_item
    ADD COLUMN imposition_lane_item_id bigint GENERATED ALWAYS AS IDENTITY,
    ADD COLUMN moved_at timestamp with time zone NOT NULL DEFAULT now();
ALTER TABLE action.imposition_lane_item DROP CONSTRAINT imposition_lane_item_pk;
ALTER TABLE action.imposition_lane_item ADD CONSTRAINT imposition_lane_item_pkey PRIMARY KEY (imposition_lane_item_id);
ALTER TABLE action.imposition_lane_item ALTER COLUMN imposition_id DROP NOT NULL;
DROP INDEX IF EXISTS action.ix_imposition_lane_item_lane_item_id;
CREATE INDEX idx_imposition_lane_item_lane_item_moved ON action.imposition_lane_item (lane_item_id, moved_at DESC);
CREATE INDEX idx_imposition_lane_item_imposition_id ON action.imposition_lane_item (imposition_id);
COMMENT ON TABLE action.imposition_lane_item IS 'Membership of impositions in lane items, append-only and written on change only: first step, split, merge. The most recent write per lane_item is the set; no rows means: the same set as the predecessor (lane_item_dependency); one row with imposition_id null means: empty on purpose.';

-- 2. the reader and the writer
create function action.get_lane_item_impositions(p_lane_item_id bigint, p_as_of timestamp with time zone DEFAULT now()) returns TABLE(imposition_id bigint, sort_order numeric)
	stable
	language sql
as $$
    -- Impositions in a lane_item, at any moment. Walks up the dependency chain
    -- (to -> from, towards the predecessor) until it reaches a lane_item that
    -- carries its own set; a lane_item without rows inherits from the step
    -- before it, a merge collects both branches. A set written as one row
    -- with imposition_id null is the empty set: it stops the walk and yields
    -- nothing.
    with recursive up as (
        select p_lane_item_id as lane_item_id
        union all
        select d.from_lane_item_id
        from up
        join action.lane_item_dependency d
          on d.to_lane_item_id = up.lane_item_id
        where not exists (
            select 1 from action.imposition_lane_item i
            where i.lane_item_id = up.lane_item_id
              and i.moved_at <= p_as_of)
    )
    select distinct on (i.imposition_id) i.imposition_id, i.sort_order
    from up
    join action.imposition_lane_item i
      on i.lane_item_id = up.lane_item_id
    where i.moved_at <= p_as_of
      and i.imposition_id is not null
      -- only the most recent write per lane_item counts: a lane_item that is
      -- split again later gets a new set, the older one stays as history
      and i.moved_at = (
          select max(x.moved_at)
          from action.imposition_lane_item x
          where x.lane_item_id = i.lane_item_id
            and x.moved_at <= p_as_of)
    order by i.imposition_id, i.sort_order;
$$;

alter function action.get_lane_item_impositions(bigint, timestamp with time zone) owner to xfw3;

create function action.crud_imposition_lane_item(p_param_json jsonb, p_no_results boolean DEFAULT false) returns TABLE(imposition_lane_item_id bigint, lane_item_id bigint, imposition_id bigint, sort_order numeric, moved_at timestamp with time zone)
	language sql
as $$
    -- Write the set of a lane_item: called at the first step and on a split
    -- or merge, never for a step that keeps the same set. Every row of one
    -- call shares moved_at, so get_lane_item_impositions sees them as one
    -- set. An element with imposition_id null writes the empty set.
    with inserted as (
        insert into action.imposition_lane_item (lane_item_id, imposition_id, sort_order)
        select (el ->> 'lane_item_id')::bigint,
               (el ->> 'imposition_id')::bigint,
               (el ->> 'sort_order')::numeric
        from jsonb_array_elements(p_param_json) as el
        returning imposition_lane_item_id, lane_item_id, imposition_id, sort_order, moved_at
    )
    select * from inserted where not p_no_results;
$$;

alter function action.crud_imposition_lane_item(jsonb, boolean) owner to xfw3;

-- 3. the functions that write or read the sets
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
               lower(COALESCE(n.nest_json ->> 'status', '')) LIKE 'cancel%' AS is_cancelled
        FROM param_table pt
        JOIN legacy.nest n ON n.nest_id = pt.nest_id
        WHERE pt.crud IN ('create', 'merge', 'update')
    )
    SELECT p.nest_id, p.sort_order, p.nest_seconds, p.is_cancelled,
           lane.lane_id, item.lane_item_id
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
        -- the lane of the nest material on that plan, through the group
        -- link of its lane items. imposition_group_id acts as an alias of
        -- material_id for now (the groups were seeded 1:1 from the material
        -- ids); later the nests resolve their real imposition group here.
        SELECT l.lane_id
        FROM action.plan_lane apl
        JOIN action.lane l ON l.lane_id = apl.lane_id
        JOIN action.lane_item li2 ON li2.lane_id = l.lane_id
        JOIN action.imposition_group_lane_item igli ON igli.lane_item_id = li2.lane_item_id
        WHERE apl.plan_id = tp.plan_id
          AND igli.imposition_group_id = p.material_id
        LIMIT 1
    ) lane ON true
    LEFT JOIN LATERAL (
        SELECT li.lane_item_id
        FROM action.lane_item li
        WHERE li.lane_id = lane.lane_id
          AND li.level = 0
        ORDER BY (COALESCE(li.start_offset_in_seconds, 0) <= p.nest_seconds) DESC,
                 CASE WHEN COALESCE(li.start_offset_in_seconds, 0) <= p.nest_seconds
                      THEN -COALESCE(li.start_offset_in_seconds, 0)
                      ELSE COALESCE(li.start_offset_in_seconds, 0) END
        LIMIT 1
    ) item ON true;

    -- lane found but no lane item at all: create one for this nest
    INSERT INTO action.lane_item
        (lane_id, sort_order, start_offset_in_seconds, no_split, level, source, source_ref)
    SELECT ns.lane_id, -1 * ns.nest_id, ns.nest_seconds, true, 0, 'nest', ns.nest_id::text
    FROM nest_link ns
    WHERE ns.lane_item_id IS NULL
      AND ns.lane_id IS NOT NULL
      AND NOT ns.is_cancelled
    ON CONFLICT ON CONSTRAINT lane_item_source_ref_uq DO NOTHING;

    -- The material-lane sets are append-only (docs/plan-lane-model.md stap
    -- 2): every item a payload nest leaves or joins gets its set written
    -- anew — the current set minus the payload nests, plus the payload nests
    -- that land on it. An item left without impositions gets the explicit
    -- empty set (one row, imposition_id null), so it does not fall back to
    -- inheriting. The pv2 machine links belong to action.crud_object and
    -- stay untouched. Cancelled nests only leave. No plan or lane for the
    -- day: no link, never an invented lane — the backfill catches it later.
    WITH target AS (
        SELECT ns.nest_id, ns.sort_order,
               COALESCE(ns.lane_item_id, own.lane_item_id) AS lane_item_id
        FROM nest_link ns
        LEFT JOIN action.lane_item own
               ON own.source = 'nest' AND own.source_ref = ns.nest_id::text
        WHERE NOT ns.is_cancelled
          AND COALESCE(ns.lane_item_id, own.lane_item_id) IS NOT NULL
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

-- renamed from mock.get_nest_schedule (via get_imposition_plan); impose is
-- the step, imposition the object it produces
drop function if exists mock.get_nest_schedule(timestamp with time zone, text, text, integer[], boolean, integer, integer, integer);
drop function if exists mock.get_nest_schedule(timestamp with time zone, text, text, integer[], integer, integer, integer);
drop function if exists mock.get_imposition_plan(timestamp with time zone, text, text, integer[], integer, integer, integer);
drop function if exists mock.get_impose_plan(timestamp with time zone, text, text, integer[], boolean, integer, integer, integer);
drop function if exists mock.get_impose_plan(timestamp with time zone, text, text, integer[], integer, integer, integer);

create function mock.get_impose_plan(p_until timestamp with time zone DEFAULT now(), p_step text DEFAULT 'print'::text, p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_look_back_days integer DEFAULT 0, p_look_ahead_days integer DEFAULT 0, p_domain_id integer DEFAULT 1) returns TABLE(material_id integer, material_name text, production_line_id integer, tenant_id integer, tenant_name text, production_company_id integer, resource_uid text, resource_name text, resource_path ltree, delivery_hours integer, min_delivery_hours integer, sort_order numeric, param_json jsonb, formula jsonb, data jsonb, is_fixed_group text, is_pinned boolean, start_offset_in_seconds integer, next_start_offset_in_seconds integer, duration_in_seconds integer, nest_date date, orderline_count integer, product_amount numeric, part_amount integer, amount numeric, sqm numeric, forecast_sqm numeric, rework_count integer, rework_sqm numeric, impact_json jsonb, gross_sqm numeric, part_status_json jsonb, nest_ids bigint[], nest_count integer, seconds_to_logistics_date integer, class_names text[], unit_class_names text[], lane_item_id bigint, lane_id bigint)
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
               b.param_json, b.formula, b.data, b.is_fixed_group, b.is_pinned,
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
           r.is_fixed_group, r.is_pinned,
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

CREATE OR REPLACE FUNCTION mock.get_production_plan(p_until timestamp with time zone DEFAULT now(), p_step text DEFAULT 'print'::text, p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_domain_id integer DEFAULT 1)
 RETURNS TABLE(tenant_id integer, tenant_name text, production_company_id integer, resource_uid text, resource_name text, resource_path ltree, lane_id bigint, step text, level integer, lane_item_id bigint, sort_order numeric, is_pinned boolean, no_split boolean, is_fixed_group text, start_offset_in_seconds integer, duration_in_seconds integer, start_at timestamp with time zone, end_at timestamp with time zone, nest_ids bigint[], nest_count integer, batch_id integer, batch_name text, material_id integer, material_name text, impact_json jsonb, sqm numeric, gross_sqm numeric, part_status_json jsonb, state_json jsonb, group_state_json jsonb, class_names text[], param_json jsonb)
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
        select l.lane_id, pl_l.sort_order, l.resource_path,
               r.resource_uid, r.resource_name, r.step,
               t.tenant_id, t.tenant_name, t.production_company_id
        from the_plan tp
        join action.plan_lane pl_l on pl_l.plan_id = tp.plan_id
        join action.lane l on l.lane_id = pl_l.lane_id
        join relation.resource r on r.resource_path = l.resource_path
        -- the site is the first label of the path: the tenant's abb (dk, bh)
        left join tenant t on t.abb = ltree2text(subpath(l.resource_path, 0, 1))
        where l.resource_path is not null
          and (p_tenant_ids is null or t.tenant_id = any (p_tenant_ids))
    ),
    -- planned items with the nests hung on them
    item as (
        select li.lane_item_id, li.lane_id, li.sort_order, li.is_pinned, li.no_split,
               li.is_fixed_group, li.start_offset_in_seconds, li.duration_in_seconds, li.level,
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
           i.level, i.lane_item_id, i.sort_order, i.is_pinned, i.no_split, i.is_fixed_group,
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

-- check 1: the migration kept every set: per lane_item the reader returns
-- exactly the rows the flat table had; expected: 0
SELECT count(*) AS items_with_a_different_set
FROM (SELECT DISTINCT lane_item_id FROM action.imposition_lane_item) li
WHERE (SELECT count(*) FROM action.get_lane_item_impositions(li.lane_item_id))
   <> (SELECT count(*) FROM action.imposition_lane_item i WHERE i.lane_item_id = li.lane_item_id);

-- check 2: one shared moved_at for the migrated rows; expected: 1
SELECT count(DISTINCT moved_at) AS distinct_moved_at FROM action.imposition_lane_item;

-- check 3: the nest board, unchanged rows and nest counts; expected: 48 rows on
-- 2026-09-04, ~0,7 s
EXPLAIN (ANALYZE, SUMMARY)
SELECT * FROM mock.get_impose_plan('2026-09-04 10:00+02', 'print', 'sheet', NULL, 0, 0, 1);

SELECT count(*) AS rows, count(*) FILTER (WHERE nest_count > 0) AS rows_with_nests, sum(nest_count) AS nests
FROM mock.get_impose_plan('2026-09-04 10:00+02', 'print', 'sheet', NULL, 0, 0, 1);

-- check 4: the production board reads; expected: rows, no error
SELECT count(*) AS rows, count(*) FILTER (WHERE level = 0) AS planned_rows
FROM mock.get_production_plan('2026-09-04 10:00+02', 'print', 'sheet');

-- check 5: inheritance works on the existing pv2 chain: a cut item with no
-- rows of its own would inherit from its print item. Today every pv2 item has
-- its own rows, so this lists none; expected: 0
SELECT count(*) AS items_inheriting
FROM action.lane_item_dependency d
WHERE NOT EXISTS (SELECT 1 FROM action.imposition_lane_item i WHERE i.lane_item_id = d.to_lane_item_id);
