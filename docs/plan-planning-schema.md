# Plan: one resource planning in a new schema `schedule`

Date: 2026-09-12, revised after review the same day. Status: waiting for the second review;
one question open (§5).
Supersedes the open steps of `docs/plan-lane-model.md` and `archive/docs/plan-batch-lane-item.md`.

## 1. what it is

One kind of planning: resource planning. **A lane is one step on one resource_path on one
day.** What is planned hangs on the lane item as `data_json`. The material boards (75, 76)
group the same items by material or imposition group; they are not a separate lane kind.

Built in a new schema `schedule`, next to `action.*`. The old tables stay in `action` until
the cleanup. Every step is additive; the switch is one script with a mirrored rollback.

Contract: **every timing is in seconds**, no `_in_seconds` in a key: `start_offset`,
`end_offset`, `duration`, `lag`. Stored are `start_offset` and `end_offset`; `duration` and
`lag` are computed on the board with the `duration_formula` and `lag_formula` of the view
(`action.formula`, codes `duration-<view_code>` and `lag-<view_code>`).

Gone: `action.object` (pv2 planning), `plan.steps`, `plan.plan_date`, `plan_lane`,
`imposition_group_lane`, `imposition_group_lane_item`, `batch_lane_item` (into `data_json`),
`lane_item.is_pinned`, `source`/`source_ref`, `instance`, `day_offset`.

## 2. tables

```
schedule.plan                   the board scope: one row per line type and tenant set
  plan_id           bigint identity pk
  line_type         text not null
  tenant_ids        integer[] not null
  unique (line_type, tenant_ids)

schedule.lane                   one step on one resource on one day, of one kind
  lane_id           bigint identity pk
  plan_id           bigint not null references schedule.plan
  lane_date         date not null
  step              text not null            -- lookup_step_category
  resource_path     ltree not null           -- docs/resource-path.md
  lane_type         text not null default 'plan'   -- plan, progress, actual: lookup_lane_item_type
  sort_order        numeric not null default 0
  unique (plan_id, lane_date, step, resource_path, lane_type)
  index (lane_date), index (resource_path gist)

schedule.lane_item              the block of work on a lane; its kind is the lane's lane_type
  lane_item_id                bigint identity pk
  lane_id                     bigint not null references schedule.lane
  sort_order                  numeric not null
  start_offset                integer                        -- seconds from the start of the lane day
  end_offset                  integer                        -- seconds from the start of the lane day
  production_impact_per_unit  numeric                        -- seconds per unit of the work
  data_json                   jsonb                          -- null: inherited, see §3.3
  unique (lane_id, sort_order)

schedule.lane_item_dependency   many-to-many, from = predecessor
  from_lane_item_id bigint not null references schedule.lane_item on delete cascade
  to_lane_item_id   bigint not null references schedule.lane_item on delete cascade
  primary key (from_lane_item_id, to_lane_item_id), index (to_lane_item_id)

schedule.lane_item_event        append-only: one row per change of an item (§3.4)
  lane_item_event_id bigint identity pk
  lane_item_id       bigint not null references schedule.lane_item on delete cascade
  event_type         text not null            -- what happened: lookup_lane_item_event_type
  status             text not null            -- the status after the event: lookup_lane_item_status
  event_json         jsonb not null default '{}'  -- the changed keys, old and new value
  moved_by           integer                  -- contact, null for the system
  moved_at           timestamptz not null default now()
  index (lane_item_id, moved_at desc), index (moved_at)
```

`lane_item` is the current state of what is planned, `lane_item_event` is the history and
the only place a status lives: the item's status is the `status` of its newest event, its
status at a moment is the `status` of its newest event before that moment. No status column
on `lane_item`. Two vocabularies, both in `action.lookup`: `lookup_lane_item_status` (plan,
released, nested: where the item is) and the new `lookup_lane_item_event_type` (created,
moved, resized, split, copied, selected, placed, status-changed, deleted: what was done to
it). Every event carries the status after it; `placed` (nests placed) sets `nested`, the
release button writes `status-changed` with status `released`.

`action.formula`, `action.lookup`, `action.dates`, `action.non_working_times`,
`action.cutoff_time`, `action.week_team` stay where they are.

## 3. data_json

### 3.1 shape

