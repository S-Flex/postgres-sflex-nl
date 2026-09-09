# legacy planning chain (pv2 data)

The seven functions that drive the planning boards on the legacy (pv2)
database, how they call each other, what flows through, and where the time
goes. Read this before touching any of them.

Everything here runs on **old data**: `mapping.component_specs` (one row per
production orderline, synced from pv2), `legacy.single_product` / `legacy.nest`
/ `legacy.batch`, `mapping.internal_rework`, `mapping.production_orderline_progress`.
The target model (job → spec → imposition, see `docs/domain-model.md`) is not
involved. Do not extend this chain towards the new model; it is what keeps the
boards running until the new chain replaces it.

## 1. call graph

```
boards (json/data_group)                 functions
──────────────────────────               ─────────────────────────────────────────────
production_board (main src)          →   mapping.get_production_board_aggregate
                                             └─ mapping.get_production_orderline_detail

nest_schedule (76)                   →   mock.get_nest_schedule
nest_resource_schedule (78)                  ├─ mock.get_print_schedule_materials      (the rows: one per lane)
                                             └─ mapping.get_production_orderline_aggregate   (once for the window rows, once per nest set)
                                                    ├─ mapping.get_production_orderline_detail
                                                    ├─ action.get_date_window
                                                    └─ log.production_forecast_material (matview)
    label_options.input_data.src     →   mock.get_print_schedule_materials
    time_scale_config.input_data.src →   production.get_timeline_view_segments

print_schedule (75)                  →   mock.get_print_schedule
                                             ├─ action.get_interval_dates                (per material)
                                             ├─ mock.get_production_forecast_material     (matview + live sum over component_specs)
                                             └─ evaluate_many_nas                          (per row × panel size)
    label_options.input_data.src     →   mock.get_print_schedule_materials

impose_plan_inflow (79)             →   mapping.get_production_orderline_manifest
                                             └─ mapping.get_production_orderline_detail   (manifest_json on the row)

anything else needing orderlines     →   mapping.get_production_orderline_detail  (graph, sitrep, ...)
```

`mapping.get_production_orderline_detail` is the root of everything that shows
orderlines. Every board-level number is a sum over its rows.

## 2. the functions

### 2.1 `mapping.get_production_orderline_detail` — one row per orderline

`(p_from, p_date_type, p_look_back_days, p_look_ahead_days, p_include_weekend,
p_include_mandatory_dates, p_status_sequences, p_status_levels,
p_production_line_id, p_material_ids, p_batch_ids, p_nest_ids, p_is_open,
p_threshold, p_domain_id)`

- **scope**, in order of precedence: `batch` (`p_batch_ids`) > `nest`
  (`p_nest_ids`) > `window`. Batch and nest scope go through
  `legacy.single_product → legacy.nest → legacy.batch`; window scope is a range
  on one date column chosen by `p_date_type` (`logistics` | `production` |
  `nest` | `shipment`). The window edges come from `action.get_date_window`
  (counted on `action.dates`, so "look ahead 2" is two days *in scope*, not
  two calendar days; both counts null = no window).
- **filters** on `component_specs`: `domain_id`, `is_open`, status sequence
  and/or status level (`internal_status.level`: Pre-production, Production,
  Internal transport, Logistics, Sent), `first_production_line_id`,
  `material_id`; cancelled statuses are always out.
- **enrichment**, each once per set: nests of the orderlines (`orderline_nest`),
  nest reruns and own rework (`mapping.internal_rework`, `object_type = 'nest'`
  vs the rest), progress (`production_orderline_progress`: `status_path`,
  `status_times`, `part_statuses`, `part_amount`), status colours/i18n
  (`mapping.internal_status`), material name (`material_production_line`).
- **output shape** worth knowing:
  - `impact_json` `{count: 1, amount, sqm, rework_count, rework_amount, rework_sqm, production_order_amount}`
    — the one shape every aggregate sums; rework = own + nest reruns folded
  - `class_names` (sorted, deduped): `state-delayed` (logistics day < viewed
    day), `plan-alert` / `plan-signal` (`status_sequence < 450` and nest_date
    within / beyond 2 h), `plan-rework`
  - `delivery_class_names` kept apart because the production board groups on it
  - `unit_class_names`: `units-lte-threshold` / `units-gt-threshold` on
    `production_order_amount` vs `p_threshold`
  - `part_status_json` (parts per status, feeds the distribution bar),
    `nest_json`, `nest_ids`; the status path walked (`status_json`) was
    dropped, nobody read it
