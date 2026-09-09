# Domain model — carts, line items, specs, manifests, impositions, planning

> **Status: reconstructed from design conversations, not from the live database.**
>
> This document is written from the design decisions made in chat over the past
> months. It has **not** been verified against the current SQL. Names, columns
> and schemas have moved several times (see *Known drift* at the end).
>
> **Task for Claude Code:** read this document, then read the actual SQL
> (tables, constraints, indexes, functions). For every section, either confirm
> it matches or correct it to match reality. Mark every correction so it is
> visible what changed. Where this document states a *rule* or *invariant* that
> the SQL does not enforce, flag it — the rule may be correct and the code may
> be missing it, or the rule may be outdated.

---

## 1. Principles

These hold everywhere in this model and explain most of the design choices.

**Semantics in data, not in code.** Business meaning lives in JSON columns,
lookup tables and configuration rows, interpreted by generic functions. A new
material, status, resource type or grouping rule should never require a code
change.

**Append-only over update.** Anything that changes over time is recorded as a
new row, never as an in-place update. The current state is derived by summing
or by taking the last row. This gives history for free, removes update-driven
bloat, and — the point of this document — makes the state at any past moment
reconstructable.

**Every mutation carries `moved_at`.** A log row without a timestamp cannot
answer "what was true at 14:30 yesterday". `moved_at` is the axis on which the
whole system can be rewound.

**Movements, not states.** Status logs record `from_ → to_` pairs, not "the
status is now X". The pair form makes the log self-balancing: the total over
all statuses is constant, so units cannot get lost or double-counted.

---

## 2. Hierarchy at a glance

```
cart                       commercial container (order / bundle)
├── cart_relation          parties: customer, supplier, ...
└── line_item              one configurable product  (has linked_cart_id)
    ├── product_json       chosen configurator options
    ├── line_item_resource append-only ledger of allowed resources
    └── spec               one quantity/dimension combination
        ├── spec_json      amount, width, height, ...
        ├── file_json      artwork
        ├── spec_unit_manifest   xbom with evaluated formulas
        └── spec_event       append-only status movements

catalog                    the recipe side
├── option_tree            configurator definition
├── xbom                   extended bill of materials (items + operations)
├── formula                formula definitions
└── item                   materials and operations

production                 the physical side
├── batch
├── imposition             sheet layout (type: nest | step_and_repeat)
│   ├── placement_json     which specs sit where on the sheet
│   ├── imposition_unit_manifest
│   └── imposition_event     append-only status movements
└── ...

action                     the planning side
└── plan                   one schedule, one date, one type
    └── lane               one ordered strip of time
        └── lane_item      one block of work
            ├── lane_item_dependency   from_ → to_ edges
            ├── lane_item_event          append-only status movements
            ├── imposition_lane_item   membership, written on change only
            └── order_lane_item        legacy, orderline-based
```

---

## 3. Commercial layer (`job` schema)

### 3.1 `job.cart`

The checkout unit. `cart` and `order` are the same object at different status
stages. `parent_cart_id` groups carts under a shared pricing scope (the
multi-cart / staffel wrapper). Each cart has its own address and delivery time.

| column | notes |
|---|---|
| `cart_id` | bigint, pk |
| `parent_cart_id` | nullable, self-reference |
| `type` | data-driven |
| `cart_json` | jsonb |
| `closed_at` | nullable |
| `created_at`, `updated_at` | |

### 3.2 `job.cart_relation`

Links a cart to a company in a role. Primary key is `(cart_id, company_id)`.

| column | notes |
|---|---|
| `cart_id`, `company_id` | composite pk |
| `address_id` | |
| `relation_type` | `customer`, `supplier`, ... — data-driven |
| `contacts_json` | jsonb |

### 3.3 `job.line_item`

One configurable product on the cart. `product_json` holds the options chosen
in the configurator; `option_tree_id` says which configurator produced it.
`parent_line_item_id` is composition *within one cart* — a line item made up of
sub-items.

| column | notes |
|---|---|
| `line_item_id` | bigint, pk |
| `cart_id` | never changes after creation |
| `parent_line_item_id` | composition within the same cart |
| `option_tree_id` | |
| `product_json` | chosen options |
| `sales_price`, `purchase_price` | |
| `linked_cart_id` | **nullable** — see below |
| `link_type` | **data-driven**, e.g. `outsource` |

### 3.4 `linked_cart_id` — outsourcing

When a line item is outsourced to a supplier, a new cart is created (the
purchase order at the supplier) and `linked_cart_id` on the **existing** line
item points at it. Deliberate consequences:

- **The line item is never duplicated.** It stays the single source of truth
  for status, so there is no copy to keep in sync.
- **`cart_id` never changes.** The line item keeps belonging to its own cart.
- **`linked_cart_id` sits on the line item, not on the cart.** So cart A can
  have line item 1 → supplier cart X, line item 2 → supplier cart Y, and line
  item 3 produced in-house with `linked_cart_id` null. Each line decides
  independently.
- **At most one link at a time.** A single line item is never split across two
  suppliers simultaneously. This is why it is a column and not a junction
  table. If splitting ever becomes real, *that* is the moment to migrate to a
  table — not before.
