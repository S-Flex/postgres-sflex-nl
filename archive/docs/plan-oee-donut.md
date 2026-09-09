# Plan: OEE-donut (29) op dezelfde data als de area-chart (62)

Datum: 2026-09-05. Status: plan, nog niets gebouwd.

De donut op de pagina `oee` toont het actuele beeld van één machine, de
area-chart op `resource-oee-area-chart` de historie. Vandaag lezen ze twee
verschillende ketens en rekenen ze anders. Doel: één bron, één rekenregel, en
de legenda van de donut als filter.

## 1. hoe het nu zit

| | donut (29) | area-chart (62) |
|---|---|---|
| data_table | `get_resource_oee_aggregate` → `log.get_resource_state_aggregate` | `get_resource_state_shift_totals` → `log.get_resource_state_shift_totals` |
| bron | ruwe `log.state` + `log.data`, live tot `p_until` | `log.state_shift_agg` (gebouwd door `log.upsert_state_shift_agg`) |
| venster | 06:00 tot nu | shiftvensters uit `action.dates.shift_json` |
| producing | `least(productie, running)`; restant heet `starved.running` | idem, maar één keer gebouwd en opgeslagen |
| buckets / OEE | geen; `center_field` is `state.producing` (een som, geen OEE) | `counts_as`, `param_json`, `oee_json` met `producing_oee` |
| filter | `filter_field: type`, geen states-filter | `states` als query-param, fold-regel per bucket |
| planning | niet | `planned`-rij per dag |

Twee lezers van dezelfde meting die verschillende getallen laten zien; het
plan-document `plan-oee.md` §3g benoemt dat verschil al (v1 rekent het hele
venster, v2 alleen shift-uren).

## 2. besluit: de donut leest `get_resource_state_shift_totals`

De donut wordt een tweede weergave van precies dezelfde rijen als de area-chart,
voor één dag: `p_until = now()`, `p_days = 1`, `p_include_shifts = false`
(hele dag als één venster), `p_group_by = 'resource'`. Wat de functie al
levert en wat de donut daarvan gebruikt:

| ring / element | bron in de output | opmerking |
|---|---|---|
| buitenring | de state-rijen van de dag, serie op `counts_as`, waarde `duration_seconds` | dezelfde fold als de area-chart: een niet-aangevinkte sub-state vouwt in zijn bucket, niet-aangevinkte verliezen zitten in `available`, niet-aangevinkte breakdown/offline in `unavailable`. De ring sluit dus altijd op het venster |
| midden | `oee_json.producing_oee` | 0-100, `type: percent`; zelfde getal als de tooltip van de area-chart |
| binnenring (planning) | de rij `state = planned` tegen `param_json.total_shift_in_seconds` | `oee_json.planned_percentage` is hetzelfde getal als percentage; de ring toont gepland vs. de rest van het venster |
| legenda | de zes codes producing, starved, blocked, breakdown, offline, setup | vaste lijst, niet "wat er toevallig in de rijen zit": een state met 0 s moet aan te vinken blijven |
| kleuren / labels | `state_json.fill`, `state_json.color`, `state_json.class_name`, `state_json.i18n` | zelfde contract als 62 en 19 |

Wat er níét in de legenda komt: `available` en `unavailable` (synthetisch, de
rest van het venster), `planned` (binnenring), `idle` (staat wel in het filter
van de area-chart; hier bewust niet — dat is jouw lijst van zes).

### de legenda als filter

De legenda schrijft de query-param `states`, dezelfde die filter 64 en chart
62 gebruiken. Klik op een legenda-item = toggle van die code in `states`.
Default `["producing"]`, zoals 62 en 64. Omdat het een query-param is, geldt
een keuze in de donut ook voor de area-chart zodra je daarheen navigeert, en
andersom.

Setup blijft in producing (besloten 4 sep): setup aanvinken splitst de
producing-boog in producing − setup en een eigen setup-boog; de OEE in het
midden verandert daar niet van. Dat is precies de tooltip-regel van 62.

## 3. wat er verandert

### data_group 29 (`resource_oee_chart`)

```json
{
  "src": ["get_resource_state_shift_totals"],
  "layout": "donut-chart",
  "params": [
    { "key": "resource_uids", "is_optional": true, "is_query_param": true },
    { "key": "until", "is_optional": true, "is_query_param": true },
    { "key": "days", "default_value": 1 },
    { "key": "line_type", "is_optional": true, "is_query_param": true },
    { "key": "states", "is_optional": true, "default_value": ["producing"], "is_query_param": true },
    { "key": "include_shifts", "default_value": false },
    { "key": "group_by", "default_value": "resource" }
  ],
  "donut_chart_config": {
    "mode": "duration",
    "set_field": "counts_as",
    "set_order_field": "sort_order",
    "aggregate_field": "duration_seconds",
    "aggregate_fn": "sum",
    "content_field": "state_json.i18n",
    "fill_field": "state_json.fill",
    "color_field": "state_json.color",
    "class_names_field": "state_json.class_name",
    "center": { "field": "oee_json.producing_oee", "type": "percent" },
    "set_overrides": {
      "planned":     { "ring": "inner", "max_field": "param_json.total_shift_in_seconds" },
      "available":   { "no_legend": true, "no_tooltip": true },
      "unavailable": { "no_legend": true }
    },
    "legend": {
      "filter_param": "states",
      "items": ["producing", "setup", "idle", "starved", "blocked", "breakdown", "offline"]
    }
  }
}
```