- constants in the body, to move to a lookup later: `v_nested_sequence = 450`,
  `v_alert = 2 hours`, zone `Europe/Amsterdam`
- `SET plan_cache_mode = force_custom_plan`: replanned on every call.

### 2.2 `mapping.get_production_orderline_aggregate` — one row per material × production line

Same parameters as the detail (incl. `p_status_levels`) plus `p_tenant_ids` (only narrows the forecast),
`p_waste_percentage` (default 20), and returns per group:
`orderline_count`, `product_amount`, `part_amount`, `amount`
(`Σ greatest(part_amount, product_amount)`), `sqm`, `forecast_sqm`,
`rework_*`, `impact_json` (summed), `gross_sqm`, `specs_json`, `status_json`,
`part_status_json`, `nest_ids`, `nest_count`, `class_names` (union),
`unit_class_names`, `delivery_class_names`, `seconds_to_logistics_date`.

- `forecast_sqm` from `log.production_forecast_material` over the same window
  the detail uses (nest/batch scope: the day of `p_from`), tenant → company via
  `relation.lookup 'lookup_tenants'`. A material with forecast but no orderlines
  still gets a row (`full join`).
- `gross_sqm = (sqm + rework_sqm) × (1 + waste/100)`; with no inflow it falls
  back to `forecast_sqm × (1 + waste/100)` so the row keeps a size.
- `specs_json`: every size in `material_production_line.line_json -> 'specs'`
  with `amount` = sheets (`material_media_type_id` 1) or metres (3) the gross
  sqm needs.

### 2.3 `mapping.get_production_board_aggregate` — the production board cells

`(p_from, p_look_back_days, p_look_ahead_days, p_production_line_id,
p_domain_id, p_status_levels)`. One detail call (`logistics` window), then
grain = (status, logistics date/datetime, delivery class, material) and every
higher level derived from that grain by summing, so cells always equal the sum
of their material rows. Emits `distribution_json` / `day_distribution_json` /
`material_distribution_json` for the distribution bars.

### 2.4 `mock.get_print_schedule_materials` — the rows of the timeline boards

`(p_until, p_step, p_line_type, p_tenant_ids, p_only_starting_today)`. Reads
the newest `action.plan` of the day (`plan_date`, `step`, `type =
'material-resource-plan'`, `line_type`), its lanes, and through
`mock.material_resource_plan_lane` the `mock.material_resource_plan` row of
each lane: `material_id`, `resource_uid`, `sort_order`, `occurence`,
`start_offset_in_seconds`, `next_start_offset_in_seconds`, `is_pinned`. Adds
`material_print_schedule` (names, delivery hours, interval) and the fixed
groups from `production.lookup 'lookup_nest_moments'`. Second branch: the
tenant `noop` windows from `action.non_working_times` as rows without
material. Rows with `material_id` and `resource_uid` both null are those
spacers; the client handles them.

Used three times per board: as the base of `get_nest_schedule`, and directly
as `label_options.input_data.src` on 75/76/78.

### 2.5 `mock.get_nest_schedule` — the nest timeline board (76, 78)

`(p_until, p_step, p_line_type, p_tenant_ids, p_only_starting_today,
p_look_back_days = 0, p_look_ahead_days = 0, p_domain_id)`.

1. rows from `get_print_schedule_materials`
2. per lane the nests hung on its lane items (`action.lane_item →
   action.nest_lane_item`), aggregated to `nest_ids`
3. **one** aggregate call for all materials of rows without lane nests
   (`p_date_type = 'nest'`, window = today by default) and one per distinct
   nest set; each row takes its group back on `material_id, production_line_id`.
   `p_tenant_ids` = all tenants of the plan (forecast only)
4. `param_json.specs` = `specs_json`, `duration_in_seconds =
   ceil(gross_sqm × 45)`, fast × 15 (constants, lookup later),
   `nest_ids`/`nest_count` = the lane's, `production_company_id` via
   `lookup_tenants`, `part_status_json` for the bar, `class_names` union.

