-- Step 1b of docs/plan-planning-schema.md (13 Sep 2026): lead times and timestamps.
--   1. catalog.item_group_resource, the tenant's side of the global item
--      groups: tenant_id (whose machine), lead_in and lead_out (setup and
--      teardown seconds on that machine), item_group_json (the tenant's
--      overrides of the group json), updated_at. The table is empty, so
--      tenant_id can be not null at once.
--   2. schedule.lane_item: lead_in, lead_out (seconds; from the rows of the
--      work's item groups on the machine of the lane), created_at, updated_at.
--   3. legacy.create_nest_manifest keeps to the machines of the nest's tenant;
--      schedule.get_schedule_lane_items returns lead_in and lead_out (the
--      version already live since step 1c reads them; it fails until this runs).
-- Rollback: sql/update_schedule_01b_lead_times_down.sql.
BEGIN;

-- ============ sql/catalog/item_group_resource.sql ============
ALTER TABLE catalog.item_group_resource
    ADD COLUMN tenant_id integer NOT NULL REFERENCES site.tenant,
    ADD COLUMN lead_in integer,
    ADD COLUMN lead_out integer,
    ADD COLUMN item_group_json jsonb NOT NULL DEFAULT '{}'::jsonb,
    ADD COLUMN updated_at timestamp with time zone NOT NULL DEFAULT now();

CREATE INDEX idx_item_group_resource_tenant ON catalog.item_group_resource (tenant_id);

COMMENT ON TABLE catalog.item_group_resource IS 'The machines (or branches of the resource tree) of a tenant that can do the work of an item group, with the setup and teardown seconds on them. step is the third label of resource_path. Source of the steps and candidate machines in legacy.nest.manifest_json.';
COMMENT ON COLUMN catalog.item_group_resource.lead_in IS 'Setup time before the work of this group on this machine, in seconds. Copied to schedule.lane_item.lead_in when the step item is made.';
COMMENT ON COLUMN catalog.item_group_resource.lead_out IS 'Teardown time after the work of this group on this machine, in seconds. Copied to schedule.lane_item.lead_out when the step item is made.';
COMMENT ON COLUMN catalog.item_group_resource.item_group_json IS 'The tenant''s overrides of catalog.item_group.item_group_json for this machine; {} when none.';

-- ============ sql/schedule/lane_item.sql ============
ALTER TABLE schedule.lane_item
    ADD COLUMN lead_in integer,
    ADD COLUMN lead_out integer,
    ADD COLUMN created_at timestamp with time zone NOT NULL DEFAULT now(),
    ADD COLUMN updated_at timestamp with time zone NOT NULL DEFAULT now();

COMMENT ON COLUMN schedule.lane_item.lead_in IS 'Setup seconds before the work: catalog.item_group_resource.lead_in of the work''s item groups on the machine of the lane.';
COMMENT ON COLUMN schedule.lane_item.lead_out IS 'Teardown seconds after the work: catalog.item_group_resource.lead_out of the work''s item groups on the machine of the lane.';

-- ============ sql/legacy/create_nest_manifest.sql ============
-- The fold of legacy.imposition_unit_manifest into legacy.nest.manifest_json
-- (docs/plan-planning-schema.md §3): the imposition group of the sheet
-- (legacy.get_imposition_group over its option codes), its item code paths,
-- and one entry per production step. The step and the machines of a row come
-- from catalog.item_group_resource: the item of the xbom row belongs to an
-- item group, the group names the machines (resource paths) that can do its
-- work, and the third label of such a path is the step. A row whose item
-- group names no machine is the sheet itself (or has no capability mapping
-- yet) and stays out of steps[]. The candidate machines of a step are the
-- paths of that step under the same site and line as the nest's production
-- line (site.tenant.abb, relation.production_line.line_type), every path of
-- the step when the line is unknown.
--
-- Reads the manifest rows, writes only legacy.nest. Called at the end of
-- legacy.create_imposition_unit_manifest, and on its own by
-- legacy.backfill_nest_manifest (the rows already exist, only the fold is
-- missing). Every requested nest is written, also one without rows: its
-- manifest becomes null, so a stale manifest never survives a re-nest.
drop function if exists legacy.create_nest_manifest(bigint[]);

create function legacy.create_nest_manifest(p_nest_ids bigint[]) returns void
	language sql
as $$
WITH step_order AS (
    -- the order of the steps, for the order of steps[]
    SELECT s.value ->> 'step' AS step, (s.value ->> 'order')::integer AS step_order
    FROM relation.lookup lk
    CROSS JOIN LATERAL jsonb_array_elements(lk.lookup_json) AS s(value)
    WHERE lk.lookup = 'lookup_step_category'
),
nest_line AS (
    -- the site and line of the nest: site.tenant.abb of the production
    -- line's tenant plus the line type, the first two labels of a path
    SELECT n.nest_id, pl.tenant_id,
           CASE WHEN t.abb IS NOT NULL AND pl.line_type IS NOT NULL
                THEN text2ltree(t.abb || '.' || pl.line_type) END AS site_line
    FROM legacy.nest n
    LEFT JOIN relation.production_line pl ON pl.line_id = (n.nest_json ->> 'production_line_id')::integer
    LEFT JOIN site.tenant t ON t.tenant_id = pl.tenant_id
    WHERE n.nest_id = ANY (p_nest_ids)
),
row_step AS (
    -- the steps of each row: the item of the row belongs to an item group,
    -- the group names its machines (catalog.item_group_resource), the
    -- third label of a machine path is the step. Only the machines of the
    -- nest's tenant, and on its site and line, count when those are known. A row can name
    -- several steps (a group with print and cut machines); a row without
    -- a mapping names none
    SELECT m.imposition_id, m.option_code, m.production_impact_per_unit, m.config_json,
           igr.step, igr.resource_path
    FROM legacy.imposition_unit_manifest m
    JOIN nest_line nl ON nl.nest_id = m.imposition_id
    LEFT JOIN catalog.item i ON i.item_code = m.item_code
    LEFT JOIN catalog.item_group_resource igr
           ON igr.item_group_code = i.item_group_code
          AND (nl.tenant_id IS NULL OR igr.tenant_id = nl.tenant_id)
          AND (nl.site_line IS NULL OR subpath(igr.resource_path, 0, 2) = nl.site_line)
    WHERE m.imposition_id = ANY (p_nest_ids)
),
step_agg AS (
    SELECT rs.imposition_id,
           jsonb_agg(jsonb_build_object(
               'step',                       rs.step,
               'option_codes',               rs.option_codes,
               'production_impact_per_unit', rs.production_impact_per_unit,
               'config',                     rs.config,
               'resource_paths',             rs.resource_paths)
               ORDER BY so.step_order NULLS LAST, rs.step) AS steps
    FROM (SELECT r.imposition_id, r.step,
                 (SELECT jsonb_agg(DISTINCT x.option_code) FROM (SELECT r2.option_code FROM row_step r2
                   WHERE r2.imposition_id = r.imposition_id AND r2.step = r.step) x) AS option_codes,
                 (SELECT sum(x.production_impact_per_unit) FROM (SELECT DISTINCT r2.option_code, r2.production_impact_per_unit
                   FROM row_step r2 WHERE r2.imposition_id = r.imposition_id AND r2.step = r.step) x) AS production_impact_per_unit,
                 -- the settings of the step: every config key of its rows
                 coalesce((SELECT jsonb_object_agg(c.key, c.value)
                           FROM (SELECT DISTINCT r2.option_code, r2.config_json FROM row_step r2
                                 WHERE r2.imposition_id = r.imposition_id AND r2.step = r.step) x
                           CROSS JOIN LATERAL jsonb_each(x.config_json) AS c(key, value)), '{}'::jsonb) AS config,
                 -- the machines of the step: the union over the item groups of its rows
                 jsonb_agg(DISTINCT ltree2text(r.resource_path)) AS resource_paths
          FROM row_step r
          WHERE r.step IS NOT NULL
          GROUP BY r.imposition_id, r.step) rs
    LEFT JOIN step_order so ON so.step = rs.step
    GROUP BY rs.imposition_id
),
group_of AS (
    SELECT m.imposition_id,
           legacy.get_imposition_group(array_agg(DISTINCT m.option_code)) AS imposition_group_id
    FROM legacy.imposition_unit_manifest m
    WHERE m.imposition_id = ANY (p_nest_ids)
    GROUP BY m.imposition_id
)
UPDATE legacy.nest n
SET manifest_json = CASE WHEN g.imposition_id IS NULL THEN NULL
                         ELSE jsonb_build_object(
                             'imposition_group_id', g.imposition_group_id,
                             'item_code_paths',     coalesce((SELECT jsonb_agg(ltree2text(p)) FROM unnest(ig.item_code_paths) AS p), '[]'::jsonb),
                             'steps',               coalesce(sa.steps, '[]'::jsonb))
                    END
FROM nest_line nl
LEFT JOIN group_of g ON g.imposition_id = nl.nest_id
LEFT JOIN legacy.imposition_group ig ON ig.imposition_group_id = g.imposition_group_id
LEFT JOIN step_agg sa ON sa.imposition_id = nl.nest_id
WHERE n.nest_id = nl.nest_id;
$$;

alter function legacy.create_nest_manifest(bigint[]) owner to xfw3;

-- ============ sql/schedule/get_schedule_lane_items.sql ============
-- The items of the schedule boards (docs/plan-planning-schema.md §4): one row
-- per item on the lanes whose day is in view. The kind of an item (plan,
-- progress, actual) is the lane_type of its lane; step 1 stores plan lanes
-- only, the progress and actual lanes follow when the boards move over
-- (step 3), p_types is in place for them.
--
-- Per row:
--   data_json        the item's own data_json, or the one it inherits from its
--                    predecessors (schedule.get_lane_item_data); is_inherited
--                    says which
--   status           the status of the newest event of the item
--                    (lane_item_event), 'plan' when it has none yet, and the
--                    moment of that event
--   summary          the work of the item, computed here and never stale: the
--                    nests in data_json.batches when there are any, else the
--                    open work of data_json.selection (material and line) on
--                    the lane day -- one action.get_lane_item_work call per day
--                    in view, the fold board 76 uses. count, amount, sqm,
--                    rework_count, rework_sqm, production_impact (seconds).
--                    Null for an item without batches and without selection
--   class_names      the type's classes (lookup_lane_item_type), then the
--                    item's (data_json.class_names), then the work's
--   duration_formula the active schedule.formula of 'duration-<p_view_code>':
--                    the rules the board computes the duration of an item with
--                    (from start_offset, end_offset, summary, param_json),
--                    yielding duration (seconds); [] when no version applies
--   lag_formula      the active schedule.formula of 'lag-<p_view_code>': the
--                    rules the board chains items with, yielding lag (seconds)
--
-- p_from and p_until are the days in view, both included; inside they are one
-- datemultirange, so a p_dates datemultirange can replace the pair without a
-- change below. Timing is in seconds, no unit in a key.
drop function if exists schedule.get_schedule_lane_items(date, date, text, integer[], text[], text[], text, integer);

create function schedule.get_schedule_lane_items(p_from date DEFAULT current_date, p_until date DEFAULT current_date, p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_steps text[] DEFAULT NULL::text[], p_types text[] DEFAULT NULL::text[], p_view_code text DEFAULT 'nest-time-scale'::text, p_domain_id integer DEFAULT 1)
    returns TABLE(plan_id bigint, lane_id bigint, lane_date date, step text, resource_path ltree, lane_type text, type_json jsonb, lane_item_id bigint, sort_order numeric, start_offset integer, end_offset integer, production_impact_per_unit numeric, lead_in integer, lead_out integer, status text, status_at timestamp with time zone, is_inherited boolean, data_json jsonb, class_names text[], summary jsonb, duration_formula jsonb, lag_formula jsonb)
    stable
    language plpgsql
as $$
#variable_conflict use_column
DECLARE
    v_zone constant text := 'Europe/Amsterdam';
    v_dates      datemultirange;
    v_duration   jsonb;
    v_lag        jsonb;
BEGIN
    v_dates := datemultirange(daterange(least(p_from, p_until), greatest(p_from, p_until), '[]'));

    -- the duration and lag rules of this view, the versions that apply now
    SELECT gf.formula_json INTO v_duration
    FROM schedule.get_formula(array['duration-' || p_view_code]) gf
    LIMIT 1;
    SELECT gf.formula_json INTO v_lag
    FROM schedule.get_formula(array['lag-' || p_view_code]) gf
    LIMIT 1;
    v_duration := coalesce(v_duration, '[]'::jsonb);
    v_lag      := coalesce(v_lag, '[]'::jsonb);

    RETURN QUERY
    WITH lane AS (
        SELECT p.plan_id, l.lane_id, l.lane_date, l.step, l.resource_path, l.lane_type
        FROM schedule.lane l
        JOIN schedule.plan p ON p.plan_id = l.plan_id
        LEFT JOIN site.tenant t ON t.abb = ltree2text(subpath(l.resource_path, 0, 1))
        WHERE l.lane_date <@ v_dates
          AND (p_line_type IS NULL OR p.line_type = p_line_type)
          AND (p_steps IS NULL OR l.step = ANY (p_steps))
          AND (p_types IS NULL OR l.lane_type = ANY (p_types))
          AND (p_tenant_ids IS NULL OR t.tenant_id = ANY (p_tenant_ids))
    ),
    type_row AS (
        SELECT e.value ->> 'type' AS lane_type, e.value AS type_json
        FROM action.lookup lk
        CROSS JOIN LATERAL jsonb_array_elements(lk.lookup_json) AS e(value)
        WHERE lk.lookup = 'lookup_lane_item_type'
    ),
    item AS (
        SELECT ln.plan_id, ln.lane_id, ln.lane_date, ln.step, ln.resource_path, ln.lane_type,
               li.lane_item_id, li.sort_order,
               li.start_offset, li.end_offset, li.production_impact_per_unit, li.lead_in, li.lead_out,
               li.data_json IS NULL AS is_inherited,
               coalesce(li.data_json, schedule.get_lane_item_data(li.lane_item_id)) AS data_json
        FROM schedule.lane_item li
        JOIN lane ln ON ln.lane_id = li.lane_id
    ),
    -- the nests of an item: every nest_id of every batch object
    item_nests AS (
        SELECT i.lane_item_id,
               (SELECT array_agg(DISTINCT x.value::bigint)
                FROM jsonb_array_elements(coalesce(i.data_json -> 'batches', '[]'::jsonb)) AS b
                CROSS JOIN LATERAL jsonb_array_elements_text(coalesce(b.value -> 'nest_ids', '[]'::jsonb)) AS x(value)) AS nest_ids
        FROM item i
    ),
    -- one work call per day in view: nests set = the work of those nests,
    -- nests null = the open work of the selection on that day
    work_scope AS (
        SELECT i.lane_date,
               jsonb_agg(jsonb_build_object(
                   'lane_item_id',       i.lane_item_id,
                   'nest_ids',           to_jsonb(n.nest_ids),
                   'material_id',        (i.data_json -> 'selection' ->> 'material_id')::integer,
                   'production_line_id', (i.data_json -> 'selection' ->> 'production_line_id')::integer,
                   'resource_path',      ltree2text(i.resource_path),
                   'param_json',         production.get_setting_numbers(
                                             production.get_resource_setting(i.resource_path,
                                                                             (i.data_json ->> 'imposition_group_id')::integer)))) AS scope_json
        FROM item i
        JOIN item_nests n ON n.lane_item_id = i.lane_item_id
        WHERE n.nest_ids IS NOT NULL
           OR (i.data_json -> 'selection' ->> 'material_id') IS NOT NULL
        GROUP BY i.lane_date
    ),
    work AS (
        SELECT w.lane_item_id, w.orderline_count, w.amount, w.sqm, w.rework_count, w.rework_sqm,
               w.production_impact_in_seconds, w.class_names AS work_class_names
        FROM work_scope ws
        CROSS JOIN LATERAL action.get_lane_item_work(
            p_until      := (ws.lane_date + time '12:00') AT TIME ZONE v_zone,
            p_scope_json := ws.scope_json,
            p_date_type  := 'nest',
            p_tenant_ids := p_tenant_ids,
            p_domain_id  := p_domain_id) w
    )
    SELECT i.plan_id, i.lane_id, i.lane_date, i.step, i.resource_path,
           i.lane_type, tr.type_json,
           i.lane_item_id, i.sort_order, i.start_offset, i.end_offset, i.production_impact_per_unit, i.lead_in, i.lead_out,
           coalesce(ev.status, 'plan'), ev.moved_at,
           i.is_inherited, i.data_json,
           (SELECT array_agg(c) FROM (
                SELECT jsonb_array_elements_text(coalesce(tr.type_json -> 'class_names', '[]'::jsonb)) AS c
                UNION ALL
                SELECT jsonb_array_elements_text(coalesce(i.data_json -> 'class_names', '[]'::jsonb))
                UNION ALL
                SELECT unnest(coalesce(w.work_class_names, '{}'::text[]))) AS cls),
           CASE WHEN w.lane_item_id IS NOT NULL THEN
                jsonb_build_object('count',             w.orderline_count,
                                   'amount',            w.amount,
                                   'sqm',               w.sqm,
                                   'rework_count',      w.rework_count,
                                   'rework_sqm',        w.rework_sqm,
                                   'production_impact', w.production_impact_in_seconds)
           END,
           v_duration,
           v_lag
    FROM item i
    LEFT JOIN type_row tr ON tr.lane_type = i.lane_type
    LEFT JOIN LATERAL (
        SELECT e.status, e.moved_at
        FROM schedule.lane_item_event e
        WHERE e.lane_item_id = i.lane_item_id
        ORDER BY e.moved_at DESC, e.lane_item_event_id DESC
        LIMIT 1
    ) ev ON true
    LEFT JOIN work w ON w.lane_item_id = i.lane_item_id
    ORDER BY i.lane_date, i.lane_id, i.sort_order;
END;
$$;

alter function schedule.get_schedule_lane_items(date, date, text, integer[], text[], text[], text, integer) owner to xfw3;

COMMIT;

-- ============ check ============
-- expected: tenant_id, lead_in, lead_out, item_group_json, updated_at on item_group_resource
SELECT column_name, data_type, is_nullable
FROM information_schema.columns
WHERE table_schema = 'catalog' AND table_name = 'item_group_resource'
ORDER BY ordinal_position;

-- expected: lead_in, lead_out, created_at, updated_at on lane_item; 0 rows from the read, no error
SELECT column_name FROM information_schema.columns
WHERE table_schema = 'schedule' AND table_name = 'lane_item' ORDER BY ordinal_position;
SELECT count(*) AS lane_items FROM schedule.get_schedule_lane_items(current_date, current_date + 6);

-- then: rows in catalog.item_group_resource (tenant_id, item_group_code, resource_path,
-- lead_in, lead_out), and CALL legacy.backfill_nest_manifest(); in autocommit mode
