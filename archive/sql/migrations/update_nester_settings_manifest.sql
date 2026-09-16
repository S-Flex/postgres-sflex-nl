-- The settings of the nester travel with the orderline: catalog.xbom rows of
-- scope imposition carry them in config_json (units_threshold, nest_time,
-- print_time, ...), mapping.update_component_specs_manifest merges them key by
-- key into component_specs.manifest_json.<scope>.config, and the merge order
-- is the new column catalog.item_group.level (highest level wins a key, null
-- last). No xbom row carries a setting yet (checked 10 Sep 2026), so every
-- manifest gets an empty config until the rows are filled; the rebuild for the
-- open orderlines is at the end, commented, for that moment.
--
-- Board 79 reads mock.get_impose_plan_inflow through the data_table get_impose_plan_inflow: the
-- orderline manifest plus the lane item the nests land on and its nest moment
-- (nest_moment_code, nest_time, print_time). data_table get_impose_plan_inflow
-- replaces get_production_orderline_manifest. Runs after
-- sql/update_plan_per_nest_moment.sql (lane_item.nest_moment_code).
BEGIN;

-- ── the merge order ─────────────────────────────────────────────────────────
ALTER TABLE catalog.item_group ADD COLUMN level integer;
COMMENT ON COLUMN catalog.item_group.level IS 'The merge order of the xbom config_json within a scope (manifest_json.<scope>.config): rows of a group with a higher level override the keys of a lower level; null last. Independent of item_group_json.sort_order, the path order of the imposition group.';

-- the two groups of today in their path order: the material first, the
-- print method overrides it
UPDATE catalog.item_group SET level = 10 WHERE item_group_code = 'material';
UPDATE catalog.item_group SET level = 20 WHERE item_group_code = 'print-method';

-- ============ sql/mapping/update_component_specs_manifest.sql ============
drop function if exists mapping.update_component_specs_manifest(integer[]);

create function mapping.update_component_specs_manifest(p_production_orderline_ids integer[])
    returns integer
    language sql
as $$
-- Rebuild component_specs.manifest_json for the given orderlines from the
-- rows in mapping.spec_unit_manifest: one object keyed by scope, each scope
-- an aggregate of the row labels, the item code paths and the settings
--   { "<scope>": { "i18n": { "<lang>": { "abb": "a, b" } },
--                  "item_code_paths": ["dk.roll.banner-510", ...],
--                  "config": { "units_threshold": 1, "nest_time": "12:00:00", ... } } }
-- config is the config_json of the rows of the scope merged key by key: the
-- row whose item group has the highest catalog.item_group.level wins a key
-- (null level loses to every level), then the row's sort_order. The label
-- (i18n) is the row's own and stays out of it. For scope imposition this is
-- where the nester reads its settings (units_threshold, nest_time,
-- print_time) -- put them in catalog.xbom.config_json of the rows that carry
-- them, give their item groups a level, and the merge does the rest.
-- Orderlines without manifest rows get NULL. Only changed rows are written,
-- so re-running retroactively is cheap; returns the number of rows updated.
with target as (
    select distinct t.production_orderline_id
    from unnest(p_production_orderline_ids) as t(production_orderline_id)
),
lang_agg as (
    -- one abb line per scope and language, joined in manifest order
    select s.production_orderline_id, s.scope, l.lang,
           string_agg(nullif(l.slots ->> 'abb', ''), ', ' order by s.sort_order) as abb
    from mapping.spec_unit_manifest s
    join target t using (production_orderline_id)
    cross join lateral jsonb_each(coalesce(s.config_json -> 'i18n', '{}'::jsonb)) as l(lang, slots)
    group by s.production_orderline_id, s.scope, l.lang
),
scope_i18n as (
    select production_orderline_id, scope,
           jsonb_object_agg(lang, jsonb_build_object('abb', abb)) as i18n
    from lang_agg
    where abb is not null
    group by production_orderline_id, scope
),
per_scope as (
    -- the paths of the linked catalog items, in manifest order
    select s.production_orderline_id, s.scope,
           to_jsonb(array_remove(
               array_agg(i.item_code_path::text order by s.sort_order), null)) as item_code_paths
    from mapping.spec_unit_manifest s
    join target t using (production_orderline_id)
    left join catalog.item i on i.item_code = s.item_code
    group by s.production_orderline_id, s.scope
),
config_key as (
    -- every key of every row's settings; per key the winning row is the one
    -- with the highest item group level, then the highest sort_order
    select distinct on (s.production_orderline_id, s.scope, c.key)
           s.production_orderline_id, s.scope, c.key, c.value
    from mapping.spec_unit_manifest s
    join target t using (production_orderline_id)
    left join catalog.item i on i.item_code = s.item_code
    left join catalog.item_group ig on ig.item_group_code = i.item_group_code
    cross join lateral jsonb_each(s.config_json - 'i18n') as c(key, value)
    order by s.production_orderline_id, s.scope, c.key,
             ig.level desc nulls last, s.sort_order desc, s.unit_manifest_id desc
),
scope_config as (
    select production_orderline_id, scope, jsonb_object_agg(key, value) as config
    from config_key
    group by production_orderline_id, scope
),
agg as (
    select p.production_orderline_id,
           jsonb_object_agg(p.scope, jsonb_build_object(
               'i18n',            coalesce(si.i18n, '{}'::jsonb),
               'item_code_paths', p.item_code_paths,
               'config',          coalesce(sc.config, '{}'::jsonb))) as manifest_json
    from per_scope p
    left join scope_i18n si on si.production_orderline_id = p.production_orderline_id
                           and si.scope = p.scope
    left join scope_config sc on sc.production_orderline_id = p.production_orderline_id
                             and sc.scope = p.scope
    group by p.production_orderline_id
),
updated as (
    -- one update covers both directions: fill from agg, NULL when no rows remain
    update mapping.component_specs cs
    set manifest_json = a.manifest_json
    from target t
    left join agg a using (production_orderline_id)
    where cs.production_orderline_id = t.production_orderline_id
      and cs.manifest_json is distinct from a.manifest_json
    returning cs.production_orderline_id
)
select count(distinct production_orderline_id)::integer from updated;
$$;

