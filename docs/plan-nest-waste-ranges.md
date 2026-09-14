# plan: nest waste ranges

Written 11 Sep 2026 (replaces the percentile version of the same day). A read and a
board that show, per material and day, how the waste of the nests is spread over
ranges of waste percentage, and what that waste costs.

## the read

`legacy.get_nest_waste_ranges(p_dates, p_material_ids)`

| param | type | default | meaning |
|---|---|---|---|
| `p_dates` | `datemultirange` | today | the days of `nested_at` (Amsterdam time) that count |
| `p_material_ids` | `integer[]` | `null` | the materials, after the parent rule; null is every material with nests on those days |

The ranges are the lookup `lookup_nest_waste_ranges` in `legacy.lookup` (file
`json/lookup/legacy/lookup_nest_waste_ranges.json`): per range `code`, `range_min`,
`range_max` and `sort_order`; a range takes min <= waste < max. The row `0-100` (the total) is gone
since 14 Sep 2026: the ranges flow-table sums its rows itself (`row_options.summary: true`, per field a
`summary` with `aggregate_fn` sum for nests, sqm, waste sqm and waste cost, avg for the waste
percentage, and an `i18n` label `0-100%` on the range column). The rows carry `tenant_id` and
`tenant_name` (the tenant of the nest's production line), and the imposition group is joined per tenant.
Changing the ranges is a change in the lookup, not in code.

A nest of a child material (imposition group with a parent, 28 under 300) counts
with the parent, as the queue and the print schedule do. Every range of a material
and day is a row, also an empty one, so the list always has the same shape.

| column | meaning |
|---|---|
| `material_id`, `material_name` | the material (the parent for a child) |
| `nest_date` | the day of `nested_at`, Amsterdam time |
| `range_min`, `range_max`, `waste_range`, `is_total`, `sort_order`, `class_names` | the range from the lookup, `waste_range` its code (`60-70`), `is_total` and the class `aggregate` on the row `0-100` that spans everything; the table colours its rows on `class_names` |
| `nest_count` | the sum of `legacy.nest.amount`, the impositions of the sheets |
| `sqm` | width x height x amount in m2 (the dimensions are cm) |
| `avg_waste_percentage` | the average `nest_json.waste_percentage` in the range |
| `waste_sqm` | the sum of sqm x waste of the nests |
| `purchase_price_per_sqm`, `waste_cost` | the purchase price per m2 of the material item (`catalog.item_base_price`, first tier, `price_tiers_json -> 0 ->> 'purchase_price'`) through `catalog.get_item_prices` for the tenant of the nest's production line, and `waste_sqm` x that price; null while the material has no price |

`site.data_table`: `get_nest_waste_ranges`, primary keys `material_id, nest_date, range_min`.

## the board

data_group `nest_waste_ranges` (96), layout `flow-board`: a flow-container per material with
the sums (nests, area, waste area, cost), a flow-table with one row per range aggregated over
the days (sums, the average of the average waste), and under each range a flow-table with the
same figures per day. The rows colour on `class_names` (the total row `aggregate`). Params `dates`, `material_ids`.

## the chart

data_group `nest_waste_ranges_chart` (98), layout `stacked-bar-chart` on the same read: one
x position per range (`x_field` and `group_by` `waste_range`, `sort` on `sort_order`), and per position
two bars as positional `groups`: the area of the nests with the waste area stacked on top of it (two
`segments[]`), and next to it the waste cost (one segment); a segment has `field`, `aggregate_fn` sum and its
`fill` and `color` as css variables (`var(--state-producing)` for the area, `var(--state-breakdown)` for the
waste, `var(--state-starved)` for the cost, each with its `-color` twin for the text), the way
`lookup_resource_state` carries them; the tooltip in the `sections` form; `window_class_name` p-8 like the table.
`y_field`, `stacked` and `template` are not part of the layout and left the chart invisible until 14 Sep
2026 (`sql/update_nest_waste_chart_groups.sql`); the total row is gone, so there is no filter. Between the filter and the table on the page.

## the status bar

group `nests` in the `status_bar` lookup, source `mapping.get_status_bar_nests`: the nests
of today on the lines of the production line's line type -- how many, their m2, the
average waste -- plain figures without colour. The nav opens the nest-waste page.

## the filter

data_group `nest_waste_ranges_filter` (97), layout `filter`, above the board on the page
`nest-waste` (json/data/block/pages.json, title in pages-content.json). `dates` as a
`multi-date-picker` (type `datemultirange`) and `material_ids` as a `multi-select` on
`mapping.get_materials` (the materials with a print schedule, parents only).

## checked live, 11 sep

- `nest_json` carries `waste_percentage` as a number on every nest of the last week;
  `material_id` and `production_line_id` sit in the json too, `legacy.nest` has no
  columns for them.
- `catalog.item_base_price` is empty: `waste_cost` is null on every row until prices are
  loaded. The join is through `catalog.get_item_prices`, so the root tenant and the
  version rules of the price chain apply once they are.
- ids 96 and 97 were free (max 95).

## open

- the frontend: the control `multi-date-picker` with a datemultirange value is new.

## scripts

| step | script | state |
|---|---|---|
| lookup, read, material list, data_tables | `sql/update_nest_waste_ranges.sql` | written 11 sep |
| data_groups 96, 97 and 98 | `sql/update_data_group_partial.sql` | written 11 sep |
| status bar group | `sql/update_status_bar_nests.sql` | written 11 sep |
| page | `json/data/block/pages.json`, `pages-content.json`, page `nest-waste` | written 11 sep |
