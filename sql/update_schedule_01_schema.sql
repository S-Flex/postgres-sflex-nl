-- Step 1 of docs/plan-planning-schema.md: the schedule schema and its reads.
--   1. schema schedule with plan, lane, lane_item, lane_item_dependency,
--      lane_item_event (§2); nothing in action.* is touched.
--   2. action.lookup lookup_lane_item_event_type (json/lookup/action/...).
--   3. action.get_formula (the as-of reader of action.formula) and the reads
--      schedule.get_lane_item_data (helper), schedule.get_schedule_lane,
--      schedule.get_schedule_lane_items (§4).
--   4. site.data_table rows get_schedule_lane and get_schedule_lane_items.
-- Additive: the tables are empty until step 2. Rollback:
-- sql/update_schedule_01_schema_down.sql.
BEGIN;

CREATE SCHEMA IF NOT EXISTS schedule;
ALTER SCHEMA schedule OWNER TO xfw3;
COMMENT ON SCHEMA schedule IS 'The resource planning (docs/plan-planning-schema.md): one plan per line type, lanes per day, step and machine, lane items with what is planned in data_json, their dependencies and their event history.';

-- The board scope of the resource planning (docs/plan-planning-schema.md):
-- one row per line type and the tenants that run it. No date and no steps:
-- the lanes under it carry the day, the step and the machine.
create table schedule.plan
(
	plan_id bigint generated always as identity
		primary key,
	line_type text not null,
	-- the tenants that run this line type (relation.production_line)
	tenant_ids integer[] not null,
	unique (line_type, tenant_ids)
);

comment on table schedule.plan is 'The scope of a planning board: one row per line type and tenant set. Its lanes (schedule.lane) hold every step of every day; a board filters the lanes on date, step and resource_path.';

alter table schedule.plan owner to xfw3;
-- One strip of time: one step on one machine on one day, of one kind
-- (docs/plan-planning-schema.md §2). The material boards group the items of
-- these lanes by material or imposition group; there is no other lane kind.
create table schedule.lane
(
	lane_id bigint generated always as identity
		primary key,
	plan_id bigint not null
		references schedule.plan,
	lane_date date not null,
	-- vocabulary relation.lookup lookup_step_category
	step text not null,
	-- the machine, docs/resource-path.md; an impose lane carries the impose
	-- path of mock.material_print_schedule (site.line.impose.width)
	resource_path ltree not null,
	-- plan (what is planned), progress (what is left of it), actual (what the
	-- machine did): action.lookup lookup_lane_item_type. The kind of every
	-- item on the lane
	lane_type text default 'plan' not null,
	sort_order numeric default 0 not null,
	unique (plan_id, lane_date, step, resource_path, lane_type)
);

comment on table schedule.lane is 'One step on one resource_path on one day, of one lane_type (plan, progress, actual). Unique per plan, day, step, path and type; the items on it are schedule.lane_item and share its type.';

alter table schedule.lane owner to xfw3;

create index idx_schedule_lane_date
	on schedule.lane (lane_date);

create index idx_schedule_lane_resource_path
	on schedule.lane using gist (resource_path);
-- The block of work on a lane (docs/plan-planning-schema.md §2, §3). Current
-- state only: every change writes a schedule.lane_item_event row, and the
-- status of the item is the status of its newest event. The kind of the item
-- (plan, progress, actual) is the lane_type of its lane. Timing is in
-- seconds, that is the contract: no unit in the key. The duration is not
-- stored: the board computes it from the item's own offsets and its work with
-- the duration formula of the view (action.formula 'duration-<view_code>'),
-- the way it chains items with the lag formula.
create table schedule.lane_item
(
	lane_item_id bigint generated always as identity
		primary key,
	lane_id bigint not null
		references schedule.lane,
	sort_order numeric not null,
	-- seconds since the local midnight of the lane day; null: the board chains it
	start_offset integer
		constraint lane_item_start_offset_check
			check (start_offset >= 0 and start_offset <= 86399),
	-- seconds since the local midnight of the lane day; null: the board
	-- computes it (duration formula)
	end_offset integer
		constraint lane_item_end_offset_check
			check (end_offset >= 0 and end_offset <= 86399),
	-- seconds per unit of the work
	production_impact_per_unit numeric,
	-- what is planned (§3.1); null on a step item that inherits it from its
	-- predecessor (§3.3)
	data_json jsonb,
	unique (lane_id, sort_order)
);