alter function mapping.update_component_specs_manifest(integer[]) owner to xfw3;

-- ============ sql/mock/get_impose_plan_inflow.sql ============
-- The read of the inflow sidebar (79, impose_plan_inflow): the orderline
-- manifest of a material (mapping.get_production_orderline_manifest, every
-- column as is) plus the lane item the nests of that material will land on,
-- so the release button knows what to release, and the nest moment of that
-- item (nest_moment_code, nest_time, print_time) for the head of the sidebar.
-- Per production line of the rows: the items of the material on the newest
-- material plan of p_date, and of those the first instance not released yet
-- (instance 0 before 1); when every instance is released, the last one, the
-- item the nests go to now. p_instance is honoured when it names an instance
-- that is still unreleased; otherwise the rule wins, so a sidebar opened
-- from the 14:00 instance while 10:00 is still open points at 10:00.
-- p_date is a timestamp, like p_until of the other plan reads: a date column
-- reaches the client as a moment (2026-09-11T00:00:00.000Z) and comes back as
-- one; the day is taken in Amsterdam time.
-- the type of p_date changed, so the old signature goes first
drop function if exists mock.get_impose_plan_inflow(integer, date, integer, integer, text, integer, integer, integer[]);
drop function if exists mock.get_impose_plan_inflow(integer, timestamp with time zone, integer, integer, text, integer, integer, integer[]);

create function mock.get_impose_plan_inflow(p_material_id integer, p_date timestamp with time zone DEFAULT now(), p_look_ahead_days integer DEFAULT '-1'::integer, p_threshold integer DEFAULT 1, p_line_type text DEFAULT NULL::text, p_instance integer DEFAULT NULL::integer, p_domain_id integer DEFAULT 1, p_tenant_ids integer[] DEFAULT NULL::integer[]) returns TABLE(number text, order_sequence integer, order_id integer, production_order_id integer, production_orderline_id integer, sales_orderline_id integer, customer_json jsonb, material_id integer, material_name text, product_amount numeric, sqm numeric, product_width numeric, product_height numeric, ship_separately boolean, production_line_id integer, production_company_id integer, tenant_name text, internal_status_code text, status_sequence integer, status_level text, status_title text, part_amount integer, part_status_json jsonb, nest_date date, production_date date, logistics_date date, logistics_at timestamp without time zone, shipment_date date, dates_json jsonb, impact_json jsonb, rejected_amount numeric, produced_amount numeric, nest_json jsonb, nest_ids bigint[], delivery_class_names text[], class_names text[], unit_class_names text[], queue_class_names text[], manifest_json jsonb, fill_percentage numeric, lane_item_id bigint, instance integer, nest_moment_code text, nest_time time, print_time time)
	stable
	language sql
