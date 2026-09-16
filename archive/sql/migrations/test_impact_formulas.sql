-- Read-only test van de impact-formules met evaluate_many_nas.
--
-- Elke printmethode vult zijn eigen production_impact_per_unit. De formules
-- draaien op sort_order binnen formula_level; de namen links van de = zijn
-- globale param-properties, dus een latere formule ziet wat een eerdere zette.
--
-- De gangvariabelen: fc, fc_2, fc_4, w, w_2, neon. Elke variabele is een gang
-- die dit vel maar EEN keer hoeft te maken:
--
--   fc     de eerste full-colour gang
--   fc_2   de tweede
--   fc_4   de derde en vierde samen (dus 2 x de gangprijs)
--   w      de eerste witgang
--   w_2    de tweede
--   neon   de neongang
--
-- Een code claimt de gangen die hij nodig heeft. Is een gang al door een
-- eerdere code geclaimd, dan kost hij hier niets:
--
--   fc = fc >= 0 ? 0 : sqm / fc_speed * 3600
--
-- TWEE DINGEN DIE MISGAAN ALS JE ZE VERGEET
--
-- 1. Seed op -1, niet op 0. Anders betekent 0 twee dingen tegelijk - "nog
--    niet geclaimd" en "geclaimd, kostte niets" - en rekent de derde code die
--    dezelfde inkt tegenkomt hem opnieuw. Met seed 0 en "> 0" geeft
--    fc, fc_2, fc_4 samen 1375,4 s in plaats van 1100,2 s.
--
-- 2. Een code bevat ALLEEN de claim-regels van zijn eigen gangen. Zet je ze
--    alle zes in elke formule, dan claimt full-color ook fc_2 en fc_4 en
--    houdt de volgende code niets meer over: fc, fc_2, fc_4 geeft dan 275,1 s
--    in plaats van 1100,2 s.
--
-- Gangsnelheden: fc 80 m2/h, w 60 m2/h, neon 40 m2/h.
-- Vel 2415019 is 203 x 301,1 cm = 6,1123 m2, dus per gang:
--   fc 275,1 s   w 366,7 s   neon 550,1 s


-- ── 0. demo: drie printmethodes op een vel ────────────────────────────
-- Het hele mechanisme in een resultaat. De full-colour gang wordt maar een
-- keer betaald, hoe vaak hij ook langskomt. -1 betekent "nog niet geclaimd".
--
--  stap  option_code                          claimt      fc     w      w_2    neon   impact  totaal
--  1     print-method.full-color              fc          275,1  -1     -1     -1     275,1   1558,7
--  2     print-method.full-color-white-white  fc, w, w_2    0,0  366,7  366,7  -1     733,5   1558,7
--  3     print-method.full-color-neon         fc, neon      0,0  366,7  366,7  550,1  550,1   1558,7
--
-- Dezelfde vier gangen als een enkele code (full-color-white-white-neon)
-- geven 1558,6 - het verschil van 0,1 is afronding per regel.
WITH vel AS (
    SELECT jsonb_build_object(
               'sqm', n.width * n.height / 10000.0,
               'fc_speed', 80, 'w_speed', 60, 'neon_speed', 40,   -- m2/h
               'fc', -1, 'fc_2', -1, 'fc_4', -1, 'w', -1, 'w_2', -1, 'neon', -1
           ) AS v
    FROM legacy.nest n WHERE n.nest_id = 2415019
),
s1 AS (SELECT public.evaluate_many_nas(jsonb_build_array(
           'fc = fc >= 0 ? 0 : sqm / fc_speed * 3600',
           'production_impact_per_unit = fc'), vel.v) AS v FROM vel),
s2 AS (SELECT public.evaluate_many_nas(jsonb_build_array(
           'fc  = fc  >= 0 ? 0 : sqm / fc_speed * 3600',
           'w   = w   >= 0 ? 0 : sqm / w_speed * 3600',
           'w_2 = w_2 >= 0 ? 0 : sqm / w_speed * 3600',
           'production_impact_per_unit = fc + w + w_2'), s1.v) AS v FROM s1),
