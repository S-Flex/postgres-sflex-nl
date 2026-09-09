-- The machines of a line type, in step order (lookup_step_category). p_step
-- narrows to one step: the printer select of the inflow queue asks for print.
drop function if exists relation.get_resources(text);
drop function if exists relation.get_resources(text, text);

create function relation.get_resources(p_line_type text, p_step text DEFAULT NULL::text) returns TABLE(resource_uid text, resource_name text)
	stable
	language sql
as $$
    SELECT r.resource_uid, r.resource_name
    FROM   relation.resource r
    JOIN   relation.production_line pl ON pl.line_id = r.line_id
    JOIN   relation.lookup l ON l.lookup = 'lookup_step_category'
    JOIN   LATERAL jsonb_array_elements(l.lookup_json) AS el ON el ->> 'step' = r.step
    WHERE  pl.line_type = p_line_type
      AND  (p_step IS NULL OR r.step = p_step)
    ORDER  BY (el ->> 'order')::int, r.resource_name;
$$;

alter function relation.get_resources(text, text) owner to xfw3;