comment on table schedule.lane_item is 'The block of work on a lane. data_json says what: material or imposition group, nest moment, batches with nests, selected orderlines, summary. Null data_json = inherited along lane_item_dependency. History and status live in schedule.lane_item_event; the kind (plan, progress, actual) is the lane''s lane_type.';
comment on column schedule.lane_item.start_offset is 'Seconds since the local midnight of the lane day. Null: no time of its own, the board chains it after its predecessor with the lag formula.';
comment on column schedule.lane_item.end_offset is 'Seconds since the local midnight of the lane day. Null: the board computes it with the duration formula of the view; set by the planner (event resized) or a split.';

alter table schedule.lane_item owner to xfw3;

-- the upsert key of schedule.generate_day: one item per material and nest
-- moment on a lane
create unique index uq_schedule_lane_item_material_moment
	on schedule.lane_item (lane_id, (data_json ->> 'material_id'), (data_json ->> 'nest_moment_code'))
	where data_json ? 'material_id';

-- which item holds a nest: data_json @> '{"batches": [{"nest_ids": [123]}]}'
create index idx_schedule_lane_item_data_json
	on schedule.lane_item using gin (data_json jsonb_path_ops);
-- Which item follows which: many-to-many, from is the predecessor. Written by
-- schedule.crud_lane_item from legacy.nest.manifest_json steps[] when a nest is
-- placed, and by a split or merge on the board. An item without data_json
-- inherits it from its predecessors (schedule.get_lane_item_data).
create table schedule.lane_item_dependency
(
	from_lane_item_id bigint not null
		references schedule.lane_item
			on delete cascade,
	to_lane_item_id bigint not null
		references schedule.lane_item
			on delete cascade,
	primary key (from_lane_item_id, to_lane_item_id)
);

comment on table schedule.lane_item_dependency is 'from = predecessor, to = successor. A step item (print after impose, cut after print) hangs on its predecessor and inherits its data_json until it gets one of its own.';

alter table schedule.lane_item_dependency owner to xfw3;

create index idx_schedule_lane_item_dependency_to
	on schedule.lane_item_dependency (to_lane_item_id);
-- Append-only: one row per change of a lane item, written by
-- schedule.crud_lane_item in the same statement as the change
-- (docs/plan-planning-schema.md §3.4). Two vocabularies, both in action.lookup:
-- event_type says what was done (lookup_lane_item_event_type: created, moved,
-- resized, split, copied, selected, placed, status-changed, deleted), status
-- says where the item is after it (lookup_lane_item_status: plan, released,
-- nested). The item has no status column: its status is the status of its
-- newest event, its status at a moment the status of its newest event before
-- that moment.
create table schedule.lane_item_event
(
	lane_item_event_id bigint generated always as identity
		primary key,
	lane_item_id bigint not null
		references schedule.lane_item
			on delete cascade,
	-- what was done: action.lookup lookup_lane_item_event_type
	event_type text not null,
	-- the status after this event: action.lookup lookup_lane_item_status
	status text not null,
	-- the changed keys with their old and new value, e.g.
	-- {"start_offset": {"from": 3600, "to": 7200}}; {} when the status column
	-- says it all
	event_json jsonb default '{}'::jsonb not null,
	-- the contact who did it; null for the system
	moved_by integer,
	moved_at timestamp with time zone default now() not null
);

comment on table schedule.lane_item_event is 'The history of a lane item, one row per change. event_type = what was done, status = the status after it, event_json = the changed keys with from/to. The newest row per item is its status.';

alter table schedule.lane_item_event owner to xfw3;

create index idx_schedule_lane_item_event_item_moved_at
	on schedule.lane_item_event (lane_item_id asc, moved_at desc);

create index idx_schedule_lane_item_event_moved_at
	on schedule.lane_item_event (moved_at);