- **`link_type` is data**, so the same mechanism can later carry other
  cross-cart relations (replacement, rework, transfer) without code changes.

> **Verify:** do `linked_cart_id` and `link_type` actually exist on
> `job.line_item`? They were agreed in design but may not be migrated yet.
> Is there an FK from `linked_cart_id` to `job.cart`?

### 3.5 `job.spec`

The production unit. A line item has one or more specs; each spec is one
quantity × dimension combination ("1000× 100×200mm, single-sided"). Files hang
off the spec, not off the line item, because the spec is what gets produced and
uploaded for.

| column | notes |
|---|---|
| `spec_id` | bigint, pk |
| `line_item_id` | |
| `parent_spec_id` | nullable, self-reference |
| `amount` | integer |
| `spec_json` | width, height, and further parameters |
| `file_json` | artwork |
| `closed_at` | nullable |
| `created_at`, `updated_at` | |

Alongside specs sit **parts** (front, back, frame) at line item level — parts
describe the physical structure, specs are the production unit.

> **Verify:** is there a `parts` table, or are parts held inside
> `product_json` / the xbom? The design discussion left this open.

---

## 4. `job.line_item_resource` — the resource ledger

### 4.1 Why it exists

Each spec, through its unit manifest, determines which resources it *could*
physically run on. But planning happens at **line item** level: once one spec is
committed to a printer, every other spec of that line item must follow to the
same machine.

Concretely: printer A takes 300 cm wide, printer B takes 500. Specs are
200×200, 300×300 and 400×400. The 400×400 only fits B, so **all three** specs go
over B — you cannot print two specs of one job on one machine and the third on
another.

### 4.2 The table

Append-only. Each row holds the *resulting* set after that action, plus a `kind`
saying what produced it.

| column | meaning |
|---|---|
| `line_item_resource_id` | bigint, pk |
| `line_item_id` | |
| `kind` | `narrow` \| `commit` \| `revert` \| `force` |
| `resource_uids` | text[] — the full resulting set, all resource types mixed |
| `reason` | mandatory for `force`, optional otherwise |
| `updated_at` | |

**The set is deliberately type-agnostic.** Printers, cutters and coaters live in
one array. A resource's step is a property of `relation.resource.step`, never of
this ledger. A resource type the product does not use simply never appears in
any spec's set, so it is absent automatically — no special handling.

**The core invariant is monotonicity:** the set may only shrink, never grow. If
the first spec restricts it to {B, C}, a later smaller spec that would fit on A
can never bring A back. The last row is always the current truth; history is
kept for auditing.

### 4.3 The four actions

**`narrow`** — intersection of the newly eligible set with the current set.
Called after each spec iteration. On the first call for a line item there is
nothing to intersect with, so it seeds.

```
current {A, B, C}  narrow {B, C, D}  →  {B, C}
```

**`commit`** — the planner picks one resource. Same-step siblings (from
`relation.resource.step`) are dropped; resources of other steps are preserved,
because committing a printer says nothing about which cutter will be used.

```
current {A, B, cut1, cut2}  commit B  →  {B, cut1, cut2}
```

**`revert`** — rolls back a commit by restoring the latest non-commit row. Used
when a machine breaks down *before* anything was produced.

**`force`** — breaks monotonicity, with a mandatory reason. For overrides after
production has started: machine B broke after printing, everything must move to
C even though C was intersected away.

### 4.4 Boundaries

- Whether a revert is still allowed (nothing produced yet) versus a force being
  required (output exists) is **production-status knowledge in the calling
  layer**, not in this ledger.
- An **empty set after intersection** means the specs are jointly impossible on
  any resource — a configuration error the caller should surface before
  planning, not something discovered at the planning board.

### 4.5 The function

`crud_line_item_resource(p_param_json jsonb, p_no_results boolean)`

Loops `FOR el IN SELECT * FROM jsonb_array_elements(p_param_json)`, reads the
*then-current* last row per element, and inserts one row per action. Because the
read happens inside the loop, mixed payload order works by itself: narrow after
commit, revert then commit, all in supplied order.

Payload keys: `resource_uids` for sets, `resource_uid` (singular) for the commit
selection.

> **Verify:** the table was designed as `core.line_item_resource` but appears in
> the schema dump as `job.line_item_resource`; the function was written as
> `catalog.crud_line_item_resource`. Confirm the actual schema for both, and
> whether the function still references the old schema in its body.

---

## 5. Catalog layer — xbom and manifests

### 5.1 `catalog.xbom`

The eXtended bill of materials: not just materials but also operations. Rows
are matched on `option_code`; each row names an `item_code`, a `formula_id`, a
`scope`, and carries `param_json` and `config_json` for extra information.

| column | notes |
|---|---|
| `xbom_id` | |
| `option_code` | which configurator option this row belongs to |
| `item_code` | → `catalog.item` |
| `formula_id` | → `catalog.formula` |
| `scope` | `batch` \| `imposition` \| `sub-imposition` \| `unit` |
| `param_json`, `config_json` | |
| `version`, `status`, `sort_order` | |

### 5.2 Scope

