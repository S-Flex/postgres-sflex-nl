create function action.crud_imposition_lane_item(p_param_json jsonb, p_no_results boolean DEFAULT false) returns TABLE(imposition_lane_item_id bigint, lane_item_id bigint, imposition_id bigint, sort_order numeric, moved_at timestamp with time zone)
	language sql
as $$
    -- Write the set of a lane_item: called at the first step and on a split
    -- or merge, never for a step that keeps the same set. Every row of one
    -- call shares moved_at, so get_lane_item_impositions sees them as one
    -- set. An element with imposition_id null writes the empty set.
    with inserted as (
        insert into action.imposition_lane_item (lane_item_id, imposition_id, sort_order)
        select (el ->> 'lane_item_id')::bigint,
               (el ->> 'imposition_id')::bigint,
               (el ->> 'sort_order')::numeric
        from jsonb_array_elements(p_param_json) as el
        returning imposition_lane_item_id, lane_item_id, imposition_id, sort_order, moved_at
    )
    select * from inserted where not p_no_results;
$$;

alter function action.crud_imposition_lane_item(jsonb, boolean) owner to xfw3;