-- ============ action.lookup lookup_lane_item_event_type ============
-- json/lookup/action/lookup_lane_item_event_type.json
INSERT INTO action.lookup (lookup, lookup_json)
VALUES ('lookup_lane_item_event_type', $lk$
[
  {
    "event_type": "created",
    "i18n": {
      "de": { "title": "Erstellt" },
      "en": { "title": "Created" },
      "es": { "title": "Creado" },
      "fr": { "title": "Créé" },
      "nl": { "title": "Aangemaakt" },
      "uk": { "title": "Створено" }
    },
    "sort_order": 0
  },
  {
    "event_type": "moved",
    "i18n": {
      "de": { "title": "Verschoben" },
      "en": { "title": "Moved" },
      "es": { "title": "Movido" },
      "fr": { "title": "Déplacé" },
      "nl": { "title": "Verplaatst" },
      "uk": { "title": "Переміщено" }
    },
    "sort_order": 1
  },
  {
    "event_type": "resized",
    "i18n": {
      "de": { "title": "Dauer geändert" },
      "en": { "title": "Resized" },
      "es": { "title": "Duración cambiada" },
      "fr": { "title": "Durée modifiée" },
      "nl": { "title": "Duur gewijzigd" },
      "uk": { "title": "Змінено тривалість" }
    },
    "sort_order": 2
  },
  {
    "event_type": "split",
    "i18n": {
      "de": { "title": "Geteilt" },
      "en": { "title": "Split" },
      "es": { "title": "Dividido" },
      "fr": { "title": "Divisé" },
      "nl": { "title": "Gesplitst" },
      "uk": { "title": "Розділено" }
    },
    "sort_order": 3
  },
  {
    "event_type": "copied",
    "i18n": {
      "de": { "title": "Kopiert" },
      "en": { "title": "Copied" },
      "es": { "title": "Copiado" },
      "fr": { "title": "Copié" },
      "nl": { "title": "Gekopieerd" },
      "uk": { "title": "Скопійовано" }
    },
    "sort_order": 4
  },
  {
    "event_type": "selected",
    "i18n": {
      "de": { "title": "Auftragszeilen gewählt" },
      "en": { "title": "Orderlines selected" },
      "es": { "title": "Líneas seleccionadas" },
      "fr": { "title": "Lignes sélectionnées" },
      "nl": { "title": "Orderregels gekozen" },
      "uk": { "title": "Вибрано рядки замовлення" }
    },
    "sort_order": 5
  },
  {
    "event_type": "placed",
    "i18n": {
      "de": { "title": "Nests platziert" },
      "en": { "title": "Nests placed" },
      "es": { "title": "Nests colocados" },
      "fr": { "title": "Nests placés" },
      "nl": { "title": "Nests geplaatst" },
      "uk": { "title": "Розміщено нести" }
    },
    "sort_order": 6
  },
  {
    "event_type": "status-changed",
    "i18n": {
      "de": { "title": "Status geändert" },
      "en": { "title": "Status changed" },
      "es": { "title": "Estado cambiado" },
      "fr": { "title": "Statut modifié" },
      "nl": { "title": "Status gewijzigd" },
      "uk": { "title": "Статус змінено" }
    },
    "sort_order": 7
  },
  {
    "event_type": "deleted",
    "i18n": {
      "de": { "title": "Gelöscht" },
      "en": { "title": "Deleted" },
      "es": { "title": "Eliminado" },
      "fr": { "title": "Supprimé" },
      "nl": { "title": "Verwijderd" },
      "uk": { "title": "Видалено" }
    },
    "sort_order": 8
  }
]
$lk$::jsonb)
ON CONFLICT (lookup) DO UPDATE SET lookup_json = EXCLUDED.lookup_json;

-- The version of each action.formula code that applies at p_at: the newest
-- active or archived row created at or before that moment (the rule of
-- catalog.get_formula, on the action twin). Draft and pending-approval never
-- apply. One row per code, none when no version applied yet. First reader:
-- schedule.get_schedule_lane_items, for the lag formula of a view code
-- (formula_code 'lag-<view_code>', docs/plan-planning-schema.md §7.2).
drop function if exists action.get_formula(text[], timestamp with time zone);

create function action.get_formula(p_formula_codes text[], p_at timestamp with time zone DEFAULT now())
    returns TABLE(formula_code text, formula_id integer, version integer, version_status text, created_at timestamp with time zone, formula_json jsonb, formula_level integer)
    stable
    language sql