Scope says **at which level in the production sequence** an option applies.
Scope is recursive and hierarchical: `imposition → sub-imposition → unit`, each
a subgroup within its parent.

`imposition` deliberately replaced `nest` as the scope name. Nesting (packing
irregular shapes tightly) and step-and-repeat (a fixed grid of identical items)
are two *types* of imposition — using `nest` as the category name would be a
special case pretending to be the general one. The choice between the two is
made later and elsewhere, so the scope name must not prejudge it.

### 5.3 `grouping_key` / `xbom_grouping_key`

The value on which members coincide within a scope. Same field name at every
scope level; the scope alone determines what it groups. On imposition level it
is the composite string built from item codes; on batch level it is
`line_item_id` or `cart_id`; on unit level whatever determines grouping there.
The engine reads `grouping_key` everywhere and does not know that batch and
imposition are "different".

Code serialization follows the naming conventions document: `.` for hierarchy,
`_` for step separation, `:` for key:value, `;` as the series separator between
multiple SKUs, and a leading `_` after `;` for a variant of the previous element
stating only the differing parameters.

`xbom_code` is a **pure scope-path string** (`imposition;sub-imposition;...`)
holding only options and scopes — never amount, width or height. Unit-specific
parameters live in a separate `unit_code`. This lets the nester read `xbom_code`
alone with no parsing or stripping, while other consumers concatenate the two
using the `;_` variant convention when they need the full identifier.

### 5.4 `job.spec_unit_manifest`

**The manifest is the xbom with the formulas evaluated**, using `spec.amount`,
`spec.width` and `spec.height`. One row per item per spec.

| column | notes |
|---|---|
| `unit_manifest_id` | bigint, pk |
| `spec_id` | |
| `option_code` | |
| `item_code` | |
| `param_json`, `config_json` | |
| `possible_status_sequence` | jsonb, **nested array** e.g. `[[10,20,30],[40,50]]` |
| `production_impact_per_unit` | integer |
| `price` | numeric |
| `created_at`, `updated_at` | |

`possible_status_sequence` holds the status sequences this item can pass
through — nested because there are alternative routes. Query it with double
`jsonb_array_elements` (faster than the jsonpath engine for this shape), and
cast via `text` to integer, never directly from jsonb.

Formulas are evaluated by the Rust/WASM evaluator (`evaluate_many_nas`).

Relevant functions seen in design:

- `mapping.create_spec_unit_manifest(int[])` — delete-insert, returns row counts
- `mapping.update_component_specs_manifest(int[])` — rebuilds
  `component_specs.manifest_json` (one object per scope with `i18n` and
  `item_code_paths`) from the manifest rows; called by create in the same pass
- `job.next_status_sequence`

---

## 6. Production layer

### 6.1 `production.imposition`

Renamed in place from `production.nest`. The container for a sheet layout;
`type` distinguishes `nest` from `step_and_repeat`.

| column | notes |
|---|---|
| `imposition_id` | bigint, pk |
| `batch_id` | |
| `width`, `height` | integer |
| `amount` | integer, check `> 0` |
| `production_impact` | integer, default 0 |
| `remaining_impact` | integer, default 0 |
| `waste_percentage` | numeric(3,1) |
| `status_json` | jsonb |
| `placement_json` | jsonb — `specs: [{spec_id, placement[]}]` |
| `domain_id` | default 1 |
| `closed_at` | nullable |
| `created_at`, `updated_at` | |

`placement_json -> 'specs'` is read with
`jsonb_to_recordset(...) AS el(spec_id bigint, placement jsonb)`;
`jsonb_array_length(el.placement)` is the number of copies of that spec on the
sheet.

> **Verify:** does a `type` column exist on `production.imposition`? It was
> agreed in the naming discussion but the DDL shown at rename time did not have
> it. Also confirm the rename actually ran (`imposition_id`,
> `imposition_amount_check`, `idx_imposition_batch_id`, and the renamed
> functions `compute_imposition_manifest_production_impact` and
> `imposition_unit_status_update`).

### 6.2 `production.batch`

| column | notes |
|---|---|
| `batch_id`, `batch_sequence` | |
| `spec_id` | |
| `production_impact`, `remaining_impact` | |
| `created_at`, `updated_at` | |

### 6.3 `production.imposition_unit_manifest`

Same idea as `spec_unit_manifest` but frozen at imposition level. Indexed on
`imposition_id` and `item_code`.

### 6.4 Production impact

`compute_imposition_manifest_production_impact(p_imposition_id, p_item_code, p_overhead_fixed, p_overhead_factor)`

Sums `production_impact_per_unit` per spec from `job.spec_unit_manifest`, joins
it against the placement counts from the imposition, and applies
`amount * impact_per_unit * (1 + overhead_factor) + overhead_fixed`.

---

## 7. Status model — the heart of it

### 7.1 `job.status`

The status vocabulary. Statuses are data, not an enum in code.

| column | notes |
|---|---|
| `code` | text, pk |
| `sequence` | integer — the ordering axis |
| `phase` | grouping |
| `created_at`, `updated_at` | |

The logs store **`sequence` (integer), not `code`**. Earlier design notes used
`from_status` / `to_status` as text; the live tables use
`from_status_sequence` / `to_status_sequence`. Both are described here because
the *semantics* are identical — only the key type changed.

