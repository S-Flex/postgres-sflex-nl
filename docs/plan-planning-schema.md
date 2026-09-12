# Plan: one resource planning in a new schema `schedule`

Date: 2026-09-12. Status: proposal, waiting for approval of the decisions in §6.
Supersedes the open steps of `docs/plan-lane-model.md` and `archive/docs/plan-batch-lane-item.md`.

## 1. goal

One kind of planning: resource planning. A day is planned by the lanes of that day, one
lane per step and machine. What is planned hangs on the lane item as `data_json`. The
material boards (75, 76) group the same items by material or imposition group; they do
not get their own lane kind.

Gone with it: `action.object` (pv2 planning), `action.plan.steps` and `plan_date`,
`action.plan_lane`, `action.imposition_group_lane`, `action.imposition_group_lane_item`,
`action.batch_lane_item` (its content moves into `data_json`).

Built next to what runs, in a new schema `schedule`, so every step is additive until the
switch, and the switch itself is one script with a matching rollback script.

## 2. the new model

```
schedule.plan                       one row per line type (+ tenant set): the board scope
  plan_id            bigint identity pk
  line_type          text not null
  tenant_ids         integer[] not null
  unique (line_type, tenant_ids)

schedule.lane                       one strip of time: one machine on one day for one step
  lane_id            bigint identity pk
  plan_id            bigint not null references schedule.plan
  lane_date          date not null
  step               text not null              -- lookup_step_category
  resource_path      ltree not null             -- docs/resource-path.md
  sort_order         numeric not null default 0
  unique (plan_id, lane_date, step, resource_path)
  index (lane_date), index (resource_path gist)

schedule.lane_item                  the block of work on a lane
  lane_item_id                bigint identity pk
  lane_id                     bigint not null references schedule.lane
  lane_item_type              text not null default 'plan'   -- lookup_lane_item_type
  sort_order                  numeric not null
  start_offset_in_seconds     integer check 0..86399
  duration_in_seconds         integer not null default 0 check >= 0
  production_impact_per_unit  numeric                        -- seconds per unit of the work
  data_json                   jsonb                          -- null on an inherited item, see §3
  unique (lane_id, sort_order)
  unique index on (lane_id, (data_json->>'material_id'), (data_json->>'nest_moment_code'))
    where lane_item_type = 'plan' and data_json ? 'material_id'   -- the upsert key of the generator

schedule.lane_item_dependency       many-to-many, from = predecessor
  from_lane_item_id  bigint not null references schedule.lane_item on delete cascade
  to_lane_item_id    bigint not null references schedule.lane_item on delete cascade
  primary key (from_lane_item_id, to_lane_item_id), index (to_lane_item_id)

schedule.lane_item_event            append-only status moves (plan -> released -> nested)
  lane_item_event_id bigint identity pk
  lane_item_id       bigint not null references schedule.lane_item on delete cascade
  status             text not null              -- lookup_lane_item_status
  moved_by           integer
  moved_at           timestamptz not null default now()
```

What is not a column any more and why:

| was | now |
|---|---|
| `plan.steps`, `plan.plan_date`, `plan.type` | the lanes say it: `lane.step`, `lane.lane_date`; one plan per line type holds all steps of all days |
| `plan_lane` | `lane.plan_id`; a lane hangs under one plan, a board filters on tenant and resource_path (§6.3) |
| `lane_item.source`, `source_ref`, `instance` | the generator finds its items on `(lane_id, material_id, nest_moment_code)`; one item per nest moment code (decided 9 Sep), so `instance` is redundant |
| `lane_item.fixed_group`, `no_split`, `nest_moment_code` | `data_json` |
| `lane_item.type` | `lane_item_type` (a key named `type` says nothing) |
| `lag_formula` | read column, not stored (§6.2) |
| `is_pinned`, `day_offset` | gone (decided 12 Sep): not used any more |
| `batch_lane_item`, `imposition_group_lane_item`, `imposition_group_lane` | `data_json.batches[]`, `data_json.imposition_group_id`, `data_json.material_id` |
| `action.object` | nothing: step items come from the nest manifest (§3.2), not from pv2 |

`action.formula`, `action.lookup`, `action.dates`, `action.non_working_times`,
`action.cutoff_time`, `action.week_team` stay in `action`: they are not planning rows.

## 3. data_json

### 3.1 shape