s3 AS (SELECT public.evaluate_many_nas(jsonb_build_array(
           'fc   = fc   >= 0 ? 0 : sqm / fc_speed * 3600',
           'neon = neon >= 0 ? 0 : sqm / neon_speed * 3600',
           'production_impact_per_unit = fc + neon'), s2.v) AS v FROM s2)
SELECT stap, option_code, claimt,
       round((v ->> 'fc')::numeric, 1)   AS fc,
       round((v ->> 'w')::numeric, 1)    AS w,
       round((v ->> 'w_2')::numeric, 1)  AS w_2,
       round((v ->> 'neon')::numeric, 1) AS neon,
       round((v ->> 'production_impact_per_unit')::numeric, 1) AS impact,
       sum(round((v ->> 'production_impact_per_unit')::numeric, 1)) OVER () AS totaal
FROM (
    SELECT 1 AS stap, 'print-method.full-color' AS option_code, 'fc' AS claimt, v FROM s1
    UNION ALL
    SELECT 2, 'print-method.full-color-white-white', 'fc, w, w_2', v FROM s2
    UNION ALL
    SELECT 3, 'print-method.full-color-neon',        'fc, neon',   v FROM s3
) x
ORDER BY stap;


-- ── 1. de elf formule-arrays, elk apart op een schoon vel ─────────────
-- gangen = het aantal gangen dat de code nodig heeft; impact moet daarmee
-- kloppen (gangen x de gangprijs van die inkt).
WITH code AS (
    SELECT * FROM (VALUES
        ('full-color', 1, 0, 0, jsonb_build_array(
            'fc = fc >= 0 ? 0 : sqm / fc_speed * 3600',
            'production_impact_per_unit = fc')),
        ('white', 0, 1, 0, jsonb_build_array(
            'w = w >= 0 ? 0 : sqm / w_speed * 3600',
            'production_impact_per_unit = w')),
        ('full-color-full-color', 2, 0, 0, jsonb_build_array(
            'fc   = fc   >= 0 ? 0 : sqm / fc_speed * 3600',
            'fc_2 = fc_2 >= 0 ? 0 : sqm / fc_speed * 3600',
            'production_impact_per_unit = fc + fc_2')),
        ('white-white', 0, 2, 0, jsonb_build_array(
            'w   = w   >= 0 ? 0 : sqm / w_speed * 3600',
            'w_2 = w_2 >= 0 ? 0 : sqm / w_speed * 3600',
            'production_impact_per_unit = w + w_2')),
        ('full-color-neon', 1, 0, 1, jsonb_build_array(
            'fc   = fc   >= 0 ? 0 : sqm / fc_speed * 3600',
            'neon = neon >= 0 ? 0 : sqm / neon_speed * 3600',
            'production_impact_per_unit = fc + neon')),
        ('full-color-white', 1, 1, 0, jsonb_build_array(
            'fc = fc >= 0 ? 0 : sqm / fc_speed * 3600',
            'w  = w  >= 0 ? 0 : sqm / w_speed * 3600',
            'production_impact_per_unit = fc + w')),
        ('full-color-white-full-color', 2, 1, 0, jsonb_build_array(
            'fc   = fc   >= 0 ? 0 : sqm / fc_speed * 3600',
            'fc_2 = fc_2 >= 0 ? 0 : sqm / fc_speed * 3600',
            'w    = w    >= 0 ? 0 : sqm / w_speed * 3600',
            'production_impact_per_unit = fc + fc_2 + w')),
        ('full-color-white-white', 1, 2, 0, jsonb_build_array(
            'fc  = fc  >= 0 ? 0 : sqm / fc_speed * 3600',
            'w   = w   >= 0 ? 0 : sqm / w_speed * 3600',
            'w_2 = w_2 >= 0 ? 0 : sqm / w_speed * 3600',
            'production_impact_per_unit = fc + w + w_2')),
        ('full-color-white-neon', 1, 1, 1, jsonb_build_array(
            'fc   = fc   >= 0 ? 0 : sqm / fc_speed * 3600',
            'w    = w    >= 0 ? 0 : sqm / w_speed * 3600',
            'neon = neon >= 0 ? 0 : sqm / neon_speed * 3600',
            'production_impact_per_unit = fc + w + neon')),
        ('full-color-full-color-full-color-full-color', 4, 0, 0, jsonb_build_array(
            'fc   = fc   >= 0 ? 0 : sqm / fc_speed * 3600',
            'fc_2 = fc_2 >= 0 ? 0 : sqm / fc_speed * 3600',
            'fc_4 = fc_4 >= 0 ? 0 : 2 * (sqm / fc_speed * 3600)',
            'production_impact_per_unit = fc + fc_2 + fc_4')),
        ('full-color-white-white-neon', 1, 2, 1, jsonb_build_array(
            'fc   = fc   >= 0 ? 0 : sqm / fc_speed * 3600',
            'w    = w    >= 0 ? 0 : sqm / w_speed * 3600',
            'w_2  = w_2  >= 0 ? 0 : sqm / w_speed * 3600',
            'neon = neon >= 0 ? 0 : sqm / neon_speed * 3600',
            'production_impact_per_unit = fc + w + w_2 + neon'))
    ) AS t(option_code, fc_n, w_n, neon_n, formula_json)
),
seed AS (
    SELECT jsonb_build_object('sqm', n.width * n.height / 10000.0,
                              'fc_speed', 80, 'w_speed', 60, 'neon_speed', 40,
                              'fc', -1, 'fc_2', -1, 'fc_4', -1,
                              'w', -1, 'w_2', -1, 'neon', -1,
                              'production_impact_per_unit', 0) AS v,
           n.width * n.height / 10000.0 AS sqm
    FROM legacy.nest n WHERE n.nest_id = 2415019
)
SELECT c.option_code,
       jsonb_array_length(c.formula_json) - 1 AS claim_regels,
       c.fc_n + c.w_n + c.neon_n              AS gangen,
       round((r.v ->> 'production_impact_per_unit')::numeric, 1) AS impact,
       round((c.fc_n * s.sqm / 80 + c.w_n * s.sqm / 60 + c.neon_n * s.sqm / 40) * 3600, 1) AS verwacht