```jsonc
{
  "material_id": 480,
  "imposition_group_id": 12,
  "nest_moment_code": "30",
  "fixed_group": "30",
  "no_split": false,
  "class_names": ["timeline-plan", "nest-moment-30"],
  "i18n": { "nl": { "title": "Dibond 3 mm", "text": "…" } },

  // the parameters that select the open work of this item (§5)
  "selection": { "material_id": 480, "nest_moment_code": "30" },

  // one object per distinct manifest.item_code_paths: the nests of that path, per batch
  "batches": [
    { "batch_id": 91234, "nest_ids": [2431178, 2431179],
      "manifest": { /* legacy.nest.manifest_json */ } }
  ],

  // one object per distinct manifest.item_code_paths: orderlines the planner selected (§5)
  "production_orderlines": [
    { "production_orderline_ids": [501, 502, 503],
      "manifest": { /* mapping.component_specs.manifest_json, scope imposition */ } }
  ],

  "summary": { "count": 7, "amount": 41, "sqm": 12.3,
               "rework_count": 1, "rework_amount": 2, "rework_sqm": 0.8 }
}
```

- `batches`, `production_orderlines`, `nest_ids`, `production_orderline_ids`, `class_names`
  are always arrays
- the object key inside `batches` and `production_orderlines` is the manifest's
  `item_code_paths`; the writer merges on it
- `material_id` and `imposition_group_id` may both be present; `imposition_group_id` is the
  material alias until the xbom groups land

### 3.2 who writes what

Two writers only.

| writer | writes |
|---|---|
| `schedule.generate_day(p_date, p_line_type)` | the plan row when missing; the lanes of the day (every step, every active machine of the line, `lookup_step_category` × `relation.resource`); one `plan` item per schedule row × nest moment code on the impose lane the row names, with `material_id`, `imposition_group_id`, `nest_moment_code`, `fixed_group`, `no_split`, `class_names`, `i18n`, `selection`. Re-run completes a day, touches nothing stamped |
| `schedule.crud_lane_item(p_param_json)` | everything else, set-based over `jsonb_array_elements`: board moves (`sort_order`, `start_offset`, `end_offset`, lane), copy, split, orderline selection, release, delete; **nest placement** (called by `legacy.crud_nest` with the nests as payload); the `summary` of the items it touched; and **one `lane_item_event` row per change**, written in the same statement (§3.4) |

There is no `schedule.crud_lane_item_event`: the board's release button posts to
`crud_lane_item` with `{"crud": "update", "data": {"lane_item_id": …, "status": "released"}}`.

Nest placement inside `crud_lane_item`: the nest lands on the impose item of its material,
moment and day (released item, first moment at or after `nested_at`); it is merged into the
`batches` object of its `item_code_paths` and batch. Then, per `step` and `resource_path` in
`legacy.nest.manifest_json`, one item on the lane `(lane_date, step, resource_path)` of the
same plan (created when missing) and an edge from the impose item. Those step items have
`data_json` null. A `nested` event is written.

Copy: a new item on the target lane with the same `data_json` minus `batches` and minus
`production_orderlines`: only the `selection` travels.

Split: the payload gives the original its new `end_offset`; the new item starts there and
ends where the original ended (original 7200 seconds long, payload cuts it at 1800: new item
5400). The nests follow the same ratio, whole batches first: the original keeps the largest batches that fit its share, one batch is split for the
remainder, everything else moves to the new item. Four batches 123 (10), 124 (8), 125 (6),
129 (12), share 1800/7200 of 36 = 9 nests: the original keeps 124 and one nest of 125; the
new item gets five of 125, 123 and 129. `no_split` refuses the split.

### 3.3 inherited data_json

A step item carries no `data_json`. `schedule.get_lane_item_data(p_lane_item_id)`, a helper
used only inside `get_schedule_lane_items`, walks `lane_item_dependency` from `to` to `from`
(recursive CTE) until it meets an item with `data_json`; a merge returns the union of the
`batches`. A split writes an own `data_json` on the item that deviates; from then on that
item is the source for its successors.

### 3.4 events: the day as it happened

Decided 12 Sep: `lane_item` stays a current-state row (stable `lane_item_id` for the
dependencies, the board and the nest placement; no newest-version filter in the reads; no
row copy per arriving nest). `lane_item_event` records every change, one small row each,
written by `crud_lane_item` in the same statement as the change.

| event_type | by | event_json |
|---|---|---|
| `created` | generate_day, copy, split | `{}` |
| `moved` | planner | `{"lane_id": {"from", "to"}, "sort_order": {"from", "to"}, "start_offset": {"from", "to"}}` — only the keys that changed |
| `resized` | planner | `{"end_offset": {"from", "to"}}` |
| `split` | planner | `{"end_offset": {"from", "to"}, "to_lane_item_id": …, "nest_ids_moved": [...]}` |
| `copied` | planner | `{"from_lane_item_id": …}` on the new item |
| `selected` | planner | `{"production_orderline_ids": {"from": [...], "to": [...]}}` |
| `placed` | crud_nest | `{"nest_ids": [...], "batch_id": …}` |
| `status-changed` | planner | `{}`: the `status` column says it all (the release button) |
| `deleted` | planner | the last `data_json` |

