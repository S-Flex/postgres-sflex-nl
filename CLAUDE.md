# Project conventions

Working language is English: code, comments, SQL, JSON, docs, commit messages, handoffs.

Stack: PostgreSQL (owner `xfw3`), React 19.2.8, Tailwind 4.3, UntitledUI/react, Figma MCP.

## General
- always the simplest, shortest solution
- semantics in the data, not in the code — business logic in JSON, never hardcoded
- generic components, no special cases in code
- no column or key named `id` — always descriptive (`nest_group_id`, `resource_uid`, ...)
- never assume — ask when in doubt

## Planning
- when I ask for a plan: no assumptions, ask questions until everything is clear
  (which tables, which keys, which config, what happens at the edges)
- unknown is a question, not a guess — ten questions up front beat a wrong plan
- plan first, code only after I approve the plan

## Functions
- write the shortest function that does the job, then look again: fewer steps,
  fewer branches, fewer parameters?
- one set-based statement beats a loop, one query beats two
- no parameters, branches or helpers "for later"
- if a function needs a special case, that case belongs in the data

## Database access
- I have a direct connection to postgres, read-only:
  `select`, `explain`, catalog/definition lookups — I run those myself
- anything that changes something I never run: ddl, dml, `create/alter/drop`,
  grants, `vacuum`, functions and views — not through a detour or helper script either
- changes always go like this: I deliver the full script, you check it and run it
- I wait until you say it ran, and never invent the outcome of something not yet executed
- unsure whether something reads or writes? then I deliver it as a script

## SQL
- always qualify functions with the schema (`mapping.crud_ticket`), also in
  `ALTER FUNCTION ... OWNER TO xfw3`
- crud functions are always set-based: no FOR loop, no temp table —
  use `jsonb_array_elements(p_param_json) AS el`, fields via `(el->>'field')::type`
- `ON CONFLICT DO UPDATE`: only `EXCLUDED.*`, never `rec.*`
- `RETURNS TABLE`: first line after `AS $$` is always `#variable_conflict use_column`
- comments always in English
- breaks/non-working time stretch the job (never separate spacer rows)
- non_working_times go to the frontend/timeline as JSON; never compute start/duration server-side
- resources: `resource_uid` is the key, `resource_path` (ltree) the tree —
  8 fixed positions `site.material.step.width.medium.brand.type.serial`, see `docs/resource-path.md`

## JSON
- snake_case for keys, kebab-case for code values
- `i18n` (not `ml`) for multilingual blocks
- `template` (not `text_formula`) for template strings
- with "code" as main key: property `content` for all text, plus a property for what you create
- property names are unambiguous, clear and generic: no overlapping or duplicate names
  for the same concept, so every key means the same thing everywhere and stays reusable.
  Before you invent a key, look up what the other data_groups call it
  (`node` inventory of all `_field`/`_config` keys in `xfw3_site_data_group.json`)
- fixed vocabulary in a `<layout>_config`: the kind of a row is a **set**
  (`set_field`, `set_order_field`); what differs per kind lives in `set_overrides`
  keyed by the set value; a formula computes via `evaluate {formula_field, params_field}`;
  the sublevel of a row is `items` with `data_field` for the array
- a key that points at a field ends in `_field` and carries no unit
  (`duration_field: "duration"`, `hours_field: "delivery_hours"`, not `delivery_hours_field`);
  the text slot is `title_field` everywhere (also when the value is `i18n`); the title of
  a set is `set_title_field` (next to the global `title_field`); the x-axis of a chart
  is `x_field`; a string with `${...}` is a `template`, not a `field`

## Lookup JSON
- the content of a lookup lives in `json/lookup/<schema>/<lookup>.json`
- the folder is the schema, the filename is the lookup name, the file holds the `lookup_json` itself
- example: `SELECT lookup_json FROM production.lookup WHERE lookup = 'lookup_nest_moments'`
  lives in `json/lookup/production/lookup_nest_moments.json`
