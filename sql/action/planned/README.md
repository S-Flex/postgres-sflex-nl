# planned — ontworpen, nog niet uitgerold

Wat hier stond (de append-only `imposition_lane_item`, `get_lane_item_impositions`,
`crud_imposition_lane_item`) is op 5 sep 2026 uitgerold als stap 2 van
`docs/schedule-base.md` §9; de bestanden staan nu in `sql/action/`.

Wat nog open staat: `imposition_id` is een alias van `legacy.nest.nest_id`
zonder foreign key. Zodra de verhuizing van `legacy.nest` naar
`production.imposition` rond is, krijgt de kolom een foreign key naar
`production.imposition` en verhuizen de bestaande id's mee.