```jsonc
{
  "material_id": 480,
  "imposition_group_id": 12,
  "nest_moment_code": "30",
  "fixed_group": "30",
  "no_split": false,
  "i18n": { "nl": { "title": "Dibond 3 mm", "text": "…" }, "en": { … } },

  // one object per distinct manifest.item_code_paths: the nests of that path, per batch
  "batches": [
    { "batch_id": 91234,
      "nest_ids": [2431178, 2431179],
      "manifest": { /* legacy.nest.manifest_json of these nests */ } }
  ],

  // one object per distinct manifest.item_code_paths: the open orderlines of that path
  "production_orderlines": [
    { "production_orderline_ids": [501, 502, 503],
      "manifest": { /* mapping.component_specs.manifest_json, scope imposition */ } }
  ],

  "summary": {
    "count": 7, "amount": 41, "sqm": 12.3,
    "rework_count": 1, "rework_amount": 2, "rework_sqm": 0.8
  }
}
```

Rules:

- a key has one form everywhere: `batches` and `production_orderlines` are always arrays,
  `nest_ids` and `production_orderline_ids` always arrays
- the object key is the manifest's `item_code_paths`; the writer merges on it, so a second
  nest with the same paths lands in the same object (same batch) or a new object (other batch)
- `summary` is written, not computed at read time: `schedule.refresh_lane_item_data` recomputes
  it whenever `batches` or `production_orderlines` change
- `material_id` and `imposition_group_id` may both be present; at least one is, on an item
  the generator made. `imposition_group_id` is still the material alias until the xbom groups land

### 3.2 who writes which part

| part | writer | when |
|---|---|---|
| `material_id`, `imposition_group_id`, `nest_moment_code`, `fixed_group`, `no_split`, `i18n` | `schedule.generate_day` | stamping the day from `mock.material_print_schedule` |
| `production_orderlines`, `summary` | `schedule.refresh_lane_item_data` | daily refresh, for items not yet released; and after every `batches` change |
| `batches` | `schedule.place_nests` (from `legacy.crud_nest`) | a nest is nested: it lands on the impose item of its material, moment and day (rule of 9 Sep: released item, first moment at or after `nested_at`) |
| step items + `lane_item_dependency` | `schedule.place_nests` | same moment: per step and resource_path in `legacy.nest.manifest_json`, one item on the lane `(lane_date, step, resource_path)` of the same plan, created when missing, and an edge from the impose item. The step item has `data_json` null |
| `sort_order`, `start_offset_in_seconds`, lane move, copy, delete | `schedule.crud_lane_item` | the board (`docs/contracts/drag-and-drop.md`) |
| `lane_item_event` | `schedule.crud_lane_item_event` | release on the board, `nested` from `place_nests` |

### 3.3 inherited data_json

A step item carries no `data_json`. The read resolves it: `schedule.get_lane_item_data(p_lane_item_id)`
walks `lane_item_dependency` from `to` to `from` (recursive CTE) until it meets an item with
`data_json`; a merge (two predecessors) returns the union of their `batches`. This is the
`get_lane_item_impositions` design of `plan-lane-model.md` step 6, on `data_json`.

A split on the board (coat over two machines) writes an own `data_json` on the item that
deviates, via `schedule.crud_lane_item`; from then on that item is the source for its successors.

## 4. functions

Reads, all `stable`, all with `#variable_conflict use_column`:

| function | replaces | returns |
|---|---|---|
| `schedule.get_lanes(p_until, p_line_type, p_tenant_ids, p_steps, p_view_code)` | `action.get_plan_lanes_imposition_group`, `action.get_plan_lanes_resource` | one row per lane: `lane_id`, `lane_date`, `step`, `resource_path`, `resource_uid`, `resource_name`, `tenant_id`, `sort_order`, `formula` (from `production.resource_setting`) |
| `schedule.get_lane_items(p_until, p_line_type, p_tenant_ids, p_steps, p_types, p_view_code)` | `action.get_resource_plan`, `mock.get_impose_plan` | one row per lane item and type: the columns of §2 plus `lag_formula` (§6.2), `type_json`, `data_json` (own or inherited), `class_names`; `progress` and `actual` rows derived as `get_resource_plan` does today |
| `schedule.get_lane_item_data(p_lane_item_id)` | `get_lane_item_impositions` (never live) | the effective `data_json` |
| `schedule.get_inflow(...)` | `mock.get_impose_plan_inflow` | 79: pass-through of `mapping.get_production_orderline_manifest` plus `lane_item_id` of the first unreleased item |

Writes, all set-based over `jsonb_array_elements(p_param_json) AS el`:

| function | replaces |
|---|---|
| `schedule.generate_day(p_date, p_line_type)` | `mock.generate_plan`, `mock.generate_production_plan` |
| `schedule.refresh_lane_item_data(p_lane_item_ids)` | the aggregate fold in `get_impose_plan` / `get_lane_item_work` |
| `schedule.place_nests(p_nest_ids)` | the `batch_lane_item` block in `legacy.crud_nest`, `action.sync_pv2_batch_items` |
| `schedule.crud_lane_item(p_param_json)` | `action.crud_lane_item` |
| `schedule.crud_lane_item_event(p_param_json)` | `action.crud_lane_item_event` |