Step categories also live in `relation.lookup` under `lookup_step_category`,
with sequences such as 600 rip/ripped, 700 print/printed, 790 coat/coated,
795 laminate/laminated, 801 cut.

> **Verify:** are `job.status.sequence` and the `lookup_step_category`
> sequences the same numbering, or two parallel systems? This matters for
> anything joining production logs to job statuses.

### 7.2 `job.spec_event`

An **event log, not a counter table**. Never `UPDATE`, never `DELETE` per row —
only `INSERT`.

| column | meaning |
|---|---|
| `spec_event_id` | bigint, pk |
| `spec_id` | |
| `from_status_sequence` | where the units come from; `NULL` = entry into the system |
| `to_status_sequence` | where the units go; `NULL` = exit |
| `amount` | number of units in this movement (may be > 1 for a batch) |
| `remaining_impact_delta` | integer — impact released by this movement |
| `moved_at` | timestamptz |

One movement is one insert:

```sql
INSERT INTO job.spec_event (spec_id, from_status_sequence, to_status_sequence, amount)
VALUES ($1, 700, 710, 1);
```

### 7.3 Deriving the current position

Amount per status = incoming minus outgoing.

```sql
SELECT status, SUM(amount) AS amount
FROM (
  SELECT to_status_sequence   AS status,  amount FROM job.spec_event WHERE spec_id = $1
  UNION ALL
  SELECT from_status_sequence AS status, -amount FROM job.spec_event
   WHERE spec_id = $1 AND from_status_sequence IS NOT NULL
) m
GROUP BY status
HAVING SUM(amount) <> 0;
```

Equivalent form using filters, as used in the legacy nest functions:

```sql
sum(amount) FILTER (WHERE to_status_sequence   = s.sequence)
- sum(amount) FILTER (WHERE from_status_sequence = s.sequence)
```

### 7.4 Invariants

- **Amount 0 does not exist as a row.** A status at net zero drops out via the
  `HAVING`. Absence means zero. Never store or clean up zero rows.
- **`SUM(amount)` over all statuses is constant** and equals the total unit
  count of the spec. This is the built-in consistency check: units cannot get
  lost or double-counted.
- **Cleanup happens by partition**, never row-by-row `DELETE`. After an order
  completes, `TRUNCATE`/`DROP` the partition.

### 7.5 Why append-only

The old counter model updated an `amount` per status in place. At ~200,000
units/day across ~10 statuses that is ~2 million updates/day on a small hot row
set — the worst case for MVCC, giving enormous update-driven dead tuples and
bloat. Append-only turns those updates into inserts (no dead tuples), gives full
history and traceability for free, and keeps the position always derivable and
balanced.

### 7.6 `production.imposition_event`

Same pattern one level up.

| column | notes |
|---|---|
| `imposition_event_id` | bigint, pk |
| `imposition_id` | |
| `from_status_sequence`, `to_status_sequence` | |
| `amount` | run quantity of the imposition |
| `remaining_impact_delta` | `amount * (R(to) − R(from))`, R from the frozen imposition manifest |
| `resource_uids` | which machines ran it |
| `moved_at` | |

`imposition_unit_status_update(p_imposition_id, p_current_status_sequence, p_new_status_sequence, p_resource_uids)`
writes one imposition-level row and then calls
`job.spec_unit_status_update_batch(...)` to push the same movement down to the
specs on the sheet — the printer that ran the imposition ran its specs, so the
same resources flow through.

### 7.7 `legacy.nest_log`

Mirrors `production.nest_log` for legacy data. Filled by
`legacy.insert_nest_log(p_nest_name text)`, which uses
`legacy.get_nest_relevant_steps(p_nest_name)` to decide which steps apply.

**Known trap:** `lag()` for computing `from_sequence` must be computed over the
**full** lookup sequence first and only then filtered to relevant steps.
Filtering first makes `from_sequence` NULL for whichever step happens to be
first in the filtered subset.

---

## 8. Point-in-time reconstruction

This is the requirement the whole append-only design serves: **at any moment in
the past, the complete exact state must be reconstructable.**

### 8.1 The rule

Every derivation query in this document becomes a point-in-time query by adding
one predicate:

```sql
AND moved_at <= $as_of
```

Nothing else changes. Because the logs are append-only and no row is ever
mutated, filtering on `moved_at` yields exactly the set of facts known at that
moment.

```sql
-- Position per status for a spec, as it was at $as_of
SELECT status, SUM(amount) AS amount
FROM (
  SELECT to_status_sequence   AS status,  amount FROM job.spec_event
   WHERE spec_id = $1 AND moved_at <= $as_of
  UNION ALL
  SELECT from_status_sequence AS status, -amount FROM job.spec_event
   WHERE spec_id = $1 AND from_status_sequence IS NOT NULL AND moved_at <= $as_of
) m
GROUP BY status
HAVING SUM(amount) <> 0;
```

### 8.2 The two shapes

**Summing ledgers** (`spec_event`, `imposition_event`, stock): sum all rows up to
`$as_of`. The `SUM = constant` invariant holds at every point in time, so the
reconstruction is self-checking.

