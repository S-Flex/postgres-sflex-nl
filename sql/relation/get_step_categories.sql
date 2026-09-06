-- The production steps, from relation.lookup / lookup_step_category
-- (json/lookup/relation/lookup_step_category.json): per step its order and
-- the status at which the step's work is done. Feeds the steps filter of the
-- resource board (resource_plan_filter): the filter reads the lookup, never a
-- copy in its config. A step added to the lookup shows up without a change.
drop function if exists relation.get_step_categories();

create function relation.get_step_categories() returns TABLE(step text, sort_order integer, done_sequence integer, done_internal_status_code text)
    stable
    language sql
as $$
    SELECT s.value ->> 'step',
           (s.value ->> 'order')::integer,
           (s.value ->> 'sequence')::integer,
           s.value ->> 'internal_status_code'
    FROM relation.lookup lk
    CROSS JOIN LATERAL jsonb_array_elements(lk.lookup_json) AS s(value)
    WHERE lk.lookup = 'lookup_step_category'
    ORDER BY (s.value ->> 'order')::integer;
$$;

alter function relation.get_step_categories() owner to xfw3;
