# Plan: get_plan_lanes generiek, drie borden werkend

Vervangt `nest-planning-lane-items.md` en `testplan-impose-planning.md` (verwijderd;
wat daarin af was, is af — de kernbegrippen staan hieronder opnieuw waar ze nodig zijn).

**Doel:** impose_plan (76), impose_resource_plan (78) en production_resource_plan (81)
werkend; print_schedule (75) blijft ongemoeid werken. `action.get_plan_lanes` is de ene
read voor de lanes (labels) van elk bord.

## de read: action.get_plan_lanes

Verhuisd van mock naar action (het lane-model woont daar). Twee modi, geschakeld door
`p_steps`:

| modus | aanroep | levert |
|---|---|---|
| materiaal (`p_steps` null) | 75, 76: labels én items-basis (via `get_impose_plan`) | één rij per gepland moment van het dagplan, `imposition_group_id` = alias van `material_id`; plus de noop-vensters per tenant |
| resource (`p_steps` gevuld) | 78: `steps ['impose']`; 81: `steps ['print','coat','laminate','route','cut']` + `plan_type 'production-plan'` | één rij per resource van die steps: pad, uid, naam, tenant (padpositie 0 = site-abb), formule + constanten uit `production.resource_setting`, `next_start_offset_in_seconds` uit `resource_json` |

Resource-modus, twee bronnen (besloten 26 aug):

- **production-plan**: de lanes van het nieuwste dagplan (`action.plan → plan_lane →
  lane.resource_path`); `lane_id` en `plan_lane.sort_order` reizen mee, dus de
  groepering `[tenant_id, lane_id]` van bord 81 klopt. Machines zonder lane in het
  plan zijn onzichtbaar.
- **andere plan-types** (impose: het materiaalplan heeft geen resource-lanes): alle
  resources van de steps, gefilterd op line_type via padpositie 1; `lane_id` null,
  bord 78 groepeert op `[tenant_id, resource_uid]`.

`route` heeft nog geen resources in `relation.resource`; die lanes verschijnen vanzelf
zodra resources die step krijgen (besloten: geen datascript nu).

## de offset-regel

Alleen een **fixed group** (`coalesce(lane_item, klassetijd uit lookup_nest_moments)`)
of een **gepind** item (eigen offset) draagt `start_offset_in_seconds`. Elk ander item
is een filler en levert **null** — de frontend ketent fillers zelf (fixed groups eerst,
dan pinned, rest automatisch; `chain_scope` plan/lane). Een verplaatst maar ongepind
item veert bij verversen terug (besloten: verplaatsen pint níet automatisch).

`next_start_offset_in_seconds` — gecheckt 26 aug: komt correct uit
`relation.resource.resource_json ->> 'next_start_lag_in_seconds'` (alle 17
impose-resources: 900; andere steps hebben er geen, en dat is goed — echte duren).
Het connector-mechanisme vervangt deze kolom later.

## wat er per bord om staat

| bord | wijziging |
|---|---|
| 75 print_schedule | niets — alleen regressie-checken |
| 76 impose_plan | alleen de offset-regel (SQL) en de primary keys |
| 78 impose_resource_plan | label-params: `steps ['impose']` i.p.v. `only_starting_today`. Label-`group_by` blijft `[tenant_id]` — de lane-koppeling loopt via `set_group_fields [tenant_id, resource_uid]`, niet via de label-groepering (teruggedraaid 27 aug) |
| 81 production_resource_plan | label-src `get_production_plan` → `get_plan_lanes` met `steps` + `plan_type 'production-plan'` |

`site.data_table`: `query` → `action.get_plan_lanes`; primary keys zonder het
gedropte `copy_index` — `get_plan_lanes` `[tenant_id, material_id,
production_line_id, lane_item_id, resource_uid]`, `get_impose_plan` idem zonder
`resource_uid` (contract-regel: elke gedeclareerde kolom moet geserveerd worden).

## performance (gemeten 27 aug)

`get_impose_plan` deed 2,57 s. Waar dat zat, met de fix:

| onderdeel | was | oorzaak | fix |
|---|---|---|---|
| 24 aggregate-calls (één per nest-set) | ~2,0 s | `get_production_orderline_detail` filtert in nest-scope pas op de láátste regel op de nests: elke call verrijkte eerst alle 2141 open orderregels (~100 ms per call) | vroege scope-filter in `orderline_base` (helpt ook `get_production_plan`, zelfde patroon) |
| forecast-bijvangst per call | in het bovenstaande | nest-calls zonder materiaalfilter: 238 forecast-rijen per call terug, 0 gebruikt | `get_impose_plan` geeft per set de materialen van het item mee (`p_material_ids`) |
| `get_plan_lanes` met `only_starting_today` | 519 ms (49 ms zonder) | intervalcheck (`get_interval_dates` + `min(action.dates)`) per rij, 65× | één check per distinct (start, interval)-paar — 32 paren, join terug per rij, semantiek identiek (geverifieerd) |