**Last-row ledgers** (`line_item_resource`): take the last row per key up to
`$as_of`.

```sql
SELECT DISTINCT ON (line_item_id) line_item_id, kind, resource_uids, updated_at
FROM job.line_item_resource
WHERE updated_at <= $as_of
ORDER BY line_item_id, line_item_resource_id DESC;
```

**Change-only tables** (`imposition_lane_item`): rows exist only where the value
changes; everything else is inherited. Reconstruction takes the most recent
write per key up to `$as_of` and derives the rest — see
`action.get_lane_item_impositions(p_lane_item_id, p_as_of)` in 9.6, which does
exactly this.

### 8.3 What this requires — checklist for the SQL

1. **Every log table has a timestamp column**, and it is `timestamptz`, not
   naive `timestamp`. Mixed types break comparison across DST boundaries.
2. **Naming is consistent.** `moved_at` on movement logs; `line_item_resource`
   currently uses `updated_at` for the same concept.
   → *Decide: rename to `moved_at`, or accept the exception and document it.*
3. **No `UPDATE` or `DELETE` touches an event row.** Any function that does breaks
   reconstruction silently. Claude Code should grep for `UPDATE ... _event` and
   `DELETE FROM ... _event` (and legacy `... _log`) across all functions and
   report every hit.
4. **Denormalized snapshots are consistent with the log.** `imposition.status_json`,
   `imposition.remaining_impact`, `batch.remaining_impact` and `nest.status_json`
   are current-state caches. They cannot be rewound. Either they are always
   derivable from the log, or point-in-time answers differ depending on which
   source you read.
   → *Claude Code: for each of these, confirm the log is the source of truth
   and the cache is derived, and write the check query that proves they agree.*
5. **Partition dropping destroys history.** Cleanup by partition after order
   completion is deliberate, but it caps how far back reconstruction reaches.
   → *Document the retention window; it is the real limit of "any moment in the
   past".*
6. **Reference data is not versioned.** `job.status`, `catalog.xbom`,
   `relation.resource` and the lookups change over time and mostly have no
   history. Reconstructing "what the system computed then" is only exact where
   the computed result was frozen into a row.
   Two things are already frozen deliberately and should stay that way:
   - the **imposition unit manifest** (frozen at imposition creation, which is
     why `remaining_impact_delta` can be recomputed consistently afterwards);
   - the **lane → material_resource_plan pin** (the lane records the exact
     append-only pattern version it was generated from, so the daily plan is a
     snapshot even when the pattern moves on).
   → *Claude Code: list every other place where a computed value depends on
   mutable reference data without being frozen. Those are the gaps in
   reconstruction.*

---

## 9. Planning layer (`action` schema)

### 9.1 `action.plan`

A plan is **one schedule for one date**: the print schedule of a tenant on a
day. `type` distinguishes schedules that share a date (nest, print). The axis
origin belongs to the type and is passed to the read function per plan.

| column | notes |
|---|---|
| `plan_id` | bigint, pk |
| `tenant_id` | |
| `type` | `nest`, `print`, ... |
| `plan_date` | date |
| | unique `(tenant_id, type, plan_date)` |

Introducing `plan` removed two columns that had wrongly sat on `lane`:
`tenant_id` and `step`. The step is fully derived — the plan type distinguishes
nest from print schedule, and within a lane the pattern attachments carry it.
It also fixed two seams: `sort_order` uniqueness became per plan (no collision
between locations), and an unplanned pool lane inherits its tenant scope from
its plan instead of from the caller.

> **Verify:** the schema dump shows `action.plan` with `step`, `type` and
> `line_type` but no `tenant_id`. That contradicts the design above. Establish
> which is current.

### 9.2 `action.lane`

One ordered strip of time within a plan. Everything else attaches to it.

| column | notes |
|---|---|
| `lane_id` | bigint, pk |
| `plan_id` | |
| `sort_order` | numeric, unique within plan |

A `path` column on `lane` was replaced by a linking table
(`mock.material_resource_plan_lane` / `action.lane_material_resource_plan`),
joined on `sort_order`.

### 9.3 `action.lane_item`

One block of work in a lane.

| column | notes |
|---|---|
| `lane_item_id` | bigint, pk |
| `lane_id` | |
| `sort_order` | numeric |
| `start_offset_in_seconds` | integer — offset from the plan's axis origin |
| `duration_in_seconds` | integer |
| `fixed_group` | |
| `is_pinned` | |

**Times are offsets, not timestamps.** The axis origin comes from the plan type.

**Non-working times (breaks, nights) are never computed into planning start
times or durations server-side.** They are sent to the frontend as JSON and
rendered there. A break extends the job it falls within; it is never modelled
as a separate spacer row.

### 9.4 `action.lane_item_dependency`

Many-to-many edges between lane items. Primary key `(from_lane_item_id,
to_lane_item_id)`, CASCADE on both sides.

The model went `parent_lane_item_id` → `child_lane_item_id` → this table,
because one rip lane item can feed multiple print lane items and vice versa.

Dependencies drive the shift behaviour: move a print lane item forward or back
and the steps after it move with it. `lag_mode` and `lag_seconds` are **resolved
at read time from the resource**, not stored on the edge.

