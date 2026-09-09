-- The work behind a lane item, in one place.
--
-- 1. mapping.get_production_orderline_detail gains impact_scope_json (the
--    manifest seconds per scope; the scope of a manifest row is its step) and
--    nest_json now carries batch_id next to nest_id and amount, so a reader can
--    split an item into its batches by the pieces on their nests.
-- 2. action.get_lane_item_work is new: one entry per row a board draws, and it
--    gives back the totals, the row's own list (per batch with nests, per status
--    without, with part_status_json per entry for the distribution bar), a
--    manifest list with a sub-list per batch or per nest date and unit class,
--    and per step the manifest seconds plus the fastest and slowest machine.
--    It reads the detail at most twice: once for every nest in play together,
--    once for the window of the entries without nests.
-- 3. mock.get_impose_plan and action.get_resource_plan drop their own folds --
--    an aggregate call per nest set plus a lateral that summed the delivery
--    classes back together, in both functions -- and read that one function.
--    Their new columns: production_seconds_min/max, batch_count,
--    delivery_hours_json, step_json, set_json, manifest_json. min_delivery_hours
--    on board 76 is now the shortest delivery time of the work, with the
--    setting of the material as the fallback.
--
-- Needs sql/update_plan_lanes_split.sql first: the two reads call
-- production.get_resource_setting and production.get_setting_numbers, and the
-- lane read now carries material_media_type_id in param_json.
--
-- Second run: every json a reader expands is now read through jsonb_typeof.
-- jsonb_build_object turns a SQL null into a JSON null, and that is a scalar --
-- "cannot extract elements from a scalar" on every row without nests.
BEGIN;

-- ============ 1. the detail ============
-- return type changes, so the old signature has to go first
drop function if exists mapping.get_production_orderline_detail(timestamp with time zone, text, integer, integer, boolean, boolean, integer[], integer, integer[], integer[], bigint[], boolean, integer, integer);
drop function if exists mapping.get_production_orderline_detail(timestamp with time zone, text, integer, integer, boolean, boolean, integer[], text[], integer, integer[], integer[], bigint[], boolean, integer, integer);
drop function if exists mapping.get_production_orderline_detail(timestamp with time zone, text, integer, integer, boolean, boolean, integer[], text[], integer, integer[], integer[], bigint[], boolean, integer, integer, integer[]);
drop function if exists mapping.get_production_orderline_detail(timestamp with time zone, text, integer, integer, boolean, boolean, integer[], text[], integer, integer[], integer[], bigint[], boolean, integer, integer, integer[], timestamp without time zone);
drop function if exists mapping.get_production_orderline_detail(timestamp with time zone, text, integer, integer, boolean, boolean, integer[], text[], integer, integer[], integer[], bigint[], boolean, integer, integer, integer[], timestamp with time zone);
-- the version before production_impact_in_seconds joined the output
drop function if exists mapping.get_production_orderline_detail(timestamp with time zone, text, integer, integer, boolean, boolean, integer[], text[], integer[], integer[], integer[], bigint[], boolean, integer, integer, integer[], timestamp without time zone, integer);

create function mapping.get_production_orderline_detail(p_date timestamp with time zone DEFAULT CURRENT_DATE, p_date_type text DEFAULT 'logistics'::text, p_look_back_days integer DEFAULT NULL::integer, p_look_ahead_days integer DEFAULT NULL::integer, p_include_weekend boolean DEFAULT true, p_include_mandatory_days_off boolean DEFAULT true, p_status_sequences integer[] DEFAULT NULL::integer[], p_status_levels text[] DEFAULT NULL::text[], p_production_line_ids integer[] DEFAULT NULL::integer[], p_material_ids integer[] DEFAULT NULL::integer[], p_batch_ids integer[] DEFAULT NULL::integer[], p_nest_ids bigint[] DEFAULT NULL::bigint[], p_is_open boolean DEFAULT true, p_threshold integer DEFAULT 1, p_domain_id integer DEFAULT 1, p_tenant_ids integer[] DEFAULT NULL::integer[], p_logistics_at timestamp without time zone DEFAULT NULL::timestamp without time zone, p_customer_id integer DEFAULT NULL::integer) returns TABLE(number text, order_sequence integer, order_id integer, production_order_id integer, production_orderline_id integer, sales_orderline_id integer, customer_json jsonb, material_id integer, material_name text, product_amount numeric, sqm numeric, product_width numeric, product_height numeric, ship_separately boolean, production_line_id integer, production_company_id integer, delivery_hours integer, internal_status_code text, status_sequence integer, status_level text, status_title text, part_amount integer, part_status_json jsonb, nest_date date, production_date date, logistics_date date, logistics_at timestamp without time zone, shipment_date date, dates_json jsonb, impact_json jsonb, rejected_amount numeric, produced_amount numeric, nest_json jsonb, nest_ids bigint[], delivery_class_names text[], class_names text[], unit_class_names text[], order_count integer, manifest_json jsonb, production_impact_in_seconds integer, impact_scope_json jsonb)
	stable
	SET plan_cache_mode=force_custom_plan
	language plpgsql
as $$
    #variable_conflict use_column
declare
    v_zone  constant text     := 'Europe/Amsterdam';
    v_alert constant interval := interval '2 hours';
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
          and (v_scope <> 'window' or v_from is null
               or (p_date_type = 'logistics'
                   and cs.logistics_date >= v_from and cs.logistics_date < v_until)
               or (p_date_type = 'production'
                   and cs.production_date >= v_from and cs.production_date < v_until)
               or (p_date_type = 'nest'
                   and cs.nest_date >= (v_from::timestamp  at time zone v_zone)
                   and cs.nest_date <  (v_until::timestamp at time zone v_zone))
               or (p_date_type = 'shipment'
                   and cs.shipment_date >= v_from and cs.shipment_date < v_until))
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
        -- production_order_amount is kept on the row, so no aggregate needed
        case when ob.production_order_amount is null then '{}'::text[]
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

alter function mapping.get_production_orderline_detail(timestamp with time zone, text, integer, integer, boolean, boolean, integer[], text[], integer[], integer[], integer[], bigint[], boolean, integer, integer, integer[], timestamp without time zone, integer) owner to xfw3;


