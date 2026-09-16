# Plan: OEE report

Date: 2026-09-13. Status: steps 1 to 4 ran (checked live 14 Sep 2026); the frontend work is in docs/handoff-oee-report-frontend.md.

## 1. what it is

One report: per resource (`resource_path`) and per day in view the availability of the
machine, what was planned on it, what it produced, and the ratios between them. The same
numbers once more per resource over the whole period in view (the aggregated row). The
numbers are measured in SQL, the ratios are rules in `production.formula`, evaluated by
`public.evaluate_many_nas` on the server and by `evaluate` on the board, so a rule changes
in one place.

Contract: seconds and sqm, no unit in a key; percentages end in `_percentage` and are 0..100.

## 2. the read: `log.get_oee_report`

`log.get_oee_report(p_until, p_line_type, p_tenant_ids, p_resource_paths, p_dates, p_steps, p_workdays)`,
`stable`, `#variable_conflict use_column`. The days in view are the Amsterdam date of `p_until` (a
timestamp, as on every other read) and the `p_workdays` workdays before it, default 4: five day
columns plus the aggregated one, so the grid always has two columns or more. `p_dates`, when given,
replaces that (the filter's multi-date-picker, once the frontend sends a datemultirange). `p_steps`
keeps to the resources of those steps (`relation.resource.step`); default `print`. `sql/log/get_oee_report.sql`,
data_table `get_oee_report`.

One row per print machine with a `resource_path` on a line of the tenants in view, per day in
view, plus one aggregated row per machine.

| column | what |
|---|---|
| `report_date` | the day; null on the aggregated row |
| `report_key` | the day as text, `aggregated` on the aggregated row: the column key of the grid |
| `i18n` | `{lang: {title}}`: the day as text, or the translated word for aggregated (`totaal`, `aggregated`, ...): the column title |
| `tenant_id`, `tenant_name` | the tenant of the resource's production line, name from `lookup_tenants` |
| `resource_uid`, `resource_path`, `resource_name` | the machine; on a summary row `tenant-<tenant_id>`, null, the tenant name |
| `set` | `resource` or `summary` (decided 14 Sep): the summary row per tenant and day, and per tenant aggregated, carries the sums of the tenant's resources, the operators once per line, `break_times` already multiplied by the flag |
| `param_json` | the measured inputs (§2.1), every key always present (the evaluator raises on a missing variable), plus the outputs of §3: `evaluate_many_nas(formula_json, inputs)` returns inputs and results in one object. No separate result column (decided 14 Sep) |
| `formula_json` | the active `production.formula` row `oee-report`, the rule list |
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
| `actual_gross_output_sqm` | `log.state_shift_agg`, the `producing` row |
| `actual_net_output_sqm` | `log.state_shift_agg`, the `producing` row: the produced area less the waste of the nests (`nest_json.waste_percentage`), the area of the customer orders (15 Sep). Shown first on the card; every rule works on `actual_gross_output_sqm` |
| `planned_output_sqm` | `log.state_shift_agg`, the `planned` row |
| `period_output_per_planned_hour` | the resource's output per planned hour over every day in view; on a summary row the resources' overcapacity over their not-planned hours (so the tenant's overcapacity is the sum of its resources'); §9 |
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
  "not_planned = technical_availability - planned",
  "not_planned_percentage = technical_availability > 0 ? not_planned / technical_availability * 100 : 0",
  "not_planned_calibrated = technical_availability - plan_calibrated",
  "producing_oee_planned_percentage = planned > 0 ? producing / planned * 100 : 0",
  "producing_oee_plan_calibrated_percentage = plan_calibrated > 0 ? producing / plan_calibrated * 100 : 0",
  "output_per_planned_hour = planned > 0 ? actual_gross_output_sqm / (planned / 3600) : 0",
  "actual_output_per_hour = producing > 0 ? actual_gross_output_sqm / (producing / 3600) : 0",
  "overcapacity = not_planned / 3600 * period_output_per_planned_hour",
  "planned_operator_duration = planned_operators * operator_working_time",
  "planned_operator_cost = planned_operator_duration * operator_cost_per_second",
  "operator_cost_per_sqm = actual_gross_output_sqm > 0 ? planned_operator_cost / actual_gross_output_sqm : 0",
  "output_per_operator = planned_operators > 0 ? actual_gross_output_sqm / planned_operators : 0",
  "planned_printers_per_operator = planned_operators > 0 ? planned / (operator_working_time * planned_operators) : 0"
]
```

Two names differ from the request, both by the json rules of `CLAUDE.md`:
`producing_oee_planned` and `producing_oee_plan_callibrated` are ratios, so they are
`producing_oee_planned_percentage` and `producing_oee_plan_calibrated_percentage` (x 100,
one l). `actual_output_per_hour` follows the sheet (output / hour). `overcapacity` is in sqm: the sqm the machine could still have produced at its
measured speed in the technical availability it did not use.

## 4. the board: data_group `oee_report`

`json/data_group/oee_report.json` is the source; `archive/sql/migrations/update_oee_report_data_group.sql` carries
it into `site.data_group`. One `flow-board` on `src get_oee_report`, params `from`, `until`
(dates, query params), `line_type` and `tenant_ids` optional.

```
flow-grid       group_by [report_key]            one column per day, the aggregated column last
                group_title_fields [i18n]        (sort {sort_order, asc})
  flow-container group_by [tenant_id]            header "Vestiging <tenant>" (template on tenant_name)
    flow-cards   group_by [resource_uid]          the machine name, then the lines of the sheet in
                 set_field set                   (set_overrides.summary: the tenant's summary row)
                two columns                      two columns: availability; technical failure + %;
                                                 technical availability + %; not planned + %; planned
                                                 availability; producing + OEE %; output; output / hour;
                                                 overcapacity; on the summary card also operators,
                                                 operator cost, cost per m²
```

The master `field_config` on the block carries the `i18n` titles and the types of every field:
seconds are `ui.type duration`, ratios `ui.type percent`, areas `suffix m²` with `scale 0`. The
nested `field_config`s carry only `order` and `class_name`, as the other boards
do. Every value is a dot-notation field into `param_json` or `param_json`.

The board follows the sheet Cees drew (14 Sep): no totals row per column any more, the tenant and
the machine are headers, the values are one list per machine. Seconds show as `duration`, which the
frontend renders as hours and minutes. `planned_print_operator_duration`
and the calibrated values stay in the data and the master `field_config`, not in the list.

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
| 1 | `archive/sql/migrations/update_oee_report.sql`: `has_break_times` in `relation.resource` to 1/0 (its two readers cast with `::boolean`, which takes 1/0), the formula row, `log.get_oee_report`, data_table `get_oee_report`. Needs `production.formula` (step 1c of the schedule plan) and the `plan_calibrated` rows | `archive/sql/migrations/update_oee_report_down.sql` | the check at the end shows the printers of `dk.sheet` with availability and percentages for the last 7 days |
| 2 | data_groups `oee_report_filter` and `oee_report`: `archive/sql/migrations/update_oee_report_data_group.sql` (the content of the two json files; sync them into `xfw3_site_data_group.json` with the next rebuild) and the page `oee-report` (`json/data/block/pages.json`, `pages-content.json`, nav view list in `json/data/nav/app-nav.json`, environment development) | `DELETE FROM site.data_group WHERE data_group = 'oee_report'`, delete the page | the board shows one column per day plus the aggregated column, the totals container, one card per resource_path, the table |
| 3 | OEE in the status bar: `archive/sql/migrations/update_status_bar_oee.sql` (lookup group `oee`, `mapping.get_status_bar_oee`, the branch in `mapping.get_status_bar`) | `archive/sql/migrations/update_status_bar_oee_down.sql` | the check shows OEE planned per line of the sheet model |

## 7. frontend handoff (compact)

- new `src` `get_oee_report`, params `from`, `until` (dates); `line_type`, `tenant_ids` optional
- rows carry `param_json` (inputs and outputs in one object) and `formula_json` (rule list); all
  board fields are dot-notation into `param_json`
- `flow-grid` `group_by [i18n.title]`, sort on `sort_order`: the aggregated row has
  `report_date null`, `sort_order 1`
- new: `evaluate {formula_field, params_field}`, since 14 Sep on the `flow-cards` (§8.4)
- types: `duration` for seconds with `format hh:mm`, `percent` for 0..100 ratios, areas as plain numbers, the unit in the label (`Output (m²)`), no `suffix`

## 6. open

1. `planned_print_operator_duration` on the totals container: sum over resources counts a
   line several times. Advice: the container takes it from the aggregated rows through
   `max` per line, or the report gets a per-line row later.
2. Days without shifts (`shift_json` empty) have `availability 0` and every percentage 0.
   Leave them in, or filter on `availability > 0` in the board: a `hidden_when` on the card.

## 8. step 4: operators, operator cost, summary card (14 Sep)

Decided with Cees, 14 Sep: 21 workdays a month; `planned_operators` is a line value, the
headcount of the print-operator group of the day; the cost per m² shows only on the summary
card; formula version 1 is updated in place; the filter sends one `date`; the tenant
container sorts on `tenant_id` and has no colexp.

### 8.1 the read

- Signature: `log.get_oee_report(p_date date, p_line_type, p_tenant_ids, p_resource_paths, p_dates, p_steps, p_workdays)`.
  `p_date` (default the Amsterdam date of today) replaces `p_until`; the days in view are
  `p_date` and the `p_workdays` (4) workdays before it, so the grid always has five day
  columns and the aggregated column. `p_dates` stays in the signature for later, not in the
  data_group params. `mapping.get_status_bar_oee` calls `p_date := d.date`.
- Variables in `DECLARE`, to be tuned later:

  | variable | value |
  |---|---|
  | `v_operator_monthly_cost` | 3500 (euro) |
  | `v_workdays_per_month` | 21 |
  | `v_operator_working_time` | 8 * 3600 |
  | `v_operator_cost_per_second` | `v_operator_monthly_cost / v_workdays_per_month / v_operator_working_time` (0.005787) |

- `planned_operators`: the department resource of the line is `relation.resource` with the
  same `line_id` and step `labor` (third label of the path, `department-174` for Plaat). Its
  `log.hr_shift_planning` row of the day: the groups of `plan.groups` whose kebab-case
  name is in the `print-operators` codes of `lookup_teams` (`printer-operator`), the
  `employee_count` of every entry in `shifts` summed (day 4 + evening 3 + night 1 = 8). That
  count is already without the absent employees (sick, leave), nothing is subtracted.
  A line value, repeated on every resource of the line, like
  `planned_print_operator_duration`.
- New keys in `param_json`, on every row so the board can recompute without the server:
  `planned_operators`, `operator_working_time`, `operator_cost_per_second`.
  The aggregated row sums `planned_operators` over the days (operator-days) and repeats the
  two constants.
- `mapping.get_status_bar_oee` sums every param over the machines of the line. That is
  wrong for the line values and the constants, and it already was for `has_break_times`
  (the summed flag multiplies the summed breaks). The line values and the flag take `max`:
  `has_break_times`, `planned_print_operator_duration`, `planned_operators`,
  `operator_working_time`, `operator_cost_per_second`.

### 8.2 the rules

Appended to `production.formula` `oee-report` version 1 (the insert is idempotent on
code and version):

```
planned_operator_duration = planned_operators * operator_working_time
planned_operator_cost = planned_operator_duration * operator_cost_per_second
operator_cost_per_sqm = actual_gross_output_sqm > 0 ? planned_operator_cost / actual_gross_output_sqm : 0
```

### 8.3 the board

- `flow-container`: `group_by [tenant_id]`, `sort {field: tenant_id, direction: asc}`; no
  colexp, no checkmarks, nothing selectable, everything open.
- `flow-cards`: `group_by [resource_uid]`, `set_field set`; the summary row of the read is the last
  card of the tenant (the read orders it last). `set_overrides.summary` shows the operator fields,
  styles the input and titles the card `Totaal <tenant>`. `evaluate {formula_field: formula_json,
  params_field: param_json}` on the cards, so an edited card is recomputed on the board. No
  client-side aggregation, no `aggregate_fn`, no `summary` key. A `class_name` makes a card read
  as a table row.
- Only on the summary card, through `ui.hidden true` in the master and `ui.hidden false` in
  `set_overrides.summary`:
  `param_json.planned_operators` (`ui.control input`, `ui.type number`),
  `param_json.planned_operator_cost` (`Operatorkosten (€)`, scale 0),
  `param_json.operator_cost_per_sqm` (`Operatorkosten (€/m²)`, scale 2).
  Changing the input re-evaluates the rule list on that card's params and re-renders its
  `param_json` fields.
- Filter `oee_report_filter`: `date` (`ui.control date-picker`, `ui.type date`) replaces `dates`;
  `line_type` and `tenant_ids` unchanged. Report params: `date`, `line_type`, `tenant_ids`.
- The grid reads as the sheet `docs/images/oee-overall.png`: `row_options.label_column true` puts
  the field labels once, as a column in front of the day columns, the cells show values only;
  `label_column_sticky true` keeps that column in view; `full_grid_scroll true` gives the grid one
  vertical scroll for all columns (a column has its own by default); the `class_name`s take every
  border away.
- The cards carry the fields themselves (no `flow-table` child), `fields_class_name` two columns,
  the machine name on top. The grid groups on the plain column `report_key` with the title from
  `i18n` (`group_title_fields`); the read orders on `tenant_id` first, so the data order is the
  tenant order.

### 8.4 frontend handoff (compact)

- `flow-grid` children: `flow-container` or `flow-cards`; `sort` on a `flow-container`
- `flow-cards` `set_field set` + `set_overrides.summary {row_options, field_config}`: the summary
  row of the read is a normal card with overrides (the timeline vocabulary); no summary feature
- `evaluate {formula_field, params_field}` on `flow-cards`: the results land in the params field
  itself (no result key), recomputed per card when an `input` changes a param
- new `ui.control: input` on a param field (`ui.type number`): edits the row's param client-side
- `src get_oee_report` param `date` (date) replaces `until`; new column `report_key`
- `flow-grid` `group_by [report_key]` + `group_title_fields [i18n]`: one column per key, dynamic
- new on `flow-grid` `row_options`: `label_column true` (labels once, as a first column in front of
  the grid columns, cells values only), `label_column_sticky true`, `full_grid_scroll true` (one
  vertical scroll for the whole grid instead of one per column), `class_name` on the grid and on
  the cards (no borders). Target look: `docs/images/oee-overall.png`; the compact handoff is
  `docs/handoff-oee-report-frontend.md`
- new `ui.control: date-picker` (`ui.type date`) on a filter: one date, the single of `multi-date-picker`

### 8.5 decided

1. A tenant container can hold more than one line when `line_type` is not set; the summary
   card then shows the line values of one line (`max`). Accepted: the filter on line type is
   the normal use, `p_line_type` stays in the function.
2. The aggregated column sums `planned_operators` over the days; the input on that summary
   card edits the operator-days.
3. Superseded 14 Sep: the summary is a row of the read (`set summary`), not a client aggregate.

| step | what | rollback | done when |
|---|---|---|---|
| 4 | `archive/sql/migrations/update_oee_report.sql` (formula rules, `log.get_oee_report` with `p_date`), `archive/sql/migrations/update_status_bar_oee.sql` (`mapping.get_status_bar_oee` on `p_date`, line values with `max`), `archive/sql/migrations/update_oee_report_data_group.sql` (`oee_report`, `oee_report_filter`); all three rerunnable | `archive/sql/migrations/update_oee_report_down.sql` | the check shows `planned_operators` 8 for Plaat on 14 Sep, the board a summary card per tenant with operators, cost and cost per m² |

## 9. the sheet check (14 Sep, `OEE voorbeeld Probo Hub.xlsx`)

The rules follow the sheet since 14 Sep:

- not planned = technical availability - planned, its percentage over technical availability
  (the sheet's identity: availability = technical failure + not planned + planned availability)
- output per hour: both. `output_per_planned_hour` is the sheet's (output / planned availability),
  `actual_output_per_hour` ours (output / producing hours), shown lighter on the card
- overcapacity = not planned hours x the resource's output per planned hour over the period
  (`period_output_per_planned_hour`, the sheet's total column). The summary row prices its
  not-planned hours at the resources' overcapacity over their not-planned hours, so it equals the
  sum of its resources', as the sheet's total block does
- operator cost per m² divides by the output. The sheet divides by the overcapacity total (a wrong
  cell reference), not followed
- new on the summary: `output_per_operator` (output / operators) and `planned_printers_per_operator`
  (planned availability / (operator working time x operators)): the planned hours of all printers
  expressed in operator shifts, per operator; how many printers one operator runs on average
- the cost per second is no longer rounded (the sheet: operators x 3500 / 21 exactly)

## 10. shifts, offline, step (15 Sep)

- Availability is shift time minus offline minus the breaks when the resource has them:
  `availability = shift_duration - offline - has_break_times * break_times`. The card shows shift
  time, offline and availability as three rows. `offline` is the state of that name in the shift
  aggregate.
- Every shift has a code: `code` on the shift in `action.dates.shift_json` (the source), day /
  evening / night, the codes and titles of legacy `lookup_shift`. `archive/sql/migrations/update_shift_code.sql`
  sets the codes (rank of the start within the shifts of the same tenants; a start before 06:00 is
  the night that ranks last; a preview query first), adds `shift_code` to `log.state_shift_agg`,
  lets the upsert write it, and rebuilds the aggregate from 7 Sep. The upsert already clips every
  state, plan item and production job to the shift windows, so a plan item over a shift change is
  already two pieces; only the code was missing.
- The read: `param_json.shifts`, one element per shift code of the row with the same inputs and
  the rules evaluated per element on the server (the board evaluates nothing per shift); the flat
  keys stay the totals, so every percentage is over the total. The aggregated and summary rows sum
  per shift code. `p_step` (text, default `print`) replaces `p_steps`; the filter has a select
  print / coat / cut. The rows come per tenant by resource name, the summary last.
- The board: `items {data_field: param_json.shifts, title_field: i18n, key_field: shift}` on the
  cards: a value row shows one cell per shift, the percentage cell from the row itself.
- The status bar sums only the numeric keys of `param_json` (`shifts` is an array).
- Output in two areas (15 Sep): `actual_gross_output_sqm` (was `actual_gross_output_sqm`, also the column
  of the shift aggregate) and `actual_net_output_sqm`, the production area less the nest's waste,
  computed per job in the upsert. The card shows the customer-order area first, the production
  area under it; the rules use the production area. `archive/sql/migrations/update_shift_code.sql` carries the
  columns and the rebuild.

## 11. from the report into the detail: nest waste per resource, shift employees, planning (15 Sep)

Status: built 15 Sep, waiting to be run (§11.5). Decisions of Cees in the text.

### 11.1 the nest waste read per resource

`legacy.get_nest_waste_ranges(p_dates, p_material_ids, p_line_type, p_resource_uids, p_nest_date)`: the nests
printed on the resources (a print job in `log.data` carries `nest_name` and `resource_uid`; `legacy.nest`
has no resource), and one day through `p_nest_date` (the column of the report, not the range). `p_dates`
wins when both are given, neither is today. Data_table `get_nest_waste_ranges` unchanged.

### 11.2 the sidebar: resource nest waste

Data_groups `resource_nest_waste_ranges` and `resource_nest_waste_ranges_chart`: the board and the chart
of `nest_waste_ranges` with params `resource_uids`, `date`, `line_type`. Page `resource-nest-waste`
(a sidebar page): chart above board, no filter.

### 11.3 the columns and navs of the report

A nav param names the target's query param and, with `value_from`, the row field it takes; without
`value_from` the row field of the same name. The report declares what its navs hand on as params of its own, computed
from the row with `value_from` (`resource_uids` from `resource_uid`, `nest_date`, `error_date` from
`business_date`); a sidebar takes a key of its own, never `date`, which the report page owns
(decided 15 Sep, after the hub found that a shared `date` moved the report). A date column reaches the board as a timestamp, so
the read serves the day as text: `business_date` (was `report_date`; YYYY-MM-DD), `until` (the end
of that day, for the planning sidebar), `production_line_id` (the line of the resource; on a summary row the line of its
resources) and `resource_uids` (the resource; on a summary row every resource of the tenant). On the
aggregated column `business_date` and `until` are null and a sidebar falls back to today.

| field | nav | params | opens |
|---|---|---|---|
| `param_json.actual_gross_output_sqm` | `on_select` | `resource_uids` from `resource_uid`, `nest_date` from `business_date` | `(sidebar:resource-nest-waste)` |
| `param_json.planned` | `on_select` | `resource_uids`, `until` | `(sidebar:production-planning-info)` |
| `param_json.technical_failure` | `on_select` | `resource_uid`, `error_date` from `business_date` | `(sidebar:error-log)`, the error log of the resource, five days back from that day |
| `production_line_id`, `control button`, summary card only, next to the operators input | `on_click` | `production_line_id`, `business_date` | `(sidebar:shift)` |

The summary card keeps the two resource navs: its `resource_uids` are the tenant's resources.

### 11.4 the shift employees per line and day

`legacy.get_resource_shift_employees(p_production_line_id, p_business_date)` replaces the model/until version;
`mapping.get_status_bar_teams(p_production_line_id, p_business_date)` follows and `mapping.get_status_bar` asks
the teams per line. The status bar's teams nav and the data_group `resource_shift_employees` pass
`production_line_id` and `business_date`. The sidebar `oee` is renamed `production-planning-info`; the menu item
`resource.oee` points there and is titled Planning; the nav in `production_line_overview` follows.

### 11.5 steps

| step | script | done when |
|---|---|---|
| 1 | `archive/sql/migrations/update_nest_waste_resource.sql` | the check lists the materials of one printer of yesterday; the two data_groups exist |
| 2 | `archive/sql/migrations/update_oee_report.sql` (rerun: `business_date`, `until`, `production_line_id`, `resource_uids`), then `archive/sql/migrations/update_status_bar_oee.sql` | the rows carry the four columns |
| 3 | `archive/sql/migrations/update_shift_employees_line.sql` | the check shows the data_table on the legacy function, the employees of the sheet line, the status bar teams |
| 4 | `archive/sql/migrations/update_oee_report_data_group.sql` | the three navs on the cards, the button on the summary card |

Rollbacks: `_down.sql` next to each. The page and menu renames live in `json/data` (git).