### 9.5 A lane item is a step, not a status

This is the point that is easiest to get wrong when reading the rest of this
document.

An **order** moves through the production process, going from status to status —
that is what `spec_event` and `imposition_event` record. A **lane item** does not
move through anything. It *is* one step in that process: nest, rip, print, coat,
route, cut. The impositions hanging under a lane item normally pass through all
the steps, which is exactly what `lane_item_dependency` expresses.

So a lane item does not need a status history, and anything modelling it that
way is a category error. What does need history is **which impositions were
sitting under which lane item at a given moment** — because impositions get
**split and merged** across lane items during planning.

> **Verify:** an `action.lane_item_event` table with a bare `status` column
> appears in the schema dump. Establish what it is currently used for. If it
> only ever recorded membership or step lifecycle, it is superseded by 9.6 and
> should be dropped or migrated. If it carries a genuine lane-item lifecycle
> (planned / released / started / done) that the planning board depends on, keep
> it and document it here — but that is a separate concern from membership.

### 9.6 `action.imposition_lane_item` — membership by exception

The five steps of a normal run are one lane item each: **nested → ripped →
printed → coated → cut**, chained by `lane_item_dependency`. The impositions
that enter at the first step normally travel through all of them unchanged.

So membership only has to be recorded **where it actually changes**. A lane item
with no rows of its own means: *the same impositions as the step before me*.
Rows are written on the first step, and after that only on a split or a merge.
Nothing is stored for the steps in between.

```sql
-- Which impositions sit in a lane_item. Rows are written only where the set
-- changes: at the first step, and on a split or a merge. A lane_item without
-- rows carries the same impositions as the step before it.
CREATE TABLE action.imposition_lane_item (
    imposition_lane_item_id bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    lane_item_id            bigint      NOT NULL REFERENCES action.lane_item (lane_item_id),
    imposition_id           bigint      NOT NULL REFERENCES production.imposition (imposition_id),
    moved_at                timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE action.imposition_lane_item OWNER TO xfw3;

CREATE INDEX idx_imposition_lane_item_lane_item_id
    ON action.imposition_lane_item (lane_item_id);
CREATE INDEX idx_imposition_lane_item_imposition_id
    ON action.imposition_lane_item (imposition_id);
```

No `action` or `kind` column and no `from_`/`to_` pair: a row simply states that
this imposition belongs to this lane item from `moved_at` onwards. Split and
merge are not different operations, only different *shapes* of the same write —
a split writes several sets out of one lane item, a merge writes one set drawn
from several.

`lane_item_dependency` must allow multiple parents per lane item, because the
merge at `cut` has two upstream coater lane items. It already does: the table is
many-to-many on `(from_lane_item_id, to_lane_item_id)`.

#### Worked example

Lane items 1–5 are nested, ripped, printed, coated, cut. Impositions a–f enter
at 1. Coating then runs on two machines, so lane item 6 is added as a second
coater alongside 4; both depend on 3. At `cut` the two coaters merge back into 5.

Edges: 1→2, 2→3, 3→4, 3→6, 4→5, 6→5.

Rows in `imposition_lane_item`:

| lane_item_id | imposition_id |
|---|---|
| 1 | a, b, c, d, e, f |
| 4 | a, b, c |
| 6 | d, e, f |
| 5 | a, b, c, d, e, f |

Nothing is written for 2 (ripped) or 3 (printed) — no split, no merge, so they
inherit. `get_lane_item_impositions(2)` and `(3)` return a–f without a single
row having been stored for them.

#### Reading it back

```sql
-- Impositions in a lane_item, at any moment. Walks up the dependency chain
-- until it reaches a lane_item that carries its own set.
CREATE OR REPLACE FUNCTION action.get_lane_item_impositions(
    p_lane_item_id bigint,
    p_as_of        timestamptz DEFAULT now()
)
RETURNS TABLE (imposition_id bigint)
LANGUAGE sql
STABLE
AS $$
    WITH RECURSIVE up AS (
        SELECT p_lane_item_id AS lane_item_id
        UNION ALL
        SELECT d.from_lane_item_id
        FROM up
        JOIN action.lane_item_dependency d
          ON d.to_lane_item_id = up.lane_item_id
        WHERE NOT EXISTS (
            SELECT 1 FROM action.imposition_lane_item i
            WHERE i.lane_item_id = up.lane_item_id
              AND i.moved_at <= p_as_of)
    )
    SELECT DISTINCT i.imposition_id
    FROM up
    JOIN action.imposition_lane_item i
      ON i.lane_item_id = up.lane_item_id
    WHERE i.moved_at <= p_as_of
      -- Only the most recent write per lane_item counts: a lane_item that is
      -- split again later gets a new set, the older one stays as history.
      AND i.moved_at = (
          SELECT max(x.moved_at)
          FROM action.imposition_lane_item x
          WHERE x.lane_item_id = i.lane_item_id
            AND x.moved_at <= p_as_of);
$$;

ALTER FUNCTION action.get_lane_item_impositions(bigint, timestamptz) OWNER TO xfw3;
```

