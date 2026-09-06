# plan: `mock.get_production_plan` — plan and realized on one board

Status: proposal. Replaces `action.get_plan_timeline` + `plan_timeline.json` (56)
with a board in the style of `nest_resource_schedule` (78): lanes per resource,
the plan from `action.plan → lane → lane_item`, the realized from `log.data`
and `log.state`. Nothing here is built yet; the repo has only the stop-gap fix
of `mock.get_material_planning_aggregate` that makes the old function run
again.

## 1. what there is today

| piece | reads | state |
|---|---|---|
| `action.get_plan_timeline` | `action.object` (pv2 planning), `relation.resource`, `mock.get_material_planning_aggregate`, `mock.get_resource_speed_factor`, four lookups, `log.production_forecast_material` | ran again after the stop-gap; old model |
| `plan_timeline.json` (56) | its own `plan_config` (connectors, `evaluate`, `valid_resources`, `is_locked`, `rank_field`, `is_atomic`, `is_fixed_offset`) | shares nothing with the nest boards |
| `log.get_resource_state` | `log.state` + `lookup_resource_state`: state blocks per resource, anchored before `p_from`, duration to the next change | realized: **states** |
| `log.get_resource_produced` | `log.data` + `legacy.nest/batch`: one row per produced item (nest, filename, amount, `production_time_seconds`) | realized: **output** |
| `log.get_resource_plan_batch` | `action.object` again, with nest status per batch | old plan side, superseded |
| `log.get_resource_plan_impact` | `mapping.v_resource_capacity` fastest profile | plan impact per resource |
| `log.get_resource_timeline` | union of the four above; **no data group uses it** | the shape to keep |
| `action.plan / lane / lane_item / nest_lane_item` | the new plan model; `lane_item.level` (0 = plan, 1 = realized) exists in the database, not yet in the repo DDL | new model |

Both realized functions already speak the timeline shape: `resource_uid`,
`state`, `group_state`, `start_at`, `offset_seconds`, `duration_seconds`,
`data`. That is what the new function builds on; the plan side is new.

## 2. the model changes first

### 2.1 `action.plan.step` → `steps text[]`

One plan, one date, one type; the steps it covers as a list. A production plan
today: `{print}`; later `{print,coat,cut}` or a mounting plan `{mount}`.

```sql
alter table action.plan add column steps text[];
update action.plan set steps = array[step];
alter table action.plan alter column steps set not null;
alter table action.plan drop column step;
```

Readers of `plan.step`: `mock.get_print_schedule_materials`, `mock.get_nest_schedule`
(`where step = p_step` → `p_step = any (steps)`), and the new function.
Repo DDL `sql/action/plan.sql` follows.

Step vocabulary is data: `lookup_step_category` in `relation.lookup` (already
there: rip 600, print 700, coat 790, laminate 795, cut 801, …). New steps —
nest, embellish, route, package, ship, mount — go into that lookup, not into
code. A step that is not in the lookup has no lane on any board.

### 2.2 `action.lane_item.level`

Already in the database: `0` = planned, `1` = realized. Into `sql/action/lane_item.sql`
with a check `level in (0, 1)` and a comment. Realized lane items are written
by the log side (a job that folds `log.data`/`log.state` into lane items), not
by the board — see §4.

### 2.3 `action.lane` gets the resource — decided: `resource_path`

Today a lane is `(plan_id, sort_order)` and the material/resource comes through
`mock.material_resource_plan_lane`. A production plan lane *is* a resource:
`lane.resource_path ltree` (nullable, for the material lanes of the nest plan
it stays null) — the path as it was when the plan was made, a snapshot. See
`docs/resource-path.md` for the level order. The join to the live resource is
`relation.resource.resource_path = lane.resource_path` (btree on both);
resources are also grouped and filtered on the tree (`<@ 'dokkum.sheet'`).

**Extended (2026-08-19): the lane is a machine-day, `plan_lane` carries the
boards.** A machine physically in the sheet hall can run foil orders; its time
is one strip that both boards must see. So `lane` = `(lane_date,
resource_path ltree)` (one machine per lane; material
lanes of the nest plan have null paths), and `action.plan_lane (plan_id,
lane_id, sort_order)` says which plans show the lane and in which order per
board. `crud_object` hangs a lane under the order-side plan **and** the
physical department's plan automatically; every board shows all items of its
lanes, so borrowed occupation is always visible. The drag mutation writes
`plan_lane.sort_order` (order differs per board).

## 3. `mock.get_production_plan` — the plan side

