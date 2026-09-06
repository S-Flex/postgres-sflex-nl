# Data group governance

Naming and shape rules for `json/data_group/*.json`. The rules themselves live in the
`data_group json` section of `CLAUDE.md`; this document records the analysis behind them,
what has been applied, and what is still open.

Scan of 56 files, 552 unique keys before, 538 after.

---

## Applied

Run over all 56 files, plus a rebuilt `xfw3_site_data_group.json`. Old -> new is machine
readable in `json/data_group/rename-map.json`; the database side is `sql/update_data_group.sql`.

### Structural

| Change | Count |
|---|---|
| `field_config.class_name` moved to block level as `fields_class_name` | 55 |
| `field_config.groups` moved to block level | 1 |
| `children` object -> array | 28 |
| `hidden_when` object -> array | 64 |
| `src` string -> array | 65 |
| conditions -> `{field, op, value}` | 67 |
| `sort_by` / `sort_field` / `order_field` / `sort_order` -> `sort: {field, direction}` | 9 |
| `group_field` / `group_fields` / `group_by_field` -> `group_by`, always an array | 18 |
| `old_group_by` removed | 1 |

`field_config` now holds field names only. That was the root cause of most polymorphism:
`title`, `code`, `name`, `width`, `height`, `data`, `type`, `color`, `group_by` and
`sort_order` looked like they had two shapes, but the object form was always a data column
sharing a namespace with a config key.

### Keys

`deselect` -> `deselectable` (8) · `no_labels` -> `no_label` (4) ·
`hide_column_when_empty` -> `hidden_when_column_empty` (2) · `aggregation` -> `aggregate_fn` (2) ·
`stack` -> `stacked` (1) · `is_ident` -> `is_ident_only` (1) ·
`multi_select` -> `multi_selectable` (2) · `ui.table` -> `ui.table_config` (9) ·
`stacked_bar_config` -> `stacked_bar_chart_config` (1) ·
`area_chart_stacked_config` -> `stacked_area_chart_config` (1) ·
`name` -> `template` where it held a template string (1)

### ui.type vs ui.control

`type` says what the value is, `control` says how it is rendered.

- `control` `datetime` (24), `date` (20), `duration` (6), `time` (2) moved to `type`
- 9 blocks had a `control` next to a `type` that already covered it, `control` dropped
- `ui.type: img` -> `ui.control: img` (3)
- `ui.type: hidden` -> `ui.hidden: true` (1)
- one field entry carried `control` outside `ui`, moved into `ui`

| | values |
|---|---|
| `type` | number, percent, date, datetime, boolean, duration, text, hours, hh:mm, content |
| `control` | badge, chip, toggle, select, multi-select, img, i18n-text, distribution-bar, progress, template, label, icon-map, status, dropdown-list, table, time-scale, datetime-with-offset |

### i18n

`text` (110) and `label` (37) folded into `title`. All 2851 blocks now use `title`, with
`subtitle` only in the 6 places that really have a second line.

### Values

`flow-card` -> `flow-cards` · `stacked-bar` -> `stacked-bar-chart` ·
`area-chart-stacked` -> `stacked-area-chart` · `planCapacityOverview` -> `plan-capacity-overview` ·
`planCapacity` -> `plan-capacity` · `three_d` -> `three-d` · `multiselect` -> `multi-select` ·
`datetime_with_offset` -> `datetime-with-offset` · `time_scale` -> `time-scale` ·
`saveLocalData` -> `save-local-data` · `addRow` -> `add-row` · `op: <>` -> `!=`

### Verification

Leaf values 6860 -> 6846. The 14 removals are exactly the 9 redundant `control` values,
2 duplicate `type: img` and the 3 entries of `old_group_by`. No `data_group_id` or
`data_group` changed.

---

## Deferred: data field names

These are columns returned by the `src` functions, so the JSON and the SQL function have to
change in the same deploy. Not touched.

| Now | Proposed | Note |
|---|---|---|
| `waste_perc` | `waste_percentage` | also a key in `v_params` of `mock.get_print_schedule` and `_test` |
| `sqm_pct_cut` / `_done` / `_printed` | `sqm_percentage_*` | |
| `order_pct_cut` / `_done` / `_printed` | `order_percentage_*` | |
| `deadline_fill_perc` | `deadline_fill_percentage` | |
| `duration_percent`, `parent_percent` | `*_percentage` | |
| `duration_seconds`, `total_duration_seconds`, `timeline_seconds`, `offset_seconds` | `*_in_seconds` | `duration_in_seconds` already exists elsewhere |
| `occurence` | `occurrence` | spelling; `occurence_field` points at it, so both move together |

`src` values are function names and follow the same rule: `plan-capacity` and
`plan-capacity-overview` are kebab where the other 54 are snake `get_*`, and `testFormAddr`
is camelCase.

---

## Still open

| Item | Detail |
|---|---|
| `widget_id` casing | 50 snake_case, 3 kebab (`product-direct`, `product-save`, `product-batch`). The rule says kebab for values, the majority says snake. Either the values move or the rule gets an explicit exception for identifiers. |
| `colexp` (40) + `colexp_field` (3) | Rename to `collapsible` only if it means "may collapse". If it means "starts collapsed" the name should be `collapsed`. Needs the frontend. |
| `normalized` (bool) vs `normalize` (object) | Same feature, two levels of expressiveness. Folding the bool into `normalize: {mode: "percentage"}` needs the default for `scope`. |
| `op: "not in"` | The only operator with a space. Pick a dialect and spell all operators the same way. |
| `track` / `track-board` | The flow family uses `flow-container` for children; `track` has no equivalent name yet. |
| `nav` as string | One `"nav:resource_menu"` reference against 28 inline objects. Left as is by decision. |
| `input_data` as array | Three cases of `["data", "label_options"]` against 18 objects. Left as is by decision. |
| Boolean polarity | `show_grid` / `show_legend` against `no_label` / `no_popup` / `no_timeline` (~95). Parked: `no_*` defaults to false. |
| i18n completeness | 413 blocks have all six languages, 113 have de/en/nl, 22 are nl only, 6 are en/nl. One block title (`production_line_overview`) has no i18n at all. |
| `donut_chart_config.filter_field` | Kept. It sits among `code_field`, `color_field`, `center_field`, `title_field` (was `content_field`) and `aggregate_field`, so it follows the `_field` convention and is not a condition. |
