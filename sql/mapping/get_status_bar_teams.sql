-- The teams of the status bar for one production line: per team of
-- lookup_teams the employees planned in the current shift, the planned count
-- of the shift (already without the absent). The current shift of a group is
-- the one that started last before now; before the first shift of the day, the
-- first one. p_business_date is the day of the planning, today by default.
drop function if exists mapping.get_status_bar_teams(text, timestamp with time zone);
drop function if exists mapping.get_status_bar_teams(integer, date);

create function mapping.get_status_bar_teams(p_production_line_id integer, p_business_date date) returns jsonb
    stable
    language sql
as $$
    WITH shift AS (
        SELECT g.value ->> 'group' AS group_name,
               (s.value ->> 'start_at')::timestamptz AS start_at,
               (s.value ->> 'employee_count')::integer AS employee_count
        FROM log.hr_shift_planning sp
        JOIN relation.resource r ON r.resource_uid = sp.shift_json ->> 'resource_uid'
        CROSS JOIN LATERAL jsonb_array_elements(coalesce(sp.shift_json -> 'plan' -> 'groups', '[]'::jsonb)) AS g(value)
        CROSS JOIN LATERAL jsonb_array_elements(coalesce(g.value -> 'shifts', '[]'::jsonb)) AS s(value)
        WHERE r.line_id = p_production_line_id
          AND sp.business_date = coalesce(p_business_date, (now() AT TIME ZONE 'Europe/Amsterdam')::date)
    ),
    current_shift AS (
        SELECT DISTINCT ON (group_name) group_name, employee_count
        FROM shift
        ORDER BY group_name,
                 (start_at <= now()) DESC,
                 CASE WHEN start_at <= now() THEN start_at END DESC,
                 start_at ASC
    ),
    team AS (
        SELECT grp ->> 'code'  AS code,
               grp -> 'i18n'   AS i18n,
               grp ->> 'order' AS order_key,
               coalesce(sum(c.employee_count), 0)::integer AS value
        FROM relation.lookup rl
        CROSS JOIN LATERAL jsonb_array_elements(rl.lookup_json) AS grp
        LEFT JOIN current_shift c ON grp -> 'codes' @> to_jsonb(public.to_kebab(c.group_name))
        WHERE rl.lookup = 'lookup_teams'
        GROUP BY grp ->> 'code', grp -> 'i18n', grp ->> 'order'
    )
    SELECT coalesce(jsonb_agg(jsonb_build_object('code', code, 'i18n', i18n, 'value', value) ORDER BY order_key), '[]'::jsonb)
    FROM team;
$$;

alter function mapping.get_status_bar_teams(integer, date) owner to xfw3;
