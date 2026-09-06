create function action.get_lane_item_impositions(p_lane_item_id bigint, p_as_of timestamp with time zone DEFAULT now()) returns TABLE(imposition_id bigint, sort_order numeric)
	stable
	language sql
as $$
    -- Impositions in a lane_item, at any moment. Walks up the dependency chain
    -- (to -> from, towards the predecessor) until it reaches a lane_item that
    -- carries its own set; a lane_item without rows inherits from the step
    -- before it, a merge collects both branches. A set written as one row
    -- with imposition_id null is the empty set: it stops the walk and yields
    -- nothing.
    with recursive up as (
        select p_lane_item_id as lane_item_id
        union all
        select d.from_lane_item_id
        from up
        join action.lane_item_dependency d
          on d.to_lane_item_id = up.lane_item_id
        where not exists (
            select 1 from action.imposition_lane_item i
            where i.lane_item_id = up.lane_item_id
              and i.moved_at <= p_as_of)
    )
    select distinct on (i.imposition_id) i.imposition_id, i.sort_order
    from up
    join action.imposition_lane_item i
      on i.lane_item_id = up.lane_item_id
    where i.moved_at <= p_as_of
      and i.imposition_id is not null
      -- only the most recent write per lane_item counts: a lane_item that is
      -- split again later gets a new set, the older one stays as history
      and i.moved_at = (
          select max(x.moved_at)
          from action.imposition_lane_item x
          where x.lane_item_id = i.lane_item_id
            and x.moved_at <= p_as_of)
    order by i.imposition_id, i.sort_order;
$$;

alter function action.get_lane_item_impositions(bigint, timestamp with time zone) owner to xfw3;
