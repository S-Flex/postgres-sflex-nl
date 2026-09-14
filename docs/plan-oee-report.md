# Plan: OEE report

Date: 2026-09-13. Status: step 1 ran; steps 2 and 3 delivered, waiting to be run.

## 1. what it is

One report: per resource (`resource_path`) and per day in view the availability of the
machine, what was planned on it, what it produced, and the ratios between them. The same
numbers once more per resource over the whole period in view (the aggregated row). The
numbers are measured in SQL, the ratios are rules in `production.formula`, evaluated by
`public.evaluate_many_nas` on the server and by `evaluate` on the board, so a rule changes
in one place.

Contract: seconds and sqm, no unit in a key; percentages end in `_percentage` and are 0..100.

## 2. the read: `log.get_oee_report`

`log.get_oee_report(p_from, p_until, p_line_type, p_tenant_ids, p_resource_paths, p_dates)`,
`stable`, `#variable_conflict use_column`. `p_from` and `p_until` become one
`datemultirange` inside; `p_dates`, when given, replaces the pair (the filter's
multi-date-picker, once the frontend sends a datemultirange). `sql/log/get_oee_report.sql`,
data_table `get_oee_report`.

One row per resource with a `resource_path` on a line of the tenants in view, per day in
view, plus one aggregated row per resource.

| column | what |
|---|---|
| `report_date` | the day; null on the aggregated row |
| `i18n` | `{lang: {title}}`: the day as text, or the translated word for aggregated (`totaal`, `aggregated`, ...). The board groups its columns on `i18n.title` |
| `tenant_id`, `tenant_name` | the tenant of the resource's production line, name from `lookup_tenants` |
| `resource_uid`, `resource_path`, `resource_name` | the machine |
| `param_json` | the measured inputs, every key always present (the evaluator raises on a missing variable) |
| `formula_json` | the active `production.formula` row `oee-report`, the rule list |
| `oee_json` | `evaluate_many_nas(formula_json, param_json)`: the outputs of §3 |
| `sort_order` | 0 for a day, 1 for the aggregated row |

### 2.1 param_json

| key | source |
|---|---|
| `shift_duration`, `break_times` | `action.dates.shift_json` of the day: the shifts naming the tenant of the resource's line (a shift without tenants counts for every machine), both summed |
| `has_break_times` | `relation.resource.resource_json`, 1 or 0 (step 1 turns the booleans into numbers: 41 true, 47 false; a resource without the key is 0). Availability is then a rule: `shift_duration - has_break_times * break_times` |
| `technical_failure` | `log.state_shift_agg`, state `breakdown`, seconds |
| `planned` | `log.state_shift_agg`, state `planned`, seconds |
| `producing` | `log.state_shift_agg`, state `producing`, seconds |
| `plan_calibrated` | `log.state_shift_agg`, state `plan_calibrated`, seconds (`update_plan_calibrated.sql`) |
| `actual_output_sqm` | `log.state_shift_agg`, the `producing` row |
| `planned_output_sqm` | `log.state_shift_agg`, the `planned` row |
| `planned_print_operator_duration` | `log.hr_shift_planning` of the day: the rows of the department resources of the resource's line, the employees of the groups `lookup_teams` lists under `print-operators` (group name in kebab-case), `sum(duration) * 60`. A line value, repeated on every resource of the line |

The aggregated row sums every param over the days and evaluates the same rules on the
sums, so its percentages are weighted by time, not averaged.

### 2.2 what the function does not do

- It does not read `break_times` as `breaks`: the key in `shift_json` is `break_times`
  (`update_shift_json_start_offset.sql`). The example in the request said `breaks`.
- It does not spread `planned_print_operator_duration` over the machines of a line. It is
  the line's number on every row of that line; a total over resources must take it once
  per line (§4).
- It does not compute anything the formula can: every ratio is a rule.

## 3. the formulas: `production.formula` code `oee-report`

One row, `formula_level 0`, `version 1`, `active`. Inputs are the keys of §2.1; every
division is guarded, a zero denominator yields 0.

```json
[
  "availability = shift_duration - has_break_times * break_times",
  "technical_failure_percentage = availability > 0 ? technical_failure / availability * 100 : 0",
  "technical_availability = availability - technical_failure",
  "technical_availability_percentage = availability > 0 ? technical_availability / availability * 100 : 0",
  "not_planned = availability - planned",
  "not_planned_percentage = availability > 0 ? not_planned / availability * 100 : 0",
  "not_planned_calibrated = availability - plan_calibrated",
  "producing_oee_planned_percentage = planned > 0 ? producing / planned * 100 : 0",
  "producing_oee_plan_calibrated_percentage = plan_calibrated > 0 ? producing / plan_calibrated * 100 : 0",
  "actual_output_per_second = producing > 0 ? actual_output_sqm / producing : 0",
  "overcapacity = (technical_availability - producing) * actual_output_per_second"
]
```

Two names differ from the request, both by the json rules of `CLAUDE.md`:
`producing_oee_planned` and `producing_oee_plan_callibrated` are ratios, so they are
`producing_oee_planned_percentage` and `producing_oee_plan_calibrated_percentage` (x 100,
one l). `overcapacity` is in sqm: the sqm the machine could still have produced at its
measured speed in the technical availability it did not use.

## 4. the board: data_group `oee_report`