## performance (gemeten 4 sep, servertijd via EXPLAIN ANALYZE)

Aanleiding: 114 ms voor de lanes en 665 ms voor het schema in de browser. De
tunnel/roundtrip zit daar in; op de server:

| read | was | nu (getest als losse query) | wat het was |
|---|---|---|---|
| `get_plan_lanes` materiaal, `only_starting_today` (76 + binnen `get_impose_plan`) | 135 ms | 16-21 ms | 16× `get_interval_dates` als function scan, 5-9 ms per call (70.000 buffers) |
| `get_plan_lanes` materiaal zonder | 38 ms | 38 ms | — |
| `get_plan_lanes` resource (78, 81) | 12 ms | 12 ms | — |
| `get_print_schedule` | 465-545 ms | ~250 ms | zie onder |
| `get_interval_dates` los | 5-9 ms | 0,5 ms | nummerde de hele `action.dates` (4.000 rijen, vier keer per call) |

`get_interval_dates` is herschreven: één scan, begrensd op de datums die er
toe doen, de ankers als window-aggregaten. Output identiek over 5.224
combinaties van anker × interval × look-ahead × offset × weekend × dagen-vrij ×
tenants (read-only vergeleken met de oude functie). Elke caller profiteert
(`get_plan_lanes`, `get_print_schedule`, `get_components_inflow`,
`get_batch_orderlines`, `get_nest_planning`).

`get_print_schedule`, waar de 500 ms zat en wat eraan gedaan is:

| onderdeel | was | fix |
|---|---|---|
| `evaluate_many_nas` per rij × maat (1.721×) | ~120 ms + 175 ms voor het schoonmaken van 19 variabelen per rij | de evaluator krijgt alleen de variabelen die de formules lezen (`needed_key`, uit de rechterkant van elke formule; 19 keys kosten 4× zoveel als 7), de constanten per materiaal worden één keer schoongemaakt, en er is één evaluatie per distinct variabelenset (803 i.p.v. 1.721) |
| `get_production_forecast_material` | 65-110 ms | de `actual`-som over `component_specs` heeft geen datum-index: bitmap over het hele materiaalbereik. Index `ix_component_specs_production_date` (include line, material, sqm, status) → index-only scan |
| intervallen | inline al goedkoop | krijgt nu `p_tenant_ids` mee, zoals de as en het anker (dezelfde fout als in `get_plan_lanes` op 27 aug: zonder tenants verschoof een vrije dag van tenant A de intervallen van tenant B). Zonder tenantfilter identiek; mét tenantfilter verschuiven de kaarten van materialen met een anker in het verleden waar een andere tenant vrij was — dat is de bedoeling |

Output van `get_print_schedule` zonder tenantfilter: 1.362 rijen, 0 verschillen
met de oude functie. Na de eerste deploy bleek `only_starting_today` 5-6 s te
kosten (was 640 ms): de planner inlinede `material_vars` in `row_base` en bouwde
de constanten per kaartrij opnieuw, en joinde `calc` per rij op jsonb. Nu
`MATERIALIZED` en een `md5`-sleutel voor de join: 280-330 ms mét filter, 150-190
ms zonder, beide 0 verschillen met de oude functie. Wat overblijft (~250 ms) is het bouwen van 1.362
jsonb-rijen en de forecast; de index haalt daar nog ~50 ms af.

**Bord 76/78 stonden stuk.** `mock.get_impose_plan` leest
`production_impact_in_seconds` van de aggregate, maar de live
`mapping.get_production_orderline_aggregate` was nog de versie zonder die kolom
(`column na.production_impact_in_seconds does not exist`). De repo-versie was
niet gedraaid. Staat in de draailijst hieronder.

### te draaien (4 sep, in deze volgorde)