`status` on every event is the item's status after it. The reads take the status from the
newest event per item (lateral on the `(lane_item_id, moved_at desc)` index, as
`get_plan_lanes` does today); a `status-changed` row is how a status moves without anything
else changing. Replaying the events of an item backwards from its row gives its state at any
moment of the day. A full snapshot, if ever
needed, is a nightly insert-select of `lane_item` into a history table; not part of this plan.

## 4. reads

Both take `p_from date, p_until date` and build `v_dates datemultirange` from them; when the
frontend can send a datemultirange, `p_dates` replaces the pair without a change inside.
Both `stable`, `#variable_conflict use_column`.

| function | replaces | returns |
|---|---|---|
| `schedule.get_schedule_lane(p_from, p_until, p_line_type, p_tenant_ids, p_steps, p_types)` | `action.get_plan_lanes_imposition_group`, `action.get_plan_lanes_resource` | one row per lane in `v_dates`: `lane_id`, `lane_date`, `step`, `resource_path`, `lane_type`, `type_json`, `resource_uid`, `resource_name`, `tenant_id`, `sort_order`, `param_json`, `formula` (from `production.resource_setting`) |
| `schedule.get_schedule_lane_items(p_from, p_until, p_line_type, p_tenant_ids, p_steps, p_types, p_view_code)` | `action.get_resource_plan`, `mock.get_impose_plan` | one row per item on those lanes: the columns of §2 with the lane's `lane_type` and `type_json`, `status`, `data_json` own or inherited, `class_names`, `summary`, `duration_formula` and `lag_formula` (the active `action.formula` rows `duration-<view_code>` and `lag-<view_code>`, yours); progress and actual lanes follow in step 3 |

79 (inflow) keeps `mapping.get_production_orderline_manifest` and gets `lane_item_id` from
`schedule.lane_item` instead of `action.lane_item`: a `src` change, no new function.

Not ported: `crud_object`, `sync_pv2_batch_items`, `get_plan_timeline`,
`crud_material_impose_plan`, `generate_production_plan`, `crud_lane_item_event` (folded
into `crud_lane_item`). The log readers of `action.object`
stay as they are; the new schedule is not logged for now.

## 5. open: orderlines on an item

500 to 1000 orderlines an hour make any stored list or stored summary of the open work stale
within minutes. Advice:

- `data_json.selection` is always there (the generator writes it): the parameters that select
  the open work, the same parameters `get_lane_item_work` takes today.
- `data_json.production_orderlines` only exists when the planner selected orderlines on the
  board; `crud_lane_item` stores that list (a few times a day). An item with a list shows the
  list, an item without shows the selection: one rule in the read, `coalesce(list, selection)`.
- `summary` of the **open work is computed in the read** over that set, as board 76 does now;
  `crud_lane_item` stores in `data_json.summary` only what is fixed: the nests in `batches` and
  the selected orderlines. So a stored summary is never stale, and an item without batches or
  selection has no stored summary at all.

If you would rather have one stored `summary` for everything, the daily refresh would have to
recompute every unreleased item, and the board would still be hours behind on new orders.

## 6. steps

Each step: `sql/update_schedule_<nn>_<name>.sql` and `..._down.sql`, assembled from the
object files in `sql/schedule/` (one file per table and function, as everywhere in the repo).
Nothing touches `action.*` before step 4. I deliver, you run, I wait.

**Delivered 12 Sep, waiting to be run:** step 0 (`update_schedule_00_nest_manifest.sql`) and
step 1 (`update_schedule_01_schema.sql`). Step 0 creates `catalog.item_group_resource`
(`sql/catalog/item_group_resource.sql`: item group → machine or branch path, the step is the
third label) when it is missing; the steps and machines of a nest come from the item groups
of its xbom rows through that table, so a nest whose groups have no rows yet gets an empty
`steps[]`; rerun the backfill block after filling it. Step 1's `get_schedule_lane_items` serves
the plan rows; progress and actual rows come with step 3. The lag rows go in `action.formula`
as `formula_code = 'lag-<view_code>'`, `formula_json` the rule list.

