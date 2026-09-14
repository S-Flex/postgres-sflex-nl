create function catalog.cascade_item_code_paths() returns trigger
	language plpgsql
as $$
begin
    -- catalog.item is the master. An item_code rename cascades the code
    -- itself to xbom and item_base_price through their FKs (their generated
    -- path columns recompute on their own); this trigger rewrites the
    -- derived path inside every imposition group array, which no FK can do.
    update catalog.imposition_group g
    set item_code_paths = array_replace(
            g.item_code_paths,
            text2ltree(replace(lower(old.item_code), '-', '.')),
            text2ltree(replace(lower(new.item_code), '-', '.')))
    where text2ltree(replace(lower(old.item_code), '-', '.')) = any (g.item_code_paths);
    return new;
end;
$$;

alter function catalog.cascade_item_code_paths() owner to xfw3;

create trigger trg_item_code_paths_cascade
    after update of item_code on catalog.item
    for each row
    when (old.item_code is distinct from new.item_code)
    execute function catalog.cascade_item_code_paths();