**`p_as_of` is the whole point-in-time story for planning.** Leave it out and
you get the current set; pass a timestamp and you get exactly what was in that
lane item then, including the grouping as it was before a later split. No
separate history table, because the table already only holds changes.

> **Claude Code:** the recursive term uses a correlated `NOT EXISTS` against the
> working table. Confirm PostgreSQL accepts it as written; if the planner
> objects, the fallback is the plpgsql form — `IF EXISTS (own rows) THEN return
> them ELSE recurse into the parents END IF` — which is equivalent but branches
> in procedural code instead.

#### Writing it

```sql
-- Write a set for a lane_item. Called on the first step and on a split or
-- merge; never for steps that keep the same set.
CREATE OR REPLACE FUNCTION action.crud_imposition_lane_item(p_param_json jsonb)
RETURNS TABLE (
    imposition_lane_item_id bigint,
    lane_item_id            bigint,
    imposition_id           bigint,
    moved_at                timestamptz
)
LANGUAGE sql
AS $$
    INSERT INTO action.imposition_lane_item (lane_item_id, imposition_id)
    SELECT (el ->> 'lane_item_id')::bigint,
           (el ->> 'imposition_id')::bigint
    FROM jsonb_array_elements(p_param_json) AS el
    RETURNING imposition_lane_item_id, lane_item_id, imposition_id, moved_at;
$$;

ALTER FUNCTION action.crud_imposition_lane_item(jsonb) OWNER TO xfw3;
```

All rows of one split or merge must be written in **one call**, so they share a
`moved_at` and the "most recent write per lane item" rule sees them as one set.

#### Two open points

- **Removing an imposition entirely.** Absence of rows means *inherit*, so it
  cannot express "this lane item has nothing". In practice a split always leaves
  a non-empty set on both sides, so this may never occur. If it can, the
  simplest fix is a row with `imposition_id` null as an explicit empty set.
  → *Claude Code: check whether the planning UI can empty a lane item.*
- **Dependencies must follow a split.** When lane item 6 is added next to 4,
  the edges 3→6 and 6→5 must be written in the same transaction as the
  membership rows. This is the failure mode: the membership is right but an edge
  is missing, so the downstream steps stop shifting along when the coater moves.

### 9.7 From lane item to specs

Impositions are the planning unit; specs are the production unit. The bridge is
`imposition.placement_json`:

```sql
-- Specs in a lane_item, with the number of copies on each sheet.
SELECT el.spec_id,
       i.imposition_id,
       jsonb_array_length(el.placement) AS amount
FROM action.get_lane_item_impositions($lane_item_id) li
JOIN production.imposition i ON i.imposition_id = li.imposition_id
CROSS JOIN LATERAL jsonb_to_recordset(i.placement_json -> 'specs')
                   AS el(spec_id bigint, placement jsonb);
```

From there, `job.spec_unit_manifest` gives the items and
`production_impact_per_unit` per spec, and `job.spec_event` gives the position of
those specs in the production flow. That is the full chain:

```
lane_item → imposition → placement_json → spec → spec_unit_manifest → spec_event
```

> **Legacy:** `action.order_lane_item` / `production_orderline_lane_item`,
> `single_item` and `internal_status_code_sequence` belong to the old
> orderline-based model. They are still referenced by
> `mock.get_nest_schedule` and `get_orderline_details`. Claude Code should list
> where they are still used and note that the target is the imposition/spec
> chain above, not extend them.

### 9.8 Rework

A reprint gets its **own object** — a new imposition or an imposition version —
rather than a second movement on the same one. That keeps `(step_code,
object_id)` unique and removes the ambiguity of two prints for one nest. Rework
specs inherit the resource set of the original run via recorded actuals plus a
precedence rule; the short time window (same shift or day) makes resource state
drift physically impossible.

### 9.9 Calendar and cutoffs

- **`action.dates`** — `date` (pk), `weekday`, `is_weekend`,
  `tenants_mandatory_day_off` (integer[], leeg = gewone werkdag), `shift_json`:
  de shifts van de dag, per shift `tenants` (integer[]), `start_offset_in_seconds`
  (na middernacht), `shift_duration` (seconden) en `start_time` (alleen leesbaar,
  de functies rekenen met de offset). Lezers: `log.upsert_state_shift_agg`,
  `log.get_resource_state_shift_totals`
- **`action.non_working_times`** — `type`, `rule_path`, `weekday`,
  `start_offset_in_seconds`, `duration_in_seconds`, `moved_at`, `moved_by`
- **`action.cutoff_time`** — append-only, `type`, `code`, `rule_path`,
  `weekday`, `cutoff_seconds`, `moved_at`, `moved_by`

`rule_path` is a dot-separated integer path for hierarchical lookup: the most
specific matching path wins. Both tables are append-only with `moved_at`, so
they reconstruct the same way as the logs.

`mapping.calculate_nest_date(order_date, production_hours)` derives the nest
moment from `action.dates` plus `production.lookup` key `lookup_nest_moments`.
Note that `component_specs.nest_at` stores the *result* — a snapshot that goes
stale if the lookup, a mandatory day off, or `production_hours` changes. That is
a deliberate speed-over-derived-truth trade; the function exists to make
resyncing trivial.

