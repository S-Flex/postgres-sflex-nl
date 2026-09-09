# handoff: OEE states from the lookup (29, 62, 64)

De states van de OEE-borden komen uit `lookup_resource_state` via de data_table
`get_resource_states` (kolommen `code`, `sort_order`, `counts_as`, `i18n`,
`class_name`, `fill`, `color`). Alleen de nodes met `counts_as`, één per titel: een
alias met dezelfde titels als zijn doel (`starved.operator` naast `starved`) komt
niet apart voor.

## 64 resource_oee_area_chart_filter

`field_config.states.ui.input_data`: `data` is weg, in plaats daarvan

```json
{"src": ["get_resource_states"], "params": [], "title_field": "i18n", "value_field": "code"}
```

## 29 resource_oee_chart

`donut_chart_config.legend`: `items` is weg, dezelfde `input_data` als hierboven
ernaast `filter_param: "states"`. De legenda toont `i18n` van de node, klikken
zet `code` in de filter-param.

## 62 resource_oee_area_chart

`stacked_area_chart_config.set_title_field: "state_json.i18n"`: de titel van een
set (legenda) is de `i18n` van de lookup-node die op de rij meekomt.
