# Schedule: the resource planning in schema `schedule`

Last revised 16 Sep 2026. The one planning document: the model, the stand and what is open.
Merges the lane model of 5 Sep, the batch model of 9 Sep and the schema and template plans of
12/14 Sep. Branch `worktree-plan-schema-plan`, worktree `.claude/worktrees/plan-schema-plan`.

Ground rule: **the old planning keeps working while the new one is built** (§9). The functions
of `mock`, `action`, `legacy` and `mapping` stay as they are; `schedule` gets its own. Old
functions were touched once, for the tenant key (§4.4).

## 1. what it is

One kind of planning: resource planning. **A lane is one step on one resource_path on one
day.** What is planned hangs on the lane item as `data_json`. The material boards group the
same items by material or imposition group; they are not a separate lane kind. A resource is a
machine or software (the imposition step is software); the word is resource, never machine.

Built in the schema `schedule`, next to `action.*`. Every step is additive; the switch is one
script with a mirrored rollback.

**Timing contract: every timing is in seconds**, no `_in_seconds` in a key — `start_offset`,
`end_offset`,  `duration`, `lag`. Stored are `start_offset` and `end_offset`;  `duration` and `lag` are computed on the board with the `duration_formula` and `lag_formula` of the view
(`schedule.formula`, codes `duration-<view_code>` and `lag-<view_code>` read by `schedule.get_formula`). The server calculates and the board recalculates if lane_items are dragged. A run anchors the day with its `start_offset` from the rules; every item that follows on the lane starts at `start_offset + lag` of the item before it, the leads (`lead_in`, `lead_out`) are parameters of the lag formula. A job at 12:00 of 900 seconds puts the next job at 12:15.
## 2. where we are

Ran live: step 0 (nest manifest), 1 (schema), 1b (`item_group_resource` as tenant side),
1c (formula into `schedule`), 1d (the planning template) and the nest waste script. Checked
live 14 Sep after the run: tenant key, 66 schedule entries, xbom clean, leads gone, nine
functions on the new signatures, nest waste summary in the data_group.

Next: **step 2**, `schedule.generate_day` and `schedule.crud_lane_item` (§6), reading
`rules_json.schedules[]`. Nothing of step 2 is written yet. The step table is §10.

Working notes: object files per table and function live in `sql/schedule/` and `sql/legacy/`;
update scripts are assembled from them. Read-only checks run through the SQLTools driver;
everything that writes is a script for Cees.

## 3. tables

```
schedule.plan                   the board scope: one row per line type and tenant set
  plan_id           bigint identity pk
  line_type         text not null
  tenant_ids        integer[] not null
  unique (line_type, tenant_ids)

schedule.lane                   one step on one resource on one day
  lane_id           bigint identity pk
  plan_id           bigint not null references schedule.plan
  lane_date         date not null
  step              text not null            -- lookup_step_category
  resource_path     ltree not null           -- docs/resource-path.md
  sort_order        numeric not null default 0
  unique (plan_id, lane_date, step, resource_path)
  index (lane_date), index (resource_path gist)

schedule.lane_item              the block of work on a lane, of one kind
  lane_item_id                bigint identity pk
  lane_id                     bigint not null references schedule.lane
  lane_item_type              text not null default 'plan'   -- plan, progress, actual: lookup_lane_item_type
  sort_order                  numeric not null
  start_offset                integer                        -- seconds from the start of the lane day
  end_offset                  integer                        -- seconds from the start of the lane day
  production_impact_per_unit  numeric                        -- seconds per unit of the work
  lead_in                     integer                        -- setup seconds, from item_group_resource.item_group_json
  lead_out                    integer                        -- teardown seconds, same source
  data_json                   jsonb                          -- null: inherited, see §5.3
  created_at, updated_at      timestamptz not null default now()
  unique (lane_id, sort_order)

schedule.lane_item_dependency   many-to-many, from = predecessor
  from_lane_item_id bigint not null references schedule.lane_item on delete cascade
  to_lane_item_id   bigint not null references schedule.lane_item on delete cascade
  primary key (from_lane_item_id, to_lane_item_id), index (to_lane_item_id)

schedule.lane_item_event        append-only: one row per change of an item (§5.4)
  lane_item_event_id bigint identity pk
  lane_item_id       bigint not null references schedule.lane_item on delete cascade
  event_type         text not null            -- what happened: lookup_lane_item_event_type
  status             text not null            -- the status after the event: lookup_lane_item_status
  event_json         jsonb not null default '{}'  -- the changed keys, old and new value
  moved_by           integer                  -- contact, null for the system
  moved_at           timestamptz not null default now()
  index (lane_item_id, moved_at desc), index (moved_at)

schedule.formula                the duration and lag rules per view code (was action.formula)
  formula_code      lag-<view_code>, duration-<view_code>; read by schedule.get_formula
```