as $$
    WITH applying AS (
        SELECT DISTINCT ON (f.formula_code)
               f.formula_code, f.formula_id, f.version, f.version_status,
               f.created_at, f.formula_json, f.formula_level
        FROM action.formula f
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

alter function action.get_formula(text[], timestamp with time zone) owner to xfw3;
-- The effective data_json of a lane item (docs/plan-planning-schema.md §3.3).
-- An item with its own data_json is its own source. An item without one (a
-- step item made from the nest manifest) walks lane_item_dependency from to
-- to from, predecessor by predecessor, and stops at the first item on each
-- branch that has a data_json. One source: that data_json. Several sources (a
-- merge): the nearest one is the base, its batches and production_orderlines
-- become the union over all sources, and the stored summary is dropped, since
-- it belongs to one source only (the read computes it anyway). Helper of
-- schedule.get_schedule_lane_items; not a board read of its own.
drop function if exists schedule.get_lane_item_data(bigint);

create function schedule.get_lane_item_data(p_lane_item_id bigint) returns jsonb
    stable
    language sql
as $$
    WITH RECURSIVE walk AS (
        SELECT li.lane_item_id, li.data_json, 0 AS depth, array[li.lane_item_id] AS path
        FROM schedule.lane_item li
        WHERE li.lane_item_id = p_lane_item_id

        UNION ALL

        -- only an item without data_json looks further back
        SELECT p.lane_item_id, p.data_json, w.depth + 1, w.path || p.lane_item_id
        FROM walk w
        JOIN schedule.lane_item_dependency d ON d.to_lane_item_id = w.lane_item_id
        JOIN schedule.lane_item p ON p.lane_item_id = d.from_lane_item_id
        WHERE w.data_json IS NULL
          AND NOT (p.lane_item_id = ANY (w.path))
    ),
    source AS (
        SELECT DISTINCT ON (w.lane_item_id) w.lane_item_id, w.data_json, w.depth
        FROM walk w
        WHERE w.data_json IS NOT NULL
        ORDER BY w.lane_item_id, w.depth
    ),
    base AS (
        SELECT s.data_json, (SELECT count(*) FROM source) AS source_count
        FROM source s
        ORDER BY s.depth, s.lane_item_id
        LIMIT 1
    ),
    merged AS (
        SELECT (SELECT jsonb_agg(DISTINCT b) FROM source s
                CROSS JOIN LATERAL jsonb_array_elements(coalesce(s.data_json -> 'batches', '[]'::jsonb)) AS b) AS batches,
               (SELECT jsonb_agg(DISTINCT o) FROM source s
                CROSS JOIN LATERAL jsonb_array_elements(coalesce(s.data_json -> 'production_orderlines', '[]'::jsonb)) AS o) AS production_orderlines
    )
    SELECT CASE
               WHEN b.source_count = 1 THEN b.data_json
               ELSE (b.data_json - 'summary')
                    || jsonb_build_object('batches',               coalesce(m.batches, '[]'::jsonb),
                                          'production_orderlines', coalesce(m.production_orderlines, '[]'::jsonb))
           END
    FROM base b
    CROSS JOIN merged m;
$$;

alter function schedule.get_lane_item_data(bigint) owner to xfw3;
-- The lanes (labels) of the schedule boards (docs/plan-planning-schema.md §4):
-- one row per lane whose day is in view. A lane is one step on one machine on
-- one day of one kind (lane_type: plan, progress, actual); the material boards
-- group its items, not its lanes. The formula and constants of the machine
-- come from production.resource_setting, so the board evaluates the same way
-- on every board.
--
-- p_from and p_until are the days in view, both included; inside they are one
-- datemultirange, so a p_dates datemultirange can replace the pair without a
-- change below once the frontend sends one. p_steps null = every step,
-- p_types null = every lane_type, p_line_type null = every line type,
-- p_tenant_ids null = every tenant (the tenant of a lane is the first label of
-- its path, site.tenant.abb).
drop function if exists schedule.get_schedule_lane(date, date, text, integer[], text[], text[]);

create function schedule.get_schedule_lane(p_from date DEFAULT current_date, p_until date DEFAULT current_date, p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_steps text[] DEFAULT NULL::text[], p_types text[] DEFAULT NULL::text[])
    returns TABLE(plan_id bigint, lane_id bigint, lane_date date, step text, resource_path ltree, lane_type text, type_json jsonb, resource_uid text, resource_name text, tenant_id integer, tenant_name text, sort_order numeric, param_json jsonb, formula jsonb)
    stable
    language plpgsql
as $$
#variable_conflict use_column
DECLARE
    v_dates datemultirange;
BEGIN
    v_dates := datemultirange(daterange(least(p_from, p_until), greatest(p_from, p_until), '[]'));

    RETURN QUERY
    SELECT p.plan_id, l.lane_id, l.lane_date, l.step, l.resource_path,
           l.lane_type, tr.type_json,
           r.resource_uid, r.resource_name,
           t.tenant_id, t.name,
           l.sort_order,
           -- the resource constants the board evaluates with, and its formula
           production.get_setting_numbers(rs.setting_json),
           coalesce(rs.setting_json -> 'formula', '[]'::jsonb)
    FROM schedule.lane l
    JOIN schedule.plan p ON p.plan_id = l.plan_id
    -- the node of the kind: sort order, class names, placement
    LEFT JOIN LATERAL (
        SELECT e.value AS type_json
        FROM action.lookup lk
        CROSS JOIN LATERAL jsonb_array_elements(lk.lookup_json) AS e(value)
        WHERE lk.lookup = 'lookup_lane_item_type' AND e.value ->> 'type' = l.lane_type
        LIMIT 1
    ) tr ON true
    -- an impose lane carries a branch path (site.line.impose.width): no
    -- machine of its own, so no uid and no name
    LEFT JOIN relation.resource r ON r.resource_path = l.resource_path
    CROSS JOIN LATERAL (SELECT production.get_resource_setting(l.resource_path) AS setting_json) rs
    -- the site is the first label of the path
    LEFT JOIN site.tenant t ON t.abb = ltree2text(subpath(l.resource_path, 0, 1))
    WHERE l.lane_date <@ v_dates
      AND (p_line_type IS NULL OR p.line_type = p_line_type)
      AND (p_steps IS NULL OR l.step = ANY (p_steps))
      AND (p_types IS NULL OR l.lane_type = ANY (p_types))
      AND (p_tenant_ids IS NULL OR t.tenant_id = ANY (p_tenant_ids))
    ORDER BY l.lane_date, t.tenant_id, l.sort_order, l.resource_path, l.lane_type;
END;
$$;

alter function schedule.get_schedule_lane(date, date, text, integer[], text[], text[]) owner to xfw3;
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
--   duration_formula the active action.formula of 'duration-<p_view_code>':
--                    the rules the board computes the duration of an item with
--                    (from start_offset, end_offset, summary, param_json),
--                    yielding duration (seconds); [] when no version applies
--   lag_formula      the active action.formula of 'lag-<p_view_code>': the
--                    rules the board chains items with, yielding lag (seconds)
--
-- p_from and p_until are the days in view, both included; inside they are one
-- datemultirange, so a p_dates datemultirange can replace the pair without a
-- change below. Timing is in seconds, no unit in a key.
drop function if exists schedule.get_schedule_lane_items(date, date, text, integer[], text[], text[], text, integer);

create function schedule.get_schedule_lane_items(p_from date DEFAULT current_date, p_until date DEFAULT current_date, p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_steps text[] DEFAULT NULL::text[], p_types text[] DEFAULT NULL::text[], p_view_code text DEFAULT 'nest-time-scale'::text, p_domain_id integer DEFAULT 1)
    returns TABLE(plan_id bigint, lane_id bigint, lane_date date, step text, resource_path ltree, lane_type text, type_json jsonb, lane_item_id bigint, sort_order numeric, start_offset integer, end_offset integer, production_impact_per_unit numeric, status text, status_at timestamp with time zone, is_inherited boolean, data_json jsonb, class_names text[], summary jsonb, duration_formula jsonb, lag_formula jsonb)
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
    FROM action.get_formula(array['duration-' || p_view_code]) gf
    LIMIT 1;
    SELECT gf.formula_json INTO v_lag
    FROM action.get_formula(array['lag-' || p_view_code]) gf
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
               li.start_offset, li.end_offset, li.production_impact_per_unit,
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
           i.lane_item_id, i.sort_order, i.start_offset, i.end_offset, i.production_impact_per_unit,
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

-- ============ site.data_table ============
INSERT INTO site.data_table (data_table, query, stored_proc, description, data_table_json, do_cache)
VALUES ('get_schedule_lane', 'schedule.get_schedule_lane', '',
        'the lanes of the schedule boards: one row per step, machine and day in view',
        '{"primary_keys": ["lane_id"]}'::jsonb, false),
       ('get_schedule_lane_items', 'schedule.get_schedule_lane_items', '',
        'the items of the schedule boards: one row per lane item on the lanes in view, with data_json, status, summary, duration and lag formula',
        '{"primary_keys": ["lane_item_id"]}'::jsonb, false)
ON CONFLICT (data_table) DO UPDATE
    SET query           = EXCLUDED.query,
        description     = EXCLUDED.description,
        data_table_json = EXCLUDED.data_table_json;

COMMIT;

-- ============ check ============
-- expected: five tables, four functions in schedule plus action.get_formula
SELECT c.relname, c.relkind
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'schedule' AND c.relkind = 'r'
ORDER BY c.relname;

SELECT n.nspname, p.proname
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE (n.nspname = 'schedule')
   OR (n.nspname = 'action' AND p.proname = 'get_formula')
ORDER BY 1, 2;

-- expected: 0 rows each, no error
SELECT count(*) AS lanes FROM schedule.get_schedule_lane(current_date, current_date + 6);
SELECT count(*) AS lane_items FROM schedule.get_schedule_lane_items(current_date, current_date + 6);

-- expected: one row per code once the duration and lag rows exist in action.formula
SELECT f.formula_code, f.version, f.formula_json
FROM action.get_formula(array['duration-nest-time-scale', 'lag-nest-time-scale', 'duration-print-day-scale', 'lag-print-day-scale']) f;
