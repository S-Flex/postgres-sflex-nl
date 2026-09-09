# Overdracht naar control-room: data_group-json

Alles wat de React-kant moet weten over de vorm van de data_group-json na de
normalisatie (augustus 2026). Dit gaat over de **conventies die voor alle
data_groups gelden**, niet over de velden van één data_group. Bron van
waarheid: `json/data_group/*.json`; de export `xfw3_site_data_group.json`
gaat met `sql/update_data_group_inline.sql` naar `site.data_group`.

## 1. structuur

| was | is nu | aantal |
|---|---|---|
| `class_name` in `field_config` (later `class_name` naast `field_config`) | `fields_class_name`, naast `field_config` — de grid waarin de velden gerenderd worden; `field_config` bevat alleen velden | 79 |
| `groups` in `field_config` | `groups` naast `field_config` | 1 |
| `children` als object | altijd een lijst, ook met één element | 28 |
| `hidden_when` als object | altijd een lijst van condities | 64 |
| `src` als string | altijd een lijst van bronfuncties | 65 |
| conditie `{key, op, value}` / `{key, op, val}` | `{field, op, value}`; vergelijk je twee velden dan `value_field` | 67 |
| `sort_by` / `sort_field` / `order_field` / `sort_order` (string) | `sort: {field, direction}` | 9 |
| `group_field` / `group_fields` / `group_by_field` | `group_by`, altijd een lijst | 18 |

Drie soorten class:

| key | op | betekent |
|---|---|---|
| `fields_class_name` | een blok met `field_config` (blok, tooltip-sectie, `group`, `label_options`) | de grid van de velden, bv. `grid grid-cols-6 gap-1` |
| `ui.class_name` | een veld | de class van de cel van dat veld, bv. `col-span-3 text-right` |
| `class_name` | een element zelf (bv. `row_options`) | de class van dat element |

Een renderer die de grid nog uit `class_name` naast `field_config` leest,
rendert de velden zonder grid.

## 2. hernoemde keys

| was | is nu | waar |
|---|---|---|
| `deselect` | `deselectable` | row_options, label_options |
| `multi_select` | `multi_selectable` | row_options, label_options |
| `no_labels` | `no_label` | timeline_config |
| `hide_column_when_empty` | `hidden_when_column_empty` | flow_board_config |
| `aggregation` | `aggregate_fn` | combo_chart_config.header_metric |
| `stack` | `stacked` | stacked_area_chart_config.set_overrides |
| `is_ident` | `is_ident_only` | params[] |
| `val` | `value` | condities |
| `val` | `default_value` | params[] |
| `key` | `field` | condities |
| `filter_field` | `value_field` | conditie die twee velden vergelijkt |
| `ui.table` | `ui.table_config` | ui |
| `stacked_bar_config` | `stacked_bar_chart_config` | blok |
| `area_chart_stacked_config` | `stacked_area_chart_config` | blok |
| `name` | `template` | stacked_bar_chart_config (template-string) |
| `old_group_by` | vervallen | dode key |

Regels achter de namen: snake_case voor keys, kebab-case voor code-waardes;
`<naam>_field` = de naam van een veld, zonder suffix = de waarde zelf;
eenheid in de key (`duration_in_seconds`), percentages `_percentage`;
chart-config heet `<chart>_chart_config`; `no_*` / `hide_*` staan default op
false.

## 3. hernoemde waardes

| key | was | is nu |
|---|---|---|
| `layout` | `flow-card` | `flow-cards` |
| `layout` | `stacked-bar` | `stacked-bar-chart` |
| `layout` | `area-chart-stacked` | `stacked-area-chart` |
| `layout` | `planCapacityOverview` | `plan-capacity-overview` |
| `layout` | `planCapacity` | `plan-capacity` |
| `layout` | `three_d` | `three-d` |
| `control` | `multiselect` | `multi-select` |
| `control` | `datetime_with_offset` | `datetime-with-offset` |
| `control` | `time_scale` | `time-scale` |
| `func` | `saveLocalData` | `save-local-data` |
| `func` | `addRow` | `add-row` |
| `op` | `<>` | `!=` |

## 4. `ui.type` en `ui.control`

`type` zegt wat de waarde **is**, `control` hoe hij **getoond** wordt.

- naar `type` verplaatst: `datetime` (24), `date` (20), `duration` (6), `time` (2)
- `control` date/datetime naast een `type` is weggehaald, `type` wint (9)
- `ui.type img` → `ui.control img` (3); `ui.type hidden` → `ui.hidden: true` (1)
- `type`-waardes: `number` `percent` `date` `datetime` `boolean` `duration` `text` `hours` `hh:mm` `content`
- `control`-waardes: `badge` `chip` `toggle` `select` `multi-select` `img` `i18n-text` `distribution-bar` `progress` `template` `label` `icon-map` `status` `dropdown-list` `table` `time-scale` `datetime-with-offset`

