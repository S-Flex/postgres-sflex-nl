-- The cutoff window of the nest board (76) and the unit classes of the work.
--
-- 1. mapping.get_production_orderline_detail takes a moment window
--    (p_from_at, p_until_at; timestamptz, half open) next to the day window.
--    Given, it wins: the nest date compares with the moments as they are, the
--    other dates take them as clock times. The unit class of an orderline is
--    now one of three groups that do not overlap: 'units-all' within 48 hours of its
--    production moment (or past it), else 'units-lte-threshold' for
--    production_order_amount at or below p_threshold, else
--    'units-gt-threshold'.
-- 2. action.get_lane_item_work passes the moment window through to the window
--    read. The manifest sub-list per nest date has one entry per unit class,
--    three disjoint groups that add up to the total (the 'all' entry used to
--    be the total next to the two halves).
-- 3. mock.get_impose_plan reads the days and, per day, the span of the axis
--    from production.get_timeline_view_segments(p_view_code): the first
--    segment start to the last segment end, moved to the working day of that
--    day_offset. That span is the moment window of the work, so the day before
--    counts the work from its evening moment on. p_threshold (new, after
--    p_tenant_ids) goes to the work read.
--
-- Order matters: the mock calls the work read with the new parameters, the
-- work read calls the detail with them.
BEGIN;

-- ============ sql/mapping/get_production_orderline_detail.sql ============
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
    -- parent (catalog.imposition_group.parent_imposition_group_id; the group
    -- ids are the material ids) is asked counts as that material. Null stays
    -- null (every material), an empty array stays empty (none)
    v_material_ids integer[] := case when p_material_ids is null then null
        else coalesce((select array_agg(distinct m)
                       from (select unnest(p_material_ids) as m
                             union
                             select g.imposition_group_id
                             from catalog.imposition_group g
                             where g.parent_imposition_group_id = any (p_material_ids)) x),
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

-- ============ sql/action/get_lane_item_work.sql ============
-- What hangs on a lane item: the work of its scope as one row, with the lists
-- the plan boards show. This is the fold both boards kept their own copy of
-- (mock.get_impose_plan, action.get_resource_plan), in one place.
--
-- One entry in p_scope_json per row a board draws:
--   [{"lane_item_id": 8842, "nest_ids": [12,13,14], "material_id": 480,
--     "production_line_id": 5, "resource_path": "dk.sheet.impose.320",
--     "param_json": {"waste_factor": 0.22, "imposition_sqm": 4.58}}]
-- nest_ids null asks for the open work of that material on that line in the day
-- window (narrowed to the moment window p_from_at .. p_until_at when the caller
-- gives one); nest_ids set asks for the work of those nests whatever its status --
-- there the class names carry the state. resource_path and param_json come from
-- the lane read, so the format of the group stays in one place. Board 76 gives
-- one entry per lane (the nests of all its items together), board 81 one entry
-- per item (its own nests).
--
-- The reads: at most two calls to mapping.get_production_orderline_detail --
-- one for every nest in play at once (a nest hangs on one lane item, so the
-- rows map back without ambiguity) and one window call for the entries without
-- nests. Every breakdown below is a group by over that one result, instead of
-- one aggregate call per nest set.
--
-- The lists:
--   set_json      the row's own list: one entry per batch (with nests, set
--                 'batch'; the nests without a batch are batch 0) or per status
--                 (without, set 'orders'). One shape either way, "set" says which, and
--                 part_status_json rides along per entry for the distribution
--                 bar. sort_order orders the list.
--   manifest_json one entry per manifest of the work, each with items: per
--                 batch, or per nest date and unit class (the work imposed all
--                 together, or the small and the big orders apart: three groups
--                 that add up to the total).
--   step_json     per step of the work -- the scope of a manifest row is its
--                 step -- the manifest seconds plus the fastest and the slowest
--                 machine of that step.
--
-- Time comes as min and max, not as one number: the row keeps evaluating its
-- own duration on the board (a drag to another machine has to change it), and
-- min/max are that same formula run over the candidate machines of the step --
-- every resource of that step under the same site and line type as the row's
-- own resource, the same rule as valid_resources on the lane read. A step whose
-- machines carry no formula falls back to the manifest seconds and reports no
-- min/max.
--
-- A batch divides an orderline by the pieces on its nests (nest_json.amount),
-- so an orderline on nests in two batches counts once, split over the two.
drop function if exists action.get_lane_item_work(timestamp with time zone, jsonb, text, integer[], integer, integer, integer, numeric, integer[], integer);
drop function if exists action.get_lane_item_work(timestamp with time zone, jsonb, text, integer[], integer, integer, integer, numeric, integer[], integer, timestamp with time zone, timestamp with time zone);

create function action.get_lane_item_work(p_until timestamp with time zone DEFAULT now(), p_scope_json jsonb DEFAULT '[]'::jsonb, p_date_type text DEFAULT 'nest'::text, p_status_sequences integer[] DEFAULT NULL::integer[], p_look_back_days integer DEFAULT 0, p_look_ahead_days integer DEFAULT 0, p_threshold integer DEFAULT 1, p_waste_percentage numeric DEFAULT 20, p_tenant_ids integer[] DEFAULT NULL::integer[], p_domain_id integer DEFAULT 1, p_from_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_until_at timestamp with time zone DEFAULT NULL::timestamp with time zone) returns TABLE(lane_item_id bigint, material_id integer, material_name text, orderline_count integer, product_amount numeric, part_amount integer, amount numeric, sqm numeric, forecast_sqm numeric, rework_count integer, rework_sqm numeric, gross_sqm numeric, impact_json jsonb, part_status_json jsonb, specs_json jsonb, min_delivery_hours integer, seconds_to_logistics_date integer, production_impact_in_seconds integer, production_seconds_min integer, production_seconds_max integer, batch_count integer, class_names text[], unit_class_names text[], delivery_hours_json jsonb, step_json jsonb, set_json jsonb, manifest_json jsonb)
	stable
	language plpgsql
as $$
#variable_conflict use_column
DECLARE
    v_zone constant text := 'Europe/Amsterdam';