```
mock.get_production_plan(
    p_until        timestamptz default now(),   -- the viewed moment (p_at later, see plan-date-parameters.md)
    p_step         text        default 'print',  -- one step per board call; the client asks per step
    p_line_type    text        default null,
    p_tenant_ids   integer[]   default null,
    p_domain_id    integer     default 1)
```

Rows, one set:

| kind | one row per | from |
|---|---|---|
| plan (`level` 0) | lane_item of the newest `production-plan` of the day with `p_step = any (steps)` | `action.lane_item` + `nest_lane_item` → `mapping.get_production_orderline_aggregate(p_nest_ids => …)` for the numbers (sqm, impact_json, class_names, part_status_json), material via the nests |
| realized (`level` 1) | lane_item of level 1, or — until those are written — directly the blocks of `log.get_resource_state` (state) and `log.get_resource_produced` (output) | `log.state`, `log.data` |
| noop | tenant window | `action.non_working_times`, as on the nest boards |

Columns (superset of 78, so the client renders it with the same config):

`tenant_id, tenant_name, production_company_id, resource_uid, resource_name,
step, level, lane_item_id, sort_order, is_pinned, fixed_group,
start_offset_in_seconds, next_start_offset_in_seconds, duration_in_seconds,
start_at, nest_ids, nest_count, material_id, material_name,
impact_json, sqm, gross_sqm, forecast_sqm, part_status_json,
state_json, group_state_json, class_names, param_json`

- `start_at` for the realized side is the log timestamp; for the plan side
  `plan_date + start_offset_in_seconds`; the client keeps working in offsets
  (`offset_field`), `start_at` is for the tooltip and the drill-down.
- `duration_in_seconds` plan: `greatest(ceil(gross_sqm × seconds per sqm /
  speed_factor), 900)`, speed factor from `mock.get_resource_speed_factor`;
  realized: from the log (state block length, `production_time_seconds`).
- `class_names`: plan rows the union of the orderlines' (as on 78); realized
  rows the state's `class_name` from `lookup_resource_state`.
- `param_json`: `standard/fast_production_impact_in_seconds`, `speed_factor`
  — what the tooltip shows; **no formulas** (see §5).

The two realized functions are called once with the resources of the line
and joined on `resource_uid`; they already clip to the window and to `now()`.

## 4. who writes the lane items — decided

**Planned (level 0): `action.crud_object`.** The plan comes from pv2 and lands
in `action.object`; that stays for now. The same crud now also maintains the
new model, so the board reads one source and pv2's intraday updates flow
through:

| pv2 | new model |
|---|---|
| day of `start_date`, line type of the resource, the machine types in the payload | one `action.plan` (`production-plan`, `steps` = every step seen that day) per day and line type |
| resource | `action.lane` per (plan, `resource_path`) — a resource without a path gets no lane, its items wait |
| plannable item of type `batch` (`batch-reserved` / `batch-initiated` are ignored) | `action.lane_item` level 0, keyed `(source 'pv2', source_ref plannable_item_id)`; offset since local midnight, duration `end − start`, `is_pinned = is_fixed_offset`, `no_split = true` |
| `batched_amounts[].nest_id` | `nest_lane_item`, replaced as a set |
| chain printer → coater/laminator → cutter per batch | `lane_item_dependency`, replaced as a set |
| `deleted_at` | item, nests, edges gone |

After every payload the touched lanes are renumbered by start (`sort_order`
is unique per lane), in two steps so the constraint never trips.

**Realized (level 1): read from the logs**, not written yet.
`get_production_plan` calls `log.get_resource_state` and
`log.get_resource_produced` for the lanes' resources. A writer that folds
them into level-1 lane items can come later; the board will not notice.

`action.lane_item_event` has no role in this; drop it once nothing reads it.

## 5. `plan_config` (56) versus `timeline_config` (78) — what to keep