Not ported: `action.crud_object`, `action.sync_pv2_batch_items`, `action.get_plan_timeline`,
`mock.crud_material_impose_plan`. The board formula per machine keeps coming from
`production.resource_setting`; `action.get_lane_item_work` stays as the detail read behind a
row until the boards read `data_json.summary` directly, then it goes too.

## 5. steps

Every step ships as `sql/schedule/<nn>_<name>.sql` (up) and `sql/schedule/<nn>_<name>_down.sql`
(rollback). Nothing in a step touches `action.*` until step 7. I deliver, you run, I wait.

| step | what | rollback | done when |
|---|---|---|---|
| 0 | decisions of §6 taken; `alter table legacy.nest add column manifest_json jsonb` plus its writer in `legacy.create_imposition_unit_manifest` and a backfill of the nest window (§6.1); `action.formula` gets its lag rows (§6.2) | drop the column, redeploy the function from the repo | every nest of the window has a `manifest_json` with `step` and `resource_paths` per scope |
| 1 | schema `schedule` with the five tables of §2, owner `xfw3`, comments in English; lookups stay where they are | `drop schema schedule cascade` | tables exist, empty |
| 2 | reads of §4 on the empty schema, plus `site.data_table` rows for them | drop functions + data_table rows | `check_plan_reads.sql` returns 0 rows without error |
| 3 | `schedule.generate_day` + `schedule.refresh_lane_item_data`; backfill the same window as `site.refresh_derived_data` (today + 14 days, every line type) in a DO block with RAISE NOTICE; `refresh_derived_data` calls `schedule.generate_day` **next to** `mock.generate_plan` | drop functions, `truncate schedule.lane_item, schedule.lane, schedule.plan`, remove the call | per day and line type: same materials × nest moment codes as `action.lane_item` with source `material-plan` |
| 4 | `schedule.place_nests`; `legacy.crud_nest` calls it **next to** its `batch_lane_item` block; backfill nests of the window; `schedule.crud_lane_item`, `schedule.crud_lane_item_event`; release events copied from `action.lane_item_event` for the window | remove the call, drop functions, `truncate schedule.lane_item_dependency, schedule.lane_item_event` | every `batch_lane_item.nest_ids` of the window is in exactly one `data_json.batches[].nest_ids`; step items and edges exist per manifest step |
| 5 | data side: new data_groups next to the old ones, same layouts, `src` on the `schedule` data_tables: `plan_lane_items` (76 + 81 as one board, steps per page as `params` on the section), `plan_lane_items_filter` (82), `plan_inflow` (79), `plan_print_schedule` (75 on `schedule.get_lanes`); pages `nest-plan`, `production-plan` next to the current pages; frontend handoff §7 | delete the new data_groups and pages | both new pages load with the same labels and items as 76/81 |
| 6 | parallel run, at least a full week of nesting. Read-only compare script `sql/schedule/check_parallel.sql`: items per day/step/resource, nests per item, `summary.sqm` against `get_lane_item_work.sqm`, released items per day | n/a | differences explained or fixed |
| 7 | switch, one script: nav and pages point at the new data_groups; `crud_nest` drops the `batch_lane_item` block; `refresh_derived_data` drops `mock.generate_plan`; `log.upsert_state_shift_agg` reads `planned_output_sqm` from `schedule.lane_item` (§6.7); old data_groups archived to `archive/data_group/` | the same script mirrored: nav back, blocks back, data_groups restored; the `schedule` schema keeps running so nothing is lost | boards in use for a week without a rollback |
| 8 | cleanup, after one week on the new boards: `pg_dump -n action -t 'action.(plan|plan_lane|lane|lane_item|lane_item_dependency|lane_item_event|batch_lane_item|imposition_group_lane|imposition_group_lane_item|object)'` first; then drop those tables and the functions of §4 "replaces" and "not ported", `mock.material_impose_plan` if still there; repo files to `archive/sql/`; docs (`domain-model.md` §9, `database-erd.md`, `contracts/drag-and-drop.md`) on the new stand | restore from the dump | no function in `action` or `mock` reads the dropped tables; `pg_stat_statements` clean after a day |

Order: 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8. Steps 2 and 3 can be delivered together.
Step 0 blocks 3 (formula, manifest) and 4 (manifest).

## 6. decisions needed before step 1

