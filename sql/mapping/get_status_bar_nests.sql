-- The nest items of the status bar (data_group 43, group nests): the nests
-- nested today (Amsterdam day of nested_at) on the production lines of the
-- line type of the production line: how many, their area in m2 (width x
-- height x amount, the dimensions are cm) and the average waste percentage.
-- No colour: plain figures, like the file inflow. A click on the group opens
-- the nest waste page (the nav of the group in the status_bar lookup).
create or replace function mapping.get_status_bar_nests(p_line_id integer) returns jsonb
	stable
	language sql
as $$
    WITH nest AS (
        SELECT coalesce(n.amount, 1)                              AS amount,
               n.width * n.height / 10000 * coalesce(n.amount, 1) AS sqm,
               (n.nest_json ->> 'waste_percentage')::numeric      AS waste_percentage
        FROM legacy.nest n
        JOIN relation.production_line pl ON pl.line_id = (n.nest_json ->> 'production_line_id')::integer
        WHERE (n.nested_at AT TIME ZONE 'Europe/Amsterdam')::date = (now() AT TIME ZONE 'Europe/Amsterdam')::date
          AND pl.line_type = (SELECT l.line_type FROM relation.production_line l WHERE l.line_id = p_line_id)
    ),
    total AS (
        SELECT count(*)::integer                       AS nests,
               round(coalesce(sum(sqm), 0))::integer   AS sqm,
               round(avg(waste_percentage), 1)         AS avg_waste_percentage
        FROM nest
    )
    SELECT jsonb_build_array(
               jsonb_build_object('code', 'nests',
                                  'i18n', jsonb_build_object('de', jsonb_build_object('title', 'Nester'),
                                                             'en', jsonb_build_object('title', 'Nests'),
                                                             'es', jsonb_build_object('title', 'Nidos'),
                                                             'fr', jsonb_build_object('title', 'Imbrications'),
                                                             'nl', jsonb_build_object('title', 'Nesten'),
                                                             'uk', jsonb_build_object('title', 'Нести')),
                                  'value', t.nests),
               jsonb_build_object('code', 'sqm',
                                  'i18n', jsonb_build_object('de', jsonb_build_object('title', 'm²'),
                                                             'en', jsonb_build_object('title', 'm²'),
                                                             'es', jsonb_build_object('title', 'm²'),
                                                             'fr', jsonb_build_object('title', 'm²'),
                                                             'nl', jsonb_build_object('title', 'm²'),
                                                             'uk', jsonb_build_object('title', 'м²')),
                                  'value', t.sqm),
               jsonb_build_object('code', 'avg-waste',
                                  'i18n', jsonb_build_object('de', jsonb_build_object('title', 'Gem. Abfall %'),
                                                             'en', jsonb_build_object('title', 'Avg. waste %'),
                                                             'es', jsonb_build_object('title', 'Desperdicio medio %'),
                                                             'fr', jsonb_build_object('title', 'Déchet moyen %'),
                                                             'nl', jsonb_build_object('title', 'Gem. afval %'),
                                                             'uk', jsonb_build_object('title', 'Сер. відходи %')),
                                  'value', coalesce(t.avg_waste_percentage, 0)))
    FROM total t;
$$;

alter function mapping.get_status_bar_nests(integer) owner to xfw3;
