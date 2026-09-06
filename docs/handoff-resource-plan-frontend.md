# handoff: resource_plan (81) — wat er in de config veranderd is

Data_group `resource_plan` (was `production_resource_plan`), layout `timeline`,
data uit `get_resource_plan`. Filter: `resource_plan_filter` (was
`production_resource_plan_filter`). Pagina en nav: `resource-plan` (was
`impose-resource-plan`); data_group 78 is weg.

## timeline_config

| key | veld | nieuw/hernoemd |
|---|---|---|
| `fixed_group_field` | `fixed_group` | hernoemd (was `is_fixed_group_field`), ook in 75 en 76 |
| `set_field` | `type` | nieuw op dit bord: de soort rij, `plan` / `progress` / `actual` (zelfde key als op 19 en 56) |
| `set_order_field` | `type_json.sort_order` | laagvolgorde van de soorten binnen een lane (als op 19 en 56) |
| `placement_field` | `type_json.placement` | nieuw: `chain` (plan, de client ketent) of `offset` (progress, actual: op eigen offset) |
| `evaluate` | `{formula_field: type_json.formula, params_field: param_json}` | als op 76; de formule van de soort rekent `start_offset_in_seconds` en `duration_in_seconds` uit de variabelen |
| `set_overrides` | `{plan: {field_config}, progress: {…}, actual: {…}}` | per soort de velden op het blok (als `set_overrides` op 29) |
| `items` | `{data_field: states_json, offset_field, duration_field, class_names_field}` | nieuw: het subniveau van een rij, blokken binnen het blok (offsets op dezelfde as); `data_field` als in `status_bar_config.items` |
| `class_names_field` | `class_names` | ongewijzigd; de class_names van de soort en van de status zitten er al in |

De variabelen in `param_json`: `planned_start_offset_in_seconds`,
`production_impact_in_seconds`, `remaining_impact_in_seconds` (plan, progress),
`actual_start_offset_in_seconds`, `actual_duration_in_seconds` (actual). De
kolommen `start_offset_in_seconds` en `duration_in_seconds` dragen dezelfde
uitkomst, voor een renderer zonder evaluator.

Gedrag per soort: `plan` is de rij die sleept en selecteert; `progress` deelt
`lane_item_id` en `start_offset_in_seconds` met zijn plan-rij en ligt erover
heen (kortere duur); `actual` heeft geen `lane_item_id` en de actual-items van
een lane sluiten op elkaar aan (runs met class `actual-produced`, was
`realized-produced`, en de stukken ertussen). Progress en actual schrijven
nooit terug.

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
- primary keys: `tenant_id`, `resource_uid`, `type`, `lane_item_id`,
  `start_offset_in_seconds`.

## params

`steps` (text[], optioneel, leeg = alle stappen van de dag) en `types` (text[],
default alle drie) als query-params; `step` is weg. Het filter leest zijn opties
uit `get_step_categories` en `get_lane_item_types` (`input_data.src`, bestaand
mechanisme).
