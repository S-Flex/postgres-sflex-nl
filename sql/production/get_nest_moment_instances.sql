-- The nest moments of a material in moment order: the codes of a schedule
-- row (material_print_schedule.nest_moment_codes) numbered 0, 1, 2 by the
-- moment the lookup (production.lookup, lookup_nest_moments) puts them at --
-- the day the code is offset to, then the nest time on that day, then the
-- code. That number is lane_item.instance of the item stamped for the code
-- (mock.generate_plan); a code the lookup does not know sorts last.
create or replace function production.get_nest_moment_instances(p_nest_moment_codes text[]) returns TABLE(nest_moment_code text, instance integer)
	stable
	language sql
as $$
    SELECT c.code,
           (row_number() OVER (ORDER BY coalesce((m.value ->> 'day_offset')::integer, 0),
                                        coalesce((m.value #>> '{nest_moments,0,nest_time,start_offset_in_seconds}')::integer, 0),
                                        c.code) - 1)::integer
    FROM unnest(p_nest_moment_codes) AS c(code)
    LEFT JOIN (SELECT v.value
               FROM production.lookup l
               CROSS JOIN LATERAL jsonb_array_elements(l.lookup_json) AS v(value)
               WHERE l.lookup = 'lookup_nest_moments') m ON m.value ->> 'code' = c.code;
$$;

alter function production.get_nest_moment_instances(text[]) owner to xfw3;
