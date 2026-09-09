# handoff: de items van 76 impose_plan en 78 impose_resource_plan

Data: `get_impose_plan` (ongewijzigde kolommen). Beeld: `impose-plan/nest-plan.png`
(de kaart, zonder chat- en info-icoon) en `impose-plan/nest-plan-tooltip.png`.

## timeline_config.lane_item_config — de kaart

```json
{"fields_class_name": "grid grid-cols-4 gap-1",
 "field_config": {"material_name", "production_seconds_min", "production_seconds_max", "sqm",
                  "seconds_to_logistics_date", "min_delivery_hours"},
 "lane_table_config": {...}}
```

- `material_name` kop; `production_seconds_min` / `_max` (`type: duration`, "Min. tijd" /
  "Max. tijd"); `sqm` (suffix m², "Opp."); `seconds_to_logistics_date` als `badge`
  ("Tijd tot productie"); `min_delivery_hours` als `badge` (het rondje "18").
- `class_names_field: "class_names"` van de timeline kleurt de kaart (warning, nested, ...).

## lane_item_config.lane_table_config — de regels op de kaart

```json
{"data_field": "set_json", "set_field": "set", "set_order_field": "sort_order",
 "class_names_field": "class_names", "fields_class_name": "grid grid-cols-4 gap-1",
 "field_config": {"orderline_count", "rework_count", "i18n", "part_status_json"},
 "set_overrides": {"orders": {...}, "batch": {...}}}
```

- `set: "orders"` (per status): `orderline_count` en `rework_count` als `template`,
  de status (`i18n`) als `badge` met de `class_names` van de regel.
- `set: "batch"` (per batch, `batch_id`, 0 = zonder batch): `orderline_count` en de
  `distribution-bar` op `part_status_json`.
- Nieuw: een `template` per taal, `i18n.<lang>.template`
  (`"${orderline_count} orderregels"`, `", ${rework_count}x herstel"`), omdat de tekst
  in de regel staat en niet als label ernaast.

## timeline_config.tooltip — alleen informatie

Sectie 1: `material_name`, `tenant_name`. Sectie 2: een `group` op `manifest_json`
(`title_field: "i18n"`, de afkorting van de nestgroep) met sub-niveau `items`:

```json
{"data_field": "items", "set_field": "set", "set_order_field": "sort_order",
 "field_config": {"nest_date", "unit_class_json.i18n", "batch_id", "sqm",
                  "step_json.print.seconds_min", "step_json.print.seconds_max",
                  "step_json.cut.seconds_min", "step_json.cut.seconds_max"},
 "set_overrides": {"nest-date": {...}, "batch": {...}}}
```

- Regel 1: `nest_date` (`type: date`), `unit_class_json.i18n` (`i18n-text`, de afkorting
  SP / MP uit `lookup_unit_class`, leeg voor alles samen) en `sqm` (suffix m²); een
  batch-regel toont `batch_id` en `sqm`.
- Regel 2: print min/max en cut min/max, `type: duration`.
- De radio-kolommen (Productie DK / BH) uit het voorbeeld zitten er niet in: de tooltip
  toont alleen informatie.

## de mutatie: drop, pin, sorteren

De data_tables `get_impose_plan` en `get_plan_lanes_imposition_group` hebben
`stored_proc: action.crud_lane_item`. Een drop met `commit: "mutation"` stuurt één
element per gewijzigde rij:

```json
[{"crud": "update", "track_by": 1,
  "data": {"lane_item_id": 8842, "start_offset_in_seconds": 43200, "sort_order": 20450, "is_pinned": true}}]
```

- `crud`: `update` (verplaatsen, pinnen, sorteren), `create` (Ctrl-drop: een kopie, dan
  `data.lane_item_id` = de bron en optioneel `lane_id`, `plan_id`,
  `imposition_group_id`), `delete`.
- `track_by`: de volgorde van de mutaties in de batch; komt terug op de resultaatrij.
- `data`: alleen de properties die veranderen; wat ontbreekt blijft staan.
- Terug: `param_id`, `track_by`, `crud`, `lane_item_id`, `lane_id`,
  `material_impose_plan_id`.
- Gepind komt uit de data (`is_pinned_field`): eigen pin, elke rij van een vorige dag,
  elke rij met nests. Alleen de rest ketent op de client.

## 78 impose_resource_plan

Zelfde config als 76 (kopie), met de resource-lanes: `label_options.input_data.src =
get_plan_lanes_resource` (params `until`, `line_type`, `tenant_ids`, `steps: ["impose"]`),
label toont `resource_name`, `set_group_fields: ["tenant_id", "resource_uid"]`
(`drop.value_fields: ["resource_uid"]` is op 76 en 78 gelijk). De oude lane-read
`get_plan_lanes` bestaat niet meer.

## 79 impose_plan_inflow

Op tenant-niveau `impact_json.sqm` (som) naast `tenant_name` (de regels "Productie Dokkum
591 m²"). Het totaalblok uit `impose-plan/inflow-queue-total.png` is
`flow_board_config.header`:

```json
{"fields_class_name": "grid grid-cols-3 gap-2",
 "field_config": {
   "fill_percentage": {"ui": {"control": "donut-chart",
                              "donut_chart_config": {"center": {"field": "fill_percentage", "type": "percent"}}}},
   "resource_uids": {"ui": {"control": "multi-select",
                            "input_data": {"src": ["get_resources"], "params": [line_type, step = print],
                                           "title_field": "resource_name", "value_field": "resource_uid"}}}},
 "navs": [{"menu": [{"type": "button", "path": "(detail:impose-plan-inflow)",
                     "params": [material_id, date, look_ahead_days, threshold, line_type, resource_uids]}]}]}
```

- `fill_percentage` (vulling): 100 min de waste factor van de nestgroep in `catalog.imposition_group`
  (breedste formaat), op elke rij dezelfde waarde, `type: percent`.
- Nieuwe param `line_type` op 79 voor de printer-select; `get_resources` kent nu `step`.
- De knop opent pagina `impose-plan-inflow` (pages.json), dezelfde data_group met dezelfde params.
- Pallets en platen komen later uit `mapping.material_production_line`.