BEGIN
    RETURN QUERY
    WITH scope AS (
        -- jsonb_build_object turns a SQL null into a JSON null, and that is a
        -- scalar: every key is read through jsonb_typeof, so an entry without
        -- nests or without variables is a window entry instead of an error
        SELECT (e.value ->> 'lane_item_id')::bigint        AS lane_item_id,
               CASE WHEN jsonb_typeof(e.value -> 'nest_ids') = 'array'
                    THEN (SELECT array_agg(n::bigint)
                          FROM jsonb_array_elements_text(e.value -> 'nest_ids') AS n)
               END                                         AS nest_ids,
               (e.value ->> 'material_id')::integer        AS material_id,
               (e.value ->> 'production_line_id')::integer AS production_line_id,
               (e.value ->> 'resource_path')::ltree        AS resource_path,
               CASE WHEN jsonb_typeof(e.value -> 'param_json') = 'object'
                    THEN e.value -> 'param_json' ELSE '{}'::jsonb
               END                                         AS param_json
        FROM jsonb_array_elements(p_scope_json) AS e(value)
    ),
    -- the nests of every entry at once. An empty array is an empty scope, not
    -- "every nest", so a board without nested rows reads nothing here
    nest_detail AS MATERIALIZED (
        SELECT d.*
        FROM mapping.get_production_orderline_detail(
                 p_date             => p_until,
                 p_date_type        => p_date_type,
                 p_nest_ids         => coalesce((SELECT array_agg(DISTINCT n)
                                                 FROM scope s, unnest(s.nest_ids) n),
                                                '{}'::bigint[]),
                 p_material_ids     => coalesce((SELECT array_agg(DISTINCT s.material_id)
                                                 FROM scope s
                                                 WHERE s.nest_ids IS NOT NULL
                                                   AND s.material_id IS NOT NULL),
                                                '{}'::integer[]),
                 -- a planned nest set counts all its work whatever the status
                 p_status_sequences => NULL,
                 p_is_open          => NULL,
                 p_threshold        => p_threshold,
                 p_tenant_ids       => p_tenant_ids,
                 p_domain_id        => p_domain_id) d
    ),
    -- the open work of the materials of the entries without nests, in the day
    -- window, or in the moment window when the caller gives one; matched back
    -- on material and line
    window_detail AS MATERIALIZED (
        SELECT d.*
        FROM mapping.get_production_orderline_detail(
                 p_date             => p_until,
                 p_date_type        => p_date_type,
                 p_look_back_days   => p_look_back_days,
                 p_look_ahead_days  => p_look_ahead_days,
                 p_from_at          => p_from_at,
                 p_until_at         => p_until_at,
                 p_material_ids     => coalesce((SELECT array_agg(DISTINCT s.material_id)
                                                 FROM scope s
                                                 WHERE s.nest_ids IS NULL
                                                   AND s.material_id IS NOT NULL),
                                                '{}'::integer[]),
                 p_status_sequences => p_status_sequences,
                 p_is_open          => true,
                 p_threshold        => p_threshold,
                 p_tenant_ids       => p_tenant_ids,
                 p_domain_id        => p_domain_id) d
    ),
    -- one row per lane item and orderline, whichever scope it came from
    work AS (
        SELECT s.lane_item_id, s.nest_ids AS scope_nest_ids, s.material_id AS scope_material_id,
               s.resource_path, s.param_json,
               d.production_orderline_id, d.material_id, d.material_name, d.production_line_id,
               d.product_amount, d.part_amount, d.sqm, d.delivery_hours,
               d.status_sequence, d.internal_status_code, d.status_title, d.status_level,
               d.part_status_json, d.nest_date, d.logistics_at, d.nest_json,
               d.impact_json, d.class_names, d.unit_class_names,
               d.manifest_json, d.production_impact_in_seconds, d.impact_scope_json
        FROM nest_detail d
        JOIN scope s ON s.nest_ids && d.nest_ids
                    -- the nests decide the work, but the material of the row has
                    -- the last word: work of another material nested here
                    -- belongs to that material's own row
                    AND (s.material_id IS NULL OR s.material_id = d.material_id)
        UNION ALL
        SELECT s.lane_item_id, s.nest_ids, s.material_id, s.resource_path, s.param_json,
               d.production_orderline_id, d.material_id, d.material_name, d.production_line_id,
               d.product_amount, d.part_amount, d.sqm, d.delivery_hours,
               d.status_sequence, d.internal_status_code, d.status_title, d.status_level,
               d.part_status_json, d.nest_date, d.logistics_at, d.nest_json,
               d.impact_json, d.class_names, d.unit_class_names,
               d.manifest_json, d.production_impact_in_seconds, d.impact_scope_json
        FROM window_detail d
        JOIN scope s ON s.nest_ids IS NULL
                    AND s.material_id = d.material_id
                    AND s.production_line_id = d.production_line_id
    ),
    -- the batch of the work: the pieces of the orderline on the nests of that
    -- batch against its pieces on all the nests of this row
    work_batch AS (
        SELECT w.lane_item_id, w.production_orderline_id,
               coalesce((n.value ->> 'batch_id')::integer, 0)            AS batch_id,
               count(DISTINCT (n.value ->> 'nest_id')::bigint)::integer  AS nest_count,
               sum((n.value ->> 'amount')::numeric)                      AS batch_amount
        FROM work w
        CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(w.nest_json) = 'array'
                                                     THEN w.nest_json ELSE '[]'::jsonb END) AS n(value)
        WHERE w.scope_nest_ids IS NOT NULL
          AND (n.value ->> 'nest_id')::bigint = ANY (w.scope_nest_ids)
        GROUP BY 1, 2, 3
    ),
    work_batch_share AS (
        SELECT b.lane_item_id, b.production_orderline_id, b.batch_id, b.nest_count,
               b.batch_amount / nullif(sum(b.batch_amount) OVER (
                   PARTITION BY b.lane_item_id, b.production_orderline_id), 0) AS share
        FROM work_batch b
    ),
    -- one key per entry of the row's list, so the numbers, the part statuses
    -- and the class names of that entry are grouped the same way
    work_set AS (
        SELECT w.lane_item_id,
               coalesce('batch:' || b.batch_id, 'orders:' || w.status_sequence) AS set_key,
               b.batch_id, b.nest_count, coalesce(b.share, 1) AS share,
               w.production_orderline_id, w.sqm, w.part_status_json, w.class_names,
               w.status_sequence, w.internal_status_code, w.status_title, w.status_level,
               (w.impact_json ->> 'rework_count')::integer AS rework_count,
               (w.impact_json ->> 'rework_sqm')::numeric   AS rework_sqm
        FROM work w
        LEFT JOIN work_batch_share b ON b.lane_item_id = w.lane_item_id
                                    AND b.production_orderline_id = w.production_orderline_id
    ),
    total AS (
        SELECT w.lane_item_id,
               -- the material of the work when it is one; a mixed set has none
               CASE WHEN count(DISTINCT w.material_id) = 1 THEN min(w.material_id) END   AS material_id,
               CASE WHEN count(DISTINCT w.material_id) = 1 THEN min(w.material_name) END AS material_name,
               count(*)::integer                                          AS orderline_count,
               sum(w.product_amount)                                      AS product_amount,
               sum(w.part_amount)::integer                                AS part_amount,
               sum(greatest(w.part_amount, w.product_amount))             AS amount,
               round(sum(w.sqm), 2)                                       AS sqm,
               sum((w.impact_json ->> 'rework_count')::integer)::integer   AS rework_count,
               sum((w.impact_json ->> 'rework_amount')::numeric)          AS rework_amount,
               round(sum((w.impact_json ->> 'rework_sqm')::numeric), 2)    AS rework_sqm,
               -- the shortest delivery time in the work itself, not the setting
               min(w.delivery_hours)                                      AS min_delivery_hours,
               -- how much time the tightest orderline still has
               floor(extract(epoch FROM (min(w.logistics_at)
                                         - (p_until AT TIME ZONE v_zone))))::integer
                                                                          AS seconds_to_logistics_date,
               sum(w.production_impact_in_seconds)::integer                AS production_impact_in_seconds
        FROM work w
        GROUP BY w.lane_item_id
    ),
    total_class AS (
        SELECT x.lane_item_id,
               array_agg(DISTINCT x.class_name ORDER BY x.class_name)
                   FILTER (WHERE x.kind = 'class')      AS class_names,
               array_agg(DISTINCT x.class_name ORDER BY x.class_name)
                   FILTER (WHERE x.kind = 'unit')       AS unit_class_names
        FROM (
            SELECT w.lane_item_id, 'class' AS kind, c AS class_name
            FROM work w CROSS JOIN LATERAL unnest(coalesce(w.class_names, '{}'::text[])) c
            UNION ALL
            SELECT w.lane_item_id, 'unit', c
            FROM work w CROSS JOIN LATERAL unnest(coalesce(w.unit_class_names, '{}'::text[])) c
        ) x
        GROUP BY x.lane_item_id
    ),
    -- the work per delivery class of the row: a board that counts the time of
    -- one class only (the width of a nest row) picks its class here
    total_delivery AS (
        SELECT d.lane_item_id,
               jsonb_object_agg(d.delivery_hours::text, jsonb_build_object(
                   'orderline_count',              d.orderline_count,
                   'sqm',                          d.sqm,
                   'production_impact_in_seconds', d.production_impact_in_seconds))
                   AS delivery_hours_json
        FROM (SELECT w.lane_item_id, w.delivery_hours,
                     count(*)::integer                            AS orderline_count,
                     round(sum(w.sqm), 2)                          AS sqm,
                     sum(w.production_impact_in_seconds)::integer  AS production_impact_in_seconds
              FROM work w
              WHERE w.delivery_hours IS NOT NULL
              GROUP BY 1, 2) d
        GROUP BY d.lane_item_id
    ),
    -- the part statuses of the whole row, summed per status
    total_part AS (
        SELECT p.lane_item_id,
               jsonb_agg(jsonb_build_object(
                   'sequence', p.sequence, 'internal_status_code', p.internal_status_code,
                   'class_names', p.class_names, 'i18n', p.i18n, 'amount', p.amount)
                   ORDER BY p.sequence) AS part_status_json
        FROM (SELECT w.lane_item_id,
                     (e.value ->> 'sequence')::integer               AS sequence,
                     e.value ->> 'internal_status_code'              AS internal_status_code,
                     e.value -> 'class_names'                        AS class_names,
                     e.value -> 'i18n'                               AS i18n,
                     round(sum((e.value ->> 'amount')::numeric), 2)  AS amount
              FROM work w
              CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(w.part_status_json) = 'array'
                                                        THEN w.part_status_json ELSE '[]'::jsonb END) AS e(value)
              GROUP BY 1, 2, 3, 4, 5) p
        GROUP BY p.lane_item_id
    ),
    -- the manifest seconds per step of the work: the scope of a manifest row is
    -- its step
    step_seconds AS (
        SELECT w.lane_item_id, e.key AS step,
               round(sum((e.value #>> '{}')::numeric))::integer AS manifest_seconds
        FROM work w
        CROSS JOIN LATERAL jsonb_each(CASE WHEN jsonb_typeof(w.impact_scope_json) = 'object'
                                    THEN w.impact_scope_json ELSE '{}'::jsonb END) e
        GROUP BY 1, 2
    ),
    -- the candidate machines of that step: same site, same line type as the
    -- row's own resource
    candidate AS (
        SELECT ss.lane_item_id, ss.step, r.resource_path, rset.setting_json
        FROM step_seconds ss
        JOIN scope s ON s.lane_item_id = ss.lane_item_id AND s.resource_path IS NOT NULL
        JOIN relation.resource r
          ON r.step = ss.step
         AND subpath(r.resource_path, 0, 2) = subpath(s.resource_path, 0, 2)
        CROSS JOIN LATERAL (
            SELECT production.get_resource_setting(r.resource_path, s.material_id) AS setting_json
        ) rset
    ),
    -- One evaluation per machine and variable set, never per row: the formula of
    -- the machine over the work of the row. The two machines it picks are the
    -- ones the sub-rows are evaluated with as well.
    row_candidate AS MATERIALIZED (
        SELECT c.lane_item_id, c.step, c.resource_path,
               (ev.result ->> 'duration_in_seconds')::numeric AS seconds
        FROM candidate c
        JOIN total t ON t.lane_item_id = c.lane_item_id
        JOIN scope s ON s.lane_item_id = c.lane_item_id
        CROSS JOIN LATERAL (
            SELECT public.evaluate_many_nas(
                       coalesce(c.setting_json -> 'formula', '[]'::jsonb),
                       production.get_setting_numbers(s.param_json)
                       || production.get_setting_numbers(c.setting_json)
                       || jsonb_build_object('net_sqm', coalesce(t.sqm, 0))) AS result
        ) ev
    ),
    row_step AS (
        SELECT rc.lane_item_id, rc.step,
               round(min(rc.seconds))::integer AS seconds_min,
               round(max(rc.seconds))::integer AS seconds_max,
               (array_agg(rc.resource_path ORDER BY rc.seconds)
                    FILTER (WHERE rc.seconds IS NOT NULL))[1]      AS min_path,
               (array_agg(rc.resource_path ORDER BY rc.seconds DESC)
                    FILTER (WHERE rc.seconds IS NOT NULL))[1]      AS max_path
        FROM row_candidate rc
        GROUP BY 1, 2
    ),
    -- the sub-list of a manifest group: per batch when the row has nests, else
    -- per nest date and unit class: the group an orderline is imposed with (all
    -- together, or the small and the big orders apart). An orderline without a
    -- unit class goes with everything
    sub AS (
        SELECT w.lane_item_id, CASE WHEN jsonb_typeof(w.manifest_json) = 'object'
                    THEN w.manifest_json ELSE '{}'::jsonb END AS manifest,
               'batch'::text                       AS set_kind,
               b.batch_id::numeric                AS sort_order,
               b.batch_id,
               NULL::date                          AS nest_date,
               'units-all'::text                         AS unit_class,
               sum(b.nest_count)::integer          AS nest_count,
               round(sum(w.sqm * b.share), 2)      AS sqm,
               count(DISTINCT w.production_orderline_id)::integer AS orderline_count
        FROM work w
        JOIN work_batch_share b ON b.lane_item_id = w.lane_item_id
                               AND b.production_orderline_id = w.production_orderline_id
        GROUP BY 1, 2, 4, 5
        UNION ALL
        SELECT w.lane_item_id, CASE WHEN jsonb_typeof(w.manifest_json) = 'object'
                                    THEN w.manifest_json ELSE '{}'::jsonb END,
               'nest-date',
               -- the day, and behind it the unit class, so the list sorts by
               -- date with the joint group in front of the two threshold groups
               extract(epoch FROM w.nest_date)
                   + CASE u.unit_class WHEN 'units-all' THEN 0
                                       WHEN 'units-lte-threshold' THEN 1 ELSE 2 END,
               NULL::integer, w.nest_date, u.unit_class,
               NULL::integer,
               round(sum(w.sqm), 2),
               count(DISTINCT w.production_orderline_id)::integer
        FROM work w
        CROSS JOIN LATERAL unnest(coalesce(nullif(w.unit_class_names, '{}'::text[]), array['units-all'])) AS u(unit_class)
        WHERE w.scope_nest_ids IS NULL
        GROUP BY 1, 2, 4, 6, 7
    ),
    -- the same two machines per step, now over the work of the sub-row
    sub_step AS (
        SELECT sb.lane_item_id, sb.manifest, sb.set_kind, sb.batch_id, sb.nest_date, sb.unit_class,
               jsonb_object_agg(x.step, jsonb_build_object(
                   'seconds_min', x.seconds_min,
                   'seconds_max', x.seconds_max)) AS step_json
        FROM sub sb
        CROSS JOIN LATERAL (
            SELECT rs.step,
                   round(min(ev.seconds))::integer AS seconds_min,
                   round(max(ev.seconds))::integer AS seconds_max
            FROM row_step rs
            JOIN scope s ON s.lane_item_id = sb.lane_item_id
            CROSS JOIN LATERAL unnest(array_remove(array[rs.min_path, rs.max_path], NULL)) AS p(resource_path)
            CROSS JOIN LATERAL (
                SELECT production.get_resource_setting(p.resource_path, s.material_id) AS setting_json
            ) rset
            CROSS JOIN LATERAL (
                SELECT (public.evaluate_many_nas(
                            coalesce(rset.setting_json -> 'formula', '[]'::jsonb),
                            production.get_setting_numbers(s.param_json)
                            || production.get_setting_numbers(rset.setting_json)
                            || jsonb_build_object('net_sqm', coalesce(sb.sqm, 0)))
                        ->> 'duration_in_seconds')::numeric AS seconds
            ) ev
            WHERE rs.lane_item_id = sb.lane_item_id
            GROUP BY rs.step
        ) x
        GROUP BY 1, 2, 3, 4, 5, 6
    ),
    -- the unit classes as the boards name them (mapping.lookup /
    -- lookup_unit_class: code, order, i18n with title and abb)
    unit_class AS (
        SELECT u.value ->> 'code' AS code, u.value AS unit_class_json
        FROM mapping.lookup lk
        CROSS JOIN LATERAL jsonb_array_elements(lk.lookup_json) AS u(value)
        WHERE lk.lookup = 'lookup_unit_class'
    ),
    -- one entry per manifest of the work, with its sub-list
    manifest_row AS (
        SELECT sb.lane_item_id, sb.manifest,
               -- the unit classes are disjoint groups of the work, so the total
               -- is their sum
               round(sum(sb.sqm), 2)                    AS sqm,
               sum(sb.orderline_count)::integer         AS orderline_count,
               jsonb_agg(jsonb_build_object(
                   'set',             sb.set_kind,
                   'sort_order',      sb.sort_order,
                   'batch_id',       sb.batch_id,
                   'nest_date',       sb.nest_date,
                   'unit_class',      sb.unit_class,
                   'unit_class_json', uc.unit_class_json,
                   'nest_count',      sb.nest_count,
                   'orderline_count', sb.orderline_count,
                   'sqm',             sb.sqm,
                   'step_json',       coalesce(ss.step_json, '{}'::jsonb))
                   ORDER BY sb.sort_order) AS items
        FROM sub sb
        LEFT JOIN unit_class uc ON uc.code = sb.unit_class
        LEFT JOIN sub_step ss
               ON ss.lane_item_id = sb.lane_item_id
              AND ss.manifest     = sb.manifest
              AND ss.set_kind     = sb.set_kind
              AND ss.batch_id IS NOT DISTINCT FROM sb.batch_id
              AND ss.nest_date IS NOT DISTINCT FROM sb.nest_date
              AND ss.unit_class   = sb.unit_class
        GROUP BY 1, 2
    ),
    -- the row's own list: per batch with nests (set 'batch'), per status
    -- without (set 'orders')
    set_row AS (
        SELECT ws.lane_item_id, ws.set_key, 'batch'::text AS set_kind,
               ws.batch_id::numeric                              AS sort_order,
               ws.batch_id,
               ws.batch_id::text                                 AS title,
               NULL::jsonb                                        AS i18n,
               NULL::integer                                      AS sequence,
               NULL::text                                         AS internal_status_code,
               NULL::text                                         AS level,
               sum(ws.nest_count)::integer                        AS nest_count,
               count(DISTINCT ws.production_orderline_id)::integer AS orderline_count,
               round(sum(ws.rework_count * ws.share))::integer     AS rework_count,
               round(sum(ws.sqm * ws.share), 2)                   AS sqm,
               round(sum(ws.rework_sqm * ws.share), 2)            AS rework_sqm
        FROM work_set ws
        WHERE ws.batch_id IS NOT NULL
        GROUP BY 1, 2, 4, 5
        UNION ALL
        -- the i18n and the colour of a status live in mapping.internal_status
        SELECT ws.lane_item_id, ws.set_key, 'orders',
               ws.status_sequence::numeric,
               NULL::integer,
               ws.status_title,
               si.i18n,
               ws.status_sequence,
               ws.internal_status_code,
               ws.status_level,
               NULL::integer,
               count(*)::integer,
               sum(ws.rework_count)::integer,
               round(sum(ws.sqm), 2),
               round(sum(ws.rework_sqm), 2)
        FROM work_set ws
        LEFT JOIN mapping.internal_status si
               ON si.code = ws.internal_status_code AND si.domain_id = p_domain_id
        WHERE ws.batch_id IS NULL
        GROUP BY 1, 2, 4, 6, 7, 8, 9, 10
    ),
    -- the class names per entry of that list
    set_class AS (
        SELECT x.lane_item_id, x.set_key,
               array_agg(DISTINCT x.class_name ORDER BY x.class_name) AS class_names
        FROM (SELECT ws.lane_item_id, ws.set_key, c AS class_name
              FROM work_set ws
              CROSS JOIN LATERAL unnest(coalesce(ws.class_names, '{}'::text[])) c) x
        GROUP BY 1, 2
    ),
    -- the forecast of the materials on the board, over the same day window as
    -- the work: one number per material and line, the same on every row of
    -- that material
    forecast AS (
        SELECT f.material_id, f.production_line_id, sum(f.forecast_sqm) AS forecast_sqm
        FROM action.get_date_window(p_until, p_look_back_days, p_look_ahead_days,
                                    true, true, p_tenant_ids) win
        JOIN log.production_forecast_material f
          ON f.date >= win.from_date AND f.date < win.until_date
        WHERE EXISTS (SELECT 1 FROM scope s
                      WHERE s.material_id = f.material_id
                        AND s.production_line_id = f.production_line_id)
          AND (p_tenant_ids IS NULL
               OR EXISTS (SELECT 1 FROM site.tenant t
                          WHERE t.production_company_id = f.production_company_id
                            AND t.tenant_id = ANY (p_tenant_ids)))
        GROUP BY 1, 2
    ),
    -- the part statuses per entry, so the distribution bar reads them straight
    -- from the row it draws
    set_part AS (
        SELECT p.lane_item_id, p.set_key,
               jsonb_agg(jsonb_build_object(
                   'sequence', p.sequence, 'internal_status_code', p.internal_status_code,
                   'class_names', p.class_names, 'i18n', p.i18n, 'amount', p.amount)
                   ORDER BY p.sequence) AS part_status_json
        FROM (SELECT ws.lane_item_id, ws.set_key,
                     (e.value ->> 'sequence')::integer  AS sequence,
                     e.value ->> 'internal_status_code' AS internal_status_code,
                     e.value -> 'class_names'           AS class_names,
                     e.value -> 'i18n'                  AS i18n,
                     round(sum((e.value ->> 'amount')::numeric * ws.share), 2) AS amount
              FROM work_set ws
              CROSS JOIN LATERAL jsonb_array_elements(CASE WHEN jsonb_typeof(ws.part_status_json) = 'array'
                                                           THEN ws.part_status_json ELSE '[]'::jsonb END) AS e(value)
              GROUP BY 1, 2, 3, 4, 5, 6) p
        GROUP BY p.lane_item_id, p.set_key
    )
    SELECT s.lane_item_id,
           coalesce(t.material_id, s.material_id) AS material_id, t.material_name,
           t.orderline_count, t.product_amount, t.part_amount, t.amount,
           t.sqm, round(coalesce(fc.forecast_sqm, 0), 2)             AS forecast_sqm,
           t.rework_count, t.rework_sqm,
           g.gross_sqm,
           -- the one shape every overview sums
           jsonb_build_object(
               'count',         t.orderline_count,
               'amount',        t.product_amount,
               'sqm',           t.sqm,
               'rework_count',  t.rework_count,
               'rework_amount', t.rework_amount,
               'rework_sqm',    t.rework_sqm)                        AS impact_json,
           coalesce(tp.part_status_json, '[]'::jsonb)                AS part_status_json,
           -- one entry per size of the material with what the gross sqm needs
           -- of it: sheets for a sheet material, metres for a roll (sizes in
           -- cm). The sizes and the media type ride along in param_json from
           -- the lane read; the rule is the aggregate's
           (SELECT coalesce(jsonb_agg(sp.value || jsonb_build_object('amount',
                       CASE (s.param_json ->> 'material_media_type_id')::integer
                            WHEN 1 THEN ceil(g.gross_sqm / nullif((sp.value ->> 'width')::numeric
                                                                * (sp.value ->> 'height')::numeric / 10000, 0))
                            WHEN 3 THEN ceil(g.gross_sqm / nullif((sp.value ->> 'width')::numeric / 100, 0))
                       END) ORDER BY sp.ord), '[]'::jsonb)
            FROM jsonb_array_elements(CASE WHEN jsonb_typeof(s.param_json -> 'specs') = 'array'
                                           THEN s.param_json -> 'specs' ELSE '[]'::jsonb END)
                 WITH ORDINALITY AS sp(value, ord))                  AS specs_json,
           t.min_delivery_hours, t.seconds_to_logistics_date,
           t.production_impact_in_seconds,
           -- the production time of the whole work: per step the fastest and
           -- the slowest machine, the manifest seconds where a step has none
           sj.production_seconds_min, sj.production_seconds_max,
           coalesce(bc.batch_count, 0)                               AS batch_count,
           coalesce(tc.class_names, '{}'::text[])                    AS class_names,
           coalesce(tc.unit_class_names, '{}'::text[])               AS unit_class_names,
           coalesce(td.delivery_hours_json, '{}'::jsonb)             AS delivery_hours_json,
           coalesce(sj.step_json, '{}'::jsonb)                       AS step_json,
           coalesce(sr.set_json, '[]'::jsonb)                        AS set_json,
           coalesce(mr.manifest_json, '[]'::jsonb)                   AS manifest_json
    FROM scope s
    LEFT JOIN total t ON t.lane_item_id = s.lane_item_id
    LEFT JOIN total_part  tp ON tp.lane_item_id = s.lane_item_id
    LEFT JOIN total_class tc ON tc.lane_item_id = s.lane_item_id
    LEFT JOIN total_delivery td ON td.lane_item_id = s.lane_item_id
    LEFT JOIN forecast    fc ON fc.material_id = s.material_id
                            AND fc.production_line_id = s.production_line_id
    -- computed from the rounded values, so the size adds up with the sqm and
    -- the rework sqm next to it; without work the forecast carries it
    CROSS JOIN LATERAL (
        SELECT CASE WHEN coalesce(t.sqm, 0) + coalesce(t.rework_sqm, 0) > 0
                    THEN round((coalesce(t.sqm, 0) + coalesce(t.rework_sqm, 0))
                               * (1 + p_waste_percentage / 100), 2)
                    ELSE round(coalesce(fc.forecast_sqm, 0)
                               * (1 + p_waste_percentage / 100), 2)
               END AS gross_sqm
    ) g
    LEFT JOIN LATERAL (
        SELECT count(DISTINCT b.batch_id)::integer AS batch_count
        FROM work_batch_share b
        WHERE b.lane_item_id = s.lane_item_id
    ) bc ON true
    LEFT JOIN LATERAL (
        SELECT sum(coalesce(rs.seconds_min, ss.manifest_seconds))::integer AS production_seconds_min,
               sum(coalesce(rs.seconds_max, ss.manifest_seconds))::integer AS production_seconds_max,
               jsonb_object_agg(ss.step, jsonb_build_object(
                   'manifest_seconds',  ss.manifest_seconds,
                   'seconds_min',       rs.seconds_min,
                   'seconds_max',       rs.seconds_max,
                   'min_resource_path', rs.min_path::text,
                   'max_resource_path', rs.max_path::text))          AS step_json
        FROM step_seconds ss
        LEFT JOIN row_step rs ON rs.lane_item_id = ss.lane_item_id AND rs.step = ss.step
        WHERE ss.lane_item_id = s.lane_item_id
    ) sj ON true
    LEFT JOIN LATERAL (
        SELECT jsonb_agg(jsonb_build_object(
                   'set',                  srw.set_kind,
                   'sort_order',           srw.sort_order,
                   'title',                srw.title,
                   'i18n',                 srw.i18n,
                   'sequence',             srw.sequence,
                   'internal_status_code', srw.internal_status_code,
                   'level',                srw.level,
                   'batch_id',            srw.batch_id,
                   'nest_count',           srw.nest_count,
                   'orderline_count',      srw.orderline_count,
                   'rework_count',         srw.rework_count,
                   'sqm',                  srw.sqm,
                   'rework_sqm',           srw.rework_sqm,
                   'class_names',          to_jsonb(coalesce(sc.class_names, '{}'::text[])),
                   'part_status_json',     coalesce(sp.part_status_json, '[]'::jsonb))
                   ORDER BY srw.sort_order) AS set_json
        FROM set_row srw
        LEFT JOIN set_class sc ON sc.lane_item_id = srw.lane_item_id AND sc.set_key = srw.set_key
        LEFT JOIN set_part  sp ON sp.lane_item_id = srw.lane_item_id AND sp.set_key = srw.set_key
        WHERE srw.lane_item_id = s.lane_item_id
    ) sr ON true
    LEFT JOIN LATERAL (
        SELECT jsonb_agg(jsonb_build_object(
                   'manifest',        m.manifest,
                   'i18n',            m.i18n,
                   'sqm',             m.sqm,
                   'orderline_count', m.orderline_count,
                   'items',           m.items)
                   ORDER BY m.sqm DESC) AS manifest_json
        FROM (
            SELECT mrw.manifest, mrw.sqm, mrw.orderline_count, mrw.items,
                   -- one title per language: the abb of every scope of the
                   -- manifest, joined, so title_field can read i18n
                   (SELECT jsonb_object_agg(l.lang, jsonb_build_object('abb', l.abb))
                    FROM (SELECT lg.key AS lang,
                                 string_agg(nullif(lg.value ->> 'abb', ''), ', ' ORDER BY sc.key) AS abb
                          FROM jsonb_each(mrw.manifest) sc
                          CROSS JOIN LATERAL jsonb_each(CASE WHEN jsonb_typeof(sc.value -> 'i18n') = 'object'
                                                             THEN sc.value -> 'i18n' ELSE '{}'::jsonb END) lg
                          GROUP BY lg.key) l
                    WHERE l.abb IS NOT NULL)                        AS i18n
            FROM manifest_row mrw
            WHERE mrw.lane_item_id = s.lane_item_id
        ) m
    ) mr ON true
    ORDER BY s.lane_item_id;
END;
$$;

alter function action.get_lane_item_work(timestamp with time zone, jsonb, text, integer[], integer, integer, integer, numeric, integer[], integer, timestamp with time zone, timestamp with time zone) owner to xfw3;

-- ============ sql/mock/get_impose_plan.sql ============
-- renamed from mock.get_nest_schedule (via get_imposition_plan); impose is
-- the step, imposition the object it produces
drop function if exists mock.get_nest_schedule(timestamp with time zone, text, text, integer[], boolean, integer, integer, integer);
drop function if exists mock.get_nest_schedule(timestamp with time zone, text, text, integer[], integer, integer, integer);
drop function if exists mock.get_imposition_plan(timestamp with time zone, text, text, integer[], integer, integer, integer);
drop function if exists mock.get_impose_plan(timestamp with time zone, text, text, integer[], boolean, integer, integer, integer);
drop function if exists mock.get_impose_plan(timestamp with time zone, text, text, integer[], integer, integer, integer);
drop function if exists mock.get_impose_plan(timestamp with time zone, text, text, integer[], integer, integer, integer, text);
drop function if exists mock.get_impose_plan(timestamp with time zone, text, text, integer[], integer, text, text);
drop function if exists mock.get_impose_plan(timestamp with time zone, text, text, integer[], integer, integer, text, text);

-- The rows of the days in view. The time scale decides which days those are:
-- the days production.get_timeline_view_segments(p_view_code) has segments
-- for, so with nest-time-scale the evening of the day before and the day of
-- p_until, and nothing of the day after. Each day carries the plan of its own
-- date and its own work: the component specs whose nest date falls in the span
-- of that day on the axis, moved to that working day -- on the day before only
-- from the evening moment on (p_date_type says on which date the work is
-- judged: nest or production). p_threshold splits the work into its unit
-- classes (all together within 48 hours of production, else small and big
-- orders apart). Offsets count from midnight of the day of p_until, so a row
-- of the day before is negative. The order is tenant first, then day, then the
-- sort order of that day's plan.
--
-- every row is a plan row: type and type_json (the node of
-- lookup_lane_item_type, with sort_order, placement and formula) ride along as
-- on get_resource_plan, so the board reads the kind of row the same way. The
-- non-working time is the time scale's (get_timeline_view_segments), no rows.
create function mock.get_impose_plan(p_until timestamp with time zone DEFAULT now(), p_step text DEFAULT 'impose'::text, p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_threshold integer DEFAULT 1, p_domain_id integer DEFAULT 1, p_date_type text DEFAULT 'nest'::text, p_view_code text DEFAULT 'nest-time-scale'::text) returns TABLE(material_id integer, material_name text, production_line_id integer, tenant_id integer, tenant_name text, production_company_id integer, resource_uid text, resource_name text, resource_path ltree, delivery_hours integer, min_delivery_hours integer, sort_order numeric, param_json jsonb, formula jsonb, data jsonb, fixed_group text, is_pinned boolean, start_offset_in_seconds integer, next_start_offset_in_seconds integer, duration_in_seconds integer, nest_date date, orderline_count integer, product_amount numeric, part_amount integer, amount numeric, sqm numeric, forecast_sqm numeric, rework_count integer, rework_sqm numeric, impact_json jsonb, gross_sqm numeric, part_status_json jsonb, nest_ids bigint[], nest_count integer, seconds_to_logistics_date integer, class_names text[], unit_class_names text[], lane_item_id bigint, lane_id bigint, day_offset integer, type text, type_json jsonb, start_at timestamp with time zone, production_seconds_min integer, production_seconds_max integer, batch_count integer, delivery_hours_json jsonb, step_json jsonb, set_json jsonb, manifest_json jsonb)
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
    -- the width of a row counts the work of this delivery class only (hours):
    -- the other classes ride along in the numbers, not in the time. A lookup later
    v_width_delivery_hours     constant integer := 30;
    v_plan_type_json jsonb;
    v_plan_class_names text[];
begin
    -- the lookup node of the plan kind
    select t.value into v_plan_type_json
    from action.lookup lk
    cross join lateral jsonb_array_elements(lk.lookup_json) as t(value)
    where lk.lookup = 'lookup_lane_item_type' and t.value ->> 'type' = 'plan';
    -- its class names (timeline-plan) ride along in class_names, as on get_resource_plan
    v_plan_class_names := coalesce(
        (select array_agg(c) from jsonb_array_elements_text(coalesce(v_plan_type_json -> 'class_names', '[]'::jsonb)) c),
        '{}'::text[]);

    -- the statuses live in mapping.internal_status, not in code
    select array_agg(distinct s.sequence) into v_status_sequences
    from mapping.internal_status s
    where s.domain_id = p_domain_id and s.sequence <= v_max_status_sequence;

    return query
    with segment as materialized (
        -- The axis, per day from what moment to what moment. With
        -- nest-time-scale that is the evening of the day before (the 18 hours
        -- moment) and the day of p_until. The lanes read takes its days from
        -- the same view. The dates of the segments are calendar days; the plan
        -- days below are working days, so a segment only lends its day_offset
        -- and its clock times
        select s.day_offset, s.date, s.start_at, s.end_at
        from production.get_timeline_view_segments(
                 p_code       => p_view_code,
                 p_until      => p_until,
                 p_look_back  => -1,
                 p_look_ahead => -1,
                 p_tenant_ids => p_tenant_ids) s
    ),
    base as (
        select b.day_offset, b.plan_date,
               b.material_id, b.material_name, b.production_line_id,
               b.tenant_id, b.tenant_name, b.resource_uid, b.resource_name,
               -- the row's own resource: valid_resources.resource_field reads it
               b.resource_path,
               b.delivery_hours, b.min_delivery_hours, b.sort_order,
               b.param_json, b.formula, b.data, b.fixed_group, b.is_pinned,
               b.start_offset_in_seconds, b.next_start_offset_in_seconds,
               b.lane_item_id, b.lane_id
        -- The days in view, each with the plan of its own date; day_offset says
        -- which day a row comes from, plan_date the working day behind it (the
        -- day before a Monday is the Friday before it). The axis of the time
        -- scale decides which moments are rows, so a moment it does not reach
        -- (the noon of the day before) has none, and a day without a plan (a
        -- weekend) has none either. Only the materials whose interval
        -- (action.get_interval_dates on interval_start_date and interval_days)
        -- says that day is a production day; the rest of the plan stays out
        from action.get_plan_lanes_imposition_group(
                 p_until, p_step, p_line_type, p_tenant_ids, p_only_starting_today => true,
                 p_view_code => p_view_code) b
    ),
    lane_nest as (
        -- the nests hung on the lane of this row: the sets of all its plan
        -- items together (the pattern item and the batch items, one batch per
        -- item), keyed on the row's item. The reader gives the current set of
        -- every item, inherited or own
        select b2.lane_item_id, array_agg(distinct x.imposition_id) as nest_ids
        from (select distinct lane_item_id, lane_id from base where lane_item_id is not null) b2
        join action.lane_item li on li.lane_id = b2.lane_id and li.type = 'plan'
        cross join lateral action.get_lane_item_impositions(li.lane_item_id) x
        group by b2.lane_item_id
    ),
    -- One read for the work of every row: action.get_lane_item_work takes the
    -- scope of each row (the nests of its lane, else its material and line in
    -- the day window) and gives back the totals plus the two lists the board
    -- shows. The fold that used to live here -- an aggregate call per nest set
    -- and a lateral that summed the delivery classes back together -- is that
    -- function now, and board 81 reads the same one.
    work as (
        -- one call per day in view, with that day as the moment: a row of the
        -- day before carries the work of that day. The helper takes one moment
        -- for all the entries it gets, so the day is the loop
        select d.day_offset, w.*
        from (select distinct b.day_offset, b.plan_date from base b) d
        -- the span of that day on the axis, moved to its plan date: the first
        -- segment start to the last segment end. A segment carries a calendar
        -- date, the plan date is the working day, so the moment shifts by the
        -- days between them. A day without segments has no span, and the work
        -- reader then takes the whole plan date
        cross join lateral (
            select min(s.start_at + make_interval(days => d.plan_date - s.date)) as from_at,
                   max(s.end_at   + make_interval(days => d.plan_date - s.date)) as until_at
            from segment s
            where s.day_offset = d.day_offset) a
        cross join lateral action.get_lane_item_work(
                 -- that day at the same clock time as p_until
                 p_until            => (d.plan_date::timestamp
                                        + (p_until at time zone 'Europe/Amsterdam' - v_date::timestamp))
                                       at time zone 'Europe/Amsterdam',
                 p_scope_json       => (select jsonb_agg(jsonb_build_object(
                                                   'lane_item_id',       b.lane_item_id,
                                                   'nest_ids',           ln.nest_ids,
                                                   'material_id',        b.material_id,
                                                   'production_line_id', b.production_line_id,
                                                   'resource_path',      b.resource_path::text,
                                                   'param_json',         b.param_json))
                                        from base b
                                        left join lane_nest ln on ln.lane_item_id = b.lane_item_id
                                        where b.lane_item_id is not null
                                          and b.day_offset = d.day_offset),
                 p_date_type        => p_date_type,
                 p_status_sequences => v_status_sequences,
                 -- the day itself, and inside it the span of the axis: the
                 -- work of a row is the component specs whose nest date falls
                 -- between the first and the last moment of its day, so the
                 -- day before counts the evening moment only
                 p_look_back_days   => 0,
                 p_look_ahead_days  => 0,
                 p_from_at          => a.from_at,
                 p_until_at         => a.until_at,
                 -- the size at or below which an order is a small one (unit class)
                 p_threshold        => p_threshold,
                 p_tenant_ids       => p_tenant_ids,
                 p_domain_id        => p_domain_id) w
    ),
    row_data as (
        select b.*, ln.nest_ids,
               w.orderline_count, w.product_amount, w.part_amount, w.amount,
               w.sqm, w.forecast_sqm, w.rework_count, w.rework_sqm, w.impact_json, w.gross_sqm,
               w.specs_json, w.part_status_json, w.seconds_to_logistics_date,
               w.class_names, w.unit_class_names,
               -- the time of the row: the work of the width class only (30
               -- hours, from the manifests); the other classes ride along in
               -- the numbers, not in the time
               (w.delivery_hours_json -> v_width_delivery_hours::text
                    ->> 'production_impact_in_seconds')::integer as production_impact_in_seconds,
               w.production_seconds_min, w.production_seconds_max,
               w.batch_count, w.min_delivery_hours as work_min_delivery_hours,
               w.delivery_hours_json, w.step_json, w.set_json, w.manifest_json
        from base b
        left join lane_nest ln on ln.lane_item_id = b.lane_item_id
        left join work w on w.lane_item_id = b.lane_item_id and w.day_offset = b.day_offset
    )
    select r.material_id, r.material_name, r.production_line_id,
           r.tenant_id, r.tenant_name, t.production_company_id, r.resource_uid, r.resource_name,
           r.resource_path,
           r.delivery_hours,
           -- the shortest delivery time in the work of the row; without work the
           -- setting of the material
           coalesce(r.work_min_delivery_hours, r.min_delivery_hours), r.sort_order,
           -- the sizes with what the gross sqm needs of each, and the print
           -- time of the row at both speeds
           jsonb_set(r.param_json, '{specs}', coalesce(r.specs_json, r.param_json -> 'specs'))
           -- net_sqm is what the formula needs; the resource constants, the
           -- waste and the imposition size already ride along from
           -- get_plan_lanes, so the board can evaluate the duration itself
           || jsonb_build_object('net_sqm', coalesce(r.sqm, 0),
                                 -- the variables the formula of the plan kind (type_json.formula)
                                 -- runs over, the same names as on get_resource_plan
                                 'planned_start_offset_in_seconds', r.start_offset_in_seconds,
                                 'production_impact_in_seconds',
                                     greatest(coalesce(r.production_impact_in_seconds, 0), v_min_duration_in_seconds)) as param_json,
           r.formula, r.data,
           r.fixed_group, r.is_pinned,
           r.start_offset_in_seconds, r.next_start_offset_in_seconds,
           -- a row lasts the standard production impact of its orderlines of the
           -- width class (30 hours, from the manifests), never shorter than the
           -- floor. The machine formula in param_json stays for the resource side.
           greatest(coalesce(r.production_impact_in_seconds, 0),
                    v_min_duration_in_seconds)                as duration_in_seconds,
           -- the day of the row: the plan date its lane comes from. Working
           -- days, so the day before a Monday is the Friday before it
           r.plan_date as nest_date,
           r.orderline_count, r.product_amount, r.part_amount, r.amount,
           r.sqm, r.forecast_sqm, r.rework_count, r.rework_sqm, r.impact_json, r.gross_sqm,
           coalesce(r.part_status_json, '[]'::jsonb),
           -- the nests of the lane items, not the ones the orderlines sit on
           coalesce(r.nest_ids, '{}'::bigint[]),
           coalesce(cardinality(r.nest_ids), 0),
           r.seconds_to_logistics_date,
           -- the class names of the work plus those of the kind
           coalesce((select array_agg(distinct c order by c)
                     from unnest(coalesce(r.class_names, '{}'::text[]) || v_plan_class_names) as c),
                    '{}'::text[]),
           coalesce(r.unit_class_names, '{}'::text[]),
           r.lane_item_id, r.lane_id, r.day_offset,
           -- the kind of row: every row is a plan row
           'plan'::text,
           v_plan_type_json,
           -- the moment the row starts: its own plan date plus the time of day
           -- in the offset. The offset itself counts from midnight of day 0 (the
           -- axis), and with working days that is another date than the plan
           -- date of the row -- the day before a Monday is the Friday before it
           case when r.start_offset_in_seconds is not null
                then (r.plan_date::timestamp
                      + make_interval(secs => r.start_offset_in_seconds - r.day_offset * 86400))
                     at time zone 'Europe/Amsterdam' end,
           -- what the work costs on the fastest and on the slowest machine of
           -- every step, the batches behind the row, and the three lists
           r.production_seconds_min, r.production_seconds_max,
           coalesce(r.batch_count, 0),
           coalesce(r.delivery_hours_json, '{}'::jsonb),
           coalesce(r.step_json, '{}'::jsonb),
           coalesce(r.set_json, '[]'::jsonb),
           coalesce(r.manifest_json, '[]'::jsonb)
    from row_data r
    left join site.tenant t on t.tenant_id = r.tenant_id
    -- tenant first, then the day: sort_order starts over per plan, so without
    -- the day in front of it the days would interleave
    order by r.tenant_id, r.day_offset, r.sort_order;
end;
$$;

alter function mock.get_impose_plan(timestamp with time zone, text, text, integer[], integer, integer, text, text) owner to xfw3;

-- the board query is planned per call and inlines the aggregate; JIT compiling
-- it costs seconds and never pays back
alter function mock.get_impose_plan(timestamp with time zone, text, text, integer[], integer, integer, text, text) set jit = off;

COMMIT;