---

## 10. Conventions

These apply to everything in this document.

**PL/pgSQL**
- `#variable_conflict use_column` as the **first line** of every `RETURNS TABLE`
  function
- Always schema-qualify function names in both `CREATE` and `ALTER`
- All functions `OWNER TO xfw3`
- Comments in English

**CRUD**
- Set-based, driven by `jsonb_array_elements(p_param_json)`
- `ON CONFLICT DO UPDATE SET ... EXCLUDED.*` only
- `p_no_results boolean` to suppress the result payload

**Naming**
- Descriptive primary and foreign keys, never a bare `id`
- `snake_case` for JSON properties, `kebab-case` for code values
- `i18n` for multilingual blocks (not `ml`)
- `template` for template strings (not `text_formula`)
- Codes: `.` hierarchy, `_` step separator, `:` key:value, `;` series,
  `;_` variant of the previous element

---

## 11. Known drift — resolve these first

Everything below is a contradiction between design conversations and the last
schema dump seen. These are the highest-value things for Claude Code to settle,
because the rest of the document depends on them.

| # | Issue | To check |
|---|---|---|
| 1 | `line_item_resource` schema | `core.` (designed) vs `job.` (dump). And the function: `catalog.crud_line_item_resource`? |
| 2 | `linked_cart_id` / `link_type` | Present on `job.line_item`, or designed but not migrated? |
| 3 | `nest` → `imposition` rename | Did it run? Dump still shows `production.nest`, `nest_log`. Both may now exist. |
| 4 | `imposition.type` | Does the `nest \| step_and_repeat` column exist? |
| 5 | `action.plan` columns | Dump: `step`, `type`, `line_type`, `plan_date`. Design: `tenant_id`, `type`, `plan_date` with unique constraint. |
| 6 | `lane_item_event` purpose | A lane item is a step, not something with a status. What is this table used for now, and is it superseded by the membership ledger? See 9.5. |
| 6b | `nest_lane_item` → `imposition_lane_item` | Rename plus the change-only semantics of 9.6. Existing rows migrate as-is (they become the set for their lane item); redundant rows for steps that never split can be dropped. |
| 7 | Status text vs sequence | `from_status`/`to_status` (early design) vs `from_status_sequence`/`to_status_sequence` (dump). |
| 8 | `job.status.sequence` vs `lookup_step_category` | One numbering or two? |
| 9 | `moved_at` vs `updated_at` | `line_item_resource` uses `updated_at` for a movement timestamp. |
| 10 | `mock.` schema | `mock.get_print_schedule`, `mock.get_nest_schedule`, `mock.material_resource_plan_lane` — still `mock`, or promoted to `action`/`production`? |
| 11 | `parts` | Does a table exist, or does it live in `product_json` / xbom? |
| 12 | Cache vs log | `imposition.status_json`, `remaining_impact`, `batch.remaining_impact` — derived from the log, or independently maintained? |

---

## 12. What Claude Code should produce

1. **A corrected version of this document**, matching the live SQL, with every
   change marked.
2. **A resolution of the table in section 11**, one line per item: what is
   actually true.
3. **A grep report** of every `UPDATE` or `DELETE` against a `_log` table in any
   function — each one is a hole in point-in-time reconstruction.
4. **The gap list from section 8.3 item 6**: every computed value that depends
   on mutable reference data without being frozen.
5. **A worked point-in-time query per log table**, tested against real data:
   spec, imposition, lane item membership, line item resource. These are the
   proof that the requirement is met. For membership, the test is the worked
   example in 9.6: `get_lane_item_impositions(5, before_the_split)` and
   `(5, after_the_split)` must give different groupings.
6. **The `imposition_lane_item` migration**: the table and both functions of
   9.6, the rewrite of every read query that currently joins `nest_lane_item`
   directly, and confirmation that the split path writes the
   `lane_item_dependency` edges in the same transaction.
7. **A usage report on the legacy orderline path** — `order_lane_item`,
   `production_orderline_lane_item`, `single_item`,
   `internal_status_code_sequence` — showing where they are still relied on.

## 13. Open decisions (2026-08-19)

Recorded, not decided. Each of these blocks a piece of the configurator/spec
work; decide before building that piece.

1. **Quantity and size in the spec.** `job.spec` has `amount` and
   `spec_json` (width, height, …). How exactly do quantity and size enter the
   spec — dedicated columns, keys in `spec_json`, or both — and what does the
   configurator write?
2. **Bundles.** Ordering in steps (5, 10, 15, 25, …). Is that a property of
   the option tree (allowed quantities per product), of the spec, or a
   pricing concern only?
3. **Print-coverage and print-method.** Merging them is — for now —
   technically awkward and cannot be mapped back from Probo. Two options
   discussed:
   - multiple `option_code`s selected at once in the tree: solves it
     technically, semantically bad (and worse for AI);
   - keep them separate, rename the coverage values for the buyer
     ("print-coverage.single-sided" presents as "enkelzijdig full color") and
     auto-select the print-method through a `depends_on`, with the content
     override on the presentation. Semantically the best route. **Leaning:
     this one.**
4. **structure_direction.** Same approach: a content override on the
   presentation.
