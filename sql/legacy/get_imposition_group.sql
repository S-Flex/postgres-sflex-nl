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
