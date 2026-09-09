-- The machine states a board can select or show in a legend, from
-- log.lookup / lookup_resource_state (json/lookup/log/lookup_resource_state.json):
-- the nodes that carry counts_as, the bucket they count in for the OEE, one
-- per title: an alias with the same titles as its target (starved.operator
-- next to starved) is the same choice, so the first in lookup order stands
-- for both. Feeds the states filter of the OEE boards
-- (resource_oee_area_chart_filter) and the legend of the OEE charts: filter
-- and legend read the lookup, never a copy in their config, so a title
-- follows the language of the user.
drop function if exists log.get_resource_states();

create function log.get_resource_states() returns TABLE(code text, sort_order integer, counts_as text, i18n jsonb, class_name text, fill text, color text)
    stable
    language sql
as $$
    SELECT n.code, n.sort_order, n.counts_as, n.i18n, n.class_name, n.fill, n.color
    FROM (
        SELECT DISTINCT ON (s.value -> 'i18n')
               s.value ->> 'code'              AS code,
               (s.value ->> 'order')::integer  AS sort_order,
               s.value ->> 'counts_as'         AS counts_as,
               s.value -> 'i18n'               AS i18n,
               s.value ->> 'class_name'        AS class_name,
               s.value ->> 'fill'              AS fill,
               s.value ->> 'color'             AS color
        FROM log.lookup lk
        CROSS JOIN LATERAL jsonb_array_elements(lk.lookup_json) AS s(value)
        WHERE lk.lookup = 'lookup_resource_state'
          AND s.value ? 'counts_as'
        ORDER BY s.value -> 'i18n', (s.value ->> 'order')::integer
    ) n
    ORDER BY n.sort_order;
$$;

alter function log.get_resource_states() owner to xfw3;
