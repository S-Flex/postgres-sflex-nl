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
