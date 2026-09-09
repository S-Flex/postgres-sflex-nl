# handoff: OEE-donut (29) — legenda als filter, OEE in het midden, planning als binnenring

Datum: 2026-09-05. Voor de Claude Code-sessie in de frontend-repo. Hoort bij
`docs/plan-oee-donut.md` (het besluit) en `docs/handoff-oee-frontend.md` (het
contract van de area-chart, dat de donut nu deelt).

## wat er verandert aan de data

De donut leest niet meer `get_resource_oee_aggregate` maar
`get_resource_state_shift_totals`, dezelfde data_table als de area-chart (62),
voor één dag. Per aanroep komen dezelfde rijen terug als voor één dag van de
area-chart:

- één rij per state die getoond wordt (`state`, `counts_as`,
  `duration_seconds`, `state_json` met `fill`/`color`/`class_name`/`i18n`,
  `sort_order`)
- één synthetische rij `available` (de rest van het productievenster) en,
  als er niet-aangevinkte breakdown/offline-tijd is, één rij `unavailable`
- één rij `planned` (de geplande productietijd van de dag)
- op elke rij dezelfde `param_json` (alle tijden in seconden) en `oee_json`
  (`producing_oee`, `planned_percentage`, … — 0-100)

De fold-regel van de area-chart geldt hier ook: een sub-state (setup in
producing) is alleen een eigen rij als hij zelf is aangevinkt; anders zit hij
in de producing-rij. Wat niet is aangevinkt zit in `available` (verliezen) of
`unavailable` (breakdown/offline). De som van alle rijen behalve `planned` is
dus altijd `param_json.total_shift_in_seconds`: de buitenring sluit.

## de config (data_group 29)

```json
"donut_chart_config": {
  "mode": "duration",
  "set_field": "counts_as",
  "set_order_field": "sort_order",
  "aggregate_field": "duration_seconds",
  "aggregate_fn": "sum",
  "content_field": "state_json.i18n",
  "fill_field": "state_json.fill",
  "color_field": "state_json.color",
  "class_names_field": "state_json.class_name",
  "center": { "field": "oee_json.producing_oee", "type": "percent" },
  "set_overrides": {
    "planned":     { "ring": "inner", "max_field": "param_json.total_shift_in_seconds" },
    "available":   { "no_legend": true, "no_tooltip": true },
    "unavailable": { "no_legend": true }
  },
  "legend": {
    "filter_param": "states",
    "items": ["producing", "setup", "idle", "starved", "blocked", "breakdown", "offline"]
  }
}
```

De keys `set_field`, `set_order_field`, `set_overrides`, `no_legend`,
`no_tooltip`, `fill_field`, `color_field`, `class_names_field` zijn dezelfde
als op de stacked-area-chart en werken hetzelfde. Weg zijn `code_field`,
`group_by`, `filter_field` en `center_field`.

## wat de widget moet kunnen

### 1. buitenring op `set_field`

Eén boog per waarde van `counts_as`, in de volgorde van `set_order_field`
(laag = eerst, met de klok mee): producing (190), setup (200), idle, starved,
blocked, available (275), breakdown (280), offline (300), unavailable (320).
Waarde: som van `aggregate_field`. Kleur en label uit `state_json`, zoals op
62. `available` is de kleurloze rest (`var(--state-available, transparent)`),
tekenen maar niet in legenda of tooltip (`no_legend`, `no_tooltip`).

### 2. midden: `center`

`center.field` is een pad in de rij (`oee_json.producing_oee`), `center.type`
zegt hoe het getoond wordt; `percent` is 0-100, zoals overal (85 → "85 %").
Elke rij van de groep draagt hetzelfde `oee_json`, pak het van de eerste rij.
Met meerdere resources in `resource_uids` levert de functie één groep (de
aanroep groepeert op resource; voor een groep machines kan de pagina
`group_by` op `step` of `line` zetten) en dus één `oee_json` — niet de
`oee_json`'s van losse rijen optellen.

### 3. binnenring: `set_overrides.<set>.ring: "inner"`

De set `planned` wordt niet in de buitenring gestapeld maar apart getekend
als smalle ring binnen de buitenring. Vulling: `duration_seconds` van die set
tegen `max_field` (`param_json.total_shift_in_seconds`), de rest van de ring
leeg. Kleur en label uit `state_json` van de planned-rij. Tooltip op de
binnenring: `planned` met `duration_seconds` als hh:mm en
`oee_json.planned_percentage` als percentage. Geen planned-rij (dag zonder
planning) = binnenring leeg, wel tekenen.

### 4. legenda als filter: `legend`

- `legend.items` is de vaste lijst codes die de legenda toont, in deze
  volgorde. Niet afleiden uit de rijen: een state met 0 seconden moet
  zichtbaar en aanklikbaar blijven (anders kun je hem nooit aanvinken).
- Label en kleur van een item: uit `state_json` van de rij met die code als
  die er is, anders uit de lookup `lookup_resource_state` (die de timeline
  (19) al laadt) op `code`.
- Aangevinkt = de code staat in de query-param `legend.filter_param`
  (`states`). Klik = toggle; de param wordt herschreven en de data_group
  herlaadt met de nieuwe `states`. Het is dezelfde param als filter 64 en
  area-chart 62 lezen, dus de keuze reist mee tussen de pagina's.
- Leeg maken mag niet leiden tot "alles": `states` zonder waarden betekent
  in de functie "alles" (`p_states is null`). Houd minimaal `producing`
  aangevinkt, of stuur bij een lege selectie de default `["producing"]`.
- Een niet-aangevinkt item tekent gedempt (zoals een uitgezette serie in
  een legenda); zijn tijd zit dan in `available` of `unavailable`.
- Setup aanvinken splitst de producing-boog in producing − setup en een
  setup-boog; het OEE-getal in het midden verandert daar niet van. Dat is
  gewenst.

### 5. tooltip op een boog

Per boog: label uit `state_json.i18n`, `duration_seconds` als hh:mm, en het
aandeel `duration_percentage` (0-100). `available` heeft geen tooltip.

## checken

Voor één machine, vandaag: dezelfde bogen en hetzelfde OEE-getal als de
laatste dag van de area-chart op `resource-oee-area-chart` met dezelfde
`states`. Met alleen `producing` aangevinkt: producing-boog = `producing_in_seconds`,
midden = `producing_in_seconds / (total_shift_in_seconds − unavailable_in_seconds)`.
Met alle zeven legenda-items aangevinkt is `available` 0 en vullen de
gekleurde bogen de hele ring: elke seconde van het venster zit in een van de
zeven buckets (missingdata en installation vouwen in offline, maintenance en
interruption in breakdown, starved.running en de operator-varianten in
starved en blocked).

## wat je níét hoeft te doen

De tabel achter de functie wordt door de database zelf actueel gehouden na
elke `crud_state_log`/`crud_data_log` (`docs/handoff-state-refresh.md`). De
donut hoeft niet te pollen of iets te verversen; elke load is bij tot en met
de laatste batch.