| step | what | rollback | done when |
|---|---|---|---|
| 0 | `alter table legacy.nest add column manifest_json jsonb`; `legacy.create_imposition_unit_manifest` writes it per scope: `item_code_paths`, `step`, `resource_paths`, `production_impact_per_unit`, `config`; backfill the nest window; your lag rows in `action.formula` per view code | drop the column, redeploy the function | every nest of the window has `step` and `resource_paths` per scope |
| 1 | schema `schedule`, the five tables of §2; lookup `lookup_lane_item_event_type` in `action.lookup` (`json/lookup/action/lookup_lane_item_event_type.json`, i18n titles by Cees); the two reads of §4 and `get_lane_item_data`; `site.data_table` rows | `drop schema schedule cascade`, delete the lookup and the data_table rows | reads run on the empty schema without error |
| 2 | `generate_day` and `crud_lane_item`; backfill today + 14 days per line type in a DO block; `site.refresh_derived_data` calls `generate_day` **next to** `mock.generate_plan`; `legacy.crud_nest` calls `crud_lane_item` **next to** its `batch_lane_item` block; backfill the nests of the window | remove both calls, drop the functions, truncate the schema | per day, line type and step: the same items as `action`; every `batch_lane_item.nest_ids` of the window is in exactly one `batches[].nest_ids`; step items and edges per manifest step |
| 3 | new data_groups next to the old ones: `schedule_lane_items` (76 and 81 as one board, steps per page as section `params`), `schedule_lane_items_filter` (82), `schedule_print_schedule` (75), 79 on the new `src`; pages `nest-schedule` and `production-schedule` next to the current pages; handoff §7. Then a week of parallel run with the read-only compare script `sql/schedule/check_parallel.sql` | delete the new data_groups and pages | the new pages show the same labels and items as 76 and 81; differences explained |
| 4 | switch: nav and pages to the new data_groups; `crud_nest` drops the `batch_lane_item` block; `refresh_derived_data` drops `mock.generate_plan`; old data_groups to `archive/data_group/` | the mirrored script; the schema keeps running meanwhile | a week on the new boards |
| 5 | cleanup after that week: `pg_dump` of the ten old tables first, then drop them and the functions they served; `mock.material_impose_plan` if still there; repo files to `archive/sql/`; docs on the new stand | restore from the dump | no function in `action` or `mock` reads the dropped tables |

## 7. decided 12 Sep

1. `legacy.nest.manifest_json` as in step 0.
2. `lag_formula` from `action.formula`, keyed on `p_view_code`; Cees writes the rows.
   No `_in_seconds` anywhere; seconds are the contract.
3. One `schedule.plan` per `(line_type, tenant_ids)`; a lane hangs under one plan.
4. Schema `schedule`; the old tables stay in `action`.
5. `is_pinned` and `day_offset` are gone; the drop contract loses `is_pinned_field`.
7. The log side keeps reading `action.object`; the schedule is not logged for now.
8. Copy and split as in §3.2.

## 8. frontend handoff (step 3, compact)

- `src`: `get_impose_plan` / `get_resource_plan` → `get_schedule_lane_items`; `get_plan_lanes_*` → `get_schedule_lane`
- params: `p_from`, `p_until` (dates) on both reads; the time scale in the header spans them
- `timeline_config.set_field` `type` → `lane_type` (on the lane and on every item row); `set_order_field` `type_json.sort_order` unchanged
- `offset_field start_offset`, new `end_offset_field end_offset`; seconds, no unit in the key
- `duration` is no column: `evaluate {formula_field: duration_formula, params_field: …}` yields it
  per row, the way `lag_formula` yields `lag` for the chaining
- new field `lag_formula` (rule list, same evaluator as `type_json.formula`, yields `lag`);
  `next_start_offset_in_seconds` is gone
- dot-notation fields: `data_json.material_id`, `data_json.imposition_group_id`,
  `data_json.nest_moment_code`, `data_json.fixed_group`, `data_json.no_split`,
  `data_json.class_names`, `data_json.i18n`, `data_json.summary.*`
- `group_by` of the material boards `[data_json.imposition_group_id]`, `group_title_fields` `[data_json.i18n]`
- `items.data_field data_json.batches`
- `drop`: `order_field sort_order`, `no_split_field data_json.no_split`; `is_pinned_field` gone;
  mutation to `schedule.crud_lane_item`, plus `crud: split` with the new `end_offset` and
  `crud: create` for a copy
- release button: data_table `crud_lane_item_event` → `crud_lane_item` with `status: released`
  in `data`
- pages `nest-schedule` (`steps [impose]`) and `production-schedule`
  (`steps [print, coat, laminate, route, cut]`) as section `params`
