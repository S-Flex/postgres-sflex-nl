-- Planning template, 14 Sep 2026 (docs/plan-planning-schema.md §3).
--
-- 1. legacy.imposition_group is per tenant: tenant_id, key (tenant_id,
--    imposition_group_id), the same paths carry the same id in every tenant;
--    imposition_group_json becomes rules_json.
-- 2. A tenant 2 (Bad Hersfeld) row for every group mock.material_print_schedule
--    plans there, with the same id and the same waste.
-- 3. rules_json filled from mock.material_print_schedule: root delivery_hours,
--    min_delivery_hours, unit_threshold; one schedules[] entry (resource_path,
--    sort_order, one interval, one fixed run per nest moment code with the
--    start_offset of lookup_nest_moments) for the rows that have codes and an
--    impose resource. No lead_in / lead_out yet: nobody knows them.
-- 4. units_threshold and delivery_hours leave catalog.xbom.config_json (kept in
--    catalog.xbom_config_backup_20260914 for the rollback).
-- 5. catalog.item_group_resource loses lead_in and lead_out.
-- 6. Every function that joins the group passes the tenant along; without one
--    it takes Dokkum (1): legacy.get_imposition_group(+ p_tenant_id),
--    legacy.create_nest_manifest, legacy.get_nest_waste_ranges (the live
--    version plus the tenant join; the pending total-row change of
--    sql/update_nest_waste_total_row.sql must carry the same join),
--    mapping.get_materials, mapping.get_production_orderline_detail,
--    mapping.get_production_orderline_manifest,
--    mapping.update_component_specs_manifest, action.get_plan_lanes_imposition_group.
-- The old planning keeps running on mock.material_print_schedule; nothing
-- else changes for it. Rollback: sql/update_planning_template_down.sql.

begin;

-- 1. the table -----------------------------------------------------------------
alter table legacy.imposition_group
    add column tenant_id integer not null default 1 references site.tenant;
alter table legacy.imposition_group alter column tenant_id drop default;

alter table action.imposition_group_lane_item
    drop constraint imposition_group_lane_item_imposition_group_id_fkey;
alter table legacy.imposition_group
    drop constraint imposition_group_parent_imposition_group_id_fkey,
    drop constraint imposition_group_pkey,
    drop constraint imposition_group_item_code_paths_key;
alter table legacy.imposition_group
    add primary key (tenant_id, imposition_group_id),
    add constraint imposition_group_tenant_item_code_paths_key unique (tenant_id, item_code_paths),
    add constraint imposition_group_parent_imposition_group_id_fkey
        foreign key (tenant_id, parent_imposition_group_id)
            references legacy.imposition_group (tenant_id, imposition_group_id);

alter table legacy.imposition_group rename column imposition_group_json to rules_json;
alter table legacy.imposition_group alter column rules_json set default '{}'::jsonb;

comment on column legacy.imposition_group.tenant_id is 'The tenant the rules are for. The paths are global; the same paths carry the same imposition_group_id in every tenant.';
comment on column legacy.imposition_group.rules_json is 'The planning rules of the group for the tenant: delivery_hours, min_delivery_hours, unit_threshold, waste[] and schedules[] (per impose resource the lead times, the intervals and the runs). Seconds from the start of the day, no unit in a key. See docs/plan-planning-schema.md §3.';

-- 2. the Bad Hersfeld rows: same id, same paths, same waste ----------------------
insert into legacy.imposition_group (tenant_id, imposition_group_id, item_code_paths, rules_json, parent_imposition_group_id)
select 2,
       g.imposition_group_id,
       g.item_code_paths,
       coalesce(jsonb_strip_nulls(jsonb_build_object('waste', g.rules_json -> 'waste')), '{}'::jsonb),
       -- the parent only when it is planned there as well
       case when g.parent_imposition_group_id in (select mps.material_id from mock.material_print_schedule mps where mps.tenant_id = 2)
            then g.parent_imposition_group_id end
from legacy.imposition_group g
where g.tenant_id = 1
  and g.imposition_group_id in (select mps.material_id from mock.material_print_schedule mps where mps.tenant_id = 2);