The scope is always the material of the row; `resource_uid` is display only.
The two boards differ only in `set_group_fields` (material vs resource).

### 2.6 `mock.get_print_schedule` — the print agenda board (75)

`(p_until, p_line_type, p_tenant_ids, p_only_starting_today)`. Ten workdays
of columns. Per material in `material_print_schedule`: production days from
`action.get_interval_dates`, one card per nest moment code (day offset moves
the date, the column stays), forecast/actual per day from
`mock.get_production_forecast_material`, then `evaluate_many_nas` per card ×
panel size for panels and print impacts. Class names `plan-na` (offset day),
`plan-initiated` (beyond the interval).

### 2.7 `mapping.get_production_orderline_manifest` — the nest queue (79)

`(p_material_id, p_date, p_look_ahead_days = -1, p_threshold, p_domain_id,
p_tenant_ids)`. One detail call (`nest` window, workdays only, look-ahead =
`greatest(2, max(material_print_schedule.interval_days))` unless overridden);
the manifest rides along on the detail row itself (`manifest_json`, one object
per scope — the queue groups on `manifest_json.imposition`). Adds
`tenant_name` and `queue_class_names` (= `unit_class_names` beyond the next
working day, else `{}` — that is what lets one board level group on date +
threshold). Rows biggest first.

## 3. parameter and shape conventions across the chain

- `p_from` / `p_until` is a `timestamptz`; the day is taken in
  `Europe/Amsterdam` (detail, aggregate, manifest) or in the session zone
  (`get_print_schedule_materials`, `get_nest_schedule`, `get_print_schedule`
  use `current_setting('TimeZone')`). **Mixed** — a known seam.
- day counts are always in days of `action.dates` that are in scope; the
  timeline boards pass workdays only, the production board includes weekends.
- lookups read every call: `production.lookup 'lookup_nest_moments'`,
  `relation.lookup 'lookup_tenants'`; contents in `json/lookup/`.
- constants still in code: 450, 2 h, 45/15 s per m², waste 20 % (param), status
  sequences `225…450` in `get_nest_schedule`.

## 4. where the time goes — measured

Measured on the live database with `explain (analyze, buffers)`, board
parameters for the workday 2026-08-14, `p_line_type = 'sheet'`. Run-to-run
noise on this server is large (the same call varied 1.4–1.9 s and 1.6–2.1 s
within minutes), so read the numbers as ranges. The guesses from the code were
wrong in the ranking; the causes below are what the plans showed.

| call | before (2026-08-16) | after | what changed |
|---|---|---|---|
| `get_nest_schedule` (nest board) | 3 845–4 000 | **454** | no JIT, one aggregate call per scope |
| `get_production_orderline_aggregate`, 52 materials, nest window | 3 583 | 422 | `flag` CTE rewrite → no JIT |
| same, one material | 3 135 | 130 | idem |
| `get_production_orderline_detail`, 52 materials (75 rows) | 354 | ~55 | materialized per-orderline CTEs |
| `get_production_orderline_detail`, board window (6 318 rows) | 1 345–1 625 | **943** | `status_json` removed |
| `get_production_board_aggregate` | 1 423–2 890 | **1 263** | detail faster, level filter at the scan |
| `get_production_orderline_graph`, one level | – | 359 | level filter at the scan |
| `get_print_schedule` | 360–500 | – | not touched |
| `get_print_schedule_materials` | 25 | – | not touched |
| `get_production_forecast_material` (12 days) | 33 | – | not the problem I expected |

Causes, in the order they were found:

1. **JIT compilation, ~2.5–3 s per aggregate call.** The `flag` CTE joined
   four `unnest` laterals side by side; the planner estimated
   1000 × 10 × 10 × 10 × 10 rows, the plan cost went to 2 074 136, far past
   `jit_above_cost` / `jit_optimize_above_cost`, and PostgreSQL spent 2 468 ms
   compiling (Optimization 1 342 ms, Emission 941 ms) for 67 rows. Fix: the
   four arrays are aggregated one at a time (correlated `array_agg` per
   group). Cost after: 44 004, no JIT. A loose `select … from
   get_production_orderline_aggregate(...)` never showed it, because the SQL
   function is inlined into the calling statement and the JIT decision is
   taken on that whole statement — the board (`lateral` per row) did show it.
   Belt and braces: `alter function mock.get_nest_schedule … set jit = off`.
