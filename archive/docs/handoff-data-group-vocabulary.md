# handoff: één vocabulaire in de data_groups — wat de renderer anders leest

Alleen keys in de configs zijn hernoemd, geen velden in de data en geen
data_group-namen. Stand na `sql/update_data_group_partial.sql` van 6 sep (24
data_groups: 19, 29, 40, 43, 48, 51, 52, 53, 54, 56, 59, 63, 64, 68, 69, 70,
71, 72, 73, 75, 76, 80, 81, 82).

## hernoemd

| oud | nieuw | waar |
|---|---|---|
| `text_field`, `label_field`, `i18n_field`, `content_field`, `set_title_field`, `gauge_title_field` | `title_field` | `input_data` van filters, `x_axis`, `distribution_bar_config`, `donut_chart_config`, `combo_chart_config`, `track_board_config`, `status_bar_config.items`, `activity_gauge_config.modes`, `timeline_config` (19, 56) |
| `label_suffix_field` | `title_suffix_field` | `track_board_config` (63) |
| `start_offset_in_seconds_field` | `offset_field` | `time_scale_config.input_data` (75, 76, 81) |
| `end_offset_in_seconds_field` | `end_offset_field` | idem |
| `duration_in_seconds_field` | `duration_field` | idem |
| `segment_size_in_seconds_field` | `segment_size_field` | idem |
| `scale_field` | weg, gebruik `duration_field` | idem |
| `next_start_offset_in_seconds_field` | `next_start_offset_field` | `timeline_config`, `label_options` (75, 76) |
| `is_atomic_field` | `no_split_field` | `plan_config` (56) |
| `is_fixed_offset_field` | `is_pinned_field` | `plan_config` (56) |
| `rank_field` | `order_field` | `plan_config` (56) |
| `set_group_field` (string) | `set_group_fields` (array) | `timeline_config` (19, 56) |
| `params_field` naast `evaluate` | `evaluate.params_field` | `plan_config` (56) |
| `key_field` | `x_field` | `combo_chart_config` (53, 54) |
| `ui.field` met `${...}` | `ui.template` | `job_thumbnail` (51), `specs` (68, 69, 71) |

De waarde achter `title_field` is soms een platte tekst (`resource_name`) en
soms een i18n-node (`i18n`, `state_json.i18n`): de renderer kijkt naar de
waarde, niet naar de key.

## nieuw op resource_plan (81)

Zie `docs/handoff-resource-plan-frontend.md`: `set_field`, `set_order_field`,
`placement_field`, `evaluate`, `set_overrides`, `items` in `timeline_config`.

## de regel

Een key die een veld aanwijst eindigt op `_field` en draagt geen eenheid; het
tekst-slot heet `title_field`; de soort van een rij is een set (`set_field`,
`set_order_field`, `set_overrides`); een formule rekent via `evaluate`; het
subniveau van een rij heet `items` met `data_field`; een string met
`${...}` heet `template`. Volledige lijst per key: `json/data_group/rename-map.json`.
