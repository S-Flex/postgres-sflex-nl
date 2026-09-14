create function catalog.get_imposition_group(p_option_codes text[]) returns integer
	language sql
as $$
    -- The imposition group of a product: the item code paths of its xbom
    -- rows with scope 'imposition', ordered as laid down in item_group
    -- (item_group_json sort_order; ungrouped items last, then by path).
    -- Looks the group up and creates it when new — set-based, race-safe
    -- through the unique constraint.
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
        insert into catalog.imposition_group (item_code_paths)
        select w.item_code_paths
        from wanted w
        where w.item_code_paths is not null
        on conflict on constraint imposition_group_item_code_paths_key do nothing
        returning imposition_group_id
    )
    select coalesce(
        (select ins.imposition_group_id from ins),
        (select g.imposition_group_id
         from catalog.imposition_group g
         join wanted w on g.item_code_paths = w.item_code_paths));
$$;

alter function catalog.get_imposition_group(text[]) owner to xfw3;
