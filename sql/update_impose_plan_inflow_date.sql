-- Board 79: the date of a card reaches the api as a moment
-- (2026-09-11T00:00:00.000Z) and the date parameter of the inflow read
-- refused it (PARAM_TYPE_MISMATCH / INVALID_DATE). p_date becomes a timestamp
-- with time zone, like p_until of the other plan reads; the day is taken in
-- Amsterdam time. Same name, new signature: the data_table row stays.
BEGIN;

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

COMMIT;

-- check: rows for material 47 on the day, with the moment of the picked item
SELECT count(*), min(nest_moment_code), min(nest_time), min(print_time), min(lane_item_id)
FROM mock.get_impose_plan_inflow(47, '2026-09-11T00:00:00.000Z'::timestamptz);
