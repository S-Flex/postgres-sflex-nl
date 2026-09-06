# handoff: resource_plan (81) — wat er in de config veranderd is

Data_group `resource_plan` (was `production_resource_plan`), layout `timeline`,
data uit `get_resource_plan`. Filter: `resource_plan_filter` (was
`production_resource_plan_filter`). Pagina's en nav: `nest-resource-plan` en
`production-resource-plan` (was `impose-resource-plan`); data_group 78 is weg.

## timeline_config

| key | veld | nieuw/hernoemd |
|---|---|---|
| `fixed_group_field` | `fixed_group` | hernoemd (was `is_fixed_group_field`), ook in 75 en 76 |
| `set_field` | `type` | nieuw op dit bord: de soort rij, `plan` / `progress` / `actual` (zelfde key als op 19 en 56) |
| `set_order_field` | `type_json.sort_order` | laagvolgorde van de soorten binnen een lane (als op 19 en 56) |
| `placement_field` | `type_json.placement` | nieuw: `chain` (plan, de client ketent) of `offset` (progress, actual: op eigen offset) |
| `evaluate` | `{formula_field: type_json.formula, params_field: param_json}` | als op 76; de formule van de soort rekent `start_offset_in_seconds` en `duration_in_seconds` uit de variabelen |
| `set_title_field` | `type_json.i18n` | de titel van een set-rij (naast de globale `title_field`) |
| `set_overrides` | `{plan: {field_config, row_options}, progress: {…}, actual: {…}}` | per soort: `field_config` gemerged over de root, `row_options` (alleen plan `draggable`) |
| `items` | `{data_field: states_json, offset_field, duration_field, class_names_field}` | nieuw: het subniveau van een rij, blokken binnen het blok (offsets op dezelfde as); `data_field` als in `status_bar_config.items` |
| `class_names_field` | `class_names` | ongewijzigd; de class_names van de soort en van de status zitten er al in |

De variabelen in `param_json`: `planned_start_offset_in_seconds`,
`production_impact_in_seconds`, `remaining_impact_in_seconds` (plan, progress),
`actual_start_offset_in_seconds`, `actual_duration_in_seconds` (actual). De
kolommen `start_offset_in_seconds` en `duration_in_seconds` dragen dezelfde
uitkomst, voor een renderer zonder evaluator.

Gedrag per soort: drie set-rijen per lane, plan boven progress boven actual
(`set_order_field`). `progress` deelt `lane_item_id` met zijn plan-rij en start
op dezelfde opgeslagen offset (kortere duur); `actual` heeft geen `lane_item_id`
en de actual-items van een lane sluiten op elkaar aan (runs met class
`actual-produced`, en de stukken ertussen). Sleepbaar is wat `row_options.draggable`
zegt, per set via `set_overrides`; slepen verandert `start_offset_in_seconds`,
los van `placement`.

## velden

- `type`, `type_json` (node uit `lookup_lane_item_type`: `type`, `sort_order`,
  `class_names`, `formula`, `placement`) — `level` is weg.
- `progress_json.done_amount`, `.remaining_amount`, `.remaining_percentage`
  (0–100) — in de tooltip via dot-notatie; de resterende tijd is
  `param_json.remaining_impact_in_seconds`.
- `states_json` (alleen actual): `[{start_offset_in_seconds, duration_in_seconds,
  class_names, state_json}]`; `state_json`, `group_state_json` en `class_names`
  staan op elke soort rij.
- `param_json.is_run`, `.produced_count`, `.producing_in_seconds` (actual).
- `forecast_sqm` (plan en progress): de forecast van het materiaal op zijn lijn voor
  de dag, naast `sqm`; in de tooltip achter `sqm`. Null op actual.
- primary keys: `type`, `lane_item_id`, `resource_uid`, `start_at` (plan en
  progress uniek op type + lane_item_id, actual op type + resource_uid +
  start_at; `start_offset_in_seconds` zit er niet in, die verandert bij ketenen
  en slepen).

## params

`steps` (text[], optioneel, leeg = alle stappen van de dag) en `types` (text[],
default alle drie) als query-params; `step` is weg. Het filter leest zijn opties
uit `get_step_categories` en `get_lane_item_types` (`input_data.src`, bestaand
mechanisme).

## pagina's: sectie-`params`

Twee pagina's op dezelfde data_groups: `nest-resource-plan` en
`production-resource-plan` (`resource-plan` is weg, ook in de nav). Een sectie in
`pages.json` draagt `params` in dezelfde vorm als de data_group
(`[{key, default_value}]`); de renderer merget die per key over de `params` van
de data_group van die sectie. Op beide pagina's staat de override op het filter én
het bord, alleen `steps` verschilt: `["impose"]` tegenover
`["print","coat","laminate","route","cut"]`.

## antwoorden op de vragen van 6 sep

1. 75 heeft nu `chain_scope: "plan"`; zonder `chain_scope` geen chain, geen default in de client.
2. Progress start op `planned_start_offset_in_seconds`, de opgeslagen start. De geketende start volgen komt later, als `crud_lane_item` start, duur en instanties bijwerkt.
3. Progress is een eigen set-rij: per lane de plan-rijen, de progress-rijen en de actual-rijen, in de volgorde van `set_order_field`.
4. Sleepbaar is `row_options.draggable`, per set via `set_overrides`; geen logica op `placement`. Slepen verandert `start_offset_in_seconds`.
5. De `items` van een actual-rij dragen `class_names` (de status); hoogte en kleur komen uit de class. Per set kunnen `row_options` mee (nav met menu of on_select), zoals op `resource_oee_timeline` (19).
6. `set_overrides[set].field_config` is een merge over de root-field_config; `hidden: false` staat er daarom expliciet in.
7. `set_title_field` is de titel van een set (op 81 `type_json.i18n`, op 19 en 56 hersteld), `title_field` de globale titel. Beide bestaan.
8. Primary keys zonder `start_offset_in_seconds`: `type`, `lane_item_id`, `resource_uid`, `start_at`.
9. `get_resource_plan` levert geen noop-rijen, ook niet per lane: elke rij hangt aan een lane. Stilstand van een machine komt als actual-item (idle, offline, breakdown). De board-wide noop hoort bij 75 en 76.
10. `is_atomic = true` was "mag niet splitsen" = `no_split = true`.
11. Het voorbeeld-bestand `timeline.json` is niet meer nodig.