FROM code c
CROSS JOIN seed s
CROSS JOIN LATERAL (
    SELECT public.evaluate_many_nas(c.formula_json, s.v) AS v
) r
ORDER BY gangen, c.option_code;


-- ── 2. dezelfde inkt meerdere keren, in beide volgordes ───────────────
-- De tweede en verdere code die dezelfde gang tegenkomt rekent 0. Zo komt er
-- per vel maar een keer betaald werk uit, hoeveel printmethodes er ook op
-- liggen, en telt het bord gewoon op.
--
-- verwacht:
--   fc, fc_2, fc_4    275,1  275,1  550,1  -> 1100,3   (4 gangen)
--   fc_4, fc_2, fc    1100,2 0      0      -> 1100,2   (4 gangen)
--   fc, fc, fc        275,1  0      0      ->  275,1   (1 gang)
WITH seed AS (
    SELECT jsonb_build_object('sqm', n.width * n.height / 10000.0,
                              'fc_speed', 80, 'w_speed', 60, 'neon_speed', 40,
                              'fc', -1, 'fc_2', -1, 'fc_4', -1,
                              'w', -1, 'w_2', -1, 'neon', -1,
                              'production_impact_per_unit', 0) AS v
    FROM legacy.nest n WHERE n.nest_id = 2415019
),
f AS (
    SELECT 'fc'   AS code, jsonb_build_array(
        'fc = fc >= 0 ? 0 : sqm / fc_speed * 3600',
        'production_impact_per_unit = fc') AS arr
    UNION ALL SELECT 'fc_2', jsonb_build_array(
        'fc   = fc   >= 0 ? 0 : sqm / fc_speed * 3600',
        'fc_2 = fc_2 >= 0 ? 0 : sqm / fc_speed * 3600',
        'production_impact_per_unit = fc + fc_2')
    UNION ALL SELECT 'fc_4', jsonb_build_array(
        'fc   = fc   >= 0 ? 0 : sqm / fc_speed * 3600',
        'fc_2 = fc_2 >= 0 ? 0 : sqm / fc_speed * 3600',
        'fc_4 = fc_4 >= 0 ? 0 : 2 * (sqm / fc_speed * 3600)',
        'production_impact_per_unit = fc + fc_2 + fc_4')
),
-- reeks A: fc, fc_2, fc_4
a1 AS (SELECT public.evaluate_many_nas((SELECT arr FROM f WHERE code='fc'),   s.v) AS v FROM seed s),
a2 AS (SELECT public.evaluate_many_nas((SELECT arr FROM f WHERE code='fc_2'), a1.v) AS v FROM a1),
a3 AS (SELECT public.evaluate_many_nas((SELECT arr FROM f WHERE code='fc_4'), a2.v) AS v FROM a2),
-- reeks B: fc_4, fc_2, fc
b1 AS (SELECT public.evaluate_many_nas((SELECT arr FROM f WHERE code='fc_4'), s.v) AS v FROM seed s),
b2 AS (SELECT public.evaluate_many_nas((SELECT arr FROM f WHERE code='fc_2'), b1.v) AS v FROM b1),
b3 AS (SELECT public.evaluate_many_nas((SELECT arr FROM f WHERE code='fc'),   b2.v) AS v FROM b2),
-- reeks C: fc, fc, fc
c1 AS (SELECT public.evaluate_many_nas((SELECT arr FROM f WHERE code='fc'), s.v) AS v FROM seed s),
c2 AS (SELECT public.evaluate_many_nas((SELECT arr FROM f WHERE code='fc'), c1.v) AS v FROM c1),
c3 AS (SELECT public.evaluate_many_nas((SELECT arr FROM f WHERE code='fc'), c2.v) AS v FROM c2),
resultaat AS (
    SELECT 'A: fc, fc_2, fc_4' AS reeks, 1 AS stap, 'fc'               AS code, a1.v AS v FROM a1
    UNION ALL SELECT 'A: fc, fc_2, fc_4', 2, 'fc_2',                          a2.v FROM a2
    UNION ALL SELECT 'A: fc, fc_2, fc_4', 3, 'fc_4',                          a3.v FROM a3
    UNION ALL SELECT 'B: fc_4, fc_2, fc', 1, 'fc_4',                          b1.v FROM b1
    UNION ALL SELECT 'B: fc_4, fc_2, fc', 2, 'fc_2',                          b2.v FROM b2
    UNION ALL SELECT 'B: fc_4, fc_2, fc', 3, 'fc',                            b3.v FROM b3
    UNION ALL SELECT 'C: fc, fc, fc',     1, 'fc',                            c1.v FROM c1
    UNION ALL SELECT 'C: fc, fc, fc',     2, 'fc',                            c2.v FROM c2
    UNION ALL SELECT 'C: fc, fc, fc',     3, 'fc',                            c3.v FROM c3
)
SELECT reeks, stap, code,
       round((v ->> 'production_impact_per_unit')::numeric, 1) AS impact,
       sum(round((v ->> 'production_impact_per_unit')::numeric, 1)) OVER (PARTITION BY reeks) AS totaal
FROM resultaat ORDER BY reeks, stap;


-- ── 3. de vier imposities van materiaal 47, elk alleen full-color ─────
SELECT n.nest_id, n.width, n.height,
       round((n.width * n.height / 10000.0)::numeric, 3) AS sqm,
       round((r.v ->> 'production_impact_per_unit')::numeric, 1) AS impact,
       sum(round((r.v ->> 'production_impact_per_unit')::numeric, 1)) OVER () AS totaal
FROM legacy.nest n
CROSS JOIN LATERAL (
    SELECT public.evaluate_many_nas(
        jsonb_build_array(
            'fc = fc >= 0 ? 0 : sqm / fc_speed * 3600',
            'production_impact_per_unit = fc'),
        jsonb_build_object('sqm', n.width * n.height / 10000.0,
                           'fc_speed', 80, 'fc', -1,
                           'production_impact_per_unit', 0)) AS v
) r
WHERE n.nest_id IN (2414708, 2415019, 2415024, 2415151)
ORDER BY n.nest_id;
-- verwacht: 260,8 + 275,1 + 242,4 + 275,2 = 1053,5 s