1. **`legacy.nest.manifest_json`.** The column does not exist (checked live 12 Sep) and is
   added in step 0. The plan needs per scope: `item_code_paths`, `step`, `resource_paths` (the
   candidate machines), `production_impact_per_unit`, `config`. Proposal: `legacy.create_imposition_unit_manifest`
   also writes the aggregate to `legacy.nest.manifest_json`, same shape as
   `mapping.component_specs.manifest_json` plus `step` and `resource_paths` per scope
   (`step` from `lookup_step_category` via the option set, `resource_paths` from
   `production.resource_setting` of the group and step). Confirm, or give the shape you want.
2. **`lag_formula`.** You wrote `p_view_type`; the existing parameter is `p_view_code`
   (`nest-time-scale`, `print-day-scale`, vocabulary `lookup_timeline_views`). Proposal:
   `action.formula` row per view code, `formula_code = 'lag-' || view_code`, `formula_json`
   the rule list (`lag_in_seconds = next_start_lag_in_seconds` on a time scale, `lag_in_seconds = 0`
   on a day scale); `get_lane_items` serves the active version as `lag_formula`. It replaces
   `next_start_offset_in_seconds` on the lane read. `action.formula` is empty today and has no
   reader; a `action.get_formula(p_code, p_as_of)` comes with step 2 (same as-of rule as
   `catalog.get_formula`).
3. **Plan grain.** One `schedule.plan` per `(line_type, tenant_ids)`, no date, no steps. A lane
   hangs under one plan. The old reason for `plan_lane` (a foil board showing a sheet-hall
   printer) becomes a board filter on `resource_path`, not plan membership. OK?
4. **Names.** Decided 12 Sep: the old tables stay in `action`, the new ones go in a new schema.
   `plan.plan` doubles the word, so the schema is named after the activity and the table after
   the thing: `schedule.plan`, `schedule.lane`, `schedule.lane_item`. The alternative `plan.schedule`
   would make the top row "a schedule", while you call it a plan ("a plan for a day holds all the
   steps"), and `mock.material_print_schedule` already uses "schedule" for the weekly pattern that
   feeds it, so a "schedule" of a line type is a second meaning. Confirm `schedule`, or name it.
5. ~~`is_pinned`, `day_offset`~~ — decided 12 Sep: both gone. The drop contract loses
   `is_pinned_field`; Shift-drop on the new boards does nothing until a new gesture is defined.
6. **`production_orderlines`** on an item: written by the daily refresh for unreleased items
   (proposal), or computed at read time. Written keeps the board read a plain select and makes
   `summary` consistent with what is shown.
7. **Readers of `action.object`** that are not planning boards and need a new home before
   step 8: `action.get_resource_tickets` (maintenance tickets stored as pv2 actions),
   `log.upsert_state_shift_agg` and `log.get_resource_plan_batch` (planned output per shift),
   `legacy.get_batch_orderlines` (68, 69), `legacy.get_nest_planning` (67),
   `legacy.get_nest_status_by_bucket`. Proposal: the log side reads `schedule.lane_item` with
   `data_json.summary.sqm`; 67, 68, 69 and 56 go to the archive analysis; tickets get their
   own table (`mapping.crud_ticket` exists). Which of these are still in use?
8. **Copy semantics** of Ctrl-drop and split/merge on the board: a copy takes `data_json`
   along (own set) or becomes a successor with an edge (inherits)? Proposal: copy = own
   `data_json` (the contract says "copying the dragged row"), split/merge = edges, with a later
   `schedule.crud_lane_item_dependency` for the board.

## 7. frontend handoff (step 5, compact)

Only what changes in the configs; the layouts stay `timeline`.

- `src`: `get_impose_plan` / `get_resource_plan` → `get_lane_items`; `get_plan_lanes_*` → `get_lanes`;
  `get_impose_plan_inflow` → `get_inflow`
- `timeline_config.set_field`: `type` → `lane_item_type`; `set_order_field` → `type_json.sort_order` (unchanged)
- new field `lag_formula` (rule list, same evaluator as `type_json.formula`); `next_start_offset_in_seconds` is gone
- fields that were columns are now dot-notation: `data_json.material_id`, `data_json.imposition_group_id`,
  `data_json.nest_moment_code`, `data_json.fixed_group`, `data_json.no_split`, `data_json.i18n`,
  `data_json.summary.*`
- `group_by` of the material boards: `[data_json.imposition_group_id]` (was the lane); `group_title_fields` `[data_json.i18n]`
- `items.data_field` for the row's sub level: `data_json.batches`
- `drop`: `order_field sort_order`, `no_split_field data_json.no_split`, `within_fields ⊆ group_by`
  as before; `is_pinned_field` is gone (no Shift gesture); mutation goes to `schedule.crud_lane_item`
- pages: `nest-plan` (`steps [impose]`) and `production-plan` (`steps [print, coat, laminate, route, cut]`)
  as `params` on the sections, same as decided 6 Sep