- writing or rewriting a function that reads `lookup_json` and the file is missing:
  ask for it to be added, never invent the content

## Data_group JSON
See `docs/data-group-governance.md` for the full analysis.

- a key has the same shape everywhere — a list stays a list, also with one element
  (`children`, `hidden_when`, `src` are always an array)
- config keys never sit between field names: `field_config` holds fields only,
  the grid of those fields is `fields_class_name` next to it;
  `class_name` is always the class of the element itself (`ui.class_name` on a field)
- field_config keys support dot notation in jsonb columns (`impact_json.rework_count`),
  also combined with `aggregate_fn` — don't add a flat column to the function
  when the field already sits in a json
- `ui.type` says what the value is, `ui.control` how it is shown
- `title` is the default text slot in `i18n` (not `text` or `label`); other slots
  (`subtitle`, `abb`, ...) only when they really mean something else
- `<name>_field` means "the name of a field", without suffix it is the value itself
- default units are the contract and stay out of the key: time in seconds
  (`duration`, `start_offset`, `lag`), dimensions in cm (`width`, `height`);
  only a deviating unit goes in the key (`delivery_hours`, `sqm`), never in a separate `unit` property
- percentages always `_percentage` (not `_perc`, `_pct`, `_percent`)
- one condition shape: `{field, op, value}`, comparing two fields uses `value_field`
- sorting: `sort: {field, direction}`; grouping: `group_by`, always an array of id columns;
  the title per level is in `group_title_fields` (same order)
- drag & drop: `docs/contracts/drag-and-drop.md` is leading (`drop` block, `order_field`;
  `within_fields` ⊆ `group_by`, ids)
- chart config keys are `<chart>_chart_config`, variants are properties or a prefix
  (`stacked_bar_chart_config`), no separate key per variant
- booleans with `no_*` / `hide_*` default to false

## Frontend
The frontend is a meta-data-driven UI renderer. It has two inputs and no domain knowledge.

- input 1 is the data (rows), input 2 is the data_group that describes that data
- per layout the data_group holds a `<layout>_config` (`timeline_config`, `table_config`, ...)
  that tells the renderer which field means what (`offset_field`, `type_field`, `x_field`, ...)
- the renderer contains no field names, no business rules, no special cases —
  a component reads its meaning from the config, so the same component serves every data_group
- new behaviour comes from the data first. Only when the config genuinely cannot express it
  do you add a new, generic mechanism — never an `if` for a single case
- so: changing what is shown is a data change; changing what the renderer can do is a code change

Handoff or prompt to the frontend mentions only what is conceptually new for the renderer:
a new config key or `_field` key, a new mechanism, a bug. One line per point, no render
instructions, no expected numbers, no domain explanation.

Do not mention, because it is data and already works: new, renamed, moved or no-longer-hidden
fields, titles, params, filters, sorting, class_names. A field that becomes visible simply
loses its `hidden: true`.

## Tokens and prompt cache
The start of the session (these conventions, contracts, schema) is cached and reused for free
as long as it stays identical. Everything after the first change is recomputed.

- keep the stable part stable: edit CLAUDE.md and the contracts between sessions, not halfway
  through one — an edit invalidates the cache for the rest of that session
- put stable material at the top (conventions, schema, contracts), the changing work at the bottom
- read a file once; don't re-read what is already in context
- use the built-in Read, Grep and Glob tools instead of `cat`, `grep` and `sed` in bash:
  no permission prompt inside the working directory, and less output ends up in context
- locate first, then read: find the line number with a narrow pattern, then read only that part
- fetch targeted data: named columns with a `limit`, `pg_get_functiondef` for a single function,
  `jq` with a path for json — never a whole table, file or dump
- deliver only the changed function or the changed block, not the whole file, unless I ask for the file
- don't echo long inputs back; refer to them
- one subject per session — start a new one instead of dragging a long history along

## Style
- titles: only the first word capitalized
- no technical jargon, short explanations
