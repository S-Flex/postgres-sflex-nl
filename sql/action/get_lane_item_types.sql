-- The kinds of lane item rows, from action.lookup / lookup_lane_item_type
-- (json/lookup/action/lookup_lane_item_type.json): plan, progress, actual.
-- Feeds the types filter of the resource board (resource_plan_filter): the
-- filter reads the lookup, never a copy in its config.
drop function if exists action.get_lane_item_types();

create function action.get_lane_item_types() returns TABLE(type text, sort_order integer, class_names text[])
    stable
    language sql
as $$
    SELECT t.value ->> 'type',
           (t.value ->> 'sort_order')::integer,
           coalesce((SELECT array_agg(c) FROM jsonb_array_elements_text(coalesce(t.value -> 'class_names', '[]'::jsonb)) c), '{}'::text[])
    FROM action.lookup lk
    CROSS JOIN LATERAL jsonb_array_elements(lk.lookup_json) AS t(value)
    WHERE lk.lookup = 'lookup_lane_item_type'
    ORDER BY (t.value ->> 'sort_order')::integer;
$$;

alter function action.get_lane_item_types() owner to xfw3;