1. [`sql/action/get_interval_dates.sql`](../sql/action/get_interval_dates.sql) — create or replace, zelfde signatuur
2. [`sql/mock/get_print_schedule.sql`](../sql/mock/get_print_schedule.sql) — drop + create
3. [`sql/mapping/get_production_orderline_aggregate.sql`](../sql/mapping/get_production_orderline_aggregate.sql) — repareert 76/78
4. [`sql/migration_component_specs_production_date_idx.sql`](../sql/migration_component_specs_production_date_idx.sql) — `CREATE INDEX CONCURRENTLY`, los draaien, niet in een transactie
5. het manifest: zie `docs/imposition-unit-manifest.md` "draaivolgorde" (functie, crud_nest, backfill)
6. [`sql/check_plan_reads.sql`](../sql/check_plan_reads.sql) — de read-only checks achteraf

## te draaien (in deze volgorde, één sessie voor 1-2)

1. [`sql/action/get_plan_lanes.sql`](../sql/action/get_plan_lanes.sql) — dropt
   `mock.get_plan_lanes`, maakt `action.get_plan_lanes` (offset-regel + resource-modus).
2. [`sql/mock/get_impose_plan.sql`](../sql/mock/get_impose_plan.sql) — enige caller,
   wijst nu naar action.
3. [`archive/sql/migrations/migration_move_get_plan_lanes.sql`](../archive/sql/migrations/migration_move_get_plan_lanes.sql)
   — data_table query + primary keys (gedraaid; gearchiveerd sep 2026).
4. [`sql/update_data_group_partial.sql`](../sql/update_data_group_partial.sql) —
   data_groups 78 en 81.

Gedraaid 26 aug; de performance-scripts (scope-filter, materiaal per nest-call,
interval-hoist) 27 aug. Meting daarna: 2,32 s — de vaste voet is plantijd
(~40 ms per set-call, `force_custom_plan` op de detail); besloten: per-set-calls
blijven (semantiek boven snelheid), batchen afgewezen.

## de duur van bord 76: production_impact_per_unit (besloten 27 aug)

De duur van een impose-moment is de **standaard productie-impact van zijn
orderregels**, niet de machine-formule. Bron:
`mapping.spec_unit_manifest.production_impact_per_unit` (seconden per unit,
bestond al, stond overal 0). Cees zet de formules op de xbom-rijen
(`print-method.*`, `cutting-method.*`, `param_json.formula`); de builder
evalueert ze per orderregel (variabelen: `width`, `height`, `amount`,
`unit_sqm`, `sqm` + numerieke param_json-keys). Leesketen: detail
(`production_impact_in_seconds` = units × som per-unit) → aggregate (som per
groep) → `get_impose_plan` (`duration_in_seconds = greatest(som, 900)`).
Bord 76 leest weer de kólom; 78 blijft op de machine-formule
(`param_json.duration_in_seconds` via evaluate). `get_impose_plan` serveert nu
ook `resource_path` (contract: `valid_resources.resource_field` noemt hem).

Te draaien (volgorde):

5. [`sql/mapping/create_spec_unit_manifest.sql`](../sql/mapping/create_spec_unit_manifest.sql)
   — builder evalueert de xbom-formule naar `production_impact_per_unit`.
6. Formules door Cees op de xbom-rijen; test op een paar orderregels
   (stappen in [`sql/migration_impact_backfill.sql`](../sql/migration_impact_backfill.sql)).
7. [`sql/migration_impact_backfill.sql`](../sql/migration_impact_backfill.sql)
   — alle open orderregels opnieuw resolven.
8. In één sessie:
   [`sql/mapping/get_production_orderline_detail.sql`](../sql/mapping/get_production_orderline_detail.sql) →
   [`sql/mapping/get_production_orderline_aggregate.sql`](../sql/mapping/get_production_orderline_aggregate.sql) →
   [`sql/mock/get_impose_plan.sql`](../sql/mock/get_impose_plan.sql)
   (return-types wijzigen, drops staan erin).
9. [`sql/update_data_group_partial.sql`](../sql/update_data_group_partial.sql)
   — 76: `duration_field` terug naar `duration_in_seconds`.
10. [`sql/action/get_plan_lanes.sql`](../sql/action/get_plan_lanes.sql)
    — intervalcheck alleen voor de paren van het dagplan (15 i.p.v. 32).

Zonder backfill valt elke duur op de 900-vloer — geen regressie; het bord
krijgt breedte zodra 5-7 gedraaid zijn.

## tests per stap

Na 1-2 (read-only, Claude draait):

- **offset-regel**: `select fixed_group, is_pinned, count(*) filter (where
  start_offset_in_seconds is not null) from action.get_plan_lanes(now(), 'print',
  'sheet') group by 1,2` — fixed-rijen houden hun klassetijd, gepind houdt zijn eigen
  tijd, fillers 0 met tijd; noop-rijen ongewijzigd.