## 5. i18n

Eén tekst-slot per taal: `i18n.<lang>.title`. `text` (110) en `label` (37)
zijn daarnaar hernoemd. `subtitle` alleen bij een echte tweede regel.

## 6. layout: grid en breedte

- `fields_class_name` opent de grid (`grid grid-cols-6 gap-1`), elk veld
  zegt met `ui.class_name` hoeveel kolommen het neemt (`col-span-3`); zonder
  `col-span-*` één kolom
- verborgen velden (`ui.hidden: true`) nemen geen cel
- een `group` (herhaald blok over `data_field`) is een eigen grid per item
- data_groups gebruiken **container queries**: `@container` in de
  `fields_class_name`, `@xs:` / `@sm:` / `@md:` / `@2xl:` op de velden. Die
  meten de breedte van de widget, niet van het scherm — een data_group staat
  in een sidebar, tooltip of volle pagina. Let op: `@md` = 448px, `md:` = 768px.
- Tailwind genereert alleen classes die het als tekst in de frontend-bronnen
  vindt; de json staat in de database. Safelist daarom in de css:

  ```css
  @source inline("{@xs:,@sm:,@md:,@2xl:,}col-span-{1..12}");
  @source inline("col-start-{1..12}");
  ```

  Nu in gebruik: `grid` `gap-1` `grid-cols-{1,3,4,5,6,7,8,9,12}`
  `col-span-{1..6,12}` `col-span-full` `col-start-{1,3}` (lege kolom in een tooltip-grid)
  `md:col-span-{1,2,3,4}` `@container`
  `@xs:col-span-2` `@sm:col-span-2` `@2xl:col-span-{1,2,3}` `hidden`
  `text-xs` `text-right` `font-medium` `font-semibold`

Volledige uitleg met breakpoint-tabellen: `docs/data-group-layout.md`.

## 7. controls die op data leunen

- `distribution-bar`: `distribution_bar_config {i18n_field, value_field,
  class_names_field, sort {field}}` over een json-lijst van
  `{sequence, internal_status_code, class_names, i18n, amount}`
- `hidden_when` op een veld: lijst van `{field, op, value}`

## 8. nieuwe keys op `timeline_config`

| key | waarde | betekent | waar |
|---|---|---|---|
| `chain_scope` | `plan` \| `lane` | hoe ver een verschuiving doorketent: over alle lanes van het plan, of alleen binnen de eigen lane | `nest_schedule` (plan), `nest_resource_schedule` (lane) |
| `column_max_width` | px | bovengrens van de kolombreedte, tegenhanger van `column_min_width` | `nest_resource_schedule` (400, met `column_min_width` 26) |
| `group_title_fields` | string[] | de titelkolom per `group_by`-niveau, zelfde volgorde, positie voor positie; `group_by` zelf bevat alleen id's | `timeline_config` én `label_options` op 75, 76, 78 |

Beide staan naast de bestaande timeline-keys (`column_min_width`,
`class_names_field`, `time_scale_config`); `time_scale_config.mode` kent
`relative` en `fixed`.

## 9. drag & drop

Het contract staat in `docs/contracts/drag-and-drop.md`; de json van 75, 76 en 78
volgt het. Kort:

- op `row_options` en `label_options` hetzelfde blok: `draggable`,
  `order_field`, `copy_index_field`, en `drop {sort, order_type,
  within_fields, value_fields, commit}` — alles wat alleen de drop leest zit
  in `drop`
- `within_fields` ⊆ `group_by` en altijd id-kolommen; daarom groepeert
  `group_by` nu op `tenant_id` (78 rijen: `tenant_id, resource_uid`) en komt
  de titel uit `group_title_fields`
- de kolom `occurence` heet `copy_index` (bron én json); `0` = origineel
- weg: `drag_sort`, `drag_order_field`, `set_order_field`, `drag_order_type`,
  `drag_group_fields` (omgekeerd naar `within_fields`), `drag_value_fields`,
  `occurence_field` — zie `rename-map.json`
- `commit: "mutation"` staat er al; de mutatie-procedure op de bron volgt
  nog (tot dan draait een drop stil terug)
- `print_schedule` (75) heeft het blok alleen op `label_options`: de rijen
  van `get_print_schedule` dragen geen `sort_order`/`copy_index`/`is_pinned`

## bron

De machine-leesbare versie van 1–5 is `rename-map.json`.