2. **The detail recomputed its per-orderline aggregates per outer row when
   the material filter was long.** With 52 material ids the planner estimated
   1 row for `orderline_base`, chose nested loops, and re-ran
   `status_json_agg` and `part_status_json_agg` 75 times each (~140 ms
   each). Fix: `nest_agg`, `orderline_rework`, `part_status_json_agg` are
   `MATERIALIZED`. Detail with 52 materials: 298 → 54 ms.
3. **One aggregate call per board row.** After 1 and 2 the per-row call
   still cost ~75 ms × 52 rows. Fix in `get_nest_schedule`: one call for all
   materials without lane nests, one per distinct nest set, matched back on
   `material_id, production_line_id`.
4. **`status_json` (the status path walked) cost 345 ms on the board
   window** — 33 502 steps built with i18n — and nobody read it. Removed
   from the detail. `part_status_json` (parts per status, feeds the
   distribution bar) stays.
5. **What is left in the detail on the board window**: `part_status_json_agg`
   ~200 ms, `orderline_nest` + `nest_agg` ~260 ms, final joins and sort
   ~250 ms, the `component_specs` scan itself ~10 ms. And the board aggregate
   adds ~300 ms of its own (`step` unpacks `part_status_json` per row, three
   distribution jsons, a window function).

Not a problem: the forecast function (33 ms), the lookups, the per-row
`get_interval_dates` in `get_print_schedule_materials` (25 ms in total).

## 5. plan — what is left

Done and live: 1–4 above, plus `p_status_levels` on detail, aggregate, board
aggregate and graph (filter at the scan, not on the rows coming back).

**Next, only if the boards still feel slow:**
- **board aggregate**: measure its own CTEs (`step`, the three distribution
  jsons) with the detail time subtracted; ~300 ms today.
- **nest join in the detail** (~260 ms on the board window): only needed for
  nest scope, `nest_json`, `nest_ids` and nest rework. A `p_light` that skips
  `nest_json` (keep the rework) or an index
  `legacy.single_product (production_orderline_id) include (nest_id, amount)`
  — check the plan first.
- **`get_print_schedule_materials` once per board** (25 ms × 3): not urgent.
- **`get_print_schedule`** (360–500 ms): not profiled yet; `evaluate_many_nas`
  per card × size is the suspect.
- **JIT insurance** on `get_production_board_aggregate` and the graph
  (`set jit = off`) — measured not needed today (jit off made no difference
  there), so left alone.

Nothing done so far changed the output shape of a function except the two
removals (`rework_json` → `impact_json`, `status_json` gone), which are in
`archive/docs/handoff-control-room.md`'s scope only as data, not as config.

## 6. how to measure

The calls used for every number above, so the next round compares like with
like (a workday with a plan; today's date if it is one, otherwise the last
workday):

```sql
-- nest board
explain (analyze, buffers) select count(*)
from mock.get_nest_schedule(p_until => '<workday> 10:00+02', p_line_type => 'sheet');
-- production board
explain (analyze, buffers) select count(*)
from mapping.get_production_board_aggregate(p_from => '<workday> 10:00+02');
-- detail, board window
explain (analyze, buffers) select count(*)
from mapping.get_production_orderline_detail(p_from => '<workday> 10:00+02',
     p_date_type => 'logistics', p_look_back_days => 10, p_look_ahead_days => 5);
-- print agenda
explain (analyze, buffers) select count(*)
from mock.get_print_schedule(p_until => '<workday> 10:00+02', p_line_type => 'sheet');
```

`explain analyze` on a function call shows only the total. To see the nodes,
inline the body with literal parameters (a plpgsql body: from `return query`
to `end;`, with the `v_` variables filled in) and explain that; a `JIT:` block
with seconds in `Timing` at the bottom means a cost estimate is off somewhere
above it. Run each measurement three times; take the middle one.