as $$
    WITH day AS (
        SELECT (p_date AT TIME ZONE 'Europe/Amsterdam')::date AS plan_date
    ),
    plan AS (
        SELECT p.plan_id
        FROM action.plan p
        CROSS JOIN day d
        WHERE p.plan_date = d.plan_date
          AND p.type = 'material-resource-plan'
          AND (p_line_type IS NULL OR p.line_type = p_line_type)
        ORDER BY p.plan_id DESC
        LIMIT 1
    ),
    -- the items of the material on that plan (one per nest moment), per
    -- production line: the line sits on the schedule row of the item
    item AS (
        SELECT li.lane_item_id, li.instance, li.nest_moment_code, m.production_line_id,
               EXISTS (SELECT 1 FROM action.lane_item_event e
                       WHERE e.lane_item_id = li.lane_item_id AND e.status = 'released') AS is_released
        FROM plan
        JOIN action.plan_lane pl ON pl.plan_id = plan.plan_id
        JOIN action.imposition_group_lane igl ON igl.lane_id = pl.lane_id
        JOIN action.lane_item li ON li.lane_id = pl.lane_id AND li.type = 'plan' AND li.source = 'material-plan'
        JOIN mock.material_print_schedule m
          ON m.material_print_schedule_id = nullif(split_part(li.source_ref, ':', 1), '')::bigint
        WHERE igl.imposition_group_id = p_material_id
    ),
    pick AS (
        SELECT DISTINCT ON (i.production_line_id) i.production_line_id, i.lane_item_id, i.instance, i.nest_moment_code
        FROM item i
        ORDER BY i.production_line_id,
                 (NOT i.is_released AND i.instance = p_instance) DESC,
                 i.is_released,
                 CASE WHEN i.is_released THEN -i.instance ELSE i.instance END
    ),
    -- the nest and print time of the picked moment (lookup_nest_moments)
    moment AS (
        SELECT pk.production_line_id, pk.lane_item_id, pk.instance, pk.nest_moment_code,
               (v.value #>> '{nest_moments,0,nest_time,time}')::time  AS nest_time,
               (v.value #>> '{nest_moments,0,print_time,time}')::time AS print_time
        FROM pick pk
        LEFT JOIN (SELECT v.value
                   FROM production.lookup l
                   CROSS JOIN LATERAL jsonb_array_elements(l.lookup_json) AS v(value)
                   WHERE l.lookup = 'lookup_nest_moments') v ON v.value ->> 'code' = pk.nest_moment_code
    )
    SELECT m.*, mo.lane_item_id, mo.instance, mo.nest_moment_code, mo.nest_time, mo.print_time
    FROM day d
    CROSS JOIN LATERAL mapping.get_production_orderline_manifest(
             p_material_id, d.plan_date, p_look_ahead_days, p_threshold, p_domain_id, p_tenant_ids) m
    LEFT JOIN moment mo ON mo.production_line_id = m.production_line_id;
$$;

alter function mock.get_impose_plan_inflow(integer, timestamp with time zone, integer, integer, text, integer, integer, integer[]) owner to xfw3;

-- ── the data_table of board 79 ──────────────────────────────────────────────
INSERT INTO site.data_table (data_table, query, stored_proc, description, data_table_json, do_cache)
VALUES ('get_impose_plan_inflow',
        'mock.get_impose_plan_inflow',
        '',
        'orderline manifest of a material plus the lane item and nest moment the nests land on, for the inflow sidebar (79)',
        '{"primary_keys": ["production_orderline_id"]}'::jsonb,
        false)
ON CONFLICT (data_table) DO UPDATE
    SET query           = EXCLUDED.query,
        description     = EXCLUDED.description,
        data_table_json = EXCLUDED.data_table_json;

DELETE FROM site.data_table WHERE data_table = 'get_production_orderline_manifest';

COMMIT;

-- ── checks (read-only) ──────────────────────────────────────────────────────
SELECT item_group_code, level, item_group_json FROM catalog.item_group ORDER BY level;
SELECT data_table, query FROM site.data_table WHERE data_table IN ('get_impose_plan_inflow', 'get_production_orderline_manifest');
SELECT nest_moment_code, nest_time, print_time, lane_item_id, instance, count(*)
FROM mock.get_impose_plan_inflow(47, current_date)
GROUP BY 1, 2, 3, 4, 5;

-- ── later, once the xbom rows carry their settings: the open orderlines ─────
-- SELECT mapping.update_component_specs_manifest(array_agg(production_orderline_id))
-- FROM mapping.component_specs WHERE is_open;
