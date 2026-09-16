-- The employees planned on one production line on one business date, per
-- shift, from log.hr_shift_planning of the line's department resources: the
-- shift is the code of the employee in the planning (day, evening, night; the
-- order and the titles of log.lookup lookup_shift), not the clock data. Rows
-- without a code (planning before 1 Sep 2026) are left out.
-- section is the container of the board: the group of a working employee, or
-- the absence of an absent one (marking sick or leave; log.lookup
-- lookup_absence carries the titles), so a shift shows its groups, then its
-- sick and its leave; section_i18n is the title, section_order the order.
-- One row per employee; the board counts.
drop function if exists legacy.get_resource_shift_employees(text, timestamp with time zone);
drop function if exists legacy.get_resource_shift_employees(integer, date);
drop function if exists log.get_resource_shift_employees(text, timestamp with time zone);
drop function if exists log.get_resource_shift_employees(integer, date);

create function log.get_resource_shift_employees(p_production_line_id integer, p_business_date date DEFAULT (now() AT TIME ZONE 'Europe/Amsterdam')::date)
    returns TABLE(shift_planning_id integer, department_group_id integer, department_group_name text, shift text, shift_order integer, i18n jsonb, section text, section_i18n jsonb, section_order integer, group_name text, marking text, employee_id integer, personnel_number text, first_name text, infix text, last_name text, contract_type text, start_at timestamp with time zone, end_at timestamp with time zone, duration integer, break_minutes integer, remark text)
    stable
    language sql
as $$
    WITH shift_code AS (
        SELECT c.value ->> 'code' AS code, c.ordinality::integer AS shift_order, c.value -> 'i18n' AS i18n
        FROM log.lookup lk
        CROSS JOIN LATERAL jsonb_array_elements(lk.lookup_json) WITH ORDINALITY AS c(value, ordinality)
        WHERE lk.lookup = 'lookup_shift'
    ),
    absence AS (
        SELECT c.value ->> 'code' AS code, c.ordinality::integer AS absence_order, c.value -> 'i18n' AS i18n
        FROM log.lookup lk
        CROSS JOIN LATERAL jsonb_array_elements(lk.lookup_json) WITH ORDINALITY AS c(value, ordinality)
        WHERE lk.lookup = 'lookup_absence'
    ),
    plans AS (
        -- the planning of the line's department resources on the day
        SELECT sp.shift_planning_id, sp.department_group_id, sp.shift_json
        FROM log.hr_shift_planning sp
        JOIN relation.resource r ON r.resource_uid = sp.shift_json ->> 'resource_uid'
        WHERE r.line_id = p_production_line_id
          AND sp.business_date = coalesce(p_business_date, (now() AT TIME ZONE 'Europe/Amsterdam')::date)
    ),
    employee AS (
        SELECT DISTINCT ON (p.shift_planning_id, e.value ->> 'code', (e.value ->> 'employee_id')::integer)
               p.shift_planning_id, p.department_group_id,
               p.shift_json -> 'plan' ->> 'department_group_name' AS department_group_name,
               g.value ->> 'group'                                 AS group_name,
               e.value                                             AS e,
               nullif(e.value ->> 'marking', '')                   AS marking
        FROM plans p
        CROSS JOIN LATERAL jsonb_array_elements(coalesce(p.shift_json -> 'plan' -> 'groups', '[]'::jsonb)) AS g(value)
        CROSS JOIN LATERAL jsonb_array_elements(coalesce(g.value -> 'employees', '[]'::jsonb)) AS e(value)
        WHERE e.value ->> 'code' IS NOT NULL
        ORDER BY p.shift_planning_id, e.value ->> 'code', (e.value ->> 'employee_id')::integer, (e.value ->> 'id')::bigint DESC
    )
    SELECT em.shift_planning_id, em.department_group_id, em.department_group_name,
           em.e ->> 'code'                                   AS shift,
           coalesce(sc.shift_order, 99)                      AS shift_order,
           coalesce(sc.i18n, jsonb_build_object('nl', jsonb_build_object('title', em.e ->> 'code'))) AS i18n,
           CASE WHEN em.marking IS NULL THEN em.group_name ELSE em.marking END AS section,
           CASE WHEN em.marking IS NULL
                THEN (SELECT jsonb_object_agg(l, jsonb_build_object('title', em.group_name)) FROM unnest(array['nl', 'en', 'de', 'fr', 'es', 'uk']) AS l)
                ELSE coalesce(ab.i18n, jsonb_build_object('nl', jsonb_build_object('title', em.marking))) END AS section_i18n,
           CASE WHEN em.marking IS NULL THEN 0 ELSE coalesce(ab.absence_order, 9) END AS section_order,
           em.group_name,
           em.marking,
           (em.e ->> 'employee_id')::integer                 AS employee_id,
           em.e ->> 'personnel_number'                       AS personnel_number,
           em.e ->> 'first_name'                             AS first_name,
           nullif(em.e ->> 'infix', '')                      AS infix,
           em.e ->> 'last_name'                              AS last_name,
           em.e ->> 'contract_type'                          AS contract_type,
           (em.e ->> 'start_at')::timestamptz                AS start_at,
           (em.e ->> 'end_at')::timestamptz                  AS end_at,
           (em.e ->> 'duration')::integer                    AS duration,
           (em.e ->> 'break_minutes')::integer               AS break_minutes,
           nullif(em.e ->> 'remark', '')                     AS remark
    FROM employee em
    LEFT JOIN shift_code sc ON sc.code = em.e ->> 'code'
    LEFT JOIN absence ab ON ab.code = em.marking
    ORDER BY coalesce(sc.shift_order, 99), CASE WHEN em.marking IS NULL THEN 0 ELSE coalesce(ab.absence_order, 9) END,
             em.group_name, em.e ->> 'last_name', em.e ->> 'first_name';
$$;

alter function log.get_resource_shift_employees(integer, date) owner to xfw3;
