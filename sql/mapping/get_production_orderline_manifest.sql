-- signature changes, so the old ones have to go first
drop function if exists mapping.get_production_orderline_manifest(integer, date, text, integer);
drop function if exists mapping.get_production_orderline_manifest(integer, timestamp with time zone, integer, text, integer, integer);
drop function if exists mapping.get_production_orderline_manifest(integer, date, integer, text, integer, integer);
drop function if exists mapping.get_production_orderline_manifest(integer, date, integer, text, integer, integer, integer[]);

create function mapping.get_production_orderline_manifest(p_material_id integer, p_date date DEFAULT CURRENT_DATE, p_look_ahead_days integer DEFAULT '-1'::integer, p_threshold integer DEFAULT 1, p_domain_id integer DEFAULT 1, p_tenant_ids integer[] DEFAULT NULL::integer[]) returns TABLE(number text, order_sequence integer, order_id integer, production_order_id integer, production_orderline_id integer, sales_orderline_id integer, customer_json jsonb, material_id integer, material_name text, product_amount numeric, sqm numeric, product_width numeric, product_height numeric, ship_separately boolean, production_line_id integer, production_company_id integer, tenant_name text, internal_status_code text, status_sequence integer, status_level text, status_title text, part_amount integer, part_status_json jsonb, nest_date date, production_date date, logistics_date date, logistics_at timestamp without time zone, shipment_date date, dates_json jsonb, impact_json jsonb, rejected_amount numeric, produced_amount numeric, nest_json jsonb, nest_ids bigint[], delivery_class_names text[], class_names text[], unit_class_names text[], queue_class_names text[], manifest_json jsonb, fill_percentage numeric)
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
begin
    select round((1 - (f.value ->> 'waste_factor')::numeric) * 100, 0) into v_fill_percentage
    from catalog.imposition_group g
    cross join lateral jsonb_array_elements(coalesce(g.imposition_group_json -> 'waste', '[]'::jsonb)) f
    where g.imposition_group_id = p_material_id
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
        where mps.material_id = p_material_id;
    end if;

    return query
    -- The open orderlines of one material nesting from p_date on; the
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
            p_material_ids            => array[p_material_id],
            p_threshold               => p_threshold,
            p_domain_id               => p_domain_id)
    ),
    tenant as (
        select (v.value ->> 'production_company_id')::integer as production_company_id,
               v.value ->> 'name'                             as tenant_name
        from relation.lookup lk
        cross join lateral jsonb_array_elements(lk.lookup_json) as v(value)
        where lk.lookup = 'lookup_tenants'
    )
    select d.number, d.order_sequence, d.order_id, d.production_order_id,
           d.production_orderline_id, d.sales_orderline_id, d.customer_json,
           d.material_id, d.material_name, d.product_amount, d.sqm,
           d.product_width, d.product_height, d.ship_separately,
           d.production_line_id, d.production_company_id, t.tenant_name,
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
    -- biggest first, the order the nesting queue wants its rows in
    order by d.sqm desc, d.product_width desc, d.product_height desc,
             d.production_orderline_id;
end;
$$;

alter function mapping.get_production_orderline_manifest(integer, date, integer, integer, integer, integer[]) owner to xfw3;