`json/data_group/oee_report.json` is the source; `sql/update_oee_report_data_group.sql` carries
it into `site.data_group`. One `flow-board` on `src get_oee_report`, params `from`, `until`
(dates, query params), `line_type` and `tenant_ids` optional.

```
flow-grid       group_by [i18n.title]            one column per day, the aggregated column last
                                                 (sort {sort_order, asc}; the function orders the
                                                 days inside)
  flow-container group_by [i18n.title]           the totals of the column: the params summed
                 evaluate {formula_field: formula_json, params_field: param_json}
                                                 (aggregate_fn sum on the params, the percentages
                                                 evaluated on the sums)
    flow-cards   group_by [resource_path]         one card per machine: name, tenant, OEE planned,
                                                 technical availability, producing
      flow-table                                 every value of §2.1 and §3 for that machine
```

`availability` is an output now (`oee_json.availability`); the table shows `shift_duration` and
`break_times` next to it, the container sums both and evaluates the availability of the column.

The master `field_config` on the block carries the `i18n` titles and the types of every field:
seconds are `ui.type duration`, ratios `ui.type percent`, areas `suffix m²` with `scale 0`. The
nested `field_config`s carry only `order`, `class_name` and `aggregate_fn`, as the other boards
do. Every value is a dot-notation field into `param_json` or `oee_json`.

One thing in this config is new for the frontend: `evaluate` on a `flow-container`. Today
`evaluate` exists on `timeline_config` and `plan_config` only, per row. Here it has to run once
per group on the aggregated params (the sums of `aggregate_fn`), so a percentage in the totals
is weighted and not an average of percentages. Until the frontend has it, the three
percentage fields of the container show nothing; the day columns and the cards are complete
without it, because the function already returns `oee_json` per row.

`planned_print_operator_duration` is not in the container: a sum over the machines counts a
line several times (§6.1). It is in the table per machine.

### 4.1 the filter, the page, the status bar

- `oee_report_filter` (`json/data_group/oee_report_filter.json`), the shape of
  `nest_waste_ranges_filter`: `dates` (multi-date-picker, datemultirange), `line_type`
  (select, the six line types inline), `tenant_ids` (multi-select, Dokkum and Bad Hersfeld
  inline). The report takes `dates` when the frontend sends it, else `from` and `until`.
- page `oee-report` (`pages.json`): main grid `auto 1fr` with the filter above the report,
  footer with `status_bar`, like `production-board`. The status bar needs `model` in the url,
  as on every page that carries it.
- status bar: group `oee` in the `status_bar` lookup (`legacy.lookup`,
  `json/lookup/legacy/status_bar.json`), `src oee`, nav to `(window:oee-report)`, one item: OEE planned
  (`producing_oee_planned_percentage`), nothing else.
  `mapping.get_status_bar_oee` sums the params of the machines of the line for the business
  day of `p_until` and evaluates the rules on the sums; `mapping.get_status_bar` gets the
  branch for `src oee`.

## 5. steps

| step | what | rollback | done when |
|---|---|---|---|
| 1 | `sql/update_oee_report.sql`: `has_break_times` in `relation.resource` to 1/0 (its two readers cast with `::boolean`, which takes 1/0), the formula row, `log.get_oee_report`, data_table `get_oee_report`. Needs `production.formula` (step 1c of the schedule plan) and the `plan_calibrated` rows | `sql/update_oee_report_down.sql` | the check at the end shows the printers of `dk.sheet` with availability and percentages for the last 7 days |
| 2 | data_groups `oee_report_filter` and `oee_report`: `sql/update_oee_report_data_group.sql` (the content of the two json files; sync them into `xfw3_site_data_group.json` with the next rebuild) and the page `oee-report` (`json/data/block/pages.json`, `pages-content.json`, nav view list in `json/data/nav/app-nav.json`, environment development) | `DELETE FROM site.data_group WHERE data_group = 'oee_report'`, delete the page | the board shows one column per day plus the aggregated column, the totals container, one card per resource_path, the table |
| 3 | OEE in the status bar: `sql/update_status_bar_oee.sql` (lookup group `oee`, `mapping.get_status_bar_oee`, the branch in `mapping.get_status_bar`) | `sql/update_status_bar_oee_down.sql` | the check shows OEE planned per line of the sheet model |

## 7. frontend handoff (compact)

- new `src` `get_oee_report`, params `from`, `until` (dates); `line_type`, `tenant_ids` optional
- rows carry `param_json` (inputs), `formula_json` (rule list) and `oee_json` (outputs); all
  board fields are dot-notation into those two
- `flow-grid` `group_by [i18n.title]`, sort on `sort_order`: the aggregated row has
  `report_date null`, `sort_order 1`
- new: `evaluate {formula_field, params_field}` on a `flow-container`, evaluated once per group
  on the params the group aggregated with `aggregate_fn`
- types: `duration` for seconds, `percent` for 0..100 ratios, `suffix m²` for areas

## 6. open

1. `planned_print_operator_duration` on the totals container: sum over resources counts a
   line several times. Advice: the container takes it from the aggregated rows through
   `max` per line, or the report gets a per-line row later.
2. Days without shifts (`shift_json` empty) have `availability 0` and every percentage 0.
   Leave them in, or filter on `availability > 0` in the board: a `hidden_when` on the card.
