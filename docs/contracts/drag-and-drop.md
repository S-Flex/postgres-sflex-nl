# Contract: drag & drop configuration

The data_group keys that drive dragging and dropping in the timeline, and the rules the
data side must keep. Canonical source for both sides: this file lives with the code that
reads it.

The block is **identical on `row_options` (lane_items) and `label_options` (labels)** — a
drop is the same operation on both hosts: reposition an item inside a boundary, write a
rank, copy identity from a neighbour.

## How this file is maintained — read this first (Claude Code, both repos)

The same file lives in two repos: `postgres-sflex-nl/docs/contracts/` (data side) and
control-room (client side). It is edited in **one direction per change**, never in both
at once:

1. A change that starts with a **column** (a new flag, a renamed field, a rule for what
   the source serves) is written on the data side first, in the shape of this contract.
   The user hands the file to control-room.
2. **Control-room Claude Code** implements it and may correct the text where the client
   turns out to work differently (a gesture, a default, a limitation). It edits *this
   file* in the control-room repo, keeps every section, and does not reword what it did
   not change.
3. The user pastes the control-room version back; the data side overwrites its copy
   verbatim. From that moment both copies are identical again.
4. A change that starts on the **client** (a new gesture, a new host) goes the other way
   round: control-room writes it, the data side implements the columns and confirms.

Open items for control-room in the current version — implement, then confirm or
correct here:

- `no_split_field` (board level): new. Which gesture triggers a split is not stated;
  add it to the gestures table when it exists.
- `group_title_fields`: `group_by` holds ids only, the display column per level comes
  from `group_title_fields`, same order (see `archive/docs/handoff-control-room.md` §8).
- `copy_index_field` is **dropped** (data side, this change): planned moments are real
  `action.lane_item` rows now, so a Ctrl+drag copy is a **new lane item** created by the
  mutation — no index bookkeeping on the client. The key is gone from every data group
  and the `copy_index` columns are gone from `get_nest_schedule` and
  `get_print_schedule_materials`.
- `commit: "mutation"` is set on all three boards; the mutation procedure on the source
  does not exist yet, so a drop reverts on refetch until it does.

---

## The placement rule

A key sits **inside `drop`** when the drop is the only thing that reads it. It sits
**outside** when the layout or the lane identity reads it too — otherwise a non-drag code
path ends up reading a block named `drop`.

Absent key = behaviour off. No `*_field` key is ever defaulted to a canonical column name.

---

## Host level — `row_options` / `label_options`

| key | type | meaning | also read by |
|---|---|---|---|
| `draggable` | `boolean` | the item can be picked up | — |
| `order_field` | `string` | column the new rank is written to | the lane sort; the fixed-group roll-out order |

## `drop` object — on either host

| key | type | default | meaning |
|---|---|---|---|
| `sort` | `boolean` | `false` | the drop also **reorders** (writes `order_field`). Without it a drag only moves between groups |
| `order_type` | `"rank"` | — | `rank` = midpoint of the neighbours: `(before + after) / 2`, `±10` past an edge, `null` when alone |
| `within_fields` | `string[]` | `[]` | the drag may **not** cross a change in these columns. **Every entry must also be a `group_by` level** |
| `value_fields` | `string[]` | `[]` | columns copied from the neighbour the item lands beside |
| `commit` | `"mutation" \| "local"` | `"local"` | `mutation` posts the changed row to the source and refetches; `local` stays in the query cache |

## Board level — `timeline_config`

| key | type | meaning | also read by |
|---|---|---|---|
| `is_pinned_field` | `string` | the pinned flag a Shift+drop toggles | the initial derivation (pinned items keep their served offset); the lane order; the repack |
| `no_split_field` | `string` | the flag that forbids splitting the item into two items | the split action: refused when the column is true |

---

## Gestures

The **column's presence is the switch** — there are no enable flags.

| gesture | effect | requires |
|---|---|---|
| drag | move; reorder as well when `drop.sort` | `draggable` |
| **Shift**+drag | flips the pinned flag (`false → true`, `true → false`) | `is_pinned_field` |
| **Ctrl**+drag | drops a **copy**: the mutation creates a **new lane item** (a new row, its own identity) | `drop.commit: "mutation"` |
| **Ctrl+Shift**+drag | copy, pinned | both |

Without `is_pinned_field` Shift does nothing. Without `commit: "mutation"` Ctrl degrades
to a plain move. Without `no_split_field` every item may be split.

---

## What a drop writes

Columns the source must accept on update when `commit: "mutation"`:

| column | when | value |
|---|---|---|
| `order_field` | `drop.sort` | the computed rank |
| each `drop.value_fields` entry | crossing into another group | copied from a neighbour row |
| each `group_by` level crossed | crossing | the target group's value |
| `is_pinned_field` | Shift | the flipped boolean |
| — (Ctrl) | Ctrl | no column: the mutation **inserts** a new lane item copying the dragged row (offset, duration, links) |