`lane_item` is the current state of what is planned, `lane_item_event` is the history and the
only place a status lives: the item's status is the `status` of its newest event. No status
column on `lane_item`. Two vocabularies in `schedule.lookup`: `lookup_lane_item_status` (plan,
released, nested) and `lookup_lane_item_event_type` (created, moved, resized, split, copied,
selected, placed, status-changed, deleted).

The formules for the schedule are in schedule.formula. The dates are in schedule.dates. 

Tenant side of the global catalog: `catalog.item_group` and `catalog.item` are global;
`catalog.item_group_resource` (`tenant_id`, `item_group_code`, `resource_path`, generated
`step`, `item_group_json` overrides) says which resources of a tenant do the work of an item
group; it is the source of the steps and candidate resources in `legacy.nest.manifest_json`.
`item_group_json` also carries the setup and teardown seconds of the work on that resource,
`lead_in` and `lead_out`: one row per `resource_path`, so impose, print and cut each have their
own. `generate_day` stamps them onto the lane item.

## 4. the planning template: `legacy.imposition_group.rules_json`

### 4.1 the table

The xbom is global. `legacy.imposition_group` is **per tenant**: `tenant_id`, primary key
`(tenant_id, imposition_group_id)`, unique `(tenant_id, item_code_paths)`, the parent foreign key on `(tenant_id, parent_imposition_group_id)`. The same paths carry the same
`imposition_group_id` in every tenant that plans them
(`legacy.get_imposition_group(p_option_codes, p_tenant_id default 1)` reuses the id the paths have elsewhere), so the id stays the `material_id` alias for every tenant. Bad Hersfeld got
its 15 rows from the mock schedule. `imposition_group_json` is renamed `rules_json`.

### 4.2 `rules_json`

One tenant per row, so no `tenant_id` inside. Seconds from the start of the lane day. A list
is always an array.

```jsonc
{
  "delivery_hours": 72,          // shown: the delivery time the interval allows
  "min_delivery_hours": 48,      // shown: the fastest delivery time
  "unit_threshold": 1,           // orders up to this amount are one unit class (out of the xbom)

  // the formats of the group, width and max_height in cm. A fallback for as long as the
  // waste of a format is not measured yet: an estimate, refreshed weekly from the historic
  // values of the last months. The waste differs per size.
  // imposition_sqm = (1 - waste_percentage) * width * max_height / 10000
  "waste": [
    { "width": 205.1, "max_height": 305, "waste_percentage": 0.211, "imposition_sqm": 4.94 }
  ],

  "schedules": [                 // one entry per resource
    {
      "resource_path": "dk.sheet.impose.350.uv.durst.p5-350hs",
      "sort_order": 1200,        // the rank on the boards
      "intervals": [             // the production days, they add up
        {
          "interval_start_date": "2026-06-04",
          "interval_days": 2,    // every n working days from the start (action.get_interval_dates)
          "runs": [              // one lane item per run, in day order
            // target: how much height the run aims to fill, in cm, the shape of
            // catalog.item.item_json.specs
            { "nest_moment_code": "48",  "start_offset": 78300,
              "target": { "min_height": 1600, "max_height": 2400 } },
            { "nest_moment_code": "48+", "start_offset": 78300 }
          ]
        },
        {
          "interval_start_date": "2026-06-05",
          "interval_days": 2,
          "runs": [
            // a run that may move: start_offset is where it is planned,
            // start_offset_min / start_offset_max the window; without them it is fixed
            { "nest_moment_code": "72", "start_offset": 43200,
              "start_offset_min": 39600, "start_offset_max": 50400 }
          ]
        }
      ]
    }
  ]
}
```

