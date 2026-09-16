-- ============================================================
-- Opruimen (6 sep): de tussenvoorraad kan nooit ouder zijn dan tien werkdagen,
-- maar legacy.nest draagt duizenden nests van vóór juli die nooit verder zijn
-- gekomen dan 'printed'. De nest-status wordt alleen nog via log.crud_data_log
-- bijgewerkt, en voor die nests komt er geen machine-event meer: geen snij-log
-- (de snijders logden toen niet, of het werk ging niet over een snijder). Ze
-- zijn geen voorraad, ze zijn geschiedenis zonder afloop. Weg ermee:
--   a. nests ouder dan twee maanden zonder enige regel in log.data
--      (dry run 6 sep: 85.036; al gedraaid via het eerdere script, nu 0);
--   b. nests ouder dan twee maanden die nog onder 'cut' staan (nested, ripped,
--      printed, calender, laminated, coated, applied), wél gelogd maar nooit
--      afgemeld (dry run 6 sep: 14.129).
-- Met hun legacy.nest_log-regels (die FK heeft geen cascade). Nests met regels
-- in legacy.single_product blijven staan (445), want de cascade zou de
-- koppeling orderregel -> nest wegnemen. log.data houdt zijn regels (op
-- nest_name, geen FK): de machinegeschiedenis blijft.
-- Na het draaien toont de tussenvoorraad per lijn alleen nog nests van de
-- laatste twee weken (lijn 5: 372 in plaats van 1.536).
-- ============================================================

-- check before; expected: a 0 (already deleted), b 14129, kept 445
WITH old_nest AS (
    SELECT n.nest_id,
           NOT EXISTS (SELECT 1 FROM log.data d WHERE d.nest_name = n.nest_name) AS never_logged,
           coalesce(i.sequence, -1) < 801 AS below_cut,
           EXISTS (SELECT 1 FROM legacy.single_product sp WHERE sp.nest_id = n.nest_id) AS has_parts
    FROM legacy.nest n
    LEFT JOIN mapping.internal_status i ON i.code = n.nest_json ->> 'internal_status_code' AND i.domain_id = n.domain_id
    WHERE n.nested_at < now() - interval '2 months'
      AND lower(coalesce(n.nest_json ->> 'status', '')) NOT LIKE 'cancel%'
)
SELECT count(*) FILTER (WHERE never_logged AND NOT has_parts)               AS a_never_logged,
       count(*) FILTER (WHERE NOT never_logged AND below_cut AND NOT has_parts) AS b_logged_below_cut,
       count(*) FILTER (WHERE (never_logged OR below_cut) AND has_parts)      AS kept_with_parts
FROM old_nest;

BEGIN;

CREATE TEMP TABLE del_nest ON COMMIT DROP AS
SELECT n.nest_id
FROM legacy.nest n
LEFT JOIN mapping.internal_status i ON i.code = n.nest_json ->> 'internal_status_code' AND i.domain_id = n.domain_id
WHERE n.nested_at < now() - interval '2 months'
  AND lower(coalesce(n.nest_json ->> 'status', '')) NOT LIKE 'cancel%'
  AND (NOT EXISTS (SELECT 1 FROM log.data d WHERE d.nest_name = n.nest_name)
       OR coalesce(i.sequence, -1) < 801)
  AND NOT EXISTS (SELECT 1 FROM legacy.single_product sp WHERE sp.nest_id = n.nest_id);

-- the log first: its FK to nest has no cascade
DELETE FROM legacy.nest_log nl
WHERE nl.nest_id IN (SELECT nest_id FROM del_nest);

-- the nests; imposition_unit_manifest follows by cascade
DELETE FROM legacy.nest n
WHERE n.nest_id IN (SELECT nest_id FROM del_nest);

COMMIT;

-- check after; expected: a 0, b 0, kept 445
WITH old_nest AS (
    SELECT n.nest_id,
           NOT EXISTS (SELECT 1 FROM log.data d WHERE d.nest_name = n.nest_name) AS never_logged,
           coalesce(i.sequence, -1) < 801 AS below_cut,
           EXISTS (SELECT 1 FROM legacy.single_product sp WHERE sp.nest_id = n.nest_id) AS has_parts
    FROM legacy.nest n
    LEFT JOIN mapping.internal_status i ON i.code = n.nest_json ->> 'internal_status_code' AND i.domain_id = n.domain_id
    WHERE n.nested_at < now() - interval '2 months'
      AND lower(coalesce(n.nest_json ->> 'status', '')) NOT LIKE 'cancel%'
)
SELECT count(*) FILTER (WHERE never_logged AND NOT has_parts)               AS a_never_logged,
       count(*) FILTER (WHERE NOT never_logged AND below_cut AND NOT has_parts) AS b_logged_below_cut,
       count(*) FILTER (WHERE (never_logged OR below_cut) AND has_parts)      AS kept_with_parts,
       (SELECT count(*) FROM legacy.nest) AS nests_left
FROM old_nest;

-- the intermediate stock per line; expected: only nests of the last two weeks
SELECT l.line_id, l.line,
       (SELECT count(*) FROM legacy.get_nest_list(l.line_id, NULL, array['printed'], true)) AS in_list,
       (SELECT min(g.nested_at)::date FROM legacy.get_nest_list(l.line_id, NULL, array['printed'], true) g) AS oldest
FROM relation.production_line l
WHERE l.line_id IN (2, 3, 4, 5, 9, 18, 23, 24)
ORDER BY 1;
