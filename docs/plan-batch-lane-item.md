# plan: batch_lane_item, instances and the lane step

Decided 9 Sep 2026. Replaces step 3b of `docs/plan-lane-model.md`.

## goal

Planning is resource based, always: `action.plan`, `action.lane`, `action.lane_item`.
The print schedule (75) and the impose plan (76) hide the resource, but it is in the
data. `mock.material_impose_plan` is deprecated: the instance of a moment moves to the
lane item, and `mock.generate_plan` stamps from `mock.material_print_schedule` (the
interval dates and the nest moments of a material) instead of a pattern table.

A nest hangs on a lane item through `action.batch_lane_item`: one row per batch on that
item, with the nest ids of that day. `action.imposition_lane_item` and its append-only
history disappear; history comes back later on the new table.

## how it works

1. **Release.** The planner releases a lane item to the nesting software: an event
   `released` in `action.lane_item_event` (append-only, `moved_by` for the contact later).
   An item without a time of its own gets `start_offset_in_seconds` from the `moved_at`
   of that event, so it has a moment before its nests arrive.
2. **Nests arrive** in `legacy.nest` without a batch. `legacy.crud_nest` puts a nest on the
   material lane of its `nested_at` date and line, on the item released last at or before
   `nested_at`, in the null-batch row of that item. An item that is never released
   receives no nests. `crud_nest` writes the event `nested` when the first nest lands.
3. **Batching** is manual, on the production resource plan (78/81). When a nest gets its
   `batch_id`, `crud_nest` moves it: out of the null row, into the row of that batch on
   the same item (created when missing). An empty null row is removed. A batch across
   days is one row per day: the lane item of each plan date carries the nests of that
   date only. A batch may sit on several instances of a lane, unless the item has
   `no_split`: then every nest of that batch on that lane goes to that item (writer rule).
4. **pv2 items** on a resource lane carry one row, their batch, with the nest ids of that
   batch. No batch means an empty slot (repair, maintenance, test): no row.
5. **The inflow sidebar (79)** has to point at the right instance: its read becomes a
   pass-through of `mapping.get_production_orderline_manifest` that adds `lane_item_id`
   and `instance`, and the `instance` query param picks the first unreleased instance of
   the material (instance 0 before instance 1). There is no data_table row for the
   manifest read today; the pass-through gets one.

## schema

```
action.lane
  + step text not null                     -- vocabulary lookup_step_category
  + resource_path ltree not null           -- the machine, or site.line.impose.width for a group lane
  + unique (lane_id, step)                 -- backs the composite key below
action.resource_lane                       -- dropped after its paths moved to lane
action.imposition_group_lane               -- stays: imposition_group_id (material alias) per lane

action.lane_item
  + instance integer default 0 not null    -- the repeat of a material moment on its lane
  + unique (lane_item_id, lane_id)         -- backs the composite key below

action.lane_item_event
  + moved_by integer                       -- contact_id, null for now
  status: plan -> released -> nested       -- vocabulary: action.lookup lookup_lane_item_status

action.batch_lane_item
  batch_lane_item_id bigint identity primary key
  lane_item_id       bigint not null
  lane_id            bigint not null
  step               text   not null
  batch_id           bigint                            -- null: not batched yet
  nest_ids           bigint[] not null default '{}'
  foreign key (lane_item_id, lane_id) references lane_item (lane_item_id, lane_id) on delete cascade
  foreign key (lane_id, step)         references lane (lane_id, step)
  unique (lane_item_id, batch_id)
  unique (lane_item_id) where batch_id is null         -- one null row per item
  unique (lane_item_id) where step <> 'impose'         -- one batch per item on every other step
```

The two composite foreign keys keep `lane_id` and `step` on the row true to the item and
its lane, so the partial unique indexes enforce the rules without a trigger.

Gone (step 3 and 5): `action.imposition_lane_item`, `action.crud_imposition_lane_item`,
`action.get_lane_item_impositions`, `action.resource_lane`, the 747 items with source
`nest`, `mock.material_impose_plan` and `mock.crud_material_impose_plan`.

## steps

Each step is one script in `sql/`, run in this order.

1. **schema** — `lane.step` + `lane.resource_path` (from `resource_lane`, and the impose path
   per group lane); `lane_item.instance` from the pattern rows; `lane_item_event.moved_by`;
   the status lookup; `batch_lane_item`. Additive only: the old objects stay until step 3.
2. **writers** — `action.crud_lane_item_event` (set-based, the release from the board, sets
   the offset of an item without one); `legacy.crud_nest` (placement by release, null row,
   batch move, `no_split`, the `nested` event); `action.sync_pv2_batch_items` and
   `action.crud_object` (one row per pv2 item); `action.crud_lane_item` (create: next
   instance on the lane, no pattern row).
3. **readers** — `action.get_plan_lanes_imposition_group` (one row per lane item, so per
   instance, with the last event status), `mock.get_impose_plan` and `mock.get_print_schedule`
   (the item's own rows; `set_json` set `batch` one line per row), `action.get_resource_plan`
   and `action.get_plan_lanes_resource` (`nest_ids` of the row), the inflow pass-through
   for 79. Then the old set table, its crud and reader, and `resource_lane` are dropped.
4. **backfill** — the `nest` items deleted, `batch_lane_item` filled from `legacy.nest` for
   the plan dates present, then the MySQL backfill of the hub again.
5. **pattern** — `mock.generate_plan` from `mock.material_print_schedule`: a material has a
   lane on the dates of `action.get_interval_dates(interval_start_date, interval_days)`, one
   item per `nest_moment_codes` entry, instance 0, 1, 2 in moment order; the pattern table
   dropped.
6. **docs** — `plan-lane-model.md` step 3b points here; `domain-model.md`; a short frontend
   handoff for 75, 76, 78, 79, 81 (rows per instance, `batch` set per row, the release
   button, the `instance` param).

## checks after step 4

- no nest in two rows of the same plan date
- no item with two null rows; no null row with an empty `nest_ids`
- every row of a non-impose lane is the only row of its item (the index guarantees it)
- board 76 shows a material with two instances as two rows, each with its own nests

## notes from the data

- 39 old resource lanes carry `site.step.line`; the step is taken as the first label that is
  a step of `lookup_step_category`.
- 91 pattern rows carry the full machine path; a group lane gets the first four labels,
  `site.line.impose.width`.
- `lane_item_event` has no rows yet. Between step 2 and step 3 the boards still read the old
  set table, which crud_nest no longer writes: new nests show up again after step 3 and 4.
- Testing phase (decided 9 sep): every impose item without a release is released at the local
  midnight of its lane date, once now and daily in site.refresh_derived_data
  (sql/update_release_impose_items.sql), until the planner releases from the board.

## scripts

| step | script | state |
|---|---|---|
| 1 schema | `sql/update_batch_lane_item_schema.sql` | run 9 sep |
| 1a data_table 79 | `sql/update_data_table_orderline_manifest.sql` | written 9 sep: row get_production_orderline_manifest, step 3 swaps the query |
| 2 writers | `sql/update_batch_lane_item_writers.sql` | written 9 sep: crud_lane_item_event (+ data_table row), crud_nest, sync_pv2_batch_items, crud_object, crud_lane_item, generate_plan, generate_production_plan |
| 3 readers | | |
| 4 backfill | | |
| 5 pattern | | |
| 6 docs | | |
