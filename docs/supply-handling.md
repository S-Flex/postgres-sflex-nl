# Supply handling: `catalog.item.item_json.specs`

How much material a format holds, how much a job uses and how much is left. One shape for
every material: there is no separate handling for rolls and sheets.

## the four properties

Roll and sheet material use the same four properties, all in cm.

| property | means | roll | sheet |
|---|---|---|---|
| `width` | usable width of the material | the roll width | the sheet width |
| `min_height` | smallest usable step in the running direction | 1 | the sheet height |
| `max_height` | largest height that fits in one nest | the nest length, e.g. 1200 | the sheet height |
| `supply_unit_height` | total height in the supply unit | the roll length | number of sheets × sheet height |

Everything the planning and the stock reckon with comes from these four. Nothing branches on
material type; `media_type` is a label, not a rule.

## using and what is left

The used amount is a number, expressed in cm of height. It is valid when

- it is a multiple of `min_height`, and
- every individual nest stays within `max_height`.

What is left is always `supply_unit_height - used`.

A pallet of 10 sheets of 300 × 200 cm is simply `supply_unit_height = 2000`; using 4 sheets
consumes 800. A roll of 1200 cm with `min_height` 1 can be used at any whole cm, as long as no
single nest is longer than its `max_height`.

## where it lives

`catalog.item.item_json`, one entry in `specs` per format the material comes in:

```jsonc
{
  "specs": [
    {
      "width": 150.1,
      "height": 305.1,              // the format as it is ordered
      "min_height": 305.1,
      "max_height": 305.1,
      "supply_unit_amount": 60,     // how many min_height steps the supply unit holds
      "supply_unit_height": 18306,  // min_height * supply_unit_amount
      "company_id": 14,
      "article_code": "IN-DIBBUD-3-150X305"
    }
  ],
  "params": { "weight": 3.15, "thickness": 0.3 },
  "media_type": "sheet",
  "material_id": 25
}
```

- `supply_unit_height` is derived: `min_height * supply_unit_amount`. It is stored, not
  computed at read time, so a reader needs one key and not two.
- `width`, `min_height`, `max_height` and `supply_unit_height` are the contract; `height`,
  `supply_unit_amount`, `company_id` and `article_code` say where the format comes from.
- the physical properties are not in a spec: `weight` and `thickness` sit in `params`, one set
  for the whole item.
- `catalog.item` is global; there is no tenant in here.

## the unit is in the data, not in the key

Dimensions are in cm, the default for the project, so no key carries a unit. A value that means
something else says so in its own key (`sqm`, `delivery_hours`). `supply_unit_height` is cm like
every other height, which is why a pallet of sheets and a roll can be compared without knowing
which is which.

## how the planning uses it

- a run in `legacy.imposition_group.rules_json` carries a `target` with `min_height` and
  `max_height`: how much height that run aims to fill (`docs/schedule-base.md` §4.2)
- `max_height` bounds a single nest, `min_height` is the step the used amount snaps to
- the sizes of a group come from the material item of the first path of the group, not from
  `mapping.material_production_line` (`docs/schedule-base.md` §4.5)

## where it came from

`mapping.material_production_line.line_json.specs` is the legacy source and still feeds
`catalog.get_imposition_group_specs` and the old planning chain. Its entries carry the same
format keys plus `weight` and `thickness`, which became `item_json.params` on the item. The
legacy specs have no `supply_unit_height`.
