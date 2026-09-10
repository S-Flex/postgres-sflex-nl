-- Board 79 groups its rows per tenant on tenant_id (the fixed groups Dokkum
-- and Bad Hersfeld): the orderline manifest read gets the tenant_id of the
-- row from lookup_tenants, next to tenant_name, and the inflow read passes it
-- on. Both return types change, so both are dropped and created.
BEGIN;

-- ============ sql/mapping/get_production_orderline_manifest.sql ============
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
    -- nest group (catalog.imposition_group, the widest format, at its best
    -- waste factor). The same for every row, so the header of the queue
    -- reads it from any row. imposition_group_id is the material_id alias
    -- until the xbom groups arrive
    v_fill_percentage numeric;
    -- the group of the queue: a material whose imposition group has a parent
    -- (catalog.imposition_group.parent_imposition_group_id) is nested with
    -- its parent, so the queue is the parent's -- with the orderlines of
    -- every child, shown under the parent's material_id
    v_material_id integer := (select coalesce(g.parent_imposition_group_id, g.imposition_group_id)
                              from catalog.imposition_group g
                              where g.imposition_group_id = p_material_id);
    v_material_ids integer[];
begin
    v_material_id := coalesce(v_material_id, p_material_id);
    select array_agg(g.imposition_group_id) || v_material_id into v_material_ids
    from catalog.imposition_group g
    where g.parent_imposition_group_id = v_material_id;
    v_material_ids := coalesce(v_material_ids, array[v_material_id]);

    select round((1 - (f.value ->> 'waste_factor')::numeric) * 100, 0) into v_fill_percentage
    from catalog.imposition_group g
    cross join lateral jsonb_array_elements(coalesce(g.imposition_group_json -> 'waste', '[]'::jsonb)) f
    where g.imposition_group_id = v_material_id
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
        select (v.value ->> 'production_company_id')::integer as production_company_id,
               (v.value ->> 'tenant_id')::integer             as tenant_id,
               v.value ->> 'name'                             as tenant_name
        from relation.lookup lk
        cross join lateral jsonb_array_elements(lk.lookup_json) as v(value)
        where lk.lookup = 'lookup_tenants'
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
    left join catalog.imposition_group g on g.imposition_group_id = d.material_id
    -- biggest first, the order the nesting queue wants its rows in
    order by d.sqm desc, d.product_width desc, d.product_height desc,
             d.production_orderline_id;
end;
$$;

alter function mapping.get_production_orderline_manifest(integer, date, integer, integer, integer, integer[]) owner to xfw3;

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

create function mock.get_impose_plan_inflow(p_material_id integer, p_date timestamp with time zone DEFAULT now(), p_look_ahead_days integer DEFAULT '-1'::integer, p_threshold integer DEFAULT 1, p_line_type text DEFAULT NULL::text, p_instance integer DEFAULT NULL::integer, p_domain_id integer DEFAULT 1, p_tenant_ids integer[] DEFAULT NULL::integer[]) returns TABLE(number text, order_sequence integer, order_id integer, production_order_id integer, production_orderline_id integer, sales_orderline_id integer, customer_json jsonb, material_id integer, material_name text, product_amount numeric, sqm numeric, product_width numeric, product_height numeric, ship_separately boolean, production_line_id integer, production_company_id integer, tenant_id integer, tenant_name text, internal_status_code text, status_sequence integer, status_level text, status_title text, part_amount integer, part_status_json jsonb, nest_date date, production_date date, logistics_date date, logistics_at timestamp without time zone, shipment_date date, dates_json jsonb, impact_json jsonb, rejected_amount numeric, produced_amount numeric, nest_json jsonb, nest_ids bigint[], delivery_class_names text[], class_names text[], unit_class_names text[], queue_class_names text[], manifest_json jsonb, fill_percentage numeric, lane_item_id bigint, instance integer, nest_moment_code text, nest_time time, print_time time)
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

COMMIT;

-- check: every row carries its tenant
SELECT tenant_id, tenant_name, count(*) FROM mock.get_impose_plan_inflow(300) GROUP BY 1, 2;