-- ============ 2. the work of a lane item ============
-- What hangs on a lane item: the work of its scope as one row, with the lists
-- the plan boards show. This is the fold both boards kept their own copy of
-- (mock.get_impose_plan, action.get_resource_plan), in one place.
--
-- One entry in p_scope_json per row a board draws:
--   [{"lane_item_id": 8842, "nest_ids": [12,13,14], "material_id": 480,
--     "production_line_id": 5, "resource_path": "dk.sheet.impose.320",
--     "param_json": {"waste_factor": 0.22, "imposition_sqm": 4.58}}]
-- nest_ids null asks for the open work of that material on that line in the day
-- window; nest_ids set asks for the work of those nests whatever its status --
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
--   set_json      the row's own list: one entry per batch (with nests) or per
--                 status (without). One shape either way, "set" says which, and
--                 part_status_json rides along per entry for the distribution
--                 bar. sort_order orders the list.
--   manifest_json one entry per manifest of the work, each with items: per
--                 batch, or per nest date and unit class ('all' next to the two
--                 threshold halves, so a reader can show either).
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

create function action.get_lane_item_work(p_until timestamp with time zone DEFAULT now(), p_scope_json jsonb DEFAULT '[]'::jsonb, p_date_type text DEFAULT 'nest'::text, p_status_sequences integer[] DEFAULT NULL::integer[], p_look_back_days integer DEFAULT 0, p_look_ahead_days integer DEFAULT 0, p_threshold integer DEFAULT 1, p_waste_percentage numeric DEFAULT 20, p_tenant_ids integer[] DEFAULT NULL::integer[], p_domain_id integer DEFAULT 1) returns TABLE(lane_item_id bigint, material_id integer, material_name text, orderline_count integer, product_amount numeric, part_amount integer, amount numeric, sqm numeric, forecast_sqm numeric, rework_count integer, rework_sqm numeric, gross_sqm numeric, impact_json jsonb, part_status_json jsonb, specs_json jsonb, min_delivery_hours integer, seconds_to_logistics_date integer, production_impact_in_seconds integer, production_seconds_min integer, production_seconds_max integer, batch_count integer, class_names text[], unit_class_names text[], delivery_hours_json jsonb, step_json jsonb, set_json jsonb, manifest_json jsonb)
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
    -- window; matched back on material and line
    window_detail AS MATERIALIZED (
        SELECT d.*
        FROM mapping.get_production_orderline_detail(
                 p_date             => p_until,
                 p_date_type        => p_date_type,
                 p_look_back_days   => p_look_back_days,
                 p_look_ahead_days  => p_look_ahead_days,
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
               coalesce((n.value ->> 'batch_id')::integer, 0)            AS batch_key,
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
        SELECT b.lane_item_id, b.production_orderline_id, b.batch_key, b.nest_count,
               b.batch_amount / nullif(sum(b.batch_amount) OVER (
                   PARTITION BY b.lane_item_id, b.production_orderline_id), 0) AS share
        FROM work_batch b
    ),
    -- one key per entry of the row's list, so the numbers, the part statuses
    -- and the class names of that entry are grouped the same way
    work_set AS (
        SELECT w.lane_item_id,
               coalesce('batch:' || b.batch_key, 'status:' || w.status_sequence) AS set_key,
               b.batch_key, b.nest_count, coalesce(b.share, 1) AS share,
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
    -- per nest date, and there next to the total ('all') the threshold halves
    sub AS (
        SELECT w.lane_item_id, CASE WHEN jsonb_typeof(w.manifest_json) = 'object'
                    THEN w.manifest_json ELSE '{}'::jsonb END AS manifest,
               'batch'::text                       AS set_kind,
               b.batch_key::numeric                AS sort_order,
               b.batch_key,
               NULL::date                          AS nest_date,
               'all'::text                         AS unit_class,
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
               -- date with the total in front of its halves
               extract(epoch FROM w.nest_date)
                   + CASE u.unit_class WHEN 'all' THEN 0
                                       WHEN 'units-lte-threshold' THEN 1 ELSE 2 END,
               NULL::integer, w.nest_date, u.unit_class,
               NULL::integer,
               round(sum(w.sqm), 2),
               count(DISTINCT w.production_orderline_id)::integer
        FROM work w
        CROSS JOIN LATERAL unnest(array['all'] || coalesce(w.unit_class_names, '{}'::text[])) AS u(unit_class)
        WHERE w.scope_nest_ids IS NULL
        GROUP BY 1, 2, 4, 6, 7
    ),
    -- the same two machines per step, now over the work of the sub-row
    sub_step AS (
        SELECT sb.lane_item_id, sb.manifest, sb.set_kind, sb.batch_key, sb.nest_date, sb.unit_class,
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
    -- one entry per manifest of the work, with its sub-list
    manifest_row AS (
        SELECT sb.lane_item_id, sb.manifest,
               -- the 'all' rows carry the work once; the threshold halves are the
               -- same work split, so they stay out of the total
               round(sum(sb.sqm) FILTER (WHERE sb.unit_class = 'all'), 2)          AS sqm,
               (sum(sb.orderline_count) FILTER (WHERE sb.unit_class = 'all'))::integer AS orderline_count,
               jsonb_agg(jsonb_build_object(
                   'set',             sb.set_kind,
                   'sort_order',      sb.sort_order,
                   'batch_key',       sb.batch_key,
                   'nest_date',       sb.nest_date,
                   'unit_class',      sb.unit_class,
                   'nest_count',      sb.nest_count,
                   'orderline_count', sb.orderline_count,
                   'sqm',             sb.sqm,
                   'step_json',       coalesce(ss.step_json, '{}'::jsonb))
                   ORDER BY sb.sort_order) AS items
        FROM sub sb
        LEFT JOIN sub_step ss
               ON ss.lane_item_id = sb.lane_item_id
              AND ss.manifest     = sb.manifest
              AND ss.set_kind     = sb.set_kind
              AND ss.batch_key IS NOT DISTINCT FROM sb.batch_key
              AND ss.nest_date IS NOT DISTINCT FROM sb.nest_date
              AND ss.unit_class   = sb.unit_class
        GROUP BY 1, 2
    ),
    -- the row's own list: per batch with nests, per status without
    set_row AS (
        SELECT ws.lane_item_id, ws.set_key, 'batch'::text AS set_kind,
               ws.batch_key::numeric                              AS sort_order,
               ws.batch_key,
               ws.batch_key::text                                 AS title,
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
        WHERE ws.batch_key IS NOT NULL
        GROUP BY 1, 2, 4, 5
        UNION ALL
        -- the i18n and the colour of a status live in mapping.internal_status
        SELECT ws.lane_item_id, ws.set_key, 'status',
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
        WHERE ws.batch_key IS NULL
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
        SELECT count(DISTINCT b.batch_key)::integer AS batch_count
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
                   'batch_key',            srw.batch_key,
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

alter function action.get_lane_item_work(timestamp with time zone, jsonb, text, integer[], integer, integer, integer, numeric, integer[], integer) owner to xfw3;

-- ============ 3. the two boards ============
-- renamed from mock.get_nest_schedule (via get_imposition_plan); impose is
-- the step, imposition the object it produces
drop function if exists mock.get_nest_schedule(timestamp with time zone, text, text, integer[], boolean, integer, integer, integer);
drop function if exists mock.get_nest_schedule(timestamp with time zone, text, text, integer[], integer, integer, integer);
drop function if exists mock.get_imposition_plan(timestamp with time zone, text, text, integer[], integer, integer, integer);
drop function if exists mock.get_impose_plan(timestamp with time zone, text, text, integer[], boolean, integer, integer, integer);
drop function if exists mock.get_impose_plan(timestamp with time zone, text, text, integer[], integer, integer, integer);

-- every row is a plan row: type and type_json (the node of
-- lookup_lane_item_type, with sort_order, placement and formula) ride along as
-- on get_resource_plan, so the board reads the kind of row the same way. The
-- non-working time is the time scale's (get_timeline_view_segments), no rows.
create function mock.get_impose_plan(p_until timestamp with time zone DEFAULT now(), p_step text DEFAULT 'impose'::text, p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_look_back_days integer DEFAULT 1, p_look_ahead_days integer DEFAULT 1, p_domain_id integer DEFAULT 1) returns TABLE(material_id integer, material_name text, production_line_id integer, tenant_id integer, tenant_name text, production_company_id integer, resource_uid text, resource_name text, resource_path ltree, delivery_hours integer, min_delivery_hours integer, sort_order numeric, param_json jsonb, formula jsonb, data jsonb, fixed_group text, is_pinned boolean, start_offset_in_seconds integer, next_start_offset_in_seconds integer, duration_in_seconds integer, nest_date date, orderline_count integer, product_amount numeric, part_amount integer, amount numeric, sqm numeric, forecast_sqm numeric, rework_count integer, rework_sqm numeric, impact_json jsonb, gross_sqm numeric, part_status_json jsonb, nest_ids bigint[], nest_count integer, seconds_to_logistics_date integer, class_names text[], unit_class_names text[], lane_item_id bigint, lane_id bigint, type text, type_json jsonb, start_at timestamp with time zone, production_seconds_min integer, production_seconds_max integer, batch_count integer, delivery_hours_json jsonb, step_json jsonb, set_json jsonb, manifest_json jsonb)
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
    with base as (
        select b.material_id, b.material_name, b.production_line_id,
               b.tenant_id, b.tenant_name, b.resource_uid, b.resource_name,
               -- the row's own resource: valid_resources.resource_field reads it
               b.resource_path,
               b.delivery_hours, b.min_delivery_hours, b.sort_order,
               b.param_json, b.formula, b.data, b.fixed_group, b.is_pinned,
               b.start_offset_in_seconds, b.next_start_offset_in_seconds,
               b.lane_item_id, b.lane_id
        -- only the materials whose interval (action.get_interval_dates on
        -- interval_start_date and interval_days) says the plan date is a
        -- production day; the rest of the plan stays out of the nest board
        -- the day of p_until only; the day window of the axis follows later
        from action.get_plan_lanes_imposition_group(
                 p_until, p_step, p_line_type, p_tenant_ids, p_only_starting_today => true,
                 p_look_back_days => 0, p_look_ahead_days => 0) b
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
        select w.*
        from action.get_lane_item_work(
                 p_until            => p_until,
                 p_scope_json       => (select jsonb_agg(jsonb_build_object(
                                                   'lane_item_id',       b.lane_item_id,
                                                   'nest_ids',           ln.nest_ids,
                                                   'material_id',        b.material_id,
                                                   'production_line_id', b.production_line_id,
                                                   'resource_path',      b.resource_path::text,
                                                   'param_json',         b.param_json))
                                        from base b
                                        left join lane_nest ln on ln.lane_item_id = b.lane_item_id
                                        where b.lane_item_id is not null),
                 p_date_type        => 'nest',
                 p_status_sequences => v_status_sequences,
                 p_look_back_days   => p_look_back_days,
                 p_look_ahead_days  => p_look_ahead_days,
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
        left join work w on w.lane_item_id = b.lane_item_id
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
           -- the day the row's orderlines nest: the plan date of the board
           v_date as nest_date,
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
           r.lane_item_id, r.lane_id,
           -- the kind of row: every row is a plan row
           'plan'::text,
           v_plan_type_json,
           -- the absolute start of the row: the plan date's midnight plus the offset
           -- (the board's formulas compare it with current_offset_in_seconds)
           case when r.start_offset_in_seconds is not null
                then (v_date::timestamp at time zone 'Europe/Amsterdam') + make_interval(secs => r.start_offset_in_seconds) end,
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
    order by r.tenant_id, r.sort_order;
end;
$$;

alter function mock.get_impose_plan(timestamp with time zone, text, text, integer[], integer, integer, integer) owner to xfw3;

-- the board query is planned per call and inlines the aggregate; JIT compiling
-- it costs seconds and never pays back
alter function mock.get_impose_plan(timestamp with time zone, text, text, integer[], integer, integer, integer) set jit = off;

-- The one item read of the resource board (docs/plan-lane-model.md, stap 7):
-- one row per lane item on the resource lanes of the day's plans — the
-- production plans, and the impose plan (material-resource-plan) whose
-- resource lanes are the impose machines and whose items are the material
-- items whose pattern names that machine (stap 7c) —
-- for the steps asked (p_steps null = every step planned that day), in three
-- kinds of rows, named by lane_item.type and action.lookup /
-- lookup_lane_item_type:
--   * plan     — the item as planned (stored); its nests via
--                get_lane_item_impositions, the work of the set from the
--                orderline aggregate, whatever the status of the orderlines,
--                with the forecast of its material (forecast_sqm next to sqm);
--   * progress — what of that plan is still to do for the lane's step: the
--                orderline amounts below the step's done status
--                (lookup_step_category.sequence), as a share of the plan's
--                duration. Same lane_item_id and start, shrinks as work moves
--                on, gone when everything is done. Derived here, never stored;
--   * actual   — what the machine did, as items that partition the lane's
--                day: a run = the produced items of one batch in a row
--                (log.get_resource_produced; a nest without a batch is its
--                own run, a batch interrupted by another batch or by a gap
--                longer than lookup_lane_item_type.actual.gap_split_in_seconds
--                becomes two runs), and the stretches between runs. The state
--                blocks (log.get_resource_state) are the sub level of every
--                actual item: states_json holds them clipped to the item,
--                the state that fills most of the item names it (state_json,
--                class_names). No lane_item_id.
-- The plan row carries progress_json (done and remaining amounts, share) for
-- its tooltip; its state (state_json, class_names) is the least advanced
-- status of its nests, its sub level the part statuses (part_status_json).
-- type_json is the lookup node of the row's type; its class_names ride along
-- in class_names as well, so the board styles the kinds without code, and its
-- formula computes start_offset_in_seconds and duration_in_seconds from the
-- row's param_json (planned_start_offset_in_seconds,
-- production_impact_in_seconds, remaining_impact_in_seconds,
-- actual_start_offset_in_seconds, actual_duration_in_seconds) — the same
-- evaluate mechanism as board 76 uses per resource. The columns
-- start_offset_in_seconds and duration_in_seconds carry the same result for
-- readers without an evaluator. p_types filters the kinds (null = all).
--
-- Replaces mock.get_production_plan (81) and the resource mode of
-- mock.get_impose_plan (78). The labels come from action.get_plan_lanes_resource in
-- the resource read.
drop function if exists action.get_resource_plan(timestamp with time zone, text, integer[], text[], text[], integer);

create function action.get_resource_plan(p_until timestamp with time zone DEFAULT now(), p_line_type text DEFAULT NULL::text, p_tenant_ids integer[] DEFAULT NULL::integer[], p_steps text[] DEFAULT NULL::text[], p_types text[] DEFAULT NULL::text[], p_domain_id integer DEFAULT 1)
    returns TABLE(tenant_id integer, tenant_name text, production_company_id integer, resource_uid text, resource_name text, resource_path ltree, lane_id bigint, step text, type text, type_json jsonb, lane_item_id bigint, sort_order numeric, is_pinned boolean, no_split boolean, fixed_group text, start_offset_in_seconds integer, duration_in_seconds integer, start_at timestamp with time zone, end_at timestamp with time zone, nest_ids bigint[], nest_count integer, batch_id integer, batch_name text, material_id integer, material_name text, impact_json jsonb, sqm numeric, forecast_sqm numeric, gross_sqm numeric, part_status_json jsonb, progress_json jsonb, state_json jsonb, group_state_json jsonb, states_json jsonb, class_names text[], param_json jsonb, min_delivery_hours integer, production_seconds_min integer, production_seconds_max integer, batch_count integer, delivery_hours_json jsonb, step_json jsonb, set_json jsonb, manifest_json jsonb)
    stable
    language plpgsql
    set jit = off
as $$
#variable_conflict use_column
declare
    v_zone constant text := 'Europe/Amsterdam';
    -- the plan date is the day of the viewed moment; the axis of the board is
    -- that day's local midnight, offsets are seconds since then
    v_date       date := (p_until at time zone 'Europe/Amsterdam')::date;
    v_day_start  timestamp with time zone;
    v_day_end    timestamp with time zone;
    -- print seconds per gross sqm at standard speed, and the shortest item; a lookup later
    v_standard_seconds_per_sqm constant numeric := 45;
    v_min_duration_in_seconds  constant integer := 900;
    -- legacy.nest width/height are in cm; a lookup later
    v_nest_size_per_sqm        constant numeric := 10000;
    v_state_lookup             jsonb;
    v_type_lookup              jsonb;
    -- a gap longer than this inside a batch splits its run in two
    v_gap_split_in_seconds     integer;
    -- at or below this sequence an orderline is not on a nest yet: the open
    -- work of a material item without nests (the same rule as get_impose_plan)
    v_max_status_sequence constant integer := 450;
    v_status_sequences         integer[];
begin
    select array_agg(distinct s.sequence) into v_status_sequences
    from mapping.internal_status s
    where s.domain_id = p_domain_id and s.sequence <= v_max_status_sequence;

    select lk.lookup_json into v_state_lookup
    from relation.lookup lk where lk.lookup = 'lookup_resource_state';

    select lk.lookup_json into v_type_lookup
    from action.lookup lk where lk.lookup = 'lookup_lane_item_type';

    select coalesce((t.value ->> 'gap_split_in_seconds')::integer, 900) into v_gap_split_in_seconds
    from jsonb_array_elements(coalesce(v_type_lookup, '[]'::jsonb)) as t(value)
    where t.value ->> 'type' = 'actual';
    v_gap_split_in_seconds := coalesce(v_gap_split_in_seconds, 900);

    v_day_start := v_date::timestamp at time zone v_zone;
    v_day_end   := (v_date + 1)::timestamp at time zone v_zone;

    return query
    with kind as (
        -- the three kinds of rows, with their lookup node
        select t.value ->> 'type'                                    as type,
               (t.value ->> 'sort_order')::integer                   as sort_order,
               t.value                                               as type_json,
               coalesce((select array_agg(c) from jsonb_array_elements_text(coalesce(t.value -> 'class_names', '[]'::jsonb)) c),
                        '{}'::text[])                                as class_names
        from jsonb_array_elements(coalesce(v_type_lookup, '[]'::jsonb)) as t(value)
    ),
    step_done as (
        -- per step the status at which its work is done
        select s.value ->> 'step'                 as step,
               (s.value ->> 'sequence')::integer  as done_sequence
        from relation.lookup lk
        cross join lateral jsonb_array_elements(lk.lookup_json) as s(value)
        where lk.lookup = 'lookup_step_category'
    ),
    tenant as (
        select t.tenant_id, t.name as tenant_name, t.abb, t.production_company_id
        from site.tenant t
    ),
    -- the steps asked, else every step a plan of the day carries: the
    -- production plans (print, coat, cut, ...) and the impose plan (the
    -- material-resource-plan, whose resource lanes are the impose machines)
    wanted_step as (
        select distinct s.step
        from action.plan p
        cross join lateral unnest(p.steps) as s(step)
        where p.plan_date = v_date
          and (p_line_type is null or p.line_type = p_line_type)
          and (p_steps is null or s.step = any (p_steps))
    ),
    the_plan as (
        -- per step and plan type the newest plan of the day that covers it
        select distinct on (ws.step, p.type) ws.step, p.plan_id
        from wanted_step ws
        join action.plan p on ws.step = any (p.steps)
        where p.plan_date = v_date
          and (p_line_type is null or p.line_type = p_line_type)
        order by ws.step, p.type, p.plan_id desc
    ),
    -- one lane = one machine's day, the machine's step names the lane's step;
    -- the tenant through the first label of the path (the site abb)
    lane as (
        select distinct on (l.lane_id)
               l.lane_id, pl_l.sort_order, rl.resource_path,
               r.resource_uid, r.resource_name, r.step,
               t.tenant_id, t.tenant_name, t.production_company_id,
               sd.done_sequence
        from the_plan tp
        join action.plan_lane pl_l on pl_l.plan_id = tp.plan_id
        join action.lane l on l.lane_id = pl_l.lane_id
        join action.resource_lane rl on rl.lane_id = l.lane_id
        join relation.resource r on r.resource_path = rl.resource_path and r.step = tp.step
        left join step_done sd on sd.step = r.step
        left join tenant t on t.abb = ltree2text(subpath(rl.resource_path, 0, 1))
        where (p_tenant_ids is null or t.tenant_id = any (p_tenant_ids))
        order by l.lane_id, tp.plan_id desc
    ),
    -- the material lanes of the impose plan, with the resource their pattern
    -- names and what the material boards derive per lane: material, line,
    -- fixed group and class time — the same read board 76 uses, so both
    -- boards agree on every item
    material_lane as (
        select b.lane_id, b.lane_item_id as pattern_item_id,
               b.material_id, b.material_name, b.production_line_id,
               b.resource_path, b.fixed_group, b.start_offset_in_seconds, b.param_json
        -- the day of p_until only: a resource board is one day
        from action.get_plan_lanes_imposition_group(
                 p_until, p_line_type => p_line_type, p_tenant_ids => p_tenant_ids,
                 p_only_starting_today => true,
                 p_look_back_days => 0, p_look_ahead_days => 0) b
        where b.lane_id is not null
    ),
    -- planned items with the nests hung on them: the items on the lane itself
    -- (production plans), plus for an impose lane the items of every material
    -- lane whose pattern names its resource — the pattern item with the class
    -- time and fixed group of board 76, the batch items as fillers of the same
    -- material (one batch per item)
    item as (
        select li.lane_item_id, li.lane_id, li.sort_order, li.is_pinned, li.no_split,
               li.fixed_group, li.start_offset_in_seconds, li.duration_in_seconds,
               null::integer as material_id, null::text as material_name, null::integer as production_line_id,
               '{}'::jsonb as param_json,
               (select array_agg(distinct x.imposition_id)
                from action.get_lane_item_impositions(li.lane_item_id) x) as nest_ids
        from action.lane_item li
        join lane on lane.lane_id = li.lane_id
        where li.type = 'plan'
        union all
        select li.lane_item_id, lane.lane_id, li.sort_order, li.is_pinned, li.no_split,
               case when li.lane_item_id = ml.pattern_item_id then ml.fixed_group end,
               case when li.lane_item_id = ml.pattern_item_id then ml.start_offset_in_seconds
                    else li.start_offset_in_seconds end,
               li.duration_in_seconds,
               ml.material_id, ml.material_name, ml.production_line_id,
               ml.param_json,
               (select array_agg(distinct x.imposition_id)
                from action.get_lane_item_impositions(li.lane_item_id) x)
        from lane
        join material_lane ml on ml.resource_path = lane.resource_path
        join action.lane_item li on li.lane_id = ml.lane_id and li.type = 'plan'
    ),
    -- what the nests of an item say: the batch, the run (amount x area), the
    -- materials, and the least advanced status, which names the item's state
    item_nest as (
        select i.lane_item_id,
               min(n.batch_id)                                                          as batch_id,
               min(b.batch_name)                                                        as batch_name,
               sum(coalesce(n.amount, 1) * coalesce(n.width, 0) * coalesce(n.height, 0)) / v_nest_size_per_sqm as run_sqm,
               array_agg(distinct (n.nest_json ->> 'material_id')::integer)
                   filter (where (n.nest_json ->> 'material_id') is not null)           as material_ids,
               (array_agg(n.nest_json ->> 'internal_status_code' order by ist.sequence nulls last))[1] as internal_status_code
        from item i
        cross join lateral action.get_lane_item_impositions(i.lane_item_id) nli
        join legacy.nest n on n.nest_id = nli.imposition_id
        left join legacy.batch b on b.batch_id = n.batch_id
        left join mapping.internal_status ist on ist.code = n.nest_json ->> 'internal_status_code' and ist.domain_id = p_domain_id
        group by i.lane_item_id
    ),
    -- One read for the work of every item: action.get_lane_item_work takes the
    -- scope of each item (its own nests, else its material and line on the day)
    -- and gives back the totals plus the lists. Board 76 reads the same
    -- function, so both boards agree on every item.
    work as (
        select w.*
        from action.get_lane_item_work(
                 p_until            => p_until,
                 p_scope_json       => (select jsonb_agg(jsonb_build_object(
                                                   'lane_item_id',       i.lane_item_id,
                                                   'nest_ids',           i.nest_ids,
                                                   'material_id',        i.material_id,
                                                   'production_line_id', i.production_line_id,
                                                   'resource_path',      l.resource_path::text,
                                                   'param_json',         i.param_json))
                                        from item i
                                        join lane l on l.lane_id = i.lane_id
                                        where i.nest_ids is not null or i.material_id is not null),
                 p_date_type        => 'nest',
                 p_status_sequences => v_status_sequences,
                 p_look_back_days   => 0,
                 p_look_ahead_days  => 0,
                 p_tenant_ids       => p_tenant_ids,
                 p_domain_id        => p_domain_id) w
    ),
    -- the plan rows: the lane's resource names the row
    plan_row as (
        select l.tenant_id, l.tenant_name, l.production_company_id,
               l.resource_uid, l.resource_name, l.resource_path, l.lane_id, l.step,
               i.lane_item_id, i.sort_order, i.is_pinned, i.no_split, i.fixed_group,
               i.start_offset_in_seconds,
               -- pv2's duration when it sent one; a material item (impose) lasts
               -- the standard production impact of its work, from the nests or
               -- the open work, as on board 76; else the print time of the run
               -- (nest area x amount) at the resource's speed — never shorter
               -- than the minimum
               case when i.duration_in_seconds > 0 then i.duration_in_seconds
                    when i.material_id is not null
                         then greatest(coalesce(w.production_impact_in_seconds, 0),
                                       v_min_duration_in_seconds)
                    else greatest(ceil(coalesce(nf.run_sqm, 0) * v_standard_seconds_per_sqm
                                       / coalesce(nullif(mock.get_resource_speed_factor(w.material_id, l.resource_uid), 0), 1))::integer,
                                  v_min_duration_in_seconds) end                       as duration_in_seconds,
               coalesce(i.nest_ids, '{}'::bigint[])                                   as nest_ids,
               coalesce(cardinality(i.nest_ids), 0)                                    as nest_count,
               nf.batch_id, nf.batch_name,
               -- the material of the set, else of the material item itself; the
               -- work of the set, else the open work of the material
               coalesce(w.material_id, i.material_id)                                  as material_id,
               coalesce(w.material_name, i.material_name)                              as material_name,
               w.impact_json                                                           as impact_json,
               w.sqm                                                                   as sqm,
               w.forecast_sqm                                                          as forecast_sqm,
               w.gross_sqm                                                             as gross_sqm,
               coalesce(w.part_status_json, '[]'::jsonb)                               as part_status_json,
               -- the state of a planned item is the least advanced status of its
               -- nests, from the same lookup the actual rows use
               (select st.value from jsonb_array_elements(v_state_lookup) as ss(value)
                                     cross join lateral jsonb_array_elements(ss.value -> 'states') as st(value)
                 where st.value ->> 'code' = coalesce(nf.internal_status_code, 'batch') limit 1) as state_json,
               (select ss.value - 'states' from jsonb_array_elements(v_state_lookup) as ss(value)
                                           cross join lateral jsonb_array_elements(ss.value -> 'states') as st(value)
                 where st.value ->> 'code' = coalesce(nf.internal_status_code, 'batch') limit 1) as group_state_json,
               coalesce(w.class_names, '{}'::text[])                                   as class_names,
               jsonb_build_object(
                   'standard_production_impact_in_seconds', ceil(coalesce(nf.run_sqm, 0) * v_standard_seconds_per_sqm)::integer,
                   'run_sqm',                                round(coalesce(nf.run_sqm, 0), 2),
                   'speed_factor',                           mock.get_resource_speed_factor(coalesce(w.material_id, i.material_id), l.resource_uid),
                   'orderline_count',                        w.orderline_count) as param_json,
               -- what is done and what remains for the lane's step: the part
               -- amounts at or past the step's done status against the rest.
               -- Without orderline amounts nothing is known to be done
               coalesce(pr.done_amount, 0)                                             as done_amount,
               coalesce(pr.remaining_amount, 0)                                        as remaining_amount,
               case when coalesce(pr.done_amount, 0) + coalesce(pr.remaining_amount, 0) > 0
                    then coalesce(pr.remaining_amount, 0) / (coalesce(pr.done_amount, 0) + coalesce(pr.remaining_amount, 0))
                    else 1 end                                                         as remaining_share,
               -- what the work costs on the fastest and on the slowest machine of
               -- every step, the batches behind the item, and the lists
               w.min_delivery_hours, w.production_seconds_min, w.production_seconds_max,
               coalesce(w.batch_count, 0)                                              as batch_count,
               coalesce(w.delivery_hours_json, '{}'::jsonb)                            as delivery_hours_json,
               coalesce(w.step_json, '{}'::jsonb)                                      as step_json,
               coalesce(w.set_json, '[]'::jsonb)                                       as set_json,
               coalesce(w.manifest_json, '[]'::jsonb)                                  as manifest_json
        from item i
        join lane l on l.lane_id = i.lane_id
        left join item_nest nf on nf.lane_item_id = i.lane_item_id
        left join work w on w.lane_item_id = i.lane_item_id
        left join lateral (
            select sum((e.value ->> 'amount')::numeric) filter (where (e.value ->> 'sequence')::integer >= l.done_sequence) as done_amount,
                   sum((e.value ->> 'amount')::numeric) filter (where (e.value ->> 'sequence')::integer <  l.done_sequence) as remaining_amount
            from jsonb_array_elements(coalesce(w.part_status_json, '[]'::jsonb)) as e(value)
            where l.done_sequence is not null
        ) pr on true
    ),
    -- actual: the state blocks and the produced items of the lanes'
    -- resources, up to the viewed moment (the log functions clip to now());
    -- skipped altogether when the actual rows are not asked for
    actual_state as (
        select s.resource_uid, s.state, s.group_state, s.start_at,
               s.start_at + make_interval(secs => coalesce(s.duration_seconds, 0)) as end_at
        from log.get_resource_state(
                 (select array_agg(l.resource_uid) from lane l), v_day_start, least(p_until, v_day_end), null) s
        where (p_types is null or 'actual' = any (p_types))
          and coalesce(s.duration_seconds, 0) > 0
    ),
    produced as (
        select r.resource_uid, r.start_at,
               r.start_at + make_interval(secs => coalesce(r.duration_seconds, 0)) as end_at,
               coalesce(r.duration_seconds, 0)                                    as producing_seconds,
               r.batch_id, r.batch_name, r.nest_name,
               (select sum((m.value ->> 'value')::numeric)
                from jsonb_array_elements(coalesce(r.data -> 'metrics_json', '[]'::jsonb)) as m(value)
                where m.value ->> 'code' = 'area')                                 as area_sqm,
               -- what a run is keyed on: the batch, else the nest, else the row itself
               coalesce(r.batch_id::text, r.nest_name, 'row:' || r.start_at::text) as run_key
        from log.get_resource_produced(
                 (select array_agg(l.resource_uid) from lane l), v_day_start, least(p_until, v_day_end), null) r
        where p_types is null or 'actual' = any (p_types)
    ),
    -- a new run starts where the key changes or the gap since the previous
    -- item is longer than the split
    produced_break as (
        select p.*,
               case when p.run_key is distinct from lag(p.run_key) over w
                      or p.start_at - lag(p.end_at) over w > make_interval(secs => v_gap_split_in_seconds)
                    then 1 else 0 end as is_break
        from produced p
        window w as (partition by p.resource_uid order by p.start_at, p.end_at)
    ),
    produced_run as (
        select pb.*,
               sum(pb.is_break) over (partition by pb.resource_uid order by pb.start_at, pb.end_at rows unbounded preceding) as run_no
        from produced_break pb
    ),
    run as (
        select pr.resource_uid, pr.run_no,
               min(pr.start_at) as start_at, max(pr.end_at) as end_at,
               min(pr.batch_id) as batch_id, min(pr.batch_name) as batch_name,
               count(*)::integer as produced_count,
               sum(pr.producing_seconds)::integer as producing_seconds,
               sum(pr.area_sqm) as area_sqm,
               array_agg(distinct pr.nest_name) filter (where pr.nest_name is not null) as nest_names
        from produced_run pr
        group by pr.resource_uid, pr.run_no
    ),
    -- the log can overlap: an item of the next batch starts before the last
    -- item of this one ends; a run ends where the next run begins
    run_clipped as (
        select r.resource_uid, r.run_no, r.start_at,
               least(r.end_at, lead(r.start_at) over (partition by r.resource_uid order by r.start_at, r.run_no)) as end_at,
               r.batch_id, r.batch_name, r.produced_count, r.producing_seconds, r.area_sqm, r.nest_names
        from run r
    ),
    -- the stretches between runs, from the day start and up to the viewed
    -- moment; a lane without runs is one stretch
    stretch as (
        select r.resource_uid, r.end_at as start_at,
               lead(r.start_at) over (partition by r.resource_uid order by r.start_at) as end_at
        from run_clipped r
        union all
        select l.resource_uid, v_day_start,
               (select min(r.start_at) from run_clipped r where r.resource_uid = l.resource_uid)
        from lane l
    ),
    actual_item as (
        select r.resource_uid, r.start_at, r.end_at, true as is_run,
               r.batch_id, r.batch_name, r.produced_count, r.producing_seconds, r.area_sqm, r.nest_names
        from run_clipped r
        union all
        select s.resource_uid, s.start_at, coalesce(s.end_at, least(p_until, v_day_end)), false,
               null, null, 0, 0, null, null
        from stretch s
        where coalesce(s.end_at, least(p_until, v_day_end)) > s.start_at
    ),
    -- the sub level: the state blocks clipped to the item
    actual_segment as (
        select i.resource_uid, i.start_at as item_start,
               greatest(st.start_at, i.start_at) as start_at,
               least(st.end_at, i.end_at)        as end_at,
               st.state, st.group_state
        from actual_item i
        join actual_state st
          on st.resource_uid = i.resource_uid
         and st.start_at < i.end_at and st.end_at > i.start_at
    ),
    actual_row as (
        select i.*,
               extract(epoch from (i.start_at - v_day_start))::integer as start_offset_in_seconds,
               extract(epoch from (i.end_at - i.start_at))::integer    as duration_in_seconds,
               (select jsonb_agg(jsonb_build_object(
                           'start_offset_in_seconds', extract(epoch from (sg.start_at - v_day_start))::integer,
                           'duration_in_seconds',     extract(epoch from (sg.end_at - sg.start_at))::integer,
                           'class_names',             array_remove(array[sg.state ->> 'class_name'], null),
                           'state_json',              sg.state)
                        order by sg.start_at)
                from actual_segment sg
                where sg.resource_uid = i.resource_uid and sg.item_start = i.start_at) as states_json,
               -- the state that fills most of the item names it
               d.state as state_json, d.group_state as group_state_json
        from actual_item i
        left join lateral (
            select sg.state, sg.group_state
            from actual_segment sg
            where sg.resource_uid = i.resource_uid and sg.item_start = i.start_at
            group by sg.state, sg.group_state
            order by sum(extract(epoch from (sg.end_at - sg.start_at))) desc
            limit 1
        ) d on true
        -- a stretch without any state block is nothing to show
        where i.is_run or d.state is not null
    ),
    rows as (
        -- plan
        select p.tenant_id, p.tenant_name, p.production_company_id,
               p.resource_uid, p.resource_name, p.resource_path, p.lane_id, p.step,
               'plan'::text as type,
               p.lane_item_id, p.sort_order, p.is_pinned, p.no_split, p.fixed_group,
               p.start_offset_in_seconds, p.duration_in_seconds,
               v_day_start + make_interval(secs => p.start_offset_in_seconds) as start_at,
               null::timestamp with time zone                                 as end_at,
               p.nest_ids, p.nest_count, p.batch_id, p.batch_name,
               p.material_id, p.material_name, p.impact_json, p.sqm, p.forecast_sqm, p.gross_sqm,
               p.part_status_json,
               jsonb_build_object(
                   'done_amount',          p.done_amount,
                   'remaining_amount',     p.remaining_amount,
                   'remaining_percentage', round(p.remaining_share * 100, 1)) as progress_json,
               p.state_json, p.group_state_json, null::jsonb as states_json, p.class_names,
               -- the variables the formula of the kind runs over
               p.param_json || jsonb_build_object(
                   'planned_start_offset_in_seconds', p.start_offset_in_seconds,
                   'production_impact_in_seconds',    p.duration_in_seconds,
                   'remaining_impact_in_seconds',     round(p.duration_in_seconds * p.remaining_share)::integer) as param_json,
               p.min_delivery_hours, p.production_seconds_min, p.production_seconds_max,
               p.batch_count, p.delivery_hours_json, p.step_json, p.set_json, p.manifest_json
        from plan_row p

        union all
        -- progress: the remaining share of the plan, same item and start
        select p.tenant_id, p.tenant_name, p.production_company_id,
               p.resource_uid, p.resource_name, p.resource_path, p.lane_id, p.step,
               'progress'::text,
               p.lane_item_id, p.sort_order, p.is_pinned, p.no_split, p.fixed_group,
               p.start_offset_in_seconds,
               round(p.duration_in_seconds * p.remaining_share)::integer,
               v_day_start + make_interval(secs => p.start_offset_in_seconds),
               null::timestamp with time zone,
               p.nest_ids, p.nest_count, p.batch_id, p.batch_name,
               p.material_id, p.material_name, p.impact_json, p.sqm, p.forecast_sqm, p.gross_sqm,
               p.part_status_json,
               jsonb_build_object(
                   'done_amount',          p.done_amount,
                   'remaining_amount',     p.remaining_amount,
                   'remaining_percentage', round(p.remaining_share * 100, 1)),
               p.state_json, p.group_state_json, null::jsonb, p.class_names,
               p.param_json || jsonb_build_object(
                   'planned_start_offset_in_seconds', p.start_offset_in_seconds,
                   'production_impact_in_seconds',    p.duration_in_seconds,
                   'remaining_impact_in_seconds',     round(p.duration_in_seconds * p.remaining_share)::integer),
               p.min_delivery_hours, p.production_seconds_min, p.production_seconds_max,
               p.batch_count, p.delivery_hours_json, p.step_json, p.set_json, p.manifest_json
        from plan_row p
        where round(p.duration_in_seconds * p.remaining_share) > 0

        union all
        -- actual: the items of the lane's day, named by the resource that ran
        select l.tenant_id, l.tenant_name, l.production_company_id,
               l.resource_uid, l.resource_name, l.resource_path, l.lane_id, l.step,
               'actual'::text,
               null::bigint, null::numeric, false, false, null::text,
               a.start_offset_in_seconds, a.duration_in_seconds,
               a.start_at, a.end_at,
               coalesce((select array_agg(n.nest_id order by n.nest_id) from legacy.nest n where n.nest_name = any (a.nest_names)), '{}'::bigint[]),
               coalesce(cardinality(a.nest_names), 0),
               a.batch_id, a.batch_name,
               null::integer, null::text,
               null::jsonb, round(a.area_sqm, 2), null::numeric, null::numeric,
               '[]'::jsonb,
               null::jsonb,
               a.state_json, a.group_state_json, a.states_json,
               array_remove(array[a.state_json ->> 'class_name', case when a.is_run then 'actual-produced' end], null),
               jsonb_build_object(
                   'is_run',                          a.is_run,
                   'produced_count',                  a.produced_count,
                   'producing_in_seconds',            a.producing_seconds,
                   'actual_start_offset_in_seconds',  a.start_offset_in_seconds,
                   'actual_duration_in_seconds',      a.duration_in_seconds),
               null::integer, null::integer, null::integer,
               0, '{}'::jsonb, '{}'::jsonb, '[]'::jsonb, '[]'::jsonb
        from actual_row a
        join lane l on l.resource_uid = a.resource_uid
    )
    select r.tenant_id, r.tenant_name, r.production_company_id,
           r.resource_uid, r.resource_name, r.resource_path, r.lane_id, r.step,
           r.type, k.type_json,
           r.lane_item_id, r.sort_order, r.is_pinned, r.no_split, r.fixed_group,
           r.start_offset_in_seconds, r.duration_in_seconds, r.start_at, r.end_at,
           r.nest_ids, r.nest_count, r.batch_id, r.batch_name,
           r.material_id, r.material_name, r.impact_json, r.sqm, r.forecast_sqm, r.gross_sqm,
           r.part_status_json, r.progress_json, r.state_json, r.group_state_json, r.states_json,
           -- the class names of the kind ride along with the row's own
           (select array_agg(distinct c order by c)
            from unnest(r.class_names || coalesce(k.class_names, '{}'::text[])) as c) as class_names,
           r.param_json,
           r.min_delivery_hours, r.production_seconds_min, r.production_seconds_max,
           r.batch_count, r.delivery_hours_json, r.step_json, r.set_json, r.manifest_json
    from rows r
    left join kind k on k.type = r.type
    where p_types is null or r.type = any (p_types)
    order by r.tenant_id, r.resource_path, k.sort_order nulls last, r.start_offset_in_seconds, r.sort_order;
end;
$$;

alter function action.get_resource_plan(timestamp with time zone, text, integer[], text[], text[], integer) owner to xfw3;

COMMIT;

-- ============ checks (read-only) ============

-- 1. what a manifest row calls its step: these are the keys of step_json and of
--    impact_scope_json. Are print and cut not among them, then the steps of the
--    work are named differently and the min/max find no machines
SELECT scope, count(*) AS manifest_rows,
       round(avg(production_impact_per_unit), 1) AS avg_seconds_per_unit
FROM mapping.spec_unit_manifest
GROUP BY scope
ORDER BY 2 DESC;

-- 2. does the board have rows at all, and which of them have nests? This is
--    the scope every read below is built from; empty here means the lane read
--    finds no plan for that day, and nothing further can work
SELECT b.lane_item_id, b.material_id, b.production_line_id, b.delivery_hours,
       b.resource_path::text,
       (SELECT count(DISTINCT x.imposition_id)
        FROM action.lane_item li
        CROSS JOIN LATERAL action.get_lane_item_impositions(li.lane_item_id) x
        WHERE li.lane_id = b.lane_id AND li.type = 'plan') AS nest_count,
       b.param_json ? 'material_media_type_id' AS has_media_type
FROM action.get_plan_lanes_imposition_group(
         p_until => '2026-09-08 06:00+02', p_line_type => 'sheet',
         p_look_back_days => 0, p_look_ahead_days => 0) b
ORDER BY b.sort_order;

-- 3. the detail of one nest set, as the helper reads it: with the material of
--    the row, which is what keeps it from dragging every material along
SELECT count(*) AS orderlines, round(sum(d.sqm), 2) AS sqm,
       count(*) FILTER (WHERE d.impact_scope_json IS NOT NULL) AS with_scope_seconds,
       min(d.nest_json -> 0 ->> 'batch_id') AS a_batch_id
FROM (
    SELECT b.material_id,
           (SELECT array_agg(DISTINCT x.imposition_id)
            FROM action.lane_item li
            CROSS JOIN LATERAL action.get_lane_item_impositions(li.lane_item_id) x
            WHERE li.lane_id = b.lane_id AND li.type = 'plan') AS nest_ids
    FROM action.get_plan_lanes_imposition_group(
             p_until => '2026-09-08 06:00+02', p_line_type => 'sheet',
             p_look_back_days => 0, p_look_ahead_days => 0) b
    ORDER BY b.sort_order
    LIMIT 1
) one
CROSS JOIN LATERAL mapping.get_production_orderline_detail(
         p_date         => '2026-09-08 06:00+02',
         p_date_type    => 'nest',
         p_nest_ids     => coalesce(one.nest_ids, '{}'::bigint[]),
         p_material_ids => array[one.material_id],
         p_is_open      => NULL) d;

-- 4. the work of every row of board 76 straight from the helper: the totals,
--    how many entries the two lists have, and the steps it found
WITH scope AS (
    SELECT jsonb_agg(jsonb_build_object(
               'lane_item_id',       b.lane_item_id,
               'nest_ids',           (SELECT array_agg(DISTINCT x.imposition_id)
                                      FROM action.lane_item li
                                      CROSS JOIN LATERAL action.get_lane_item_impositions(li.lane_item_id) x
                                      WHERE li.lane_id = b.lane_id AND li.type = 'plan'),
               'material_id',        b.material_id,
               'production_line_id', b.production_line_id,
               'resource_path',      b.resource_path::text,
               'param_json',         b.param_json)) AS scope_json
    FROM action.get_plan_lanes_imposition_group(
             p_until => '2026-09-08 06:00+02', p_line_type => 'sheet',
             p_look_back_days => 0, p_look_ahead_days => 0) b
    WHERE b.lane_item_id IS NOT NULL
)
SELECT w.lane_item_id, w.material_name, w.orderline_count, w.sqm, w.rework_count,
       w.min_delivery_hours, w.batch_count,
       w.production_impact_in_seconds, w.production_seconds_min, w.production_seconds_max,
       jsonb_array_length(w.set_json)      AS set_rows,
       jsonb_array_length(w.manifest_json) AS manifest_rows,
       w.step_json, w.delivery_hours_json
FROM scope, action.get_lane_item_work(
         p_until      => '2026-09-08 06:00+02',
         p_scope_json => scope.scope_json) w
ORDER BY w.lane_item_id;

-- 5. one row of board 76 in full, with the lists as they reach the frontend
SELECT material_name, delivery_hours, min_delivery_hours, sqm, rework_sqm,
       duration_in_seconds, production_seconds_min, production_seconds_max,
       batch_count, jsonb_pretty(set_json) AS set_json,
       jsonb_pretty(manifest_json) AS manifest_json
FROM mock.get_impose_plan('2026-09-08 06:00+02', 'impose', 'sheet')
WHERE sqm > 0
ORDER BY sort_order
LIMIT 3;

-- 6. and what the two boards cost now
EXPLAIN (ANALYZE, SUMMARY)
SELECT * FROM mock.get_impose_plan('2026-09-08 06:00+02', 'impose', 'sheet');

EXPLAIN (ANALYZE, SUMMARY)
SELECT * FROM action.get_resource_plan('2026-09-08 06:00+02', 'sheet');