-- 3. the rules from the mock schedule ---------------------------------------------
with nest_moment as (
    select v.value ->> 'code' as code,
           v.ord,
           (v.value #>> '{nest_moments,0,nest_time,start_offset_in_seconds}')::integer as start_offset
    from production.lookup l
    cross join lateral jsonb_array_elements(l.lookup_json) with ordinality as v(value, ord)
    where l.lookup = 'lookup_nest_moments'
),
schedule_row as (
    select mps.tenant_id,
           mps.material_id,
           jsonb_strip_nulls(jsonb_build_object(
               'delivery_hours',     mps.delivery_hours,
               'min_delivery_hours', mps.min_delivery_hours,
               'unit_threshold',     1)) as root,
           case when mps.nest_moment_codes is not null and mps.resource_path is not null then
               jsonb_build_object('schedules', jsonb_build_array(jsonb_strip_nulls(jsonb_build_object(
                   'resource_path', ltree2text(mps.resource_path),
                   'sort_order',    mps.sort_order,
                   'intervals',     jsonb_build_array(jsonb_build_object(
                       'interval_start_date', mps.interval_start_date,
                       'interval_days',       coalesce(nullif(mps.interval_days, 0), 1),
                       'runs', (select jsonb_agg(jsonb_build_object('nest_moment_code', nm.code, 'start_offset', nm.start_offset)
                                                 order by nm.ord)
                                from nest_moment nm
                                where nm.code = any (mps.nest_moment_codes))))))))
           else '{}'::jsonb end as schedules
    from mock.material_print_schedule mps
)
update legacy.imposition_group g
set rules_json = g.rules_json || s.root || s.schedules
from schedule_row s
where g.tenant_id = s.tenant_id
  and g.imposition_group_id = s.material_id;

-- 4. the xbom loses units_threshold and delivery_hours ----------------------------
create table catalog.xbom_config_backup_20260914 as
select x.xbom_id, x.config_json
from catalog.xbom x
where x.config_json ?| array['units_threshold', 'delivery_hours'];
alter table catalog.xbom_config_backup_20260914 owner to xfw3;

update catalog.xbom x
set config_json = x.config_json - 'units_threshold' - 'delivery_hours'
where x.config_json ?| array['units_threshold', 'delivery_hours'];

-- 5. the leads leave item_group_resource ------------------------------------------
alter table catalog.item_group_resource drop column lead_in, drop column lead_out;
comment on table catalog.item_group_resource is 'The machines (or branches of the resource tree) of a tenant that can do the work of an item group. step is the third label of resource_path. Source of the steps and candidate machines in legacy.nest.manifest_json.';

-- 6. the functions ----------------------------------------------------------------
-- The signature gained p_tenant_id on 14 Sep 2026; the old one goes first so a
-- call with one argument is not ambiguous.
drop function if exists legacy.get_imposition_group(text[]);

create function legacy.get_imposition_group(p_option_codes text[], p_tenant_id integer DEFAULT 1) returns integer
	language sql
as $$
    -- The imposition group of a product for a tenant: the item code paths of
    -- its xbom rows with scope 'imposition', ordered as laid down in
    -- item_group (item_group_json sort_order; ungrouped items last, then by
    -- path). Groups are per tenant (key tenant_id, imposition_group_id) and
    -- the same paths carry the same id in every tenant: a tenant's new row
    -- takes the id the paths already have elsewhere, brand-new paths take the
    -- next id. Looks the row up and creates it when new — set-based,
    -- race-safe through the unique constraint on (tenant_id, item_code_paths).
    -- A caller without a tenant passes nothing and gets Dokkum (1).
    with wanted as (
        select array_agg(p.path order by p.group_sort nulls last, p.path) as item_code_paths
        from (
            select distinct
                   text2ltree(replace(lower(x.item_code), '-', '.')) as path,
                   (ig.item_group_json ->> 'sort_order')::numeric    as group_sort
            from catalog.xbom x
            join catalog.item i on i.item_code = x.item_code
            left join catalog.item_group ig on ig.item_group_code = i.item_group_code
            where x.option_code = any (p_option_codes)
              and x.scope = 'imposition'
              and x.version_status = 'active'
        ) p
    ),
    ins as (
        insert into legacy.imposition_group (tenant_id, imposition_group_id, item_code_paths, rules_json)
        select p_tenant_id,
               -- the id of these paths in any tenant, else a new one; coalesce
               -- only draws the sequence when there is none
               coalesce((select min(g.imposition_group_id)
                         from legacy.imposition_group g
                         where g.item_code_paths = w.item_code_paths),
                        nextval(pg_get_serial_sequence('legacy.imposition_group', 'imposition_group_id'))),
               w.item_code_paths,
               '{}'::jsonb
        from wanted w
        where w.item_code_paths is not null
        on conflict on constraint imposition_group_tenant_item_code_paths_key do nothing
        returning imposition_group_id
    )
    select coalesce(
        (select ins.imposition_group_id from ins),
        (select g.imposition_group_id
         from legacy.imposition_group g
         join wanted w on g.item_code_paths = w.item_code_paths
         where g.tenant_id = p_tenant_id));
$$;

alter function legacy.get_imposition_group(text[], integer) owner to xfw3;

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
    -- the group of the nest for its tenant; a nest without a line is Dokkum's (1)
    SELECT m.imposition_id,
           coalesce(nl.tenant_id, 1) AS tenant_id,
           legacy.get_imposition_group(array_agg(DISTINCT m.option_code), coalesce(nl.tenant_id, 1)) AS imposition_group_id
    FROM legacy.imposition_unit_manifest m
    JOIN nest_line nl ON nl.nest_id = m.imposition_id
    WHERE m.imposition_id = ANY (p_nest_ids)
    GROUP BY m.imposition_id, nl.tenant_id
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
LEFT JOIN legacy.imposition_group ig ON ig.imposition_group_id = g.imposition_group_id AND ig.tenant_id = g.tenant_id
LEFT JOIN step_agg sa ON sa.imposition_id = nl.nest_id
WHERE n.nest_id = nl.nest_id;
$$;

alter function legacy.create_nest_manifest(bigint[]) owner to xfw3;

CREATE OR REPLACE FUNCTION legacy.get_nest_waste_ranges(p_dates datemultirange DEFAULT datemultirange(daterange(CURRENT_DATE, CURRENT_DATE, '[]'::text)), p_material_ids integer[] DEFAULT NULL::integer[], p_line_type text DEFAULT NULL::text)
 RETURNS TABLE(material_id integer, material_name text, nest_date date, range_min numeric, range_max numeric, waste_range text, is_total boolean, sort_order integer, class_names text[], nest_count integer, sqm numeric, avg_waste_percentage numeric, waste_sqm numeric, purchase_price_per_sqm numeric, waste_cost numeric)
 LANGUAGE sql
 STABLE
AS $function$
    WITH nest AS (
        -- the material (the parent for a child) and the tenant of a nest live
        -- in its json and its production line; legacy.nest has no columns for them
        SELECT coalesce(g.parent_imposition_group_id, (n.nest_json ->> 'material_id')::integer) AS material_id,
               pl.tenant_id,
               (n.nested_at AT TIME ZONE 'Europe/Amsterdam')::date AS nest_date,
               (n.nest_json ->> 'waste_percentage')::numeric         AS waste_percentage,
               coalesce(n.amount, 1)                                  AS amount,
               n.width * n.height / 10000 * coalesce(n.amount, 1)     AS sqm
        FROM legacy.nest n
        LEFT JOIN relation.production_line pl ON pl.line_id = (n.nest_json ->> 'production_line_id')::integer
        -- the group of the nest's tenant; a nest without a line is Dokkum's (1)
        LEFT JOIN legacy.imposition_group g ON g.imposition_group_id = (n.nest_json ->> 'material_id')::integer
                                           AND g.tenant_id = coalesce(pl.tenant_id, 1)
        WHERE (n.nested_at AT TIME ZONE 'Europe/Amsterdam')::date <@ p_dates
          AND n.nest_json ? 'waste_percentage'
          AND (p_line_type IS NULL OR pl.line_type = p_line_type)
          AND (p_material_ids IS NULL
               OR coalesce(g.parent_imposition_group_id, (n.nest_json ->> 'material_id')::integer) = ANY (p_material_ids))
    ),
    range AS (
        -- the ranges of the lookup: [range_min, range_max), the top one open
        SELECT (v.value ->> 'range_min')::numeric AS range_min,
               (v.value ->> 'range_max')::numeric AS range_max,
               v.value ->> 'code'                 AS waste_range,
               coalesce((v.value ->> 'is_total')::boolean, false) AS is_total,
               (v.value ->> 'sort_order')::integer AS sort_order,
               coalesce((SELECT array_agg(c.value) FROM jsonb_array_elements_text(coalesce(v.value -> 'class_names', '[]'::jsonb)) AS c(value)),
                        '{}'::text[]) AS class_names
        FROM legacy.lookup l
        CROSS JOIN LATERAL jsonb_array_elements(l.lookup_json) AS v(value)
        WHERE l.lookup = 'lookup_nest_waste_ranges'
    ),
    material AS (
        SELECT DISTINCT n.material_id, n.nest_date FROM nest n
    ),
    material_item AS (
        -- the material item of the group: the path in item group material
        -- DISTINCT: the same paths exist once per tenant
        SELECT DISTINCT g.imposition_group_id AS material_id, i.item_code
        FROM legacy.imposition_group g
        JOIN catalog.item i ON i.item_code_path = ANY (g.item_code_paths) AND i.item_group_code = 'material'
        WHERE g.imposition_group_id IN (SELECT m.material_id FROM material m)
    ),
    price AS (
        -- the purchase price per m2 of every material item, per tenant: the
        -- newest active base price of the tenant itself
        SELECT DISTINCT ON (bp.tenant_id, mi.material_id)
               bp.tenant_id, mi.material_id,
               (bp.price_tiers_json -> 0 ->> 'purchase_price')::numeric AS purchase_price_per_sqm
        FROM material_item mi
        JOIN catalog.item_base_price bp ON bp.item_code = mi.item_code
                                       AND bp.version_status = 'active'
        ORDER BY bp.tenant_id, mi.material_id, bp.created_at DESC, bp.version DESC
    )
    SELECT m.material_id,
           -- the name on a line of the type in view first
           (SELECT mpl.material_name
            FROM mapping.material_production_line mpl
            LEFT JOIN relation.production_line pl ON pl.line_id = mpl.production_line_id
            WHERE mpl.material_id = m.material_id
            ORDER BY (pl.line_type = p_line_type) DESC NULLS LAST, mpl.production_line_id
            LIMIT 1) AS material_name,
           m.nest_date,
           r.range_min,
           r.range_max,
           r.waste_range,
           r.is_total,
           r.sort_order,
           r.class_names,
           coalesce(sum(n.amount), 0)::integer                      AS nest_count,
           round(coalesce(sum(n.sqm), 0), 2)                        AS sqm,
           round(avg(n.waste_percentage), 1)                        AS avg_waste_percentage,
           round(coalesce(sum(n.sqm * n.waste_percentage / 100), 0), 2) AS waste_sqm,
           min(pr.purchase_price_per_sqm)                            AS purchase_price_per_sqm,
           round(sum(n.sqm * n.waste_percentage / 100 * pr.purchase_price_per_sqm), 2) AS waste_cost
    FROM material m
    CROSS JOIN range r
    LEFT JOIN nest n ON n.material_id = m.material_id
                    AND n.nest_date = m.nest_date
                    AND n.waste_percentage >= r.range_min
                    AND (r.range_max IS NULL OR n.waste_percentage < r.range_max)
    LEFT JOIN price pr ON pr.material_id = n.material_id AND pr.tenant_id = n.tenant_id
    GROUP BY m.material_id, m.nest_date, r.range_min, r.range_max, r.waste_range, r.is_total, r.sort_order, r.class_names
    ORDER BY m.material_id, m.nest_date, r.sort_order;
$function$

alter function legacy.get_nest_waste_ranges(datemultirange, integer[], text) owner to xfw3;

-- The materials a board can filter on: the materials with a print schedule
-- (mock.material_print_schedule) on the production lines given, one row per
-- material, ordered by name. A material whose imposition group has a parent
-- is not listed on its own: it nests, queues and counts with the parent
-- (legacy.imposition_group.parent_imposition_group_id). p_production_line_ids
-- null is every line; p_line_type keeps to the lines of that type
-- (relation.production_line.line_type). The one material list for every
-- material select.
drop function if exists mapping.get_materials(text);
drop function if exists mapping.get_materials(integer[]);
drop function if exists mapping.get_materials(integer[], text);

create function mapping.get_materials(p_production_line_ids integer[] DEFAULT NULL::integer[], p_line_type text DEFAULT NULL::text) returns TABLE(material_id integer, material_name text, production_line_ids integer[])
	stable
	language sql
as $$
    SELECT mps.material_id,
           min(mps.material_name)                                    AS material_name,
           array_agg(DISTINCT mps.production_line_id ORDER BY mps.production_line_id) AS production_line_ids
    FROM mock.material_print_schedule mps
    LEFT JOIN legacy.imposition_group g ON g.imposition_group_id = mps.material_id AND g.tenant_id = coalesce(mps.tenant_id, 1)
    WHERE g.parent_imposition_group_id IS NULL
      AND (p_production_line_ids IS NULL OR mps.production_line_id = ANY (p_production_line_ids))
      AND (p_line_type IS NULL OR mps.production_line_id IN (SELECT pl.line_id FROM relation.production_line pl WHERE pl.line_type = p_line_type))
    GROUP BY mps.material_id
    ORDER BY min(mps.material_name), mps.material_id;
$$;

alter function mapping.get_materials(integer[], text) owner to xfw3;

-- return type changes, so the old signature has to go first
drop function if exists mapping.get_production_orderline_detail(timestamp with time zone, text, integer, integer, boolean, boolean, integer[], integer, integer[], integer[], bigint[], boolean, integer, integer);
drop function if exists mapping.get_production_orderline_detail(timestamp with time zone, text, integer, integer, boolean, boolean, integer[], text[], integer, integer[], integer[], bigint[], boolean, integer, integer);
drop function if exists mapping.get_production_orderline_detail(timestamp with time zone, text, integer, integer, boolean, boolean, integer[], text[], integer, integer[], integer[], bigint[], boolean, integer, integer, integer[]);
drop function if exists mapping.get_production_orderline_detail(timestamp with time zone, text, integer, integer, boolean, boolean, integer[], text[], integer, integer[], integer[], bigint[], boolean, integer, integer, integer[], timestamp without time zone);
drop function if exists mapping.get_production_orderline_detail(timestamp with time zone, text, integer, integer, boolean, boolean, integer[], text[], integer, integer[], integer[], bigint[], boolean, integer, integer, integer[], timestamp with time zone);
-- the version before production_impact_in_seconds joined the output
drop function if exists mapping.get_production_orderline_detail(timestamp with time zone, text, integer, integer, boolean, boolean, integer[], text[], integer[], integer[], integer[], bigint[], boolean, integer, integer, integer[], timestamp without time zone);
-- the version before the moment window (p_from_at, p_until_at) and 'units-all'
drop function if exists mapping.get_production_orderline_detail(timestamp with time zone, text, integer, integer, boolean, boolean, integer[], text[], integer[], integer[], integer[], bigint[], boolean, integer, integer, integer[], timestamp without time zone, integer);
drop function if exists mapping.get_production_orderline_detail(timestamp with time zone, text, integer, integer, boolean, boolean, integer[], text[], integer[], integer[], integer[], bigint[], boolean, integer, integer, integer[], timestamp without time zone, integer, timestamp with time zone, timestamp with time zone);

create function mapping.get_production_orderline_detail(p_date timestamp with time zone DEFAULT CURRENT_DATE, p_date_type text DEFAULT 'logistics'::text, p_look_back_days integer DEFAULT NULL::integer, p_look_ahead_days integer DEFAULT NULL::integer, p_include_weekend boolean DEFAULT true, p_include_mandatory_days_off boolean DEFAULT true, p_status_sequences integer[] DEFAULT NULL::integer[], p_status_levels text[] DEFAULT NULL::text[], p_production_line_ids integer[] DEFAULT NULL::integer[], p_material_ids integer[] DEFAULT NULL::integer[], p_batch_ids integer[] DEFAULT NULL::integer[], p_nest_ids bigint[] DEFAULT NULL::bigint[], p_is_open boolean DEFAULT true, p_threshold integer DEFAULT 1, p_domain_id integer DEFAULT 1, p_tenant_ids integer[] DEFAULT NULL::integer[], p_logistics_at timestamp without time zone DEFAULT NULL::timestamp without time zone, p_customer_id integer DEFAULT NULL::integer, p_from_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_until_at timestamp with time zone DEFAULT NULL::timestamp with time zone) returns TABLE(number text, order_sequence integer, order_id integer, production_order_id integer, production_orderline_id integer, sales_orderline_id integer, customer_json jsonb, material_id integer, material_name text, product_amount numeric, sqm numeric, product_width numeric, product_height numeric, ship_separately boolean, production_line_id integer, production_company_id integer, delivery_hours integer, internal_status_code text, status_sequence integer, status_level text, status_title text, part_amount integer, part_status_json jsonb, nest_date date, production_date date, logistics_date date, logistics_at timestamp without time zone, shipment_date date, dates_json jsonb, impact_json jsonb, rejected_amount numeric, produced_amount numeric, nest_json jsonb, nest_ids bigint[], delivery_class_names text[], class_names text[], unit_class_names text[], order_count integer, manifest_json jsonb, production_impact_in_seconds integer, impact_scope_json jsonb)
	stable
	SET plan_cache_mode=force_custom_plan
	language plpgsql
as $$
    #variable_conflict use_column
declare
    v_zone  constant text     := 'Europe/Amsterdam';
    v_alert constant interval := interval '2 hours';
    -- up to and including the next working day after the viewed day an
    -- orderline is imposed with everything else, whatever its size (unit
    -- class 'units-all'); beyond it the size decides. The same rule as the
    -- nest queue (get_production_orderline_manifest), read here so every
    -- board shares it
    v_next_workday date;
    -- below this sequence an orderline is not nested yet
    v_nested_sequence constant integer := 450;
    -- The viewed moment is the reference for every class name; never now(),
    -- so a board of another day judges that day.
    v_day   date      := (p_date at time zone 'Europe/Amsterdam')::date;
    v_at    timestamp := (p_date at time zone 'Europe/Amsterdam');
    v_from  date;
    v_until date;
    -- Scope: batch wins over nest, nest wins over the date window.
    v_scope text := case when p_batch_ids is not null then 'batch'
                         when p_nest_ids  is not null then 'nest'
                         else 'window' end;
    -- the materials asked plus the groups planned under them: a group whose
    -- parent (legacy.imposition_group.parent_imposition_group_id; the group
    -- ids are the material ids) is asked counts as that material. Null stays
    -- null (every material), an empty array stays empty (none)
    v_material_ids integer[] := case when p_material_ids is null then null
        else coalesce((select array_agg(distinct m)
                       from (select unnest(p_material_ids) as m
                             union
                             select g.imposition_group_id
                             from legacy.imposition_group g
                             where g.parent_imposition_group_id = any (p_material_ids)
                               -- the groups of the tenants asked; none asked is Dokkum (1)
                               and g.tenant_id = any (coalesce(p_tenant_ids, array[1]))) x),
                      '{}'::integer[]) end;
begin
    -- the next working day after the viewed day, for the tenants asked
    select min(d.date) into v_next_workday
    from action.dates d
    where d.date > v_day
      and d.is_weekend = false
      and not (coalesce(p_tenant_ids, d.tenants_mandatory_day_off) <@ d.tenants_mandatory_day_off
               and d.tenants_mandatory_day_off <> '{}');

    -- Everything between the two edges is returned, so the filter below stays
    -- a plain range on one column. No window means both edges stay NULL.
    if v_scope = 'window' then
        select w.from_date, w.until_date into v_from, v_until
        from action.get_date_window(p_date, p_look_back_days, p_look_ahead_days,
                                    p_include_weekend, p_include_mandatory_days_off, p_tenant_ids) w;
    end if;

    return query
    -- Everything the filters can decide on their own, so all the enrichment
    -- below runs over the rows in scope only, once per set instead of once
    -- per row.
    -- The orderlines a batch or nest scope names, resolved once. Written
    -- inline as IN (subquery) on component_specs, the estimate for a 232-nest
    -- set was 28.446 rows against 566 real ones, and every join below chose a
    -- hash join over a full scan of single_product,
    -- production_orderline_progress and spec_unit_manifest (half a million
    -- rows each, 1,3 s per set call). Window scope leaves this empty and the
    -- predicate on orderline_base folds away.
    with scope_orderline as materialized (
        select distinct sp.production_orderline_id
        from legacy.single_product sp
        left join legacy.nest n on v_scope = 'batch' and n.nest_id = sp.nest_id
        where (v_scope = 'nest'  and sp.nest_id  = any (p_nest_ids))
           or (v_scope = 'batch' and n.batch_id  = any (p_batch_ids))
    ),
    orderline_base as materialized (
        select cs.number, cs.order_sequence, cs.order_id, cs.production_order_id,
               cs.production_orderline_id, cs.sales_orderline_id,
               cs.customer_id, cs.company_name, cs.customer_reference, cs.team_name,
               cs.material_id, cs.product_amount, cs.sqm, cs.product_width, cs.product_height,
               cs.ship_separately, cs.first_production_line_id, cs.production_company_id,
               cs.production_hours, cs.internal_status_code,
               cs.nest_date, cs.production_date, cs.logistics_date, cs.shipment_date,
               cs.order_date, cs.production_order_amount, cs.manifest_json,
               ist.sequence as status_sequence, ist.level as status_level,
               ist.internal_title as status_title, ist.class_name as status_class_name
        from mapping.component_specs cs
        join mapping.internal_status ist
          on ist.code      = cs.internal_status_code
         and ist.domain_id = p_domain_id
        where cs.domain_id = p_domain_id
          and ist.group_name is distinct from 'Cancelled'
          and (p_is_open is null or cs.is_open = p_is_open)
          and (p_status_sequences is null or ist.sequence = any (p_status_sequences))
          -- the level of the status (Pre-production, Production, ...) as
          -- derived on mapping.internal_status; empty means no filter
          and (p_status_levels is null or cardinality(p_status_levels) = 0
               or ist.level = any (p_status_levels))
          -- null or empty means every line; same for the customer filter
          and (p_production_line_ids is null or cardinality(p_production_line_ids) = 0
               or cs.first_production_line_id = any (p_production_line_ids))
          and (p_customer_id is null or cs.customer_id = p_customer_id)
          and (v_material_ids is null or cs.material_id = any (v_material_ids))
          -- a board card carries its logistics grain: today's cards the exact
          -- cutoff moment, other days a midnight stamp meaning the whole day
          -- (the same derivation as get_production_board_aggregate). The
          -- client labels the local clock time with a Z; the cast to plain
          -- timestamp drops that label and keeps the clock time — exactly
          -- what cs.logistics_date carries. Never make this timestamptz.
          and (p_logistics_at is null
               or cs.logistics_date = p_logistics_at
               or (p_logistics_at = date_trunc('day', p_logistics_at)
                   and cs.logistics_date >= p_logistics_at
                   and cs.logistics_date <  p_logistics_at + interval '1 day'))
          -- One branch per date, so the comparison stays on a single column.
          -- A moment window (p_from_at, p_until_at; half open) wins over the
          -- day window: a board whose axis starts in the evening asks for the
          -- work from that moment on, not from midnight. The nest date is the
          -- one timestamptz and compares with the moments as they are; the
          -- other dates are clock times and take the moments as clock times
          and (v_scope <> 'window' or (v_from is null and p_from_at is null)
               or (p_date_type = 'logistics'
                   and cs.logistics_date >= coalesce(p_from_at  at time zone v_zone, v_from)
                   and cs.logistics_date <  coalesce(p_until_at at time zone v_zone, v_until))
               or (p_date_type = 'production'
                   and cs.production_date >= coalesce(p_from_at  at time zone v_zone, v_from)
                   and cs.production_date <  coalesce(p_until_at at time zone v_zone, v_until))
               or (p_date_type = 'nest'
                   and cs.nest_date >= coalesce(p_from_at,  v_from::timestamp  at time zone v_zone)
                   and cs.nest_date <  coalesce(p_until_at, v_until::timestamp at time zone v_zone))
               or (p_date_type = 'shipment'
                   and cs.shipment_date >= coalesce(p_from_at  at time zone v_zone, v_from)
                   and cs.shipment_date <  coalesce(p_until_at at time zone v_zone, v_until)))
          -- Batch and nest scope narrow the base here already: every
          -- enrichment below runs over the rows in scope instead of the whole
          -- open workload. A board fires one call per nest set, so without
          -- this each call paid for every open orderline (~100 ms a call,
          -- seconds a board). The in_scope filter at the end still applies
          -- the cancel markers.
          -- = ANY of an array built by an InitPlan, not IN (subquery): the
          -- planner cannot see through a hashed subplan and kept the
          -- estimate of the material filter (28.446 rows for 566); an array
          -- of unknown length is estimated small, so the joins below stay
          -- on the indexes
          and (v_scope = 'window'
               or cs.production_orderline_id = any (coalesce((select array_agg(so.production_orderline_id)
                                                              from scope_orderline so), '{}'::integer[])))
    ),
    -- The nests of these orderlines, resolved once. Serves three purposes:
    -- the batch and nest scope, nest_json, and the nest rework.
    -- TODO: confirm the cancel marker on legacy.nest and legacy.batch.
    orderline_nest as (
        select ob.production_orderline_id, sp.nest_id, n.batch_id,
               sum(sp.amount) as amount
        from orderline_base ob
        join legacy.single_product sp on sp.production_orderline_id = ob.production_orderline_id
        join legacy.nest n            on n.nest_id  = sp.nest_id
        left join legacy.batch b      on b.batch_id = n.batch_id
        where lower(coalesce(n.nest_json  ->> 'status', '')) not like 'cancel%'
          and lower(coalesce(b.batch_json ->> 'status', '')) not like 'cancel%'
        group by ob.production_orderline_id, sp.nest_id, n.batch_id
    ),
    -- Only one of the three scopes is active, the other two fall away.
    in_scope as (
        select distinct onst.production_orderline_id
        from orderline_nest onst
        where (v_scope = 'batch' and onst.batch_id = any (p_batch_ids))
           or (v_scope = 'nest'  and onst.nest_id  = any (p_nest_ids))
    ),
    -- The per-orderline aggregates below are MATERIALIZED: computed once for
    -- the set. Inlined, a low row estimate on orderline_base makes the planner
    -- nest them and recompute the whole aggregate per outer row.
    -- Rework on a nest means the whole nest was run again: every piece of
    -- this orderline on that nest was produced again, once per rerun.
    nest_agg as materialized (
        select onst.production_orderline_id,
               -- batch_id rides along: a reader that splits a lane item into
               -- its batches needs the batch of every nest, and the pieces on
               -- that nest to divide the orderline over them
               jsonb_agg(jsonb_build_object('nest_id',  onst.nest_id,
                                            'batch_id', onst.batch_id,
                                            'amount',   onst.amount)
                         order by onst.nest_id)         as nest_json,
               array_agg(onst.nest_id order by onst.nest_id) as nest_ids,
               coalesce(sum(r.rework_count), 0)::integer      as nest_rework_count,
               coalesce(sum(onst.amount * r.rework_amount), 0) as nest_rework_amount
        from orderline_nest onst
        left join (
            select ir.object_id                          as nest_id,
                   count(*)                              as rework_count,
                   coalesce(sum(ir.object_amount), 0)    as rework_amount
            from mapping.internal_rework ir
            where ir.object_type = 'nest'
              and ir.domain_id   = p_domain_id
              and ir.deleted_at  is null
              and ir.object_id in (select nest_id from orderline_nest)
            group by ir.object_id
        ) r on r.nest_id = onst.nest_id
        group by onst.production_orderline_id
    ),
    -- Rework booked on the orderline itself.
    orderline_rework as materialized (
        select ir.production_orderline_id,
               count(*)::integer                  as rework_count,
               coalesce(sum(ir.object_amount), 0) as rework_amount
        from mapping.internal_rework ir
        join orderline_base ob on ob.production_orderline_id = ir.production_orderline_id
        where ir.object_type is distinct from 'nest'
          and ir.domain_id  = p_domain_id
          and ir.deleted_at is null
        group by ir.production_orderline_id
    ),
    -- Progress of the orderlines in scope, read once.
    progress as (
        select p.production_orderline_id, p.part_statuses, p.part_amount,
               coalesce(array_length(p.part_amount, 1), 0) as part_amount_count,
               array_length(p.part_statuses, 1)            as part_status_count,
               (select sum(x) from unnest(p.part_amount) x) as part_amount_sum
        from mapping.production_orderline_progress p
        join orderline_base ob on ob.production_orderline_id = p.production_orderline_id
        where p.domain_id = p_domain_id
    ),
    -- The statuses of the product parts.
    part_status_json_agg as materialized (
        select pc.production_orderline_id,
               jsonb_agg(jsonb_build_object(
                   'sequence',             pc.part_status,
                   'internal_status_code', si.code,
                   'class_names',          to_jsonb(array_remove(array[si.class_name], null)),
                   'i18n',                 si.i18n,
                   'amount',               pc.amount
               ) order by pc.part_status) as part_status_json
        from (
            -- one row per status: parts sharing a status collapse into one
            -- entry with their amounts summed
            select per_part.production_orderline_id, per_part.part_status,
                   sum(per_part.amount) as amount
            from (
                select pg.production_orderline_id, u.part_status,
                       -- part_amount can be shorter than part_statuses; then the
                       -- total is spread evenly instead.
                       case when pg.part_amount_count < pg.part_status_count
                            then pg.part_amount_sum::numeric / pg.part_status_count
                            else pg.part_amount[u.ord]::numeric
                       end as amount
                from progress pg
                cross join lateral unnest(pg.part_statuses) with ordinality as u(part_status, ord)
                where pg.part_statuses is not null
            ) per_part
            group by per_part.production_orderline_id, per_part.part_status
        ) pc
        left join mapping.internal_status si
               on si.sequence = pc.part_status and si.domain_id = p_domain_id
        group by pc.production_orderline_id
    ),
    -- The standard production impact per unit of the orderlines in scope:
    -- the sum of the manifest rows (seconds per unit, written by
    -- create_spec_unit_manifest from the xbom formulas), multiplied by the
    -- units in the final select.
    manifest_impact as materialized (
        select s.production_orderline_id,
               sum(s.impact_per_unit) as impact_per_unit,
               -- the same seconds per scope: the scope of a manifest row is
               -- its step, so a reader can tell print from cut
               jsonb_object_agg(s.scope, s.impact_per_unit) as impact_scope_json
        from (select m.production_orderline_id, m.scope,
                     sum(m.production_impact_per_unit) as impact_per_unit
              from mapping.spec_unit_manifest m
              join orderline_base ob on ob.production_orderline_id = m.production_orderline_id
              group by m.production_orderline_id, m.scope) s
        group by s.production_orderline_id
    ),
    -- One name per material, only for the materials in scope.
    material_name as (
        select distinct on (mpl.material_id)
               mpl.material_id,
               mpl.line_json ->> 'material_name' as material_name
        from mapping.material_production_line mpl
        where mpl.material_id in (select material_id from orderline_base)
        order by mpl.material_id
    )
    select
        ob.number,
        ob.order_sequence,
        ob.order_id,
        ob.production_order_id,
        ob.production_orderline_id,
        ob.sales_orderline_id,
        jsonb_build_object(
            'customer_id',        ob.customer_id,
            'company_name',       ob.company_name,
            'customer_reference', ob.customer_reference,
            'team_name',          ob.team_name
        ),
        ob.material_id,
        mn.material_name,
        ob.product_amount,
        ob.sqm,
        ob.product_width,
        ob.product_height,
        coalesce(ob.ship_separately, false),
        ob.first_production_line_id,
        ob.production_company_id,
        -- the delivery promise of the orderline, the same unit as the print
        -- schedule's delivery_hours
        ob.production_hours,
        ob.internal_status_code,
        ob.status_sequence,
        ob.status_level,
        ob.status_title,
        coalesce((select sum(x) from unnest(pg.part_amount) x), 0)::integer,
        coalesce(psja.part_status_json, '[]'::jsonb),
        -- nest_date is the only timestamptz of the four dates
        (ob.nest_date at time zone v_zone)::date,
        ob.production_date::date,
        ob.logistics_date::date,
        ob.logistics_date,
        ob.shipment_date::date,
        jsonb_build_object(
            'order_date',    ob.order_date::date,
            'nest_at',       (ob.nest_date at time zone v_zone),
            'production_at', ob.production_date,
            'shipment_at',   ob.shipment_date
        ),
        -- The one shape every overview sums: the regular work of this
        -- orderline and its rework, booked on the orderline itself plus the
        -- reruns of its nests. Sqm of rework follows the sqm per product.
        jsonb_build_object(
            'count',                   1,
            'amount',                  ob.product_amount,
            'sqm',                     ob.sqm,
            'rework_count',            coalesce(orw.rework_count, 0) + coalesce(na.nest_rework_count, 0),
            'rework_amount',           coalesce(orw.rework_amount, 0) + coalesce(na.nest_rework_amount, 0),
            'rework_sqm',              ob.sqm / nullif(ob.product_amount, 0)
                                       * (coalesce(orw.rework_amount, 0) + coalesce(na.nest_rework_amount, 0)),
            'production_order_amount', ob.production_order_amount
        ),
        -- Redone pieces: booked on the orderline plus the reruns of its nests.
        coalesce(orw.rework_amount, 0) + coalesce(na.nest_rework_amount, 0),
        ob.product_amount
            + coalesce(orw.rework_amount, 0) + coalesce(na.nest_rework_amount, 0),
        coalesce(na.nest_json, '[]'::jsonb),
        coalesce(na.nest_ids, '{}'::bigint[]),
        -- Delayed means: logistics day strictly before the viewed day. Kept
        -- apart from class_names, because the board groups its cells on it.
        case when ob.logistics_date::date < v_day then array['state-delayed'] end,
        -- Sorted, because consumers group on this array and array comparison
        -- is order sensitive. A nest scope reports the status of its
        -- orderlines instead: the nests exist, so the planning signals
        -- (alert/signal) say nothing there.
        case when v_scope = 'nest'
             then array_remove(array[ob.status_class_name], null)
             else array(select distinct c from unnest(array[
                 case when ob.logistics_date::date < v_day then 'state-delayed' end,
                 case when ob.status_sequence < v_nested_sequence then
                     case when (ob.nest_date at time zone v_zone) - v_at <= v_alert
                          then 'plan-alert' else 'plan-signal' end
                 end,
                 -- rework on the orderline itself or on one of its nests
                 case when coalesce(orw.rework_count, 0) > 0
                        or coalesce(na.nest_rework_count, 0) > 0 then 'plan-rework' end
             ]) c where c is not null order by c)
        end,
        -- The unit class says with what an orderline is imposed: with a nest
        -- date up to and including the next working day everything goes
        -- together, further out the small orders (production_order_amount at
        -- or below p_threshold) apart from the big ones. Three groups that do
        -- not overlap. production_order_amount is kept on the row, so no
        -- aggregate needed
        case when ob.production_order_amount is null then '{}'::text[]
             when (ob.nest_date at time zone v_zone)::date <= v_next_workday then array['units-all']
             when ob.production_order_amount <= p_threshold then array['units-lte-threshold']
             else array['units-gt-threshold'] end,
        -- 1 on the first orderline of every order: a board sums this into
        -- the order count (the frontend only sums, and rework already lives
        -- in impact_json — field_config reads it with dot notation)
        (row_number() over (partition by ob.production_order_id
                            order by ob.production_orderline_id) = 1)::integer,
        ob.manifest_json,
        -- the standard production impact of the whole orderline: units
        -- (parts when there are more of them than products, as in the
        -- aggregate's amount) times the per-unit sum of its manifest rows
        round(u.units * coalesce(mi.impact_per_unit, 0))::integer,
        -- the same seconds split over the steps of the work
        (select jsonb_object_agg(e.key, round(u.units * (e.value #>> '{}')::numeric))
         from jsonb_each(coalesce(mi.impact_scope_json, '{}'::jsonb)) e)
    from orderline_base ob
    left join nest_agg na               on na.production_orderline_id   = ob.production_orderline_id
    left join orderline_rework orw      on orw.production_orderline_id  = ob.production_orderline_id
    left join progress pg               on pg.production_orderline_id   = ob.production_orderline_id
    left join part_status_json_agg psja on psja.production_orderline_id = ob.production_orderline_id
    left join manifest_impact mi        on mi.production_orderline_id   = ob.production_orderline_id
    left join material_name mn          on mn.material_id = ob.material_id
    -- the units the impact counts: the parts when there are more of them than
    -- products, as in the aggregate's amount
    cross join lateral (
        select greatest(coalesce((select sum(x) from unnest(pg.part_amount) x), 0),
                        coalesce(ob.product_amount, 0)) as units
    ) u
    where v_scope = 'window'
       or ob.production_orderline_id in (select production_orderline_id from in_scope)
    order by ob.production_order_id, ob.production_orderline_id;
end;
$$;

alter function mapping.get_production_orderline_detail(timestamp with time zone, text, integer, integer, boolean, boolean, integer[], text[], integer[], integer[], integer[], bigint[], boolean, integer, integer, integer[], timestamp without time zone, integer, timestamp with time zone, timestamp with time zone) owner to xfw3;


-- signature changes, so the old ones have to go first
drop function if exists mapping.get_production_orderline_manifest(integer, date, text, integer);
drop function if exists mapping.get_production_orderline_manifest(integer, timestamp with time zone, integer, text, integer, integer);
drop function if exists mapping.get_production_orderline_manifest(integer, date, integer, text, integer, integer);
drop function if exists mapping.get_production_orderline_manifest(integer, date, integer, text, integer, integer, integer[]);
-- same signature, dropped so the script re-runs
drop function if exists mapping.get_production_orderline_manifest(integer, date, integer, integer, integer, integer[]);

create function mapping.get_production_orderline_manifest(p_material_id integer, p_date date DEFAULT CURRENT_DATE, p_look_ahead_days integer DEFAULT '-1'::integer, p_threshold integer DEFAULT 1, p_domain_id integer DEFAULT 1, p_tenant_ids integer[] DEFAULT NULL::integer[]) returns TABLE(number text, order_sequence integer, order_id integer, production_order_id integer, production_orderline_id integer, sales_orderline_id integer, customer_json jsonb, material_id integer, material_name text, product_amount numeric, sqm numeric, product_width numeric, product_height numeric, ship_separately boolean, production_line_id integer, production_company_id integer, tenant_id integer, tenant_name text, internal_status_code text, status_sequence integer, status_level text, status_title text, part_amount integer, part_status_json jsonb, nest_date date, production_date date, logistics_date date, logistics_at timestamp without time zone, shipment_date date, dates_json jsonb, impact_json jsonb, rejected_amount numeric, produced_amount numeric, nest_json jsonb, nest_ids bigint[], delivery_class_names text[], class_names text[], unit_class_names text[], queue_class_names text[], manifest_json jsonb, fill_percentage numeric)
	stable
	language plpgsql
as $$
#variable_conflict use_column
declare
    v_zone constant text := 'Europe/Amsterdam';
    -- the queue is a day, not a moment: class names and the window are judged
    -- from the start of p_date in Amsterdam
    v_from timestamp with time zone := p_date::timestamp at time zone v_zone;
    -- the next working day after the viewed one: up to there the queue does
    -- not split on the unit threshold
    v_next_workday date;
    -- how far the queue looks: at least two working days, at most the
    -- interval of the material; -1 means "decide here", anything else wins
    v_look_ahead_days integer;
    -- the fill of an imposition of this material: 100 minus the waste of its
    -- nest group (legacy.imposition_group, the widest format, at its best
    -- waste factor). The same for every row, so the header of the queue
    -- reads it from any row. imposition_group_id is the material_id alias
    -- until the xbom groups arrive
    v_fill_percentage numeric;
    -- the tenant of the queue: the one tenant asked, else Dokkum (1); the
    -- groups are per tenant (legacy.imposition_group, 14 Sep 2026)
    v_tenant_id integer := case when cardinality(p_tenant_ids) = 1 then p_tenant_ids[1] else 1 end;
    -- the group of the queue: a material whose imposition group has a parent
    -- (legacy.imposition_group.parent_imposition_group_id) is nested with
    -- its parent, so the queue is the parent's -- with the orderlines of
    -- every child, shown under the parent's material_id
    v_material_id integer := (select coalesce(g.parent_imposition_group_id, g.imposition_group_id)
                              from legacy.imposition_group g
                              where g.imposition_group_id = p_material_id and g.tenant_id = v_tenant_id);
    v_material_ids integer[];
begin
    v_material_id := coalesce(v_material_id, p_material_id);
    select array_agg(g.imposition_group_id) || v_material_id into v_material_ids
    from legacy.imposition_group g
    where g.parent_imposition_group_id = v_material_id and g.tenant_id = v_tenant_id;
    v_material_ids := coalesce(v_material_ids, array[v_material_id]);

    select round((1 - (f.value ->> 'waste_factor')::numeric) * 100, 0) into v_fill_percentage
    from legacy.imposition_group g
    cross join lateral jsonb_array_elements(coalesce(g.rules_json -> 'waste', '[]'::jsonb)) f
    where g.imposition_group_id = v_material_id and g.tenant_id = v_tenant_id
    order by (f.value ->> 'width')::numeric desc, (f.value ->> 'waste_factor')::numeric
    limit 1;

    select min(d.date) into v_next_workday
    from action.dates d
    where d.date > p_date and d.is_weekend = false and not (coalesce(p_tenant_ids, d.tenants_mandatory_day_off) <@ d.tenants_mandatory_day_off and d.tenants_mandatory_day_off <> '{}');

    if p_look_ahead_days <> -1 then
        v_look_ahead_days := p_look_ahead_days;
    else
        select greatest(2, coalesce(max(mps.interval_days), 0)) into v_look_ahead_days
        from mock.material_print_schedule mps
        where mps.material_id = v_material_id;
    end if;

    return query
    -- The open orderlines of one material -- the group and its children --
    -- nesting from p_date on; the
    -- manifest travels along on the row itself (component_specs.manifest_json,
    -- one object per scope) — the queue groups on manifest_json.imposition.
    with detail as (
        select *
        from mapping.get_production_orderline_detail(
            p_date                    => v_from,
            p_date_type               => 'nest',
            p_look_back_days          => 0,
            p_look_ahead_days         => v_look_ahead_days,
            p_include_weekend         => false,
            p_include_mandatory_days_off => false,
            p_tenant_ids              => p_tenant_ids,
            p_material_ids            => v_material_ids,
            p_threshold               => p_threshold,
            p_domain_id               => p_domain_id)
    ),
    tenant as (
        select t.production_company_id, t.tenant_id, t.name as tenant_name
        from site.tenant t
    )
    select d.number, d.order_sequence, d.order_id, d.production_order_id,
           d.production_orderline_id, d.sales_orderline_id, d.customer_json,
           -- a child is shown under its parent
           coalesce(g.parent_imposition_group_id, d.material_id),
           d.material_name, d.product_amount, d.sqm,
           d.product_width, d.product_height, d.ship_separately,
           d.production_line_id, d.production_company_id, t.tenant_id, t.tenant_name,
           d.internal_status_code, d.status_sequence, d.status_level, d.status_title,
           d.part_amount, d.part_status_json,
           d.nest_date, d.production_date, d.logistics_date, d.logistics_at,
           d.shipment_date, d.dates_json, d.impact_json,
           d.rejected_amount, d.produced_amount, d.nest_json, d.nest_ids,
           d.delivery_class_names, d.class_names, d.unit_class_names,
           -- the threshold class only counts beyond the next working day; up
           -- to there the day is one group, so the board needs no rule of its own
           case when d.nest_date > v_next_workday then d.unit_class_names
                else '{}'::text[] end,
           d.manifest_json,
           v_fill_percentage
    from detail d
    left join tenant t on t.production_company_id = d.production_company_id
    left join legacy.imposition_group g on g.imposition_group_id = d.material_id and g.tenant_id = v_tenant_id
    -- biggest first, the order the nesting queue wants its rows in
    order by d.sqm desc, d.product_width desc, d.product_height desc,
             d.production_orderline_id;
end;
$$;

alter function mapping.get_production_orderline_manifest(integer, date, integer, integer, integer, integer[]) owner to xfw3;

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
--                  "config": { "nest_time": "12:00:00", "print_time": "12:30:00", ... } } }
-- config is the config_json of the rows of the scope merged key by key: the
-- row whose item group has the highest catalog.item_group.level wins a key
-- (null level loses to every level), then the row's sort_order. The label
-- (i18n) is the row's own and stays out of it. For scope imposition this is
-- where the nester reads its settings (nest_time, print_time) -- put them
-- in catalog.xbom.config_json of the rows that carry them, give their item
-- groups a level, and the merge does the rest. units_threshold and
-- delivery_hours left the xbom on 14 Sep 2026: they live in
-- legacy.imposition_group.rules_json (unit_threshold, delivery_hours).
--
-- A material that nests with a parent (legacy.imposition_group
-- .parent_imposition_group_id: 28 Dibond Digital 3mm under 300 Dilite 3mm)
-- takes the parent's nest group: its material row carries the parent's
-- item path, and the material abbreviation in its label is the parent's
-- (the rest of the label, the coverage, stays). The nesting queue then
-- groups parent and child together (board 79, manifest_json.imposition).
-- Orderlines without manifest rows get NULL. Only changed rows are written,
-- so re-running retroactively is cheap; returns the number of rows updated.
with target as (
    select distinct t.production_orderline_id
    from unnest(p_production_orderline_ids) as t(production_orderline_id)
),
parent_material as (
    -- the orderlines whose material nests with a parent group: the child's
    -- material item (the row to rewrite), the parent's material item path,
    -- and the material option of both (the first part of their xbom codes)
    -- with its labels, so the abbreviation can be swapped per language
    select t.production_orderline_id,
           ci.item_code            as child_item_code,
           pi.item_code_path::text as parent_path,
           lc.option_json -> 'i18n' as child_i18n,
           lp.option_json -> 'i18n' as parent_i18n
    from target t
    join mapping.component_specs cs using (production_orderline_id)
    -- the tenant of the orderline through its production company; the
    -- groups are per tenant, an unknown company is Dokkum (1)
    left join site.tenant tn on tn.production_company_id = cs.production_company_id
    join legacy.imposition_group g on g.imposition_group_id = cs.material_id
                                   and g.tenant_id = coalesce(tn.tenant_id, 1)
                                   and g.parent_imposition_group_id is not null
    join legacy.imposition_group pg on pg.imposition_group_id = g.parent_imposition_group_id
                                    and pg.tenant_id = g.tenant_id
    join catalog.item ci on ci.item_code_path = any (g.item_code_paths)  and ci.item_group_code = 'material'
    join catalog.item pi on pi.item_code_path = any (pg.item_code_paths) and pi.item_group_code = 'material'
    left join lateral (
        select m.option_code
        from catalog.xbom x
        cross join lateral split_part(x.option_code, ';', 1) as m(option_code)
        where x.item_code = ci.item_code and x.scope = 'imposition' and x.version_status = 'active'
          and m.option_code like 'material.%'
        limit 1) co on true
    left join lateral (
        select m.option_code
        from catalog.xbom x
        cross join lateral split_part(x.option_code, ';', 1) as m(option_code)
        where x.item_code = pi.item_code and x.scope = 'imposition' and x.version_status = 'active'
          and m.option_code like 'material.%'
        limit 1) po on true
    left join catalog.library_option lc on lc.option_code = co.option_code and lc.version_status = 'active'
    left join catalog.library_option lp on lp.option_code = po.option_code and lp.version_status = 'active'
),
lang_agg as (
    -- one abb line per scope and language, joined in manifest order; the
    -- material row of a child starts with the parent's material abbreviation
    select s.production_orderline_id, s.scope, l.lang,
           string_agg(nullif(
               case when pm.child_item_code is not null
                     and coalesce(pm.child_i18n -> l.lang ->> 'abb', '') <> ''
                     and left(l.slots ->> 'abb', length(pm.child_i18n -> l.lang ->> 'abb')) = pm.child_i18n -> l.lang ->> 'abb'
                    then coalesce(pm.parent_i18n -> l.lang ->> 'abb', '')
                         || substr(l.slots ->> 'abb', length(pm.child_i18n -> l.lang ->> 'abb') + 1)
                    else l.slots ->> 'abb'
               end, ''), ', ' order by s.sort_order) as abb
    from mapping.spec_unit_manifest s
    join target t using (production_orderline_id)
    cross join lateral jsonb_each(coalesce(s.config_json -> 'i18n', '{}'::jsonb)) as l(lang, slots)
    left join parent_material pm on pm.production_orderline_id = s.production_orderline_id
                                and s.scope = 'imposition'
                                and s.item_code = pm.child_item_code
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
    -- the paths of the linked catalog items, in manifest order; a child's
    -- material row carries the parent's path
    select s.production_orderline_id, s.scope,
           to_jsonb(array_remove(
               array_agg(coalesce(pm.parent_path, i.item_code_path::text) order by s.sort_order), null)) as item_code_paths
    from mapping.spec_unit_manifest s
    join target t using (production_orderline_id)
    left join catalog.item i on i.item_code = s.item_code
    left join parent_material pm on pm.production_orderline_id = s.production_orderline_id
                                and s.scope = 'imposition'
                                and s.item_code = pm.child_item_code
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

-- One read for the imposition-group lanes (labels) of the nest boards:
-- print_schedule (75), impose_plan (76) and whatever follows. One row per
-- pattern item (source material-plan) of the newest material plan of a day:
-- one per nest moment of a material (lane_item.instance, in moment order),
-- the schedule row through lane_item.source_ref
-- (<material_print_schedule_id>:<date>:<instance>). The nests of a row are its own batch
-- rows (action.batch_lane_item, docs/plan-batch-lane-item.md); the instance
-- and the last status (action.lane_item_event) ride along. No noop
-- windows any more: the non-working time is the time scale's
-- (production.get_timeline_view_segments), not a row. imposition_group_id is
-- the material_id alias until the xbom groups arrive.
--
-- The resource lanes are action.get_plan_lanes_resource. p_step here names the
-- step of the plan to read (the plan whose steps carry it); p_steps there names
-- the steps whose resources are lanes -- two different questions, so two reads.
--
-- The nest moment of a row is on the item (lane_item.nest_moment_code, stamped
-- by mock.generate_plan: one item per code of material_print_schedule.nest_moment_codes,
-- instance in moment order). The lookup (lookup_nest_moments) gives the class
-- of that code: its fixed group, the moment it starts at -- on the day the code
-- is offset to, a 48+ item of plan day D nests on D+1 -- and the nest and
-- print time (nest_time, print_time: the third label level of board 75). The
-- material, line, tenant and impose path of a row come from the schedule row
-- named in source_ref; the item's own time is a time on the day of its moment.
--
-- The days in view are the days the time scale of p_view_code has segments for
-- (production.get_timeline_view_segments; with nest-time-scale the day before
-- and the day of p_until), each with the plan of its own date, so a row carries
-- the lane_item_id of that day's plan, its day_offset (-1 the day before, 0 the
-- day of p_until) and the plan_date behind it. Those days are working days: the
-- day before a Monday is the Friday before it, and a weekend or a mandatory day
-- off is no day. The axis decides which rows exist as well: the moment of a row
-- (its own time, else the moment of its class) has to fall inside its span. The
-- evening moment of the day before is therefore a row, while that day's noon
-- moment, which the axis does not reach, is not. A day between the first and
-- the last day of the view without segments of its own repeats day 0 -- the
-- repeat rule of the client as well (docs/handoff-time-scale-frontend.md). A
-- class without a moment lands nowhere and is a row on day 0 only. A view
-- without segments shows day 0 and every moment.
--
-- The offset rule: only a fixed group (its own time, else the class moment) or
-- a pinned item carries start_offset_in_seconds -- on a time scale. On a day
-- scale (segments of a day) every item carries its class moment, since a day
-- scale cannot chain within a day; the cards of board 75 need the item on its
-- day. Every other item is a filler
-- and serves null -- the client chains fillers itself (chain_scope), a
-- moved-but-unpinned item springs back on refresh. The offset counts from
-- midnight of day 0, as the segments of the axis do: a row of the day before
-- carries its own time minus a day, so the evening moment of that day comes out
-- negative. A day before day 0 is history: every item of it has its time (its
-- own, else the moment of its class) and is pinned, so nothing of yesterday
-- ends up in today's chain or moves. An item with nests is pinned as well: it
-- keeps the moment of its first nest (the lane item stores no time of its own
-- yet), while the items without nests keep flowing with the clock -- so a
-- nested row stays where it was nested and the free rows around it swap past it.
--
-- Duration is not computed here. The row carries the formula of its resource
-- and the variables, and the board evaluates -- otherwise a drag to another
-- resource could not change the duration. The chaining offset
-- (next_start_offset_in_seconds) belongs to the resource:
-- resource_json.next_start_lag_in_seconds; the connector mechanism replaces
-- this column later.
-- the return type changes (plan_date, then the nest moment), so the old one has to go first
drop function if exists action.get_plan_lanes_imposition_group(timestamp with time zone, text, text, integer[], boolean, integer, integer, text);
-- the version before the days came from the view
drop function if exists action.get_plan_lanes_imposition_group(timestamp with time zone, text, text, integer[], boolean, text);

create function action.get_plan_lanes_imposition_group(p_until timestamp with time zone DEFAULT now(), p_step text DEFAULT 'impose'::text, p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_only_starting_today boolean DEFAULT true, p_view_code text DEFAULT 'nest-time-scale'::text) returns TABLE(imposition_group_id integer, material_id integer, material_name text, production_line_id integer, tenant_id integer, tenant_name text, resource_path ltree, resource_uid text, resource_name text, delivery_hours integer, min_delivery_hours integer, day_offset integer, plan_date date, sort_order numeric, param_json jsonb, formula jsonb, data jsonb, fixed_group text, is_pinned boolean, start_offset_in_seconds integer, next_start_offset_in_seconds integer, lane_item_id bigint, lane_id bigint, instance integer, status text, nest_moment_code text, nest_time time, print_time time)
	stable
	language plpgsql
as $$
#variable_conflict use_column
DECLARE
    v_date   date;
    v_group  jsonb;    -- nest moment code -> its fixed group
    v_offset jsonb;    -- nest moment code -> the moment the class starts at, on its own day
    v_moment jsonb;    -- nest moment code -> its lookup element (day_offset, nest and print time)
    v_from   integer;  -- the span the board draws, from midnight of day 0
    v_to     integer;  -- the end of the last segment, so exclusive
    v_look_back_days  integer;  -- the days the view reaches before day 0 ...
    v_look_ahead_days integer;  -- ... and after it
    -- a day scale (segments of a day, print-day-scale) places an item on a
    -- day and cannot chain fillers within one: every item with a code carries
    -- its class moment there. A time scale (nest-time-scale) keeps the
    -- fillers for the client to chain
    v_day_scale boolean;
BEGIN
    SELECT coalesce((v.value ->> 'segment_size_in_seconds')::integer >= 86400, false)
    INTO v_day_scale
    FROM production.lookup l
    CROSS JOIN LATERAL jsonb_array_elements(l.lookup_json) AS v(value)
    WHERE l.lookup = 'lookup_timeline_views'
      AND v.value ->> 'code' = p_view_code;
    v_day_scale := coalesce(v_day_scale, false);

    v_date := (p_until AT TIME ZONE current_setting('TimeZone'))::date;

    -- The classes per nest moment code (production.lookup,
    -- lookup_nest_moments): the fixed group, the moment the class starts at
    -- and the element itself. A class is a template, so this is where a lane
    -- item gets its first time; once the planner moves the item, the item wins
    -- (see the coalesce below).
    SELECT coalesce(jsonb_object_agg(v.value ->> 'code', v.value -> 'fixed_group')
                    FILTER (WHERE v.value ->> 'fixed_group' IS NOT NULL), '{}'::jsonb),
           coalesce(jsonb_object_agg(v.value ->> 'code',
                                     v.value #> '{nest_moments,0,nest_time,start_offset_in_seconds}')
                    FILTER (WHERE v.value #>> '{nest_moments,0,nest_time,start_offset_in_seconds}' IS NOT NULL),
                    '{}'::jsonb),
           coalesce(jsonb_object_agg(v.value ->> 'code', v.value), '{}'::jsonb)
    INTO v_group, v_offset, v_moment
    FROM production.lookup l
    CROSS JOIN LATERAL jsonb_array_elements(l.lookup_json) AS v(value)
    WHERE l.lookup = 'lookup_nest_moments';

    -- The days in view and the span of the axis. The days are the ones the
    -- view has segments for, before and after day 0; the span runs from the
    -- first segment of the first day to the last segment of the last day,
    -- counted from midnight of day 0. A day in between without segments of its
    -- own repeats day 0. Taking the day out of a segment offset gives its time
    -- on its own day; adding the day of a row back puts that row on the axis.
    WITH segment AS (
        SELECT s.day_offset,
               min(s.start_offset_in_seconds - s.day_offset * 86400) AS from_in_seconds,
               max(s.end_offset_in_seconds   - s.day_offset * 86400) AS to_in_seconds
        FROM production.get_timeline_view_segments(
                 p_code       => p_view_code,
                 p_until      => p_until,
                 p_look_back  => -1,
                 p_look_ahead => -1,
                 p_tenant_ids => p_tenant_ids) s
        GROUP BY s.day_offset
    )
    SELECT b.look_back_days, b.look_ahead_days,
           min(d.day_offset * 86400 + coalesce(s.from_in_seconds, z.from_in_seconds)),
           max(d.day_offset * 86400 + coalesce(s.to_in_seconds,   z.to_in_seconds))
    INTO v_look_back_days, v_look_ahead_days, v_from, v_to
    FROM (SELECT coalesce(-least(min(day_offset), 0), 0)   AS look_back_days,
                 coalesce(greatest(max(day_offset), 0), 0) AS look_ahead_days
          FROM segment) b
    CROSS JOIN generate_series(-b.look_back_days, b.look_ahead_days) AS d(day_offset)
    LEFT JOIN segment s ON s.day_offset = d.day_offset
    LEFT JOIN segment z ON z.day_offset = 0
    GROUP BY b.look_back_days, b.look_ahead_days;

    RETURN QUERY
    WITH plan_day AS (
        -- The days in view are working days, not calendar days: the day before
        -- a Monday is the Friday before it. day_offset is the place on the axis
        -- (0 the day of p_until, -1 the day before it), plan_date the working
        -- day that fills it -- a weekend and a mandatory day off of the tenants
        -- asked are no day at all (action.dates). Bounded to four months, which
        -- covers any view.
        SELECT 0 AS day_offset, v_date AS plan_date
        UNION ALL
        SELECT -b.day_number, b.date
        FROM (SELECT d.date, row_number() OVER (ORDER BY d.date DESC)::integer AS day_number
              FROM action.dates d
              WHERE d.date < v_date AND d.date >= v_date - 120
                AND d.is_weekend = false
                AND NOT (coalesce(p_tenant_ids, d.tenants_mandatory_day_off) <@ d.tenants_mandatory_day_off
                         AND d.tenants_mandatory_day_off <> '{}')) b
        WHERE b.day_number <= v_look_back_days
        UNION ALL
        SELECT a.day_number, a.date
        FROM (SELECT d.date, row_number() OVER (ORDER BY d.date)::integer AS day_number
              FROM action.dates d
              WHERE d.date > v_date AND d.date <= v_date + 120
                AND d.is_weekend = false
                AND NOT (coalesce(p_tenant_ids, d.tenants_mandatory_day_off) <@ d.tenants_mandatory_day_off
                         AND d.tenants_mandatory_day_off <> '{}')) a
        WHERE a.day_number <= v_look_ahead_days
    ),
    item AS (
        -- one row per material item of that day's plan: one per nest moment
        SELECT d.day_offset, d.plan_date, li.lane_id, li.lane_item_id, li.sort_order, li.is_pinned,
               li.start_offset_in_seconds, li.nest_moment_code,
               igli.imposition_group_id,
               nullif(split_part(li.source_ref, ':', 1), '')::bigint AS material_print_schedule_id,
               -- the nests of the item itself and the moment the first one was made
               nst.first_nest_at IS NOT NULL AS has_nests,
               nst.first_nest_at,
               li.instance,
               -- the last status of the item: plan until it is released
               coalesce(ev.status, 'plan') AS status
        FROM plan_day d
        CROSS JOIN LATERAL (
            -- the newest material plan of that date, step and line type
            SELECT p.plan_id
            FROM action.plan p
            WHERE p.plan_date = d.plan_date
              AND p.type = 'material-resource-plan'
              AND p_step = ANY (p.steps)
              AND (p_line_type IS NULL OR p.line_type = p_line_type)
            ORDER BY p.plan_id DESC
            LIMIT 1
        ) tp
        JOIN action.plan_lane pl ON pl.plan_id = tp.plan_id
        JOIN action.lane_item li ON li.lane_id = pl.lane_id
                                AND li.type = 'plan' AND li.source = 'material-plan'
        LEFT JOIN action.imposition_group_lane_item igli ON igli.lane_item_id = li.lane_item_id
        LEFT JOIN LATERAL (
            SELECT min(n.nested_at) AS first_nest_at
            FROM action.batch_lane_item b
            JOIN legacy.nest n ON n.nest_id = ANY (b.nest_ids)
            WHERE b.lane_item_id = li.lane_item_id
        ) nst ON true
        LEFT JOIN LATERAL (
            SELECT e.status
            FROM action.lane_item_event e
            WHERE e.lane_item_id = li.lane_item_id
            ORDER BY e.moved_at DESC, e.lane_item_event_id DESC
            LIMIT 1
        ) ev ON true
    ),
    -- one interval check per distinct (start, days) pair of the plan's own
    -- materials and per day in view, instead of one per row: a check costs
    -- ~0,5 ms in get_interval_dates, so per row it was hundreds of
    -- milliseconds. The extra (null, 1) pair covers materials without a
    -- schedule row.
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
        SELECT s.interval_start_date, s.interval_days, w.day_offset
        FROM (SELECT DISTINCT mps.interval_start_date,
                     coalesce(nullif(mps.interval_days, 0), 1) AS interval_days
              FROM item i
              JOIN mock.material_print_schedule mps ON mps.material_print_schedule_id = i.material_print_schedule_id
              UNION
              SELECT NULL::date, 1) s
        CROSS JOIN plan_day w
        WHERE NOT p_only_starting_today
           OR EXISTS (
                  SELECT 1
                  FROM action.get_interval_dates(
                           (SELECT min(d.date)
                            FROM action.dates d
                            WHERE d.date >= coalesce(s.interval_start_date, w.plan_date)
                              AND d.is_weekend = false
                              AND NOT (coalesce(p_tenant_ids, d.tenants_mandatory_day_off) <@ d.tenants_mandatory_day_off and d.tenants_mandatory_day_off <> '{}')),
                           w.plan_date, s.interval_days, 1, false, false, 0,
                           p_tenant_ids) AS i(interval_date)
                  WHERE i.interval_date = w.plan_date)
    )
    SELECT i.imposition_group_id,
           -- alias: the group id is the material id until the xbom groups arrive
           coalesce(mps.material_id, i.imposition_group_id),
           mps.material_name, mps.production_line_id,
           mps.tenant_id, t.name,
           mps.resource_path, r.resource_uid, r.resource_name,
           mps.delivery_hours, mps.min_delivery_hours,
           i.day_offset, i.plan_date, i.sort_order,
           -- the variables the board evaluates with: the resource constants,
           -- the format of the group, and the work itself
           production.get_setting_numbers(rs.setting_json)
           || coalesce(w.format_json, '{}'::jsonb)
           -- the sizes of the material and its media type (1 sheet, 3 roll):
           -- what a reader needs to say how much of a size the work takes
           || jsonb_build_object('specs', coalesce(mpl.line_json -> 'specs', '[]'::jsonb),
                                 'material_media_type_id',
                                 (mpl.line_json ->> 'material_media_type_id')::integer),
           coalesce(rs.setting_json -> 'formula', '[]'::jsonb),
           jsonb_build_object('valid_resources', coalesce(vres.resources, '[]'::jsonb)),
           cls.fixed_group,
           -- the mutable truth lives on the lane item; a past day is pinned as a
           -- whole, and so is an item that already has nests
           i.is_pinned OR i.day_offset < 0 OR i.has_nests,
           c.start_offset_in_seconds,
           (r.resource_json ->> 'next_start_lag_in_seconds')::integer,
           i.lane_item_id, i.lane_id, i.instance, i.status,
           -- the nest moment of the row and the nest and print time of that
           -- moment (see the head of the file)
           i.nest_moment_code,
           (v_moment #>> ARRAY[i.nest_moment_code, 'nest_moments', '0', 'nest_time', 'time'])::time,
           (v_moment #>> ARRAY[i.nest_moment_code, 'nest_moments', '0', 'print_time', 'time'])::time
    FROM item i
    LEFT JOIN mock.material_print_schedule mps ON mps.material_print_schedule_id = i.material_print_schedule_id
    LEFT JOIN mapping.material_production_line mpl
           ON (mpl.material_id, mpl.production_line_id) = (mps.material_id, mps.production_line_id)
    LEFT JOIN relation.resource r ON r.resource_path = mps.resource_path
    LEFT JOIN site.tenant t ON t.tenant_id = mps.tenant_id
    -- the speed setting of that resource for that group
    CROSS JOIN LATERAL (
        SELECT production.get_resource_setting(mps.resource_path, i.imposition_group_id) AS setting_json
    ) rs
    -- the format of the group: waste and imposition size, first entry that
    -- matches the material width of the resource path
    LEFT JOIN LATERAL (
        SELECT jsonb_build_object(
                   'waste_factor',   (f.value ->> 'waste_factor')::numeric,
                   'imposition_sqm', (f.value ->> 'imposition_sqm')::numeric) AS format_json
        FROM legacy.imposition_group g
        CROSS JOIN LATERAL jsonb_array_elements(coalesce(g.rules_json -> 'waste', '[]'::jsonb)) f
        WHERE g.imposition_group_id = i.imposition_group_id
          -- the group of the row's tenant; a row without one is Dokkum's (1)
          AND g.tenant_id = coalesce(mps.tenant_id, 1)
        ORDER BY (f.value ->> 'width')::numeric DESC
        LIMIT 1
    ) w ON true
    -- every impose resource the item may be dragged to, with its own constants
    -- for this group, so the duration follows the gesture
    LEFT JOIN LATERAL (
        SELECT jsonb_agg(jsonb_build_object('resource_path', vr.resource_path::text,
                                            'resource_name', vr.resource_name)
                         || production.get_setting_numbers(
                                production.get_resource_setting(vr.resource_path, i.imposition_group_id))
                         ORDER BY vr.resource_path) AS resources
        FROM relation.resource vr
        WHERE vr.resource_path ~ '*.impose.*'
          AND subpath(vr.resource_path, 0, 2) = subpath(mps.resource_path, 0, 2)
    ) vres ON true
    -- the class of the row is its nest moment code: the fixed group, the moment
    -- the class starts at -- on the day the code is offset to, so a 48+ item of
    -- plan day D lands on D+1 -- and the item's own time, a time on that same day
    CROSS JOIN LATERAL (
        SELECT coalesce((v_moment #>> ARRAY[i.nest_moment_code, 'day_offset'])::integer, 0) AS moment_day_offset
    ) md
    CROSS JOIN LATERAL (
        SELECT v_group ->> i.nest_moment_code AS fixed_group,
               (v_offset ->> i.nest_moment_code)::integer + md.moment_day_offset * 86400 AS class_offset,
               i.start_offset_in_seconds + md.moment_day_offset * 86400 AS own_offset
    ) cls
    -- only a fixed group (its own time, else the class moment), an item of a
    -- past day, a pinned item or an item with nests (its own time, else the
    -- clock time of its first nest on its day) has a time of its own; every
    -- other item is a filler and serves null -- the client chains fillers
    -- itself. The day of the row moves the offset to midnight of day 0
    CROSS JOIN LATERAL (
        SELECT CASE WHEN cls.fixed_group IS NOT NULL OR i.day_offset < 0 OR v_day_scale
                    THEN coalesce(cls.own_offset, cls.class_offset)
                    WHEN i.is_pinned THEN cls.own_offset
                    WHEN i.has_nests
                    THEN coalesce(cls.own_offset,
                                  extract(epoch FROM (i.first_nest_at AT TIME ZONE 'Europe/Amsterdam')
                                                     - i.plan_date::timestamp)::integer)
               END + i.day_offset * 86400 AS start_offset_in_seconds
    ) c
    WHERE (p_tenant_ids IS NULL OR mps.tenant_id = ANY (p_tenant_ids))
      -- only materials whose interval says the day of the row is a production day
      AND (NOT p_only_starting_today OR EXISTS (
               SELECT 1 FROM allowed_interval ai
               WHERE ai.interval_start_date IS NOT DISTINCT FROM mps.interval_start_date
                 AND ai.interval_days = coalesce(nullif(mps.interval_days, 0), 1)
                 AND ai.day_offset = i.day_offset))
      -- the axis decides which moments are rows: the time the row carries,
      -- else the moment of its class. A moment inside the span counts also
      -- when it falls in a gap between two segments -- the client places such
      -- an item at the start of the next segment
      AND CASE WHEN coalesce(c.start_offset_in_seconds, cls.class_offset) IS NULL
                    -- a class without a moment lands nowhere and is a row on
                    -- the day of p_until only
                    THEN i.day_offset = 0
               WHEN v_from IS NULL THEN true
               ELSE coalesce(c.start_offset_in_seconds,
                             cls.class_offset + i.day_offset * 86400)
                    BETWEEN v_from AND v_to - 1
          END
    ORDER BY i.day_offset, mps.tenant_id, i.sort_order;
END;
$$;

alter function action.get_plan_lanes_imposition_group(timestamp with time zone, text, text, integer[], boolean, text) owner to xfw3;

commit;

-- check ---------------------------------------------------------------------------
select 'groups per tenant'                       as what, (select string_agg(tenant_id || ':' || n, ', ') from (select tenant_id, count(*) n from legacy.imposition_group group by 1 order by 1) x) as value
union all
select 'mock rows',                                     (select count(*)::text from mock.material_print_schedule)
union all
select 'mock rows without a group row (expect 145, 415)', (select coalesce(string_agg(mps.material_id::text, ', ' order by mps.material_id), '-') from mock.material_print_schedule mps where not exists (select 1 from legacy.imposition_group g where (g.tenant_id, g.imposition_group_id) = (mps.tenant_id, mps.material_id)))
union all
select 'roots with delivery_hours (expect 186)',        (select count(*)::text from legacy.imposition_group where rules_json ? 'delivery_hours')
union all
select 'schedule entries (expect 66)',                  (select count(*)::text from legacy.imposition_group g cross join lateral jsonb_array_elements(coalesce(g.rules_json -> 'schedules', '[]')) s)
union all
select 'resource paths unknown (expect -)',             (select coalesce(string_agg(distinct s.value ->> 'resource_path', ', '), '-') from legacy.imposition_group g cross join lateral jsonb_array_elements(coalesce(g.rules_json -> 'schedules', '[]')) s where not exists (select 1 from relation.resource r where r.resource_path = (s.value ->> 'resource_path')::ltree))
union all
select 'runs without start_offset (expect 0)',          (select count(*)::text from legacy.imposition_group g cross join lateral jsonb_array_elements(coalesce(g.rules_json -> 'schedules', '[]')) s cross join lateral jsonb_array_elements(s.value -> 'intervals') i cross join lateral jsonb_array_elements(i.value -> 'runs') r where r.value -> 'start_offset' is null)
union all
select 'xbom rows with the old keys (expect 0)',        (select count(*)::text from catalog.xbom where config_json ?| array['units_threshold', 'delivery_hours'])
union all
select 'xbom backup rows (expect 234)',                 (select count(*)::text from catalog.xbom_config_backup_20260914)
union all
select 'materials (get_materials, sheet)',             (select count(*)::text from mapping.get_materials(null, 'sheet'));