De keys volgen 62: `set_field`, `set_order_field`, `set_overrides`,
`no_legend`/`no_tooltip`. Nieuw voor de donut-widget zijn `center` (was
`center_field` op een som), `set_overrides.*.ring` met `max_field` voor de
binnenring, en `legend.filter_param` + `legend.items`. `filter_field: type`,
`code_field` en `group_by` op `state.code` vervallen.

De labels van de legenda komen uit `state_json.i18n` van de rijen; voor een
code zónder rij (0 s) uit `log.lookup / lookup_resource_state` — de frontend
heeft die lookup al voor de timeline (19). Geen tweede i18n-lijst in de config.

### de functie

Niets. `get_resource_state_shift_totals` levert alles al: de fold-regel, de
synthetische rijen, `oee_json`, de `planned`-rij. Eén check hoort erbij (§5):
de dagrij met `p_include_shifts = false` moet bij `p_days = 1` precies één
venster geven.

### actualiteit

`log.state_shift_agg` is gebouwd, niet live. `site.refresh_derived_data`
draait `upsert_state_shift_agg(current_date)`; hoe vaak die job loopt bepaalt
hoe "actueel" de donut is. De v1-functie las de ruwe log en was per definitie
bij. Voor het plan: de frequentie van `refresh_derived_data` opvragen; is die
één keer per dag, dan hoort er een frequentere run van alleen
`upsert_state_shift_agg(current_date)` bij (de builder is delete-then-insert
per datum en kost weinig). Tot die tijd loopt de donut achter op de log.

Besloten 5 sep: de herbouw komt in de schrijfactie zelf (`crud_state_log`,
`crud_data_log`) met een resource-bereik op de builder; zie
`docs/handoff-state-refresh.md`.

### pagina en filter

Pagina `oee` houdt timeline (19) boven en donut (29) onder. Geen extra
filter-data_group: de legenda ís het filter. Wil je later toch het volledige
filter (weekend, vrije dagen, shifts), dan is 64 herbruikbaar.

### frontend

1. donut-widget: `set_field`/`set_overrides` zoals de area-chart, `center`
   met `type: percent`, `ring: inner` met `max_field`, `legend.filter_param`
   en `legend.items`.
2. legenda-items zonder rij: label uit de lookup, boog 0, wel klikbaar.
3. `states` als query-param schrijven en lezen (zoals het filter van 64 al doet).

## 4. wat er weggaat

- `log.get_resource_state_aggregate` en data_table `get_resource_oee_aggregate`:
  na deze stap zonder lezer. Kandidaat voor `docs/archive-analysis.md`, samen
  met de v1-afleiding `data-error`/`starved.running` die daar nog in zit.
- `field_config` van 29 (`state.producing`, `state.i18n`): vervangen door de
  paden op `state_json` en `oee_json`.

## 5. draaien en checken

1. `sql/update_data_group_partial.sql` met 29 (na de frontend-widget, anders
   staat de donut leeg).
2. Checks, read-only:

```sql
-- één dagvenster per resource; expected: 1 rij per resource met het venster
SELECT resource_uid, count(DISTINCT (shift_start, shift_end)) AS windows,
       max((param_json ->> 'total_shift_in_seconds')::int) AS window_seconds
FROM log.get_resource_state_shift_totals(array['<resource_uid>'], now(), 1, NULL,
         array['producing'], false, false, false, 'resource', NULL)
GROUP BY resource_uid;

-- de ring sluit: som van de state-rijen (zonder planned) = venster
SELECT sum(duration_seconds) FILTER (WHERE state <> 'planned') AS ring,
       max((param_json ->> 'total_shift_in_seconds')::int)      AS window_seconds,
       max((oee_json ->> 'producing_oee')::numeric)             AS center,
       max((oee_json ->> 'planned_percentage')::numeric)        AS inner_ring
FROM log.get_resource_state_shift_totals(array['<resource_uid>'], now(), 1, NULL,
         array['producing'], false, false, false, 'resource', NULL);
```

3. Vergelijk voor één machine de donut met de laatste dag van de area-chart:
   dezelfde bogen, hetzelfde OEE-getal.

## 6. open

- **Binnenring-betekenis**: gepland vs. venster (`planned_percentage`), of
  gepland vs. gerealiseerd (`producing_in_seconds / planned_in_seconds`, ben ik
  voor of achter op de planning)? Het plan gaat uit van het eerste; het tweede
  is één formuleregel extra in `v_formula_json`.
- **Meerdere resources**: met `resource_uids` van meer machines sommeert
  `aggregate_fn` de bogen; het middengetal moet dan het OEE van de groep zijn —
  `p_group_by = 'step'` of `'line'` levert dat als één rij, de widget moet dan
  het `oee_json` van die groep tonen en niet dat van de eerste rij.