- `nest_moment_code` names the class a run collects; `delivery_hours`, `day_offset` and
  `fixed_group` of the class stay in `lookup_nest_moments`. The lookup's `nest_time` /
  `print_time` are not used by the new schedule but stay until step 5 (nine old functions
  read them).
- the line of an entry is the second label of `resource_path`; no `line`, no
  `production_line_id` (sizes come from `catalog.item.item_json.specs` of the material item
  of the first path, not from `mapping.material_production_line`).
- no `print_time`: the print item starts at `start_offset + lag` of the impose item.
- `target` says how much height a run aims to fill: `min_height` the smallest it is worth
  starting, `max_height` the most it takes. Same four properties and the same cm as
  `catalog.item.item_json.specs` (§4.5); without a `target` a run is unbounded.
- no leads here: `lead_in` and `lead_out` live in
  `catalog.item_group_resource.item_group_json`, per `resource_path`, so impose, print and cut
  each have their own (§3).
- the migration wrote 188 roots and 66 entries (the mock rows with codes and an impose
  resource; 181 fixed runs with the lookup's start offsets). Rows without codes or resource
  path got no entry; the two materials without a group row were skipped (§2).

### 4.3 what moved out

`catalog.xbom.config_json` lost `units_threshold` (230 rows, all 1) and `delivery_hours` (4
liquid finishes, 72); 
`mapping.update_component_specs_manifest` no longer writes `units_threshold` into
`manifest_json.imposition.config`; nothing in the database read it there.

### 4.4 the old readers and the tenant

Eight old functions join the group; each passes the tenant along, Dokkum (1) when it has none:

| function | tenant from |
|---|---|
| `legacy.get_imposition_group(p_option_codes, p_tenant_id default 1)` | the caller |
| `legacy.create_nest_manifest` | the nest's production line (`nest_json.production_line_id` -> `relation.production_line.tenant_id`) |
| `legacy.get_nest_waste_ranges` | the same; also returns `tenant_id`, `tenant_name` |
| `mapping.get_materials` | `material_print_schedule.tenant_id` |
| `mapping.get_production_orderline_detail` | `p_tenant_ids`, none asked is `{1}` |
| `mapping.get_production_orderline_manifest` | `p_tenant_ids[1]` when exactly one is asked, else 1 |
| `mapping.update_component_specs_manifest` | `component_specs.production_company_id` -> `site.tenant` |
| `action.get_plan_lanes_imposition_group` | `material_print_schedule.tenant_id` of the row |

### 4.5 the sizes: `catalog.item.item_json.specs`

The formats of a group come from the material item of the first path, not from
`mapping.material_production_line`. Roll and sheet use the same four properties, all in cm --
`width`, `min_height`, `max_height`, `supply_unit_height` -- and nothing branches on
material type. A run's `target` (§4.2) is the same shape: `min_height` and `max_height`.

How much a supply unit holds, what a valid used amount is and what is left:
`docs/supply-handling.md`.

## 5. data_json

### 5.1 shape

```jsonc
{
  "material_id": 480,
  "imposition_group_id": 12,
  "nest_moment_code": "30",
  "fixed_group": "30",
  "no_split": false,
  "class_names": ["timeline-plan", "nest-moment-30"],
  "i18n": { "nl": { "title": "Dibond 3 mm" } },   // catalog.item.description of the first path, one text for every language

  // the parameters that select the open work of this item (§12)
  "selection": { "material_id": 480, "nest_moment_code": "30" },

  // one object per distinct manifest.item_code_paths: the nests of that path, per batch
  "batches": [
    { "batch_id": 91234, "nest_ids": [2431178, 2431179],
      "manifest": { /* legacy.nest.manifest_json */ } }
  ],

  // one object per distinct manifest.item_code_paths: orderlines the planner selected (§12)
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
  material alias

### 5.2 the same orderlines on every resource

An orderline is not bound to a resource before it is nested: when a group has runs on two
resources, both lane items show the same open orderlines (the same `selection`). The nest
decides: the batch hangs on the resource that was picked, and the orderlines of that batch go
with it.

### 5.3 inherited data_json

A step item carries no `data_json`. `schedule.get_lane_item_data(p_lane_item_id)`, used only
inside `get_schedule_lane_items`, walks `lane_item_dependency` from `to` to `from` until it
meets an item with `data_json`; a merge returns the union of the `batches`. A split writes an
own `data_json` on the item that deviates.

### 5.4 events: the day as it happened

`lane_item` stays a current-state row; `lane_item_event` records every change, one small row
each, written by `crud_lane_item` in the same statement as the change.

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

The reads take the status from the newest event per item; a `status-changed` row is how a
status moves without anything else changing.

## 6. writers

Two writers only (step 2, next).

| writer | writes |
|---|---|
| `schedule.generate_day(p_date, p_line_type)` | the plan row when missing; the lanes of the day (every step, every active resource of the line, `lookup_step_category` × `relation.resource`); per group of the plan's tenants, per `rules_json.schedules[]` entry whose `intervals[]` make `p_date` a production day (`action.get_interval_dates`), per run one `plan` item on the lane `(p_date, impose, resource_path)` with `start_offset` from the run, `lead_in` / `lead_out` from `item_group_resource.item_group_json` of the resource (absent = 0), `sort_order` from the entry, `data_json` with `imposition_group_id`, `material_id` (alias), `nest_moment_code`, `fixed_group` (lookup), `no_split`, `class_names`, `i18n` (item description), `selection`. Re-run completes a day, touches nothing stamped |
| `schedule.crud_lane_item(p_param_json)` | everything else, set-based over `jsonb_array_elements`: board moves (`sort_order`, `start_offset`, `end_offset`, lane), copy, split, orderline selection, release, delete; **nest placement** (called by `legacy.crud_nest` with the nests as payload); the `summary` of the items it touched; and **one `lane_item_event` row per change**, written in the same statement |

There is no `crud_lane_item_event`: the release button posts to `crud_lane_item` with
`{"crud": "update", "data": {"lane_item_id": …, "status": "released"}}`.

Nest placement: the nest lands on the impose item of its group, moment and day (released item,
first run at or after `nested_at`) on the resource that was picked; it is merged into the
`batches` object of its `item_code_paths` and batch. Then, per `step` and `resource_path` in
`legacy.nest.manifest_json`, one item on the lane `(lane_date, step, resource_path)` of the
same plan (created when missing) and an edge from the impose item. Those step items have
`data_json` null. A `nested` event is written.

Copy: a new item on the target lane with the same `data_json` minus `batches` and minus
`production_orderlines`: only the `selection` travels.

Split: the payload gives the original its new `end_offset`; the new item starts there and ends
where the original ended. The nests follow the same ratio, whole batches first: the original
keeps the largest batches that fit its share, one batch is split for the remainder, everything
else moves. `no_split` refuses the split.

## 7. reads

Both take `p_from date, p_until date` and build a `datemultirange`. Both `stable`,
`#variable_conflict use_column`. Step 1 delivered them for plan rows; progress and actual rows
come with step 3.

| function | replaces | returns |
|---|---|---|
| `schedule.get_schedule_lane(p_from, p_until, p_line_type, p_tenant_ids, p_steps)` | `action.get_plan_lanes_imposition_group`, `action.get_plan_lanes_resource` | one row per lane: `lane_id`, `lane_date`, `step`, `resource_path`, `resource_uid`, `resource_name`, `tenant_id`, `tenant_name`, `sort_order`, `param_json`, `formula` (from `production.resource_setting`). No kind: that sits on the item |
| `schedule.get_schedule_lane_items(…, p_view_code)` | `action.get_resource_plan`, `mock.get_impose_plan` | one row per item: the columns of §3 with its own `lane_item_type` and `type_json` (`p_types` filters on it), `status`, `data_json` own or inherited, `class_names`, `summary`, `duration_formula` and `lag_formula`; to add in step 2/3: `unit_threshold`, `delivery_hours`, `min_delivery_hours` of the group for the labels, the sizes from `catalog.item.item_json.specs` |

To come: the successor of `mock.get_print_schedule` (75) on `rules_json` intervals and runs; a
nest-date function for the new schema (§8). 79 (inflow) keeps
`mapping.get_production_orderline_manifest` and gets `lane_item_id` from `schedule.lane_item`.

Not ported: `crud_object`, `sync_pv2_batch_items`, `get_plan_timeline`,
`crud_material_impose_plan`, `generate_production_plan`, `crud_lane_item_event`. The log readers
of `action.object` stay; the new schedule is not logged for now.

## 8. the nest date of an orderline

Today `mapping.calculate_nest_date(p_order_date, p_production_hours, p_tenant_ids)` takes the
working day by rank (48 hours and faster: the first working day, 72: the second, 96: the third)
and the one `nest_time` of the code in the lookup; it knows no group, resource or interval, and
it stays that way for the old planning. The new `schedule` function takes the group of the
orderline and its tenant and reads the runs in `rules_json`:

1. The production day is the first working day by rank that is a production day of the group's
   interval; when the ranked day is no production day, the nest date moves to the next
   production day.
2. The nest date is the first run of the orderline's code on that day over every resource of
   the group (the orderline is not bound to a resource before it is nested, §5.2). Two runs of
   one code on one day: the first.

## 9. the old planning, still running

Live until step 4 (boards) and step 5 (drop). It is the source of the migrated template and of
the parallel-run comparison, so it stays readable here.

**Tables in `action`.** `plan` (`plan_date`, `type`, `steps text[]`, `line_type`, `tenant_ids`)
with two types: `material-resource-plan` from `mock.generate_plan` and `production-plan` from
`mock.generate_production_plan`. `lane` (`lane_date`, `step`, `resource_path`), `plan_lane`
(which boards show a lane, in which order), `imposition_group_lane` (the group lane of a
material), `lane_item` (`sort_order`, `start_offset_in_seconds`, `duration_in_seconds`,
`fixed_group`, `is_pinned`, `no_split`, `level`, `instance`, `nest_moment_code`, `source`,
`source_ref`), `lane_item_dependency`, `lane_item_event`, `object` (the pv2 planning that the
shift builder still reads).

**`action.batch_lane_item`** (9 Sep) holds the nests: one row per batch on a lane item with
`nest_ids`, `batch_id` null for what is not batched, one null row per item, one row per item on
every step other than impose. `legacy.crud_nest` places a nest on the item released last at or
before `nested_at` and moves it into the batch row when it gets a `batch_id`. In the new schema
this becomes `data_json.batches` (§5.1).

**The template.** `mock.material_print_schedule` per material: `interval_days`,
`interval_start_date`, `delivery_hours`, `nest_moment_codes`, `resource_uids`, `tenant_id`,
the impose path and the rank. `mock.generate_plan` stamps a day from it — one item per nest
moment on the interval dates — and runs 14 working days ahead in `site.refresh_derived_data`.
This table is the source of `rules_json.schedules[]` and goes in step 5.

**Testing phase** (9 Sep): every impose item without a release is released at the local midnight
of its lane date, daily in `site.refresh_derived_data`, until the planner releases from the board.

**The boards.** 75 print_schedule (`mock.get_print_schedule`, computed cards, no lane items),
76 impose_plan and 78 impose_resource_plan (`mock.get_impose_plan`), 81 production_resource_plan
(`mock.get_production_schedule`), 79 impose_plan_inflow (`mapping.get_production_orderline_manifest`).
Labels come from `action.get_plan_lanes_imposition_group` (75, 76) and
`action.get_plan_lanes_resource` (78, 81). The pv2 read chain behind them is
`docs/legacy-planning-chain.md`.

**Gone in the new schema**: `action.object` (pv2 planning), `plan.steps`, `plan.plan_date`,
`plan_lane`, `imposition_group_lane`, `imposition_group_lane_item`, `batch_lane_item` (into
`data_json`), `lane_item.is_pinned`, `source` / `source_ref`, `instance`, `day_offset`,
`mock.material_print_schedule` (into `rules_json`).

## 10. steps

Each step: `sql/update_schedule_<nn>_<name>.sql` and `..._down.sql`, assembled from the object
files in `sql/schedule/`, `sql/legacy/`, `sql/mapping/`. Nothing touches `action.*` before
step 4. I deliver, Cees runs, I wait.

| step | what | status |
|---|---|---|
| 0 | `legacy.nest.manifest_json` (`item_code_paths`, `steps[]` with `step`, `resource_paths`, `production_impact_per_unit`, `config`), backfill `legacy.backfill_nest_manifest` (a commit per 200 nests) | ran 13 Sep |
| 1 | schema `schedule`, the five tables, lookup `lookup_lane_item_event_type`, the two reads and `get_lane_item_data`, `site.data_table` rows | ran 13 Sep |
| 1b | `catalog.item_group_resource` as tenant side (`tenant_id`, `item_group_json`), `lane_item.lead_in` / `lead_out`, `created_at`, `updated_at` | ran 13 Sep |
| 1c | `action.formula` into `schedule.formula`, `schedule.get_formula`; `production.formula` twin | ran 13 Sep |
| 1d | the planning template (§4): `update_planning_template.sql`, then `update_nest_waste_total_row.sql` (nest waste board, `docs/plan-nest-waste-ranges.md`) | ran 14 Sep |
| 1g | the kind of the work moves from the lane to the item: `lane.lane_type` becomes `lane_item.lane_item_type`, the lane unique key loses it, both reads follow: `sql/update_schedule_1g_lane_item_type.sql` | delivered 16 Sep, Cees runs |
| 2 | `generate_day` and `crud_lane_item` (§6); backfill today + 14 days per line type in a DO block; `site.refresh_derived_data` calls `generate_day` **next to** `mock.generate_plan`; `legacy.crud_nest` calls `crud_lane_item` **next to** its `batch_lane_item` block; backfill the nests of the window. Done when per day, line type and step the items match `action`, every `batch_lane_item.nest_ids` of the window is in exactly one `batches[].nest_ids`, step items and edges per manifest step | next |
| 3 | new data_groups next to the old ones: `schedule_lane_items` (76 and 81 as one board, steps per page as section `params`), `schedule_lane_items_filter` (82), `schedule_print_schedule` (75, sizes from `catalog.item`), 79 on the new `src`; the nest-date function (§8); pages `nest-schedule` and `production-schedule` next to the current pages; handoff §13; a week of parallel run with `sql/schedule/check_parallel.sql` | |
| 4 | switch: nav and pages to the new data_groups; `crud_nest` drops the `batch_lane_item` block; `refresh_derived_data` drops `mock.generate_plan`; old data_groups to `archive/data_group/` | |
| 5 | cleanup after that week: `pg_dump` of the old tables first, then drop them and the functions they served (`mock.material_print_schedule`, the eight old readers of §4.4 as far as they die, `production.get_nest_moment_instances`); `lookup_nest_moments` loses `nest_moments[]` (`nest_time`, `print_time`); repo files to `archive/sql/`; docs on the new stand | |

The rollback scripts of 1d are `update_planning_template_down.sql` and
`update_nest_waste_total_row_down.sql`. A second run of the template script fails on its first
statement (`tenant_id` exists) and rolls back; that is harmless.

## 11. decided

**16 Sep** — the kind of the work (plan, progress, actual) belongs to the item, not
the lane: `lane_item.lane_item_type`, so one lane carries every kind and the board draws
them on the same axis; a lane is one step on one resource on one day and nothing more. The
setup and teardown seconds move back to `catalog.item_group_resource.item_group_json`, per
`resource_path`, because impose, print and cut differ — out of `rules_json`. The waste array
is a fallback estimate, refreshed weekly from the last months, and `imposition_sqm` now has the
waste in it. A run carries a `target` (`min_height`, `max_height`, cm) in the shape of
`catalog.item.item_json.specs`.

**12 Sep** — `legacy.nest.manifest_json` as in step 0; `lag_formula` from `schedule.formula` per
`p_view_code`, seconds are the contract; one `schedule.plan` per `(line_type, tenant_ids)`;
schema `schedule`, the old tables stay in `action`; `is_pinned` and `day_offset` gone; the log
side keeps reading `action.object`; copy and split as in §6.

**13 Sep** — `catalog.item_group` and `catalog.item` global, `catalog.item_group_resource` the
tenant side; `lane_item` has `lead_in`, `lead_out`, `created_at`, `updated_at`.

**14 Sep** — `tenant_id` a regular column on `legacy.imposition_group`, key
`(tenant_id, imposition_group_id)`, same id per tenant; `rules_json` with `delivery_hours` (what
the interval allows) and `min_delivery_hours` (fastest) on the root, both shown, neither
derivable from the codes or the interval (checked: 46 and 62 of 103 rows matched); the leads per
schedule entry, dropped from `item_group_resource`; `unit_threshold` and the delivery times out
of the xbom; the lookup times unused by the new schema, the old functions untouched until
step 5; the board evaluates duration and lag; only mock rows with codes and a resource path
became a schedule entry; the title of a group is `catalog.item.description` of the first path;
sizes from `catalog.item.item_json.specs`; the interval through `action.get_interval_dates`; a
resource, never a machine; the nest date rule of §8; the same orderlines on every resource (§5.2).

**Earlier, still standing** — `lane_item_dependency` is many-to-many, `from` is the predecessor
and the reads walk `to → from` upwards; `imposition_group_id` stays the `material_id` alias
until the xbom groups are there; the nest moment travels with the item as a value, not derived
from a counter (a copy is one more moment of the same code); the stamped day is the truth, the
template is a template — a move on the board never writes back.

## 12. open

- **Orderlines on an item.** 500 to 1000 orderlines an hour make a stored list stale within
  minutes. Advice: `data_json.selection` is always there (the generator writes it);
  `production_orderlines` only when the planner selected orderlines; `summary` of the open work
  is computed in the read over `coalesce(list, selection)`, the stored `summary` holds only what
  is fixed (nests in `batches`, selected orderlines).
- **The leads themselves.** Where they live is settled (`item_group_resource.item_group_json`,
  per `resource_path`), but no row carries one yet; `generate_day` reads an absent lead as 0.
  Cees fills them, for impose, print and cut.
- **Nest waste board grouping.** The board groups by material only; a material nested in both
  tenants shows one header with the rows of both tenants. A tenant level is a `group_by` change
  not made.
- **Date parameters.** `docs/plan-date-parameters.md` proposes `p_dates datemultirange` and
  `p_at` instead of from/until/look_back/look_ahead across the whole chain. Not started; the new
  reads take `p_from` / `p_until` for now.

## 13. frontend handoff (step 3, compact)

- `src`: `get_impose_plan` / `get_resource_plan` → `get_schedule_lane_items`; `get_plan_lanes_*` → `get_schedule_lane`
- params: `p_from`, `p_until` (dates) on both reads; the time scale in the header spans them
- `timeline_config.set_field` `type` → `lane_item_type` (on the item row; the lane has no kind of its own any more); `set_order_field` `type_json.sort_order` unchanged
- `offset_field start_offset`, new `end_offset_field end_offset`; seconds, no unit in the key
- `duration` is no column: `evaluate {formula_field: duration_formula, params_field: …}` yields it
  per row; `lag_formula` yields `lag` for the chaining, with `lead_in` and `lead_out` of the item
  among the params; the next item starts at the previous `start_offset + lag`
- a run with `data_json.start_offset_min` / `start_offset_max` may be dragged inside that window
  only; without them it is fixed
- `next_start_offset_in_seconds` is gone
- dot-notation fields: `data_json.material_id`, `data_json.imposition_group_id`,
  `data_json.nest_moment_code`, `data_json.fixed_group`, `data_json.no_split`,
  `data_json.class_names`, `data_json.i18n`, `data_json.summary.*`
- `group_by` `[tenant_id, resource_path]` on every board, plus `data_json.imposition_group_id` on the print_schedule only; `group_title_fields` in the same order, the group title from `data_json.i18n`
- `items.data_field data_json.batches`
- `drop`: `order_field sort_order`, `no_split_field data_json.no_split`; `is_pinned_field` gone;
  mutation to `schedule.crud_lane_item`, plus `crud: split` with the new `end_offset` and
  `crud: create` for a copy
- release button: data_table `crud_lane_item_event` → `crud_lane_item` with `status: released`
  in `data`
- pages `nest-schedule` (`steps [impose]`) and `production-schedule`
  (`steps [print, coat, laminate, route, cut]`) as section `params`
