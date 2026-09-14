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