| `plan_config` key | does | keep? |
|---|---|---|
| `set: "plan"` | names the item set | **no** — one set; plan/realized is a row property (`level`, and `class_names`) the client renders differently. Ask the client whether it can style on `level`, else two class names `plan` / `realized`. |
| `links.connector`, `parent_field`, `foreign_field` | draws dependency lines between actions | **later** — `lane_item_dependency` exists (rip → print → coat …); once the board shows more than one step it comes back as `dependency_config {parent_field, foreign_field}` on `timeline_config`. Not for a one-step board. |
| `evaluate.formula_field` + `formula` column | the client evaluates duration/lock formulas | **no** — durations are computed in the function; a formula in the payload is code in data. |
| `draggable`, `rank_field`, `offset_field`, `params_field` | drag | **replaced** by the drag-and-drop contract (`row_options.drop`, `order_field`); `rank_field` = `order_field` |
| `resource_field` (`resource_uids[]`) | the lane | **replaced** by `set_group_fields: [tenant_id, resource_uid]` — one resource per lane, no array |
| `start_at_field` | absolute time | keep as column, not as config; the board works in offsets like 78 |
| `is_atomic_field`, `is_fixed_offset_field` | may not split / may not move | `is_pinned_field` covers "may not move"; atomic has no counterpart — **ask** whether it is still needed (splitting an item on the board) |
| `is_locked_field` (`param_json.is_locked` = offset before now) | past items are locked | **replaced**: realized rows are never draggable; plan rows before `p_until` get class `plan-locked` from the function and `draggable` obeys… **ask** the client: is there a per-row draggable field, or is "before now" a client rule? |
| `valid_resources` (`data.valid_resources`, `speed_factor_field`) | which resources may take the item, with speed | **keep, moved**: `valid_resources_json` per row from `material_print_schedule.valid_resources_json`, and the drop's `within_fields` cannot express "only these lanes" — needs a `drop.allowed_when` or the client filters on this column. **ask**. |
| `break_times_field` (`data.break_times`) | breaks | **replaced** by the noop rows / `action.non_working_times` (never computed server-side into durations — CLAUDE.md) |
| `set_field: state.group`, `set_order_field: state.order`, `set_title_field: name`, `class_names_field: state.class_names` | grouping/ordering by state | `group_by: [tenant_id, resource_uid]` + `group_title_fields`, `class_names_field: class_names`; the state itself becomes `state_json` for the tooltip |
| `start_time 04:00 / end_time 22:00 / timeline_seconds 64800` | the axis | keep as `time_scale_config` like 78 (`nest-time-scale` equivalent: a `production-schedule`, already in `lookup_timeline_views`: 06:00, 18 h, hour segments) |
| `group_by: [line, step]` | lanes | `[tenant_id, resource_uid]`; the step is a board parameter |
| `just_in_time_field`, `next_trigger_type` | JIT chaining | **later**, with dependencies |

Missing on 78's side that this board needs: a way to mark realized rows as
not draggable and visually distinct; `valid_resources`; and (later)
dependencies. Those three are the questions for the client.

## 6. data group `production_schedule` (new id, replaces 56)

Copy of 78 with: `src: [get_production_plan]`, params `line_type, until,
tenant_ids, step` (+ idents), `group_by: [tenant_id, resource_uid]`,
`group_title_fields: [tenant_name, resource_name]`, `set_group_fields`
idem, `chain_scope: lane`, `is_pinned_field`, `row_options.drop.within_fields:
[tenant_id, resource_uid]`, `commit: mutation`, card = material name + sqm,
tooltip = the 78 tooltip plus a state section for realized rows
(`state_json`, start/end, produced amount). Filter: a `production_schedule_filter`
(80's shape + `step` select from `lookup_step_category`).

56 and `resource_plan` (widget) go when the client has switched.

## 7. order of work

1. DDL: `plan.steps`, `lane_item.level` in the repo, `lane.resource_uid` (or the
   alternative from 2.3). Update `get_print_schedule_materials` /
   `get_nest_schedule` for `steps`. — one script, one measurement of the nest
   boards afterwards (nothing may change).
2. `mock.get_production_plan` plan side, on `nest_lane_item` and the
   aggregate; realized side reading `log.get_resource_state` /
   `log.get_resource_produced` directly.
3. `production_schedule.json` + filter, `site.data_table` entry, `pull` /
   partial as usual.
4. Client: `level` styling, non-draggable realized rows, `valid_resources`.
5. Level-1 writer job (realized → lane items); switch the function; drop 56 and
   `action.get_plan_timeline`, `log.get_resource_plan_batch`,
   `mock.get_resource_plan_batch`.
6. Dependencies (`lane_item_dependency`) once a second step is planned.

## 8. to decide before step 1

- §5: `is_atomic` still needed? Per-row draggable field on the client, or
  "before now" as client rule? `valid_resources` — client filter or a drop rule?
- Step vocabulary in `lookup_step_category`: add nest, embellish, route, package,
  ship, mount with their sequences (I will not invent the numbers).
- The realized side today stops at `now()`; a plan for tomorrow has no realized
  rows — fine, but confirm the board is a *day* board like 78 (one plan date).