- **regressie 75**: `mock.get_print_schedule(now(), 'sheet')` per datum/moment gelijk
  aan vóór de wijziging (75 leest de labelvelden `fixed_group` en
  `next_start_offset_in_seconds` óók — het bord moet niets merken).
- **regressie 76-items**: `mock.get_impose_plan` zelfde rijenaantal als ervoor;
  fixed-rijen met starttijd, fillers zonder.
- **resource-modus impose**: `action.get_plan_lanes(now(), 'print', 'sheet', p_steps
  => '{impose}')` → 5 lanes (dk 210/320/320-kudu, bh 210/320), elk met
  `next_start_offset_in_seconds = 900` en formule + constanten.
- **resource-modus production**: `action.get_plan_lanes(now(), 'print', 'sheet',
  p_plan_type => 'production-plan', p_steps =>
  '{print,coat,laminate,route,cut}')` → exact de lane_id-set van
  `mock.get_production_plan(now(), 'print', 'sheet')`.

Na 3-4: dezelfde twee resource-checks via de site-api (de borden), daarna de
bordcheck door Cees:

- 76: fixed groups op hun momenten (12:00/16:45/21:45), fillers automatisch geketend.
- 78: lanes per imposer, items gebundeld per resource, ketening per lane.
- 81: lanes per machine van het dagplan, level-0-items met duur, realized-blokken.
- 75: onveranderd.

Draaiproef daarna: `mock.generate_plan` voor overmorgen — fixed/pinned komen met tijd
terug, fillers zonder.

## bevindingen 27 aug: breedte en stapeling op bord 76

Diff van 76/78 tegen de data_groups van twee dagen terug (`nest_schedule` /
`nest_resource_schedule`, git HEAD), renames en tooltips daargelaten:

- **76**: alleen `duration_field: "duration_in_seconds"` →
  `"param_json.duration_in_seconds"` plus de nieuwe `evaluate`- en
  `valid_resources`-blokken. Niets anders.
- **78**: dezelfde duration/evaluate-wijziging, plus de labelwijzigingen van 26 aug
  (steps-param, group_by op resource, `next_start_offset_in_seconds_field`).

**Correctie 27 aug:** `fixed_group_field` en `next_start_offset_in_seconds_field`
horen op `timeline_config`, niet op `label_options` — een niveau te diep. Cees heeft
76 en 78 omgezet, het contract (`docs/contracts/drag-and-drop.md`) is bijgewerkt.
75 `print_schedule` heeft ze nog op `label_options`; dat bord werkt en blijft
ongemoeid tot besloten wordt of het meegaat.

Twee dagen terug rekende `get_nest_schedule` de duur server-side
(`greatest(ceil(gross_sqm × 45), 900)`) en las het bord de kólom — vandaar breedte.
Nu is de kolom een 900-vloer en moet de breedte uit de client-evaluate komen.
De data is compleet (alle 47 rijen evalueren server-side naar een duur, 0 missers)
en 76 en 78 lezen dezelfde rijen met dezelfde evaluate-config — het verschil
(78 wél breedte, 76 niet) kan dus niet uit data of data_group komen: het zit in het
`chain_scope: "plan"`-pad van de client. De stapeling is hetzelfde wortelprobleem:
alle leden van een fixed group delen bewust de klassetijd (18→21:45, 24→16:45,
30→12:00) en de client hoort ze back-to-back uit te rollen op `duration` en
`order_field` (contract) — zonder duur klapt die uitrol dicht tot "onder elkaar".
Opgelost via het impact-model (zie *de duur van bord 76* hierboven): de kolom
draagt weer een echte duur en 76 leest de kolom.

## open

- **Ketening via connector**: `next_start_offset_in_seconds` en de kolom-gebonden
  ketening vervallen zodra het connector-mechanisme van `plan_timeline` er is;
  omschakelpunt gemarkeerd in `get_plan_lanes`.
- **Echte impositiegroepen**: stempelen en resolutie schakelen van de material-alias
  naar `catalog.get_imposition_group`; elke alias-join draagt een comment.
- **T6 write-through**: `action.crud_lane_item` verplaatsen/kopiëren/verwijderen en
  kijken of het patroon (`mock.material_impose_plan`) meebeweegt; daarna
  `generate_plan` voor overmorgen.
- **45 s/m²-constante** in de realized-kant van `get_production_plan` hoort in
  `production.resource_setting` op de printpaden.
