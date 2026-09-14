-- Step 1c of docs/plan-planning-schema.md (13 Sep 2026): the formulas of the
-- schedule boards live with the schedule.
--   1. action.formula moves to schedule.formula (ALTER TABLE ... SET SCHEMA:
--      rows, indexes and identity come along; it was empty). Reader
--      schedule.get_formula (as-of, the rule of catalog.get_formula);
--      action.get_formula (step 1) is dropped.
--   2. schedule.get_schedule_lane_items reads schedule.get_formula.
--   3. production.formula and production.get_formula: the production twin of
--      catalog.formula, for the production rules; nothing reads it yet.
-- Run after update_schedule_01b_lead_times.sql. Rollback: sql/update_schedule_01c_schedule_formula_down.sql.
BEGIN;

-- ============ sql/schedule/formula.sql ============
ALTER TABLE action.formula SET SCHEMA schedule;
COMMENT ON TABLE schedule.formula IS 'Versioned formulas of the schedule boards: one row per version of a code (duration-<view_code>, lag-<view_code>). Which version applies at a moment: the newest active or archived row created before it (schedule.get_formula). draft and pending-approval never apply.';

DROP FUNCTION IF EXISTS action.get_formula(text[], timestamp with time zone);

-- ============ sql/schedule/get_formula.sql ============
-- The version of each schedule.formula code that applies at p_at: the newest
-- active or archived row created at or before that moment (the rule of
-- catalog.get_formula, on the schedule twin). Draft and pending-approval never
-- apply. One row per code, none when no version applied yet. First reader:
-- schedule.get_schedule_lane_items, for the lag formula of a view code
-- (formula_code 'lag-<view_code>', docs/plan-planning-schema.md §7.2).
drop function if exists schedule.get_formula(text[], timestamp with time zone);

create function schedule.get_formula(p_formula_codes text[], p_at timestamp with time zone DEFAULT now())
    returns TABLE(formula_code text, formula_id integer, version integer, version_status text, created_at timestamp with time zone, formula_json jsonb, formula_level integer)
    stable
    language sql
as $$
    WITH applying AS (
        SELECT DISTINCT ON (f.formula_code)
               f.formula_code, f.formula_id, f.version, f.version_status,
               f.created_at, f.formula_json, f.formula_level
        FROM schedule.formula f
        WHERE f.formula_code = ANY (p_formula_codes)
          AND f.version_status IN ('active', 'archived')
          AND f.created_at <= p_at
        ORDER BY f.formula_code, f.created_at DESC, f.version DESC
    )
    SELECT a.formula_code, a.formula_id, a.version, a.version_status,
           a.created_at, a.formula_json, a.formula_level
    FROM applying a
    ORDER BY a.formula_level, a.formula_code;
$$;

alter function schedule.get_formula(text[], timestamp with time zone) owner to xfw3;

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

-- ============ sql/production/formula.sql ============
-- Versioned formulas of the production side, the twin of catalog.formula
-- (the schedule boards have their own: schedule.formula). Same shape and same versioning as catalog.formula;
-- which version applies at a moment is production.get_formula.
create table production.formula
(
	formula_id integer generated always as identity
		primary key,
	-- the name a formula is known by; every version of it shares the code
	formula_code text not null,
	formula_json jsonb not null,
	formula_level integer default 0 not null,
	version integer default 1 not null,
	version_status text default 'active'::text not null
		constraint formula_version_status_check
			check (version_status in ('draft', 'pending-approval', 'active', 'archived')),
	created_at timestamp with time zone default now() not null,
	unique (formula_code, version)
);

comment on table production.formula is 'Versioned formulas of production: one row per version of a code. Which version applies at a moment: the newest active or archived row created before it (production.get_formula). draft and pending-approval never apply. ';
comment on column production.formula.version_status is 'draft -> pending-approval -> active -> archived. At most one active version per code; archived versions stay valid for what was created in their time.';
comment on column production.formula.created_at is 'The moment this version starts to apply. Set it when the version becomes active, not when the draft is typed.';

alter table production.formula owner to xfw3;

-- one active version per code
create unique index uq_production_formula_code_active
	on production.formula (formula_code)
	where (version_status = 'active');

-- the as-of lookup: newest applying version of a code before a moment
create index idx_production_formula_code_created
	on production.formula (formula_code, created_at desc)
	where (version_status in ('active', 'archived'));

-- ============ sql/production/get_formula.sql ============
-- The version of each production.formula code that applies at p_at: the newest
-- active or archived row created at or before that moment (the rule of
-- catalog.get_formula, on the production twin). Draft and pending-approval never
-- apply. One row per code, none when no version applied yet.
drop function if exists production.get_formula(text[], timestamp with time zone);

create function production.get_formula(p_formula_codes text[], p_at timestamp with time zone DEFAULT now())
    returns TABLE(formula_code text, formula_id integer, version integer, version_status text, created_at timestamp with time zone, formula_json jsonb, formula_level integer)
    stable
    language sql
as $$
    WITH applying AS (
        SELECT DISTINCT ON (f.formula_code)
               f.formula_code, f.formula_id, f.version, f.version_status,
               f.created_at, f.formula_json, f.formula_level
        FROM production.formula f
        WHERE f.formula_code = ANY (p_formula_codes)
          AND f.version_status IN ('active', 'archived')
          AND f.created_at <= p_at
        ORDER BY f.formula_code, f.created_at DESC, f.version DESC
    )
    SELECT a.formula_code, a.formula_id, a.version, a.version_status,
           a.created_at, a.formula_json, a.formula_level
    FROM applying a
    ORDER BY a.formula_level, a.formula_code;
$$;

alter function production.get_formula(text[], timestamp with time zone) owner to xfw3;

COMMIT;

-- ============ check ============
-- expected: schedule.formula, production.formula; get_formula in schedule and production, not in action
SELECT n.nspname || '.' || c.relname AS obj FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relname = 'formula' AND n.nspname IN ('schedule', 'production', 'action')
UNION ALL
SELECT n.nspname || '.' || p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE p.proname = 'get_formula' AND n.nspname IN ('schedule', 'production', 'action')
ORDER BY 1;

-- expected: 0 rows, no error
SELECT count(*) AS lane_items FROM schedule.get_schedule_lane_items(current_date, current_date + 6);

-- then your rows in schedule.formula: duration-<view_code> and lag-<view_code>
-- (view codes nest-time-scale and print-day-scale), formula_json the rule list
SELECT * FROM schedule.get_formula(array['duration-nest-time-scale', 'lag-nest-time-scale', 'duration-print-day-scale', 'lag-print-day-scale']);
