# handoff: the time scale control — 7 sep

The timeline layout reads `timeline_config.time_scale_config`. Its `input_data`
names a `src` and the fields below; the rows of that `src` are the axis.

## fields

| key | what the field holds |
|---|---|
| `offset_field`, `end_offset_field` | start and end of the segment in seconds since midnight of day 0, the day of `until`; negative before it, past a full day after it |
| `day_offset_field` | integer: the day of the segment relative to day 0 |
| `duration_field` | the real length of the segment |
| `segment_size_field` | the width to draw the segment with |
| `title_field` | filled on a marker segment, empty on a plain one |
| `class_names_field` | classes of the segment |
| `time_field` | the clock time of the segment |
| `x_axis.title_field` | the value that groups columns, one group per day |
| `sort_order` | position on the axis; lower sits before higher |
| `is_current` | true on the segment that holds now |

## behaviour

- The axis is the rows in `sort_order`. Positions are per segment, not linear
  in seconds: a point on the axis is a segment plus a fraction of that segment.
- Consecutive segments may leave a gap: `end_offset` of one below `offset` of
  the next. That time does not exist. Draw nothing for it, and place an item
  whose offset falls in a gap at the start of the next segment. An item that
  spans a gap keeps its width in segment terms; the gap contributes nothing.
- A plain segment (`title_field` empty) is a column, `segment_size_field`
  wide. A marker segment (`title_field` filled) overlaps a column: draw it over
  that column at its own offset and duration, never as a column of its own.
- The items of the board use the same axis: their `offset_field` counts the
  same seconds since midnight of day 0, and an item may start before day 0 or
  on a later day.
- When the board spans more days than the rows cover (`timeline_seconds`),
  repeat the rows with `day_offset` 0 for every next day: the same segments,
  offsets shifted by one day per day, the day-group value one day further. The
  stretch between a day's last segment and the next day's first is a gap like
  any other.

## 8 sep: the label read is split in two

`action.get_plan_lanes` was one function with two modes; it is two now, and the
`src` of the label read changes with it.

| board | `label_options.input_data.src` | was |
|---|---|---|
| 75 print_schedule, 76 impose_plan | `get_plan_lanes_imposition_group` | `get_plan_lanes` |
| 81 resource_plan | `get_plan_lanes_resource` | `get_plan_lanes` |

New on `get_plan_lanes_imposition_group`: `day_offset` (integer, the day of the
row relative to day 0). `start_offset_in_seconds` counts from midnight of day 0,
so a row of the day before is negative. The read order is `day_offset` first,
then `sort_order`.

`get_plan_lanes_resource` carries `step` and no longer carries the material
columns that were always empty on a resource lane (`material_id`,
`material_name`, `imposition_group_id`, `production_line_id`, `delivery_hours`,
`min_delivery_hours`, `fixed_group`, `is_pinned`, `start_offset_in_seconds`,
`lane_item_id`, `data`). It always returns resource lanes, also without a
`steps` param — the old function fell back to material lanes there.

## 8 sep: de dagen zijn werkdagen

Bord 76 leest nu `p_look_back_days` / `p_look_ahead_days` dagen mee, en die
dagen zijn **werkdagen**: de dag voor een maandag is de vrijdag ervoor, een
weekend of een verplichte vrije dag is geen dag.

| veld | wat er in zit |
|---|---|
| `day_offset` | de plek op de as: 0 de dag van `until`, −1 de dag ervoor |
| `nest_date` | de plandatum áchter die plek — voor `day_offset` −1 op een maandag dus de vrijdag |
| `start_offset_in_seconds` | onveranderd: seconden vanaf middernacht van dag 0, dus negatief voor de dag ervoor |
| `start_at` | het echte moment van de rij: `nest_date` plus de tijd van de dag uit de offset. Dat is een andere datum dan `middernacht dag 0 + offset` zodra er een weekend tussen zit |

Leesvolgorde: `day_offset` eerst, dan `sort_order` — die begint per plan opnieuw.

De lane-read (`get_plan_lanes_imposition_group`) draagt `plan_date` als nieuwe
kolom naast `day_offset`, zodat een lezer de datum niet uit de offset hoeft te
rekenen.