The mutation goes to the `stored_proc` of the data table (`action.crud_lane_item` for the
nest boards), one element per changed row:
`{"crud": "update" | "create" | "delete", "track_by": <order in the batch>, "data": {<the columns above>}}`.
`data` carries only what changed; `track_by` comes back on the result row.

---

## Rules for the data side

1. **`within_fields` ⊆ `group_by`.** A boundary the drag may not cross has to be a group
   level, or there is no boundary to enforce. For `label_options` that is
   `label_options.group_by`; for `row_options`, `timeline_config.group_by`.
2. **Every `*_field` column must be served by the source.** A key naming a column the
   source does not return silently disables the behaviour — this is the single most common
   defect. It has already cost: `filter_fields` naming `date` on `get_nest_schedule` (no
   such column) made lane_items unselectable, and a menu item's `hidden_when` on
   `forecast_sqm` (no such column) hid that item on every row.
3. **`primary_keys` must be served too.** `get_nest_schedule` declares
   `production_orderline_id`, which is absent from its own schema.
4. **`order_field` must be numeric and writable.** The rank method computes a midpoint, so
   the column needs room between neighbours — integer steps of 10 or 100, not 1.
5. **`is_pinned_field`**: boolean or null; null counts as not pinned.
5b. **`no_split_field`**: boolean, default false; the source serves it from
   `action.lane_item.no_split` (was `is_atomic` on the old plan).
6. **`commit: "mutation"` requires a mutation procedure on the source.** Without one the
   POST fails and the optimistic reorder silently reverts.
7. **Use id columns in `within_fields`**, not display names — two resources sharing a name
   would otherwise be treated as one group.

---

## Migration from the current keys

| was | is now |
|---|---|
| `drag_sort` | `drop.sort` |
| `drag_order_field` | `order_field` (host level) |
| `set_order_field` | `order_field` — one column, one key |
| `drag_order_type` | `drop.order_type` |
| `drag_group_fields` | `drop.within_fields` — **inverted**, see below |
| `drag_value_fields` | `drop.value_fields` |
| `drag_commit: true` | `drop.commit: "mutation"` |
| `occurence_field` | dropped — a copy is a new lane item |
| `instance_field` | dropped — same |
| `is_fixed_field` | `fixed_group_field` (was `is_fixed_group_field` until 2026-09-05; `is_` marks a boolean, this is the delivery class) (legacy alias, drop it) |
| `is_pinned_field` | unchanged, stays on `timeline_config` |
| `plan_config.is_atomic_field` | `no_split_field` on `timeline_config` (56 renamed 6 sep) |

**`drag_group_fields` inverts.** It currently names the levels a drag **may cross**;
`within_fields` names the levels it **may not**. On `print_schedule` the old key happens to
behave as intended only by accident: `group_by` is `["tenant_name"]` and
`drag_group_fields` is `["resource_name"]`, which is not a group level, so nothing is
unlocked and the tenant stays locked.

---

## Target configuration

`label_options` — same on `nest_schedule` and `print_schedule`:

```json
"draggable": true,
"order_field": "sort_order",
"drop": {
  "sort": true,
  "order_type": "rank",
  "within_fields": ["tenant_name"],
  "value_fields": ["resource_uid"],
  "commit": "mutation"
}
```

`row_options` — only `within_fields` differs per board:

| data_group | `within_fields` | effect |
|---|---|---|
| `nest_resource_schedule` | `["tenant_id", "resource_uid"]` | a card stays on its own resource lane |
| `nest_schedule` | `["tenant_id"]` | may move between material lanes, never between tenants |
| `print_schedule` | `["tenant_id"]` | same |

On `nest_resource_schedule`, `within_fields` already pins a card to its lane, so
`value_fields` has nothing to copy — leave it out.

`timeline_config` on all three:

```json
"is_pinned_field": "is_pinned",
"no_split_field": "no_split"
```

(`no_split_field` only where the source serves the column: the boards on
`action.lane_item` — the production schedule — not the nest boards until
`get_nest_schedule` carries it.)

---

## Related contracts

- `timeline_config.next_start_offset_field` (was `next_start_offset_in_seconds_field`, 6 sep) — the axis step for the free chain.
  Its single home is `timeline_config`: the chain is a board property, not a label one
  (corrected 27 aug, it sat a level too deep on `label_options`). It does **not** space a
  fixed group: those items run back-to-back by `duration_in_seconds` in `order_field` order.
- `timeline_config.fixed_group_field` — a nullable group **number**, not a boolean. Every
  row of group `"18"` shares the value. Same home and same correction as the key above. The
  layout only treats a board as scheduled when a lane actually carries the column, not merely
  because the key is named.
- pinned comes from the data: `is_pinned` on the lane item, every item of a past day, and every
  item that already has nests (its time is the moment of its first nest). Only the rest chains.
- `timeline_config.chain_scope` — `"plan"` (one chain per main group) or `"lane"` (one per
  lane, lanes run in parallel).
