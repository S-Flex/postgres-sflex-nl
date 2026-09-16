# Planning: plan → lane → lane_item — inventaris en vragen

Datum: 2026-09-05. Status: stap 1 (inventaris) en stap 2 (vragen) zijn af, stap 3
(het stappenplan, §5) is akkoord (5 sep). Bouw per stap; stand per stap staat
bij de stap.

De live tellingen en de profiling van de nest-planning staan in §4.

## 1. wat er is

### 1.1 het model in `action` (live, in de repo als DDL)

| tabel | sleutel | inhoud | opmerking |
|---|---|---|---|
| `plan` | `plan_id` | `plan_date`, `type`, `steps text[]`, `line_type`, `tenant_ids` | één schema voor één dag. Twee types in gebruik: `material-resource-plan` (impose- en printpatroon, uit `mock.generate_plan`) en `production-plan` (machine-dagen, uit `mock.generate_production_plan`) |
| `lane` | `lane_id` | `lane_date`, `resource_path ltree` | een strook tijd. Met `resource_path` = een machine-dag (uniek per datum+pad); zonder = een materiaallane van het patroon |
| `plan_lane` | `(plan_id, lane_id)` | `sort_order` | welke borden een lane tonen en in welke volgorde; één lane kan onder meer plannen hangen (foil-bord toont een printer uit de sheet-hal) |
| `lane_item` | `lane_item_id` | `lane_id`, `sort_order`, `start_offset_in_seconds`, `duration_in_seconds`, `fixed_group`, `is_pinned`, `no_split`, `level` (0 plan, 1 gerealiseerd), `source`, `source_ref` | het blok werk. `source_ref` = `<material_impose_plan_id>:<date>` voor patroon-items; `unique (source, source_ref)` |
| `lane_item_dependency` | `(from_lane_item_id, to_lane_item_id)` | — | **many-to-many staat al aan**: samengestelde primary key, cascade aan beide kanten, index op `to_lane_item_id`. Richting: `from` is de voorganger |
| `lane_item_event` | `lane_item_event_id` | `lane_item_id`, `status`, `moved_at` | append-only statusbewegingen |
| `imposition_lane_item` | `(imposition_id, lane_item_id)` | `sort_order` | **platte** linktabel, geen `moved_at`, niet change-only. `imposition_id` is een alias van `legacy.nest.nest_id` |
| `imposition_group_lane_item` | `(imposition_group_id, lane_item_id)` | — | het materiaal van een patroon-item; `imposition_group_id` is een alias van `material_id` |
| `non_working_times` | `non_working_time_id` | `type` (break/noop), `rule_path`, `weekday`, offset, duur | pauzes en noop-vensters, als JSON naar de client |
| `object` | `action_id` | pv2-planning (`action_json`) | de oude planning; leest de shift-builder nog voor `planned` |

### 1.2 al ontworpen, niet uitgerold: `sql/action/planned/`

Precies het model uit de opdracht, met andere namen:

| opdracht | `planned/` | verschil |
|---|---|---|
| `nest_lane_item (lane_item_id, nest_id, moved_at)` | `imposition_lane_item (imposition_lane_item_id, lane_item_id, imposition_id, moved_at)` | naam `imposition`; FK naar `production.imposition` (bestaat nog niet, dus geparkeerd) |
| `get_lane_item_nests(p_lane_item_id)` — recursief plpgsql, override of ouders | `get_lane_item_impositions(p_lane_item_id, p_as_of)` — één recursieve CTE omhoog langs `lane_item_dependency`, stopt bij het eerste item met eigen rijen | `p_as_of` en "alleen de laatste schrijfactie per lane_item telt" (een tweede split schrijft een nieuwe set, de oude blijft historie) |
| `crud_nest_lane_item(p_param_json)` | `crud_imposition_lane_item(p_param_json, p_no_results)` | zelfde insert; alle rijen van één aanroep delen `moved_at` |

De README daar zegt waarom het wacht: de verhuizing van `legacy.nest` naar
`production.imposition`. `mock.get_production_schedule` (het bestand heet
`get_production_plan.sql`) leest al `action.nest_lane_item` — een tabel die
niet in de repo-DDL staat. Of hij live bestaat: te checken (§4).

### 1.3 de mock-kant: patroon, generatie, reads, writes

| object | rol |
|---|---|
| `mock.material_impose_plan` | het **weekpatroon**: per weekdag, step, `resource_path`, `sort_order` een materiaal met offset/pinned. De template waar `generate_plan` een dagplan van stampt en waar `crud_lane_item` **terugschrijft** (een verplaatsing op het bord verandert het patroon) |
| `mock.material_print_schedule` | per materiaal: `interval_days`, `interval_start_date`, `delivery_hours`, `nest_moment_codes`, `resource_uids`, `tenant_id` — de instellingen waarmee de print-schedule zijn kaarten berekent |
| `mock.generate_plan(date, step, line_type)` | patroon → `plan` (type `material-resource-plan`) + materiaallanes + `lane_item` (`source = 'material-plan'`) + `imposition_group_lane_item`. Draait dagelijks vooruit voor 14 werkdagen in `site.refresh_derived_data` |
| `mock.generate_production_plan(date, step, line_type)` | `plan` (type `production-plan`) + machine-dag-lanes (`lane.resource_path`) + `plan_lane`. Schrijft **geen** lane_items |
| `action.get_plan_lanes_imposition_group` | de labels van de nest-borden (75, 76): één rij per lane van het dagplan, `p_step` = de step van het plan dat gelezen wordt. De as van `p_view_code` bepaalt welke dagen in beeld zijn en welke momenten rijen zijn; draagt `day_offset` en `plan_date` |
| `action.get_plan_lanes_resource` | de labels van 81: één rij per machine-lane van een plan van de dag, `p_steps` = de steps waarvan de resources lanes zijn |
| `action.get_lane_item_work` | het werk achter een lane-item: één entry per rij die een bord tekent (nests, of materiaal + lijn in het dagvenster), en terug de totalen, de lijst van de rij (per batch of per status), de manifest-lijst met sub-lijst, en per stap de snelste/traagste machine. Leest `get_production_orderline_detail` maximaal twee keer; 76 en 81 lezen hem beide |
| `mock.get_impose_plan` | de items van 76/78: `get_plan_lanes_imposition_group(only_starting_today)` + nests via `imposition_lane_item` + één `get_production_orderline_aggregate`-aanroep per nest-set; duur = productie-impact uit de manifests met een vloer van 900 s |
| `mock.get_print_schedule` | de kaarten van 75: **geen lane_items**. Per materiaal uit `material_print_schedule`: productiedagen via `get_interval_dates`, per `nest_moment_code` een kaart, met de forecast van die dag en een formule-evaluatie per maat. `lane_item_id` bestaat hier dus niet |
| `mock.get_production_schedule` | de items van 81: `plan_lane` → `lane` → `lane_item` (level 0) + `nest_lane_item` + aggregate per nest-set; level 1 uit de logs |
| `action.crud_lane_item` | update (verplaatsen/pinnen/sorteren), create (extra moment), delete; elke mutatie schrijft terug naar `material_impose_plan` |
| `action.get_lanes`, `get_plan_timeline`, `get_nest_moments`, `get_non_working_times`, `to_axis_seconds` | oudere lezers; `get_plan_timeline` is het pv2-bord (56) |

### 1.4 de borden

| bord | items | labels | drag & drop |
|---|---|---|---|
| 75 print_schedule | `get_print_schedule` (berekend) | `get_plan_lanes_imposition_group` | geen `drop`-blok |
| 76 impose_plan | `get_impose_plan` | `get_plan_lanes_imposition_group` | `drop: rank, within tenant_id, commit mutation` → `crud_lane_item` |
| 78 impose_resource_plan | `get_impose_plan` | `get_plan_lanes_resource` (`steps {impose}`) | idem |
| 81 production_resource_plan | `get_production_plan` (data_table) → `mock.get_production_schedule` | `get_plan_lanes_resource` (steps) | — |
| 79 impose_plan_inflow | orderregels per materiaal | — | — |

Rij-identiteit komt uit `site.data_table.data_table_json.primary_keys`;
`get_plan_lanes_imposition_group` en `get_impose_plan` hebben `lane_item_id` daarin,
`get_print_schedule` niet.

### 1.5 de begrippen die nu door elkaar lopen

| nu | betekent | zou moeten zijn (voorstel, te bespreken) |
|---|---|---|
| `nest` / `nest_id` (legacy, `imposition_lane_item.imposition_id` = alias) | een impositie (vel) | `imposition` — het model in `planned/` gebruikt dat al |
| `nest_lane_item` (opdracht, `get_production_schedule`) vs `imposition_lane_item` (live, planned) | lidmaatschap impositie ↔ lane_item | één naam: `imposition_lane_item` |
| `imposition_group` (= `material_id`) | het materiaal van een item | blijft alias tot de xbom-groepen er zijn (besloten eerder) |
| `material_impose_plan` (weekpatroon) | de template waar het dagplan van komt | het is geen plan maar een patroon: `lane_pattern`? |
| `material_print_schedule` (instellingen per materiaal) | intervallen, klassen, momenten | geen plan, geen lane: instellingen — `material_plan_setting`? |
| plan-type `material-resource-plan` | patroon-dagplan (impose én print) | de lanes zijn materialen, niet resources: `material-plan`? |
| `get_print_schedule`, `get_production_schedule`, `get_impose_plan`, `get_production_plan` (data_table) | de item-reads van 75, 81, 76/78, 81 | één werkwoordenset: `get_<bord>_items`? De data_table-namen zijn frontend-contract |
| `get_plan_lanes_imposition_group` / `get_plan_lanes_resource` | labels van de nest-borden en van 81 | gesplitst (was één functie met twee modi); `p_plan_type` is vervallen |
| `steps` op `plan`, `step` op `material_impose_plan`, `p_step` (de step van het plan) / `p_steps` (de steps van de resources) in reads | de productiestap(pen) | `p_step` en `p_steps` staan sinds de splitsing elk in hun eigen functie |
| `source = 'material-plan'` op `lane_item` | gestampt uit het patroon | volgt de naam van het patroon |

Hernoemen raakt: tabellen (data), functies (drop + create), `site.data_table`
(`query`-kolom; de `data_table`-naam is het frontend-contract), data_groups
(`src`, veldnamen), en de docs `plan-lanes-boards.md`, `domain-model.md`,
`legacy-planning-chain.md`, `contracts/drag-and-drop.md`.

## 2. wat de opdracht vraagt, tegen wat er is

| gevraagd | stand |
|---|---|
| ketting nested → ripped → printed → coated → cut als lane_items met dependencies | het model kan het (`lane_item_dependency` m:n). **Niemand maakt vandaag lane_items voor rip, print, coat of cut**: alleen impose-items (patroon) en lege machine-dag-lanes (production-plan) |
| nests alleen bij split/merge vastleggen, erven via de keten | ontworpen in `planned/` (`get_lane_item_impositions`), niet uitgerold; live is de platte tabel zonder `moved_at` |
| lane kopiëren/splitten in print-schedule en `get_impose_plan` | bestaat niet. `crud_lane_item` kent create (extra moment), update, delete op item-niveau; geen lane-operatie |
| `lane_item_id` in `get_print_schedule`, `get_impose_plan`, `get_production_plan` | 76/78 en 81 hebben hem; 75 kan niet: de kaarten zijn berekend, geen lane_items |
| één begrippenkader | zie 1.5 |
| production-planning met vooraf gekozen steps als data | `plan.steps text[]` bestaat; het vocabulaire staat in `lookup_step_category` (impose, rip, print, coat, laminate, route, cut). De keuze per bord zit nu in de data_group-param `steps` (81: `{print,coat,laminate,route,cut}`) |

## 3. vragen

De vijf uit de opdracht, plus wat ik onderweg tegenkwam. Zonder antwoord bouw
ik niets.

**A. `lane_item` en `lane_item_dependency`** — many-to-many staat aan (§1.1).
Klopt de richting `from` = voorganger (nested) → `to` = volgende stap (ripped)?
Het `planned/`-ontwerp loopt via `to → from` omhoog. Ik houd die aan tenzij je
anders zegt.

**B. Traagheid nest-planning** — welk bord bedoel je: 76 impose_plan, 78
impose_resource_plan of 79 impose_plan_inflow? Op 4 sep mat ik `get_impose_plan`
op 2,4-2,7 s server-side; op 27 aug was de vaste voet "één aggregate-aanroep per
nest-set plus ~40 ms plantijd per aanroep" (`force_custom_plan` op de detail),
en batchen werd toen afgewezen. Ik meet opnieuw zodra de tunnel er is (§4) en
kom met een voorstel; de eerste kandidaat is de per-set-aanroep zelf.

**C. Wat is een lane** — allebei, per plan-type: een machine-dag
(`resource_path`) in het production-plan, een materiaal (via
`imposition_group_lane_item`, `resource_path` null) in het patroon-dagplan.
Vraag: moet een materiaallane een eigen identiteit op `lane` krijgen (nu is een
materiaallane alleen herkenbaar via zijn items), of blijft de lane bewust
"alleen een strook" en hangt alles aan items?

**D. Kopiëren / splitten van een lane** — wat is de eenheid die de planner
kopieert: (1) de lane binnen het dagplan (nieuwe `lane` + `plan_lane`, de items
van die datum verdeeld, dependencies naar dezelfde ouder), of (2) ook het
weekpatroon (`material_impose_plan`), zodat de kopie morgen weer verschijnt?
`crud_lane_item` schrijft nu elke mutatie terug naar het patroon.
En: "de unieke datums blijven bij beide lanes zichtbaar" — betekent dat dat
een item met een datum die maar één keer voorkomt op **beide** lanes staat
(gedeeld, één lane_item onder twee lanes), of dat het op één lane staat en de
andere lane de datum als leeg slot toont?

**E. Print-schedule en `lane_item_id`** — de kaarten van 75 zijn berekend uit
`material_print_schedule` (interval × nest-moment × forecast), niet uit
lane_items. Er bestaat wél een print-dagplan (`generate_plan` met step `print`,
de labels van 75 komen daar al uit). Wil je dat de kaarten lane_items wórden
(één lane_item per materiaal × dag × nest-moment, gestampt uit
`material_print_schedule` zoals impose uit `material_impose_plan`), zodat
verschuiven/kopiëren/splitten dezelfde `crud_lane_item` gebruikt? Dat is de
enige weg naar een `lane_item_id` daar. Uiterlijk en werking van 75 blijven
dan gelijk; alleen de bron van de kaarten verandert.

**F. Nests vastleggen: naam en tabel** — live is de platte
`imposition_lane_item (imposition_id, lane_item_id, sort_order)`; ontworpen is
de append-only variant met `moved_at`. De opdracht noemt hem `nest_lane_item`.
Kiezen we `imposition_lane_item` (append-only, zoals `planned/`, met voorlopig
`imposition_id` = `nest_id` en zonder FK naar `production.imposition`)? En:
wat gebeurt er met de bestaande platte rijen — omzetten met `moved_at = now()`
als eerste set van elk item?

**G. Wie maakt de keten** — rip/print/coat/cut-items bestaan niet. Worden ze
(1) aangemaakt op het moment van nesten (`crud_nest` maakt voor elke stap uit
`plan.steps` een lane_item op de machine-dag-lane, met de dependency naar de
vorige), of (2) door de planner op het production-bord (drop van een nest-set
op een machine), of (3) door de generator vooraf, leeg, en gevuld bij nesten?

**H. Steps als data** — de keuze "wat willen we zien" staat nu op twee plekken:
`plan.steps` (wat het plan dekt) en de data_group-param `steps` (wat het bord
toont). Wil je één plek, en welke? Mijn voorstel: `plan.steps` is wat gepland
wordt; het bord toont die steps, en een filter (zoals 64) kan er een deel van
kiezen. En: welke steps zijn het voor de production-planning — de zeven uit
`lookup_step_category` (impose, rip, print, coat, laminate, route, cut), of de
vijf uit de opdracht (nested, ripped, printed, coated, cut)? `laminate` en
`route` staan in het vocabulaire en 81 vraagt ze al.

**I. Hernoemen** — akkoord met de kolom "zou moeten zijn" in §1.5, of streep
je er uit? Vooral: (1) `nest` → `imposition` in `action` nu al, terwijl
`legacy.nest` blijft; (2) de data_table-namen (`get_print_schedule`,
`get_impose_plan`, `get_production_plan`) zijn frontend-contract — hernoemen
we die ook, of alleen de functies achter de `query`-kolom?

**J. Bestaande data bij hernoemen** — `plan.type = 'material-resource-plan'`
staat op alle patroonplannen, `lane_item.source = 'material-plan'` op alle
items. Hernoemen = één `UPDATE` per waarde plus de lezers in dezelfde sessie.
Akkoord dat dat in de stap van de hernoeming zit, of houden we de oude
waarden en vertalen we alleen in de docs?

## 3b. besloten 5 sep (antwoorden op A-H)

| vraag | besluit |
|---|---|
| A richting | `from` = voorganger (nest), `to` = volgende stap (print) |
| B bord | 76 impose_plan; voorstel §4.1 |
| C lane | `resource_path` blijft voor 78/81. Voor 75/76 zijn de lanes imposition groups (alias van `material_id`, later breder). Idee: twee subtabellen, `resource_lane` en `imposition_group_lane`, onder `lane` |
| D kopiëren/splitten | geldt voor alle toekomstige dagen (dus het patroon én de al gestampte dagplannen). **Niets wordt gedeeld**: een kopie of split maakt een nieuw `lane_item` (nieuw id) met een extra rij in `imposition_group_lane_item`; de dependency wijst naar dezelfde voorganger |
| E print-schedule | kaarten worden lane_items, gestampt uit `material_print_schedule` |
| F nests | `imposition_lane_item` append-only zoals `planned/`, `imposition_id` = `nest_id` voorlopig; bestaande platte rijen omzetten met `moved_at = now()` |
| G keten | de stappen van een impositie komen uit het manifest (`spec_unit_manifest` / `imposition_unit_manifest`): welke regels erop liggen bepaalt welke lane_items er komen |
| H steps | alleen `plan.steps`, vocabulaire `lookup_step_category` (groeit); geen bord-param |
| planning en realisatie | in één lane staan planning-items (`level 0`) en gerealiseerde items (`level 1`): lager getekend, met state en geproduceerd. Dat is `lane_item.level`, al live en al in `get_production_plan`; de lane-soorten van stap 3 raken het niet |
| één batch per lane_item | een lane_item draagt nests van één `batch_id` (null is een eigen waarde); meer batches = meer lane_items op dezelfde lane, gevonden of aangemaakt. Nu mengen 229 van 389 items batches. Eigen stap 3b |
| één resource-read | 78 en 81 lezen straks dezelfde functie met `p_steps`; `get_production_plan` vervalt. In stap 7 |
| `lane_item.type` | `plan` / `progress` / `actual` uit `action.lookup → lookup_lane_item_type` vervangt `level`. plan = de planning (tooltip: gedaan en resterend), progress = het resterende werk voor de stap, krimpt en verdwijnt; actual = uit `log.state`/`log.data`. In stap 7; 76 volgt dezelfde splitsing |
| `fixed_group` | `is_fixed_group` heet `fixed_group` (kolom, lookup-key, output van drie reads, data_groups 75/76/78/81, `fixed_group_field`): `is_` is voor booleans, dit is de leverklasse. Zit in het 3b-script |

I en J (hernoemen, bestaande waarden): uitleg en impact in §3c, besluit open.

## 3c. hernoemen — wat het is en wat het raakt

Drie soorten namen, met verschillende impact:

| soort | voorbeelden | wat hernoemen kost | wie het merkt |
|---|---|---|---|
| **objectnamen** in de database (tabellen, functies) | `mock.material_impose_plan`, `mock.get_impose_plan`, `mock.generate_plan` | tabel: `ALTER TABLE RENAME` + alle functies die hem lezen. Functie: drop + create + de `query`-kolom in `site.data_table`. Plus mirrors en docs | niemand buiten de repo; de frontend praat via de data_table-naam |
| **data_table-namen** (het frontend-contract) | `get_print_schedule`, `get_impose_plan`, `get_production_plan`, `get_plan_lanes`, `crud_lane_item` | de `src` in elke data_group die hem gebruikt + de frontend-kant (caching, parameter-binding op naam) | de frontend; moet gelijk op |
| **waarden in rijen** | `plan.type = 'material-resource-plan'`, `lane_item.source = 'material-plan'` / `'pv2'`, `plan.type = 'production-plan'` | één `UPDATE` per waarde + elke functie die de literal vergelijkt of schrijft, in één transactie; én de data_group-params die de waarde meegeven (81 geeft `plan_type: production-plan` als default) | de borden als een param verandert; anders niemand |

Per kandidaat uit §1.5:

| kandidaat | soort | raakt | impact |
|---|---|---|---|
| `nest` → `imposition` binnen `action` | object | alleen de repo-mirror `get_production_plan.sql` (leest `nest_lane_item`, bestaat niet); live is al `imposition_lane_item` | **laag** — geen live wijziging |
| `mock.material_impose_plan` → `action.<patroon>` | object + schema | `crud_material_impose_plan`, `generate_plan`, `crud_lane_item` (schrijft terug), `get_plan_lanes` (parset `source_ref`), `get_impose_plan`; data_table `crud_material_impose_plan`? | **middel** — 5 functies, één transactie |
| `mock.material_print_schedule` → `action.<instellingen>` | object + schema | `get_print_schedule`, `get_plan_lanes`, `generate_plan`, `get_print_schedule_materials` | **middel** |
| `plan.type` `material-resource-plan` → `imposition-group-plan` (of weg, als `resource_lane`/`imposition_group_lane` het onderscheid dragen) | waarde | UPDATE 150 rijen + `get_plan_lanes`, `get_impose_plan`, `generate_plan`, `refresh_derived_data`; data_group-default in `get_plan_lanes`-params | **middel**, en het kan vervallen |
| `lane_item.source` `material-plan` → naam van het patroon | waarde | UPDATE 780 rijen + `generate_plan`, `get_plan_lanes`, `crud_lane_item` | **laag** |
| item-reads `get_print_schedule` / `get_impose_plan` / `get_production_plan` → één werkwoord | data_table (of alleen de functie erachter) | functie alleen: drop + create + `query`-kolom. Data_table ook: `src` in 75/76/78/81 + frontend | **laag** als alleen de functie; **hoog** als het contract meegaat |
| alles van `mock` naar `action` (opdracht: "alles in schema action") | object + schema | elke plan-functie en -tabel in `mock`; `query`-kolommen | **middel**, mechanisch, één sessie |

Aanbeveling: objectnamen en waarden hernoemen mag, maar pas in de stap waarin
het object toch al verandert (patroon → lane_pattern als kopiëren/splitten
erin komt; `plan.type` als de lane-subtabellen er zijn). De data_table-namen
laten staan: dat is het contract met de frontend en het levert niets op.

## 4. gemeten (5 sep, tunnel terug)

Volumes: 192 plannen, 1.793 lanes (1.013 met `resource_path`, 25 datums),
6.260 lane_items — 780 `material-plan` (impose-patroon, één item per lane) en
**5.480 `pv2`** (uit `action.object`, level 0), 982 dependency-randen, alle
**print → cut** tussen pv2-items, geen kind met twee ouders. 38.792 rijen in
`imposition_lane_item` (5.867 items, 24.450 imposities). `action.nest_lane_item`
bestaat niet; `production.imposition` wél. Live heet de 81-read
`mock.get_production_plan` (data_table `get_production_plan`); de repo-mirror
`sql/mock/get_production_plan.sql` definieert `mock.get_production_schedule` op
`nest_lane_item` — die staat dus niet live en kan zo ook niet draaien.

Nest-planning (76/78, `get_impose_plan`, vrijdag 4 sep 10:00, sheet): 1,9 s
totaal, 48 rijen.

| onderdeel | tijd |
|---|---|
| `get_plan_lanes` (labels + basis) | 39 ms |
| window-aggregate (materialen zonder nests, één aanroep) | 147 ms |
| 24 nest-sets → 24 × `get_production_orderline_aggregate` → 24 × `get_production_orderline_detail` in nest-scope | de rest, ~1,7 s |
| één set van 232 nests (566 detail-rijen), mét materiaalfilter | 1.324 ms, waarvan 1.277 ms in de detail |
| dezelfde set zónder materiaalfilter | 5.761 ms |
| alle 743 nests in één detail-aanroep | 5.357 ms (1.554 rijen) — één grote aanroep is dus **niet** de oplossing |

De tijd zit in `get_production_orderline_detail` in nest-scope: ~2,3 ms per
rij, tegen ~0,15 ms per rij op het bordvenster (943 ms voor 6.318 rijen,
`legacy-planning-chain.md` §4). Het nest-scope-pad doet per rij iets duurs;
welke CTE staat in §4.1.

### 4.1 waar de detail zijn tijd laat (één set van 232 nests, 566 rijen, 1.285 ms)

De body van `get_production_orderline_detail` als losse query, per CTE:

| CTE | tijd | wat het plan doet |
|---|---|---|
| `orderline_nest` | 547 ms | **seq scan `legacy.single_product`, 496.343 rijen** — er is een index op `production_orderline_id`, maar de planner kiest een hash join op de hele tabel |
| `orderline_base` | 385 ms | bitmap heap scan `component_specs` 197 ms voor 566 rijen, en een "seq scan" op `internal_status` (86 rijen) met 188 ms opstart: een subquery die eerst uitgerekend wordt |
| `progress` | 221 ms | **seq scan `production_orderline_progress`, 707.720 rijen** — index op `production_orderline_id` bestaat |
| `manifest_impact` | 168 ms | **seq scan `spec_unit_manifest`, 513.258 rijen** — index op `production_orderline_id` bestaat |
| `nest_agg`, `orderline_rework`, `part_status_json_agg` | < 60 ms | — |

Drie volledige tabelscans van een half miljoen rijen voor 566 orderregels, per
aanroep, 24 aanroepen per bord. De indexen zijn er; de planner gebruikt ze niet
omdat hij het aantal rijen uit de CTE `orderline_base` te hoog inschat (de
nest-scope filtert op `sp.nest_id = any(232 ids)`) en dan hash joins over de
hele tabel goedkoper vindt. Op het bordvenster (6.318 rijen) is dezelfde keuze
wél goed, vandaar het verschil van 0,15 tegen 2,3 ms per rij.

**Voorstel (niet gebouwd):** de scope-CTE `orderline_base` als `MATERIALIZED`
met de id-lijst via `unnest` in een eigen CTE, zodat de planner een kleine
rijenschatting krijgt en de drie joins over de indexen op
`production_orderline_id` lopen. Verwachting: één set-aanroep van 1,3 s naar
~0,1-0,2 s, het bord van 1,9 s naar ~0,4 s, zonder dat de 24 losse
set-aanroepen (bewust behouden op 27 aug) hoeven te veranderen. Te toetsen als
losse query vóór de deploy, zoals bij `get_print_schedule`. Eén grote aanroep
voor alle 743 nests is géén alternatief: 5,4 s.

## 5. stappenplan

Acht stappen. Elke stap is los te draaien en te controleren, en laat de borden
werkend achter. De volgorde is de afhankelijkheid: 1 en 2 staan los, 3 t/m 6
bouwen op elkaar, 7 en 8 sluiten af. Hernoemen zit in de stap waarin het object
toch verandert (§3c); de data_table-namen blijven overal.

Vaste werkwijze per stap: mirror in de repo → als losse query getest tegen de
live functie (rijen identiek, tijd gemeten) → deploy-script met checks → jij
draait → bordcheck.

### stap 1 — nest-planning sneller (bord 76)

**Wat verandert.** In `mapping.get_production_orderline_detail` krijgt de
nest-scope een kleine, zekere rijenschatting: de id-lijst in een eigen CTE via
`unnest` en `orderline_base` `MATERIALIZED`, zodat `orderline_nest`, `progress` en
`manifest_impact` de indexen op `production_orderline_id` gebruiken in plaats
van drie tabelscans van een half miljoen rijen per aanroep (§4.1). De 24
set-aanroepen in `get_impose_plan` blijven.

**Raakt.** `sql/mapping/get_production_orderline_detail.sql`. Geen contract,
geen data_group.

**Stand 5 sep: gedraaid en nagemeten.** Bord 76 (vrijdag 4 sep): 1,9 s → 0,65 s;
grootste set-aanroep 1.324 → 234 ms; kleinste 48 ms; productiebordvenster 844 ms
(niet trager). Wat overblijft zijn de 24 losse set-aanroepen à 25-40 ms
(plantijd + uitvoering); verder omlaag kan alleen door die aanroepen te
bundelen, wat op 27 aug is afgewezen. Oorspronkelijk: De scope zit in een eigen CTE
`scope_orderline`; de basis filtert met `= any(array)` uit een InitPlan in
plaats van `in (subquery)` — de planner zag door de hashed subplan niet heen en
hield de schatting van het materiaalfilter (28.446 rijen voor 566). Nu schat
hij klein en lopen alle joins over de indexen. Gemeten als losse query:
nest-scope 1.285 → 255 ms, bordvenster ongewijzigd (~0,8 s, nested loops zoals
voorheen). Output identiek in beide scopes (`except all` leeg, 566 en 7.586
rijen). Script: `archive/sql/migrations/update_orderline_detail_scope.sql`, met drie checks.

**Controle.** Detail-body als losse query voor de grootste set: 1.285 ms → doel
< 200 ms, zelfde rijen. Daarna `get_impose_plan` voor een werkdag: 1,9 s →
doel < 0,5 s, `except all` in beide richtingen leeg tegen de oude functie.
Bordvenster (`get_production_board_aggregate`) mag niet trager worden: 943 ms
blijft.

### stap 2 — imposities append-only vastleggen

**Wat verandert.** `action.imposition_lane_item` wordt de vorm uit `planned/`:
eigen id, `lane_item_id`, `imposition_id` (voorlopig = `nest_id`, zonder FK naar
`production.imposition`), `sort_order` (blijft, voor de volgorde binnen het
item), `moved_at`. Rijen alleen bij de eerste stap, een split of een merge; een
lane_item zonder rijen erft van zijn voorganger(s) via `lane_item_dependency`
(van → naar). `action.get_lane_item_impositions(p_lane_item_id, p_as_of)` en
`action.crud_imposition_lane_item` uit `planned/` gaan live; de nieuwe tabel
vervangt de platte.

**Migratie.** De 38.792 platte rijen worden de eerste set van hun item:
`moved_at = now()`, `sort_order` mee. Geen inhoudelijke wijziging.

**Raakt.** DDL `imposition_lane_item`; `legacy.crud_nest` (schrijft nu delete +
insert; wordt: append van de nieuwe set van het item); `mock.get_impose_plan`
(`lane_nest`-CTE leest de laatste set); `mock.get_production_plan` (live;
de repo-mirror is stuk, zie stap 0 hieronder); `action.get_plan_lanes` raakt
het niet.

**Stand 5 sep: gebouwd, wacht op draaien** — `archive/sql/migrations/update_imposition_lane_item_append.sql`.
De tabel wordt in place omgezet (`ALTER`: eigen id, `moved_at`, `imposition_id`
nullable, indexen op `(lane_item_id, moved_at desc)` en `imposition_id`); de
bestaande rijen delen één `moved_at` en zijn zo de eerste set van hun item.
Eén toevoeging op het ontwerp uit `planned/`: **de lege set** — een item dat al
zijn imposities verliest krijgt één rij met `imposition_id null`, anders zou
het terugvallen op erven. `crud_nest` schrijft per geraakt item de nieuwe set
(huidige set min de payload-nests, plus wat erop landt). `crud_object` (pv2) en
`crud_lane_item` houden hun delete + insert: zij vervangen de set van een item
dat ze zelf bezitten, dat blijft correct. Mirror van `get_production_plan` is
de live definitie (stap 0), plus de lees-omleiding. `planned/` is leeg op de
README na (FK naar `production.imposition` blijft open).

**Controle.** Voor elke lane_item met nests: set uit de oude tabel = set uit
`get_lane_item_impositions` (0 verschillen). Bord 76: zelfde `nest_ids` en
`nest_count` per rij. Een nest opnieuw nesten via `crud_nest` geeft een
tweede set met later `moved_at`; de oude blijft staan; `p_as_of` vóór dat
moment geeft de oude set terug.

*Stap 0, meteen erbij:* de repo-mirror `sql/mock/get_production_plan.sql`
definieert `get_production_schedule` op `nest_lane_item` (bestaat niet); de
live functie heet `mock.get_production_plan` en leest `imposition_lane_item`.
De mirror wordt de live definitie, daarna pas aanpassen.

### stap 3 — twee soorten lanes

**Wat verandert.** `action.lane` houdt alleen `lane_id` en `lane_date`. De soort
staat in een subtabel, precies één per lane:

- `action.resource_lane (lane_id pk/fk, resource_path ltree)` — machine-dag;
  uniek op `(lane_date, resource_path)` via de lane
- `action.imposition_group_lane (lane_id pk/fk, imposition_group_id)` — de
  lanes van 75 en 76; `imposition_group_id` is nu een alias van `material_id`

`plan.type` blijft voorlopig (`material-resource-plan` / `production-plan`); zodra
alle lezers de subtabel gebruiken zegt de lane-soort hetzelfde en kan het type
in stap 8 weg of hernoemd worden.

**Migratie.** 1.013 lanes met `resource_path` → `resource_lane`. 780
materiaallanes → `imposition_group_lane` met de groep van hun (enige) item uit
`imposition_group_lane_item`. Daarna `lane.resource_path` weg.

**Raakt.** DDL; `mock.generate_plan` (schrijft `imposition_group_lane`),
`mock.generate_production_plan` (schrijft `resource_lane`), `action.get_plan_lanes`
(beide modi), `mock.get_production_plan`, `action.crud_lane_item` (create maakt
een lane), `mock.get_impose_plan` indirect via `get_plan_lanes`.

**Controle.** Labels van 75, 76, 78 en 81 identiek vóór en na (`except all`
op `get_plan_lanes` in alle vier aanroepvormen). Elke lane heeft precies één
subtabelrij (check-query, verwacht 0 wezen en 0 dubbelen).

**Stand 5 sep: gebouwd, wacht op draaien** — `archive/sql/migrations/update_lane_kinds.sql`. De
migratie zit in de transactie met een `DO`-blok dat stopt als de soorten niet
kloppen (elke lane precies één subtabelrij). Vooraf is van elke bord-read een
baseline genomen (aantal rijen en md5 over de rijen: labels 75/76/78/81 en
81-foil, items 76 en 81); de checks onder het script vergelijken daarmee. Geen
lezer buiten de zeven genoemde functies gebruikte `lane.resource_path`.
`crud_nest` zoekt de materiaallane nu direct op `imposition_group_lane` in
plaats van via de items. Stap 2 nagemeten: bord 76 0,69 s; **bord 81
(`get_production_plan`) 3,6 s voor 988 rijen** — dat is een nieuw
meetpunt, niet door stap 2 veroorzaakt (zelfde aggregate-per-set-patroon als
76, maar over 5.480 pv2-items); kandidaat voor een eigen stap.

### stap 3b — één batch per lane_item

**Regel (Cees, 5 sep).** Een `legacy.nest` heeft een `batch_id` of null. Aan een
lane_item hangt maar één `batch_id` (null telt als eigen waarde). Heeft een
materiaal op een dag nests van meerdere batches, dan zijn er meerdere
lane_items op die lane: bestaande worden gevonden (zelfde
`imposition_group_id`/materiaal, zelfde batch of nog leeg), anders aangemaakt.

**Stand nu.** Van de 389 material-plan-items met nests mengen **229** batches
(tot 17 per item, 6.453 nests); item 257870 van materiaal 26 op 4 sep draagt
acht batches (88, 35, 25, 20, 18 zonder batch, 15, 11, 10 nests). 12.194 van de
44.642 nests van de laatste 30 dagen hebben geen batch. Ook 101 van de 5.506
pv2-items (`crud_object`) mengen batches.

**Wat verandert.** `legacy.crud_nest` kiest per nest niet meer "het item dat
op of vóór het nestmoment begint" maar het item van de lane waarvan de
huidige set dezelfde batch draagt (of dat nog leeg is); bestaat dat niet, dan
maakt hij een item op die lane (`source = 'nest'`, `source_ref` =
`<lane_id>:<batch_id of 0>`, `start_offset_in_seconds` = het nestmoment van de
eerste nest, `no_split`). Verandert de batch van een nest later, dan verhuist
hij (set-schrijfactie op beide items). Backfill: de 229 gemengde items worden
gesplitst, per batch een item, de sets append-only geschreven.

**Raakt.** `crud_nest` (`nest_link`-keuze + item-aanmaak), `get_impose_plan` (niets:
meer items per lane komen als meer rijen), `get_plan_lanes` (materiaalmodus
levert de extra items als rijen; `fixed_group`/`start_offset` volgen het
item), backfill-script. `crud_object` (pv2) alleen als de regel daar ook geldt.

**Controle.** Geen item met meer dan één `coalesce(batch_id, -1)` in zijn set
(verwacht 0); bord 76 toont materiaal 26 op 4 sep als acht items in plaats van
één blok van 19,5 uur.

**Besloten 5 sep.** De regel geldt ook voor de pv2-items van `crud_object`. Nests
worden eerst aangemaakt (batch null) en krijgen later via een update hun
batch: een nest verhuist dan van het null-item naar het batch-item. Starttijd
van een aangemaakt batch-item: null (filler, de client ketent), volgens de
offset-regel — alleen een fixed group of een gepind item draagt tijd; het
patroon-item houdt zijn klassetijd en neemt de eerste batch.

**Hoe het item wordt gekozen (per lane en batch, `coalesce(batch_id, 0)`):**
1. het item op de lane waarvan de huidige set die batch draagt;
2. anders een item zonder nests (geen set of de lege set), het patroon-item
   eerst, dan op `sort_order`;
3. anders een nieuw item: `source = 'nest'`, `source_ref = <lane_id>:<batch>`
   (uniek, dus twee nests van één nieuwe batch in één aanroep geven één item),
   `no_split`, offset null, `sort_order` achteraan.
De set-schrijfactie van stap 2 blijft: elk item dat een payload-nest verliest
of krijgt, krijgt zijn set opnieuw.

**pv2 (`crud_object`):** de regel staat in één functie,
`action.sync_pv2_batch_items(p_plannable_item_ids)`, die `crud_object` na zijn upsert
aanroept in plaats van zijn eigen set- en ketenblokken. Een nest zonder batch
telt als nest van de batch van het item (nests worden eerst gemaakt en later
gebatcht); alleen een nest op een *andere* batch verhuist naar een extra
lane_item `source_ref = <plannable_item_id>:<batch>` op dezelfde lane en start.
De blokduur wordt naar aantal nests verdeeld over hoofd- en extra items; een
hoofditem waarvan alle nests weg zijn houdt duur 0 (het blijft het pv2-item).
Sets en randen van hoofd- en extra items worden als geheel vervangen (pv2 is
hier de bron, geen historie); de keten loopt per batch: coater/laminator van
batch B volgt de printer van B, cutter van B volgt coater/laminator, anders
printer van B. Extra items waarvan de batch weg is worden weer verwijderd.

**Besloten 6 sep (Cees): één rij per materiaal op 75 en 76.** De batch-items
blijven in het model (één batch per item, voor de resourcekant en `crud_nest`),
maar zijn geen rij op de materiaalborden: `get_plan_lanes` geeft per lane alleen
het patroon-item, `get_impose_plan` telt de nests van alle items van de lane op
die rij bij elkaar (`archive/sql/migrations/update_material_rows_aggregate.sql`; 5 sep sheet: 102 →
46 rijen). De controle hieronder ("acht items in plaats van één blok") is daarmee
achterhaald.

**Stand 5 sep: crud_nest-deel gebouwd, wacht op draaien** —
`archive/sql/migrations/update_nest_batch_items.sql` (crud_nest, get_plan_lanes, crud_lane_item, plus
de hernoeming `is_fixed_group` → `fixed_group` in kolom, lookup en de drie reads;
data_groups 75/76/78/81 in `archive/sql/migrations/update_data_group_partial.sql`) en
daarna `archive/sql/migrations/backfill_nest_lane_items.sql`, dat de lijn-fout (1.338 nests) en de
gemengde batches (229 items) in één keer rechtzet: per materiaallane de nests
van eigen dag, materiaal en lijn, per batch een item, de eerste batch op het
patroon-item, sets append-only. `get_plan_lanes` toont batch-items als momenten
en leent materiaal, lijn, tenant en resource van het patroon-item van de lane;
`crud_lane_item` schrijft alleen vanuit een patroon-item terug naar het patroon.
Het pv2-deel: `archive/sql/migrations/update_pv2_batch_items.sql` (functie, `crud_object`, backfill in een
DO-blok, drie checks). Dry run 5 sep: 42 pv2-items met nests op een andere
batch, 89 nests, 48 extra items, 31 hoofditems zonder eigen nests (duur 0),
duren tellen per item exact op tot het blok.
Dry run van de backfill (read-only, 5 sep): 7.198 nests blijven 7.198, niets
valt weg, geen nest op twee lanes, geen item met twee batches; 594 batch-items
erbij, 233 items herschreven. 102 nests houden hun huidige lane omdat hun lijn
die dag geen lane van dat materiaal heeft (bewust).
**Fout in de backfill (gevonden 6 sep):** de `changed`-set mengde `EXCEPT` en `UNION`
zonder haakjes; SQL leest dat van links naar rechts, dus alleen items die een nest
*verloren* telden als gewijzigd. De 233 patroon-items zijn wel herschreven, maar de
594 batch-items en 93 patroon-items die alleen nests *kregen* hebben nooit een set
gekregen: 5.202 van de 7.198 nests vielen van de materiaal-lanes (ze stonden nog op
hun pv2-items en in de migratierijen van 11:30). `archive/sql/migrations/repair_nest_lane_item_sets.sql`
zet ze terug volgens dezelfde regel, zonder iets te raken wat `crud_nest` sindsdien
plaatste (dry run: 594 batch-items 4.477 rijen, 93 patroon-items 725 rijen, geen item
met twee batches). Gedraaid 6 sep: 7.198 nests, 0 batch-items zonder set, 0 gemengd.
Les: verschil in twee richtingen altijd met haakjes.
**Nagemeten 6 sep (item 257870).** De huidige set draagt één batch; de gemengde
rijen die een join zonder `moved_at`-filter toont zijn de oudere set-schrijfacties
(historie, append-only). Twee gaten in `crud_nest` gedicht in
`archive/sql/migrations/update_nest_batch_move.sql`: de batch die een item "vandaag draagt" telde de
payload-nests mee (een nest dat zijn batch kreeg bleef zo op zijn item staan en
mengde het), en de pv2-items werden alleen bij `crud_object` rechtgezet — nu roept
`crud_nest` `sync_pv2_batch_items` aan voor de pv2-items met een payload-nest.

### stap 4 — print-schedule op lane_items

**Wat verandert.** De kaarten van 75 worden lane_items. Een generator
(`action.generate_print_schedule(p_date, p_line_type)`, in `action`) stampt per
werkdag uit `material_print_schedule` wat `get_print_schedule` nu berekent: één
lane_item per materiaal × productiedag × `nest_moment_code`, op de
`imposition_group_lane` van dat materiaal in het print-dagplan van die datum,
`source = 'print-schedule'`, `source_ref = <material_id>:<date>:<code>` (uniek,
dus herhaald stampen is idempotent). Het dagplan van stap 3 is er al
(`generate_plan` met step `print`, 14 werkdagen vooruit) — de kaarten komen
erbij in dezelfde dagelijkse run (`refresh_derived_data`).
`mock.get_print_schedule` leest dan de lane_items van de 10 dagplannen en
voegt per rij toe wat hij nu ook al toevoegt (forecast, formule-evaluatie,
class_names); output-kolommen gelijk plus `lane_item_id`. Bij die gelegenheid
verhuist hij naar `action` (drop + create, `query`-kolom om; data_table-naam
blijft). `material_print_schedule` wordt `action.material_plan_setting` (het zijn
instellingen, geen schedule) in dezelfde sessie.

**Raakt.** nieuwe generator; `get_print_schedule`; `site.refresh_derived_data`;
`site.data_table`: `query` + `primary_keys` met `lane_item_id`; data_group 75
alleen als een veldnaam verandert (bedoeling: niet).

**Controle.** Output van de nieuwe read = output van de oude voor dezelfde
dag (`except all` op alle kolommen behalve `lane_item_id`: leeg), ook met
`only_starting_today` en met tenantfilter. Tijd ≤ nu (150-330 ms). Bord 75 ziet
er hetzelfde uit; één kaart verschuiven via `crud_lane_item` werkt zonder extra
frontend-werk omdat het nu een lane_item is.

### stap 5 — lane kopiëren en splitten

**Wat verandert.** `action.crud_lane(p_param_json)` met `crud` = `copy` of
`split`, voor 75 en 76. Copy: nieuwe lane (nieuwe `imposition_group_lane`-rij),
voor elk item van de bron een nieuw lane_item (nieuw id) met een eigen rij in
`imposition_group_lane_item` en dezelfde dependency-voorganger. Split: idem,
maar de items met dezelfde datum worden verdeeld over bron en kopie; een item
met een unieke datum krijgt op de kopie een nieuw item, zodat de datum op
beide lanes zichtbaar is. Geldt voor alle toekomstige dagen: de operatie
schrijft in het patroon (`material_impose_plan`, dat in deze stap
`action.lane_pattern` wordt, want het is de template en geen plan) én in de al
gestampte dagplannen vanaf vandaag; morgen stampt `generate_plan` het patroon
verder. De ontkoppeling van patroon en dag (een verplaatsing op één dag die
níét het patroon raakt) is er vandaag ook niet en blijft buiten deze stap.

**Raakt.** nieuwe `crud_lane`; `generate_plan` (leest het patroon met de kopieën);
`crud_lane_item` (schrijft terug naar het hernoemde patroon); data_groups 75 en
76: een `drop`-blok/menu-item voor kopiëren en splitten (contract
`contracts/drag-and-drop.md`, met de frontend); `site.data_table` voor `crud_lane`.

**Controle.** Op een testdag: split een lane met 3 items waarvan 2 op dezelfde
datum → bron 2 items, kopie 2 items (1 verdeeld + 1 nieuw voor de unieke
datum), 4 rijen `imposition_group_lane_item`, elke dependency naar de oude
voorganger; `generate_plan` voor overmorgen levert beide lanes. Bord 76 toont
beide lanes met hun items; 75 idem.

### stap 6 — de keten van lane_items per stap

**Het voorbeeld dat leidend is.** Tien imposities hangen via
`imposition_lane_item` aan lane_item 1234 (stap impose). Komt er een plan met de
stappen print, coat en cut, dan ontstaan drie nieuwe lane_items, één per stap:
1235 (print), 1236 (coat), 1237 (cut), en drie randen in
`lane_item_dependency`: 1234 → 1235, 1235 → 1236, 1236 → 1237. Voor 1235, 1236
en 1237 wordt níéts in `imposition_lane_item` geschreven: ze erven de tien van
1234. Pas bij een split (coat over twee coaters) of een merge (cut van twee
coaters) krijgt het item dat afwijkt een eigen set.

**De leesfunctie.** `action.get_lane_item_impositions(p_lane_item_id, p_as_of)`
staat al in `sql/action/planned/` (niet live) en doet precies dit, als één
recursieve CTE in plaats van een functie die zichzelf aanroept:

- start bij het gevraagde item; heeft het eigen rijen, dan zijn dat de
  imposities;
- zo niet, dan loopt hij via `lane_item_dependency` van `to` naar `from`
  (naar de voorganger) en herhaalt dat, per voorganger, tot hij een item met
  eigen rijen vindt; bij een merge levert dat de vereniging van beide takken
  (`distinct`);
- `p_as_of` geeft de stand van een moment; "de laatste schrijfactie per item
  telt" maakt een tweede split een nieuwe set naast de oude (historie).

Op het voorbeeld: `get_lane_item_impositions(1237)` → 1237 geen rijen → 1236 geen
rijen → 1235 geen rijen → 1234 heeft rijen → de tien. Jouw
`get_lane_item_nests` is dezelfde functie met de oude kolomnamen
(`parent_lane_item_id`/`lane_item_id`); live heten ze `from_lane_item_id`/`to_lane_item_id`.
De functie gaat in stap 2 live, samen met de tabel.

**Wat er in deze stap bij komt.** Het maken van 1235-1237 en de drie randen.
Dat gebeurt op het moment dat er een plan met die stappen is voor de dag van
het impose-item: per impose-item met imposities, per stap uit `plan.steps`
één nieuw lane_item op de lane van die stap, geketend in de volgorde van
`lookup_step_category` (`order`). Welke lane: de `resource_lane` van de machine
als die bekend is, anders de `imposition_group_lane` van het materiaal in dat
plan, waar de planner het op 81 vandaan sleept. Het manifest
(`imposition_unit_manifest`) bepaalt of een stap voor deze imposities überhaupt
aan de orde is: zonder laminaatregel geen laminate-item. Daarvoor krijgt
`lookup_step_category` per stap de optiesets die hem oproepen (data, door jou te
vullen). Splitsen en samenvoegen op 81 schrijven één set via
`crud_imposition_lane_item` (stap 2).

**Raakt.** een schrijffunctie `action.create_step_lane_items(p_plan_id)` (of
onderdeel van `generate_production_plan`); `lookup_step_category`; `crud_nest`
als het nesten zelf de trigger is; `mock.get_production_plan` (leest via
`get_lane_item_impositions`). De 982 bestaande pv2-randen (print → cut) blijven.

**Controle.** Het voorbeeld: één impose-item met tien imposities en een plan
met print, coat, cut → drie items, drie randen, `get_lane_item_impositions`
geeft voor alle vier dezelfde tien; na een split van coat over twee lanes
geeft cut de vereniging. Bord 81 toont de drie items.

**Besloten (5 sep):** de trigger is het nesten, in `legacy.crud_nest` (na het
manifest, zoals de manifest-aanroep zelf); het manifest is een filter op
`plan.steps`. Nog te vullen door Cees: optieset → stap in `lookup_step_category`.

### stap 7 — één resource-bord-read met steps, en steps als data

**Wat verandert.** De item-reads van 78 (`get_impose_plan` in resourcemodus) en
81 (`get_production_plan`) worden één functie, `action.get_resource_plan(p_until,
p_line_type, p_tenant_ids, p_steps, …)`: één rij per lane_item op de
`resource_lane`s van het dagplan voor de gevraagde steps, level 0 én 1, met
nests via `get_lane_item_impositions` en de aggregate per set. De labels komen
al uit `get_plan_lanes` in resourcemodus. `p_steps` null = alle steps van
`plan.steps`. `plan.steps` is de enige plek waar staat wat gepland wordt;
`generate_production_plan` haalt zijn steps uit `lookup_step_category` (alle
steps met een actieve machine op die `line_type`). Groeit de lookup (embellish,
mount, …), dan volgt het plan zonder codewijziging.

**`lane_item.type` (Cees, 5 sep).** Een lane_item krijgt `type text`; `level`
(0/1) gaat eruit. Het vocabulaire staat in `action.lookup / lookup_lane_item_type`
(`json/lookup/action/lookup_lane_item_type.json`), drie soorten rijen op een
lane, elk met `sort_order` en `class_names`:

| type | wat het is | duur | bron |
|---|---|---|---|
| `plan` | de planning: het item zoals gepland | al het werk van de nest-set (of het open werk van het materiaal) | `lane_item` |
| `progress` | wat er van die planning nog ligt | het resterende werk voor de stap van het plan: orderregels met status onder de "klaar"-status van die stap uit `lookup_step_category`; krimpt als nests doorschuiven, weg als alles klaar is | afgeleid van het plan-item bij het lezen |
| `actual` | wat de machine deed | states en geproduceerde tijd uit `log.state` en `log.data` | de logkant (`get_resource_state`, `get_resource_produced`) |

De tooltip van een plan-rij toont beide getallen: wat al gebeurd is en wat er
nog moet. Zo is de vraag van 5 sep over de duur beantwoord: het plan-blok
blijft de planning, het progress-blok is de werkvoorraad. Opgeslagen wordt
alleen `type = plan` (en later `actual` als de logkant items gaat
schrijven); `progress` is een leesresultaat met dezelfde `lane_item_id`. De
nieuwe `get_resource_plan` levert per rij `type` plus de node uit de lookup
(`type_json`), zodat de client de rijen zonder code per type tekent. De
lezers en schrijvers van `level` (`get_plan_lanes`, `get_production_plan`,
`crud_nest`, `crud_object`, `generate_plan`, `crud_lane_item`, `get_lanes`)
volgen. Dezelfde plan/progress-splitsing geldt voor bord 76 (`get_impose_plan`).

**Raakt.** nieuwe `get_resource_plan` + data_table; data_groups 78 en 81 (`src` en
de `steps`-param: 78 `{impose}`, 81 de rest — of één data_group met een
steps-filter, zie open); `generate_production_plan`, `refresh_derived_data`;
`get_impose_plan` houdt alleen de materiaalmodus (76); `get_production_plan`
en data_table `get_production_plan` vervallen.

**Controle.** Voor de huidige steps geven 78 en 81 dezelfde rijen als vóór de
samenvoeging (baseline-hashes zoals bij stap 3). Een extra step in de lookup met
één testmachine geeft één extra lane zonder verdere wijziging.

**Besloten 5 sep:** 78 en 81 worden één bord.

- data_group `resource_plan` (81 hernoemd; 78 vervalt) op de nieuwe read
  `get_resource_plan`; labels uit `get_plan_lanes` in resourcemodus.
- data_group `resource_plan_filter` (nieuw, zoals 64): `steps` met de items uit
  `lookup_step_category` (default alle steps van het plan) en `types` met de
  items uit `lookup_lane_item_type` (plan, progress, actual; default alle
  drie). De filter-data_group leest beide lijsten uit de lookups
  (`input_data.src`), geen kopie in de config.
- twee pagina's op dezelfde data_groups: `nest-resource-plan` (`steps` `[impose]`)
  en `production-resource-plan` (`steps` `[print, coat, laminate, route, cut]`); de
  default per pagina staat als `params` op de secties in `pages.json`, gemerged over
  de `params` van de data_group (besloten 6 sep, was één pagina `resource-plan`).
  De nest-pagina toont pas lanes zodra `generate_production_plan` ook voor step
  `impose` lanes maakt (aparte stap).
- `site.data_table`: `get_resource_plan` erbij (primary keys
  `lane_item_id`, `type`), `get_production_plan` vervalt na de omzetting.

**Stand 5 sep: gebouwd, wacht op draaien** — `archive/sql/migrations/update_resource_plan.sql` en daarna
`archive/sql/migrations/update_data_group_partial.sql` (81, 82).
- `action.lane_item.type` (text, default `plan`) vervangt `level`; alle 6.950 items zijn
  `plan`. Schrijvers omgezet: `crud_lane_item`, `crud_object`, `sync_pv2_batch_items`,
  `legacy.crud_nest`, `mock.generate_plan`; lezer `get_plan_lanes`. Lookup
  `lookup_lane_item_type` wordt in `action.lookup` gezet.
- `action.get_resource_plan(p_until, p_line_type, p_tenant_ids, p_steps, p_types,
  p_domain_id)`: plan-rijen (identiek aan de oude level-0-rijen van 81), progress-rijen
  (zelfde `lane_item_id`, duur = plan-duur × resterend deel; resterend = part-aantallen
  van de orderregels op de nest-set onder de klaar-status van de stap van de lane,
  uit `lookup_step_category`; zonder aantallen geldt alles als resterend),
  actual-rijen (identiek aan de oude level-1-rijen). De aggregate telt nu al het werk
  van de set (geen statusfilter) en alleen materialen met orderregels: 142 van de 150
  plan-rijen hebben een materiaal (was 0), en het bord leest in 2,3 s (was 4,3 s).
  Test 4 sep sheet: 150 plan, 50 progress, 838 actual.
- `get_plan_lanes` in resourcemodus: per step het nieuwste plan van de dag; bij
  `plan_type = production-plan` is `p_steps` null = alle steps van de dagplannen.
- filterbronnen `relation.get_step_categories` en `action.get_lane_item_types` (lezen de
  lookups), data_tables erbij; data_table 207 wordt `get_resource_plan`.
- data_groups: 81 → `resource_plan` (src, params `steps`/`types`, veld `type` +
  `type_json`, `progress_json.*` in de tooltip, `timeline_config.type_field`), 82 →
  `resource_plan_filter` (`steps` en `types` uit de lookups, `step` en `threshold` weg),
  78 gearchiveerd (`archive/data_group/`). Pagina `impose-resource-plan` →
  `resource-plan` (pages, pages-content, app-nav). Frontend:
  `docs/handoff-resource-plan-frontend.md`.
- **actual als items (5 sep, na analyse van de log):** `get_resource_state` (542
  statusblokken, zonder batch of nest) en `get_resource_produced` (296 items met batch,
  nest_name, metrics; `nest_id` in de data is altijd null) worden items die de dag van
  een lane opdelen: een run = de items van één batch achter elkaar (sleutel
  `coalesce(batch_id, nest_name, rij)`; een batchwissel of een gat langer dan
  `lookup_lane_item_type.actual.gap_split_in_seconds` = 900 splitst), plus de stukken
  tussen de runs. De statusblokken zijn het subniveau van elk item (`states_json`,
  geknipt op het item; `timeline_config.segment_config`), de status die het item het
  meest vult geeft `state_json` en de class. Sheet 4 sep: 154 items (74 runs, 80
  stukken) in plaats van 838 rijen, elke lane sluitend gedekt zonder overlap. Van de
  50 batch-runs staat 26 op dezelfde lane gepland en 38 op een lane van die dag; een
  actual-item hangt dus niet aan een plan-item. Afgeleid bij het lezen, niet
  opgeslagen. Script: `archive/sql/migrations/update_resource_plan_actual.sql`, dan de partial (81).
- **duur via formule (6 sep):** `lookup_lane_item_type` draagt per soort een `formula`
  (regels `name=expression`, zoals de resource-formule in `resource_setting`) die
  `start_offset_in_seconds` en `duration_in_seconds` berekent uit `param_json`:
  plan uit `planned_start_offset_in_seconds` en `production_impact_in_seconds`, progress
  uit `remaining_impact_in_seconds`, actual uit `actual_start_offset_in_seconds` en
  `actual_duration_in_seconds`. `get_resource_plan` levert de variabelen en dezelfde
  uitkomst in de kolommen (test: 0 rijen verschil over 356 rijen). Bord 81:
  `timeline_config` in het vocabulaire van 19/29/56/76: `set_field` = `type`,
  `set_order_field` = `type_json.sort_order`, `placement_field` = `type_json.placement`
  (plan `chain`, progress en actual `offset`), `evaluate {formula_field, params_field}`,
  `set_overrides` per soort, `items {data_field: states_json, …}` voor het subniveau. Script:
  `archive/sql/migrations/update_resource_plan_formula.sql`, dan de partial (81).
- nog niet in deze stap: de plan/progress-splitsing van bord 76 (`get_impose_plan`,
  materiaalmodus) — volgt als 7b, met dezelfde `progress_json`.
- **76 rekent met de soort-formule (6 sep):** `evaluate.formula_field` stond op `formula`
  (de machineformule van de resource, over `net_sqm`), terwijl `get_impose_plan` al
  `planned_start_offset_in_seconds` en `production_impact_in_seconds` in `param_json`
  zet; nu `type_json.formula`, als 81, plus die twee keys in `field_config`. De
  kolom `formula` blijft (resourcekant). Script: de partial (76).
- **één vocabulaire voor de soorten (6 sep):** de groep `state` in `lookup_resource_state`
  heet `actual` (log.lookup door Cees, relation.lookup in het script), want de soorten zijn
  plan, progress en actual. Elke soort draagt een basisclass in `class_names`:
  `timeline-plan`, `timeline-progress`, `timeline-actual` (lookup_lane_item_type voor 76
  en 81; `get_plan_timeline` zet `timeline-<group>` vóór `state.class_names` voor 56).
  Script: `archive/sql/migrations/update_timeline_set_classes.sql`; de css is van de frontend.
- lookup-spiegel `json/lookup/relation/lookup_step_category.json` stond achter op de
  database (11 stappen, oude statuscodes zoals `imposed`/`packaged`); vervangen door de
  database-inhoud (12 stappen, met `calander` en `apply`, codes `nested`/`packed`).

### stap 7c — impose-lanes uit het material-resource-plan (7 sep)

**Gevonden.** De patroonrijen (`mock.material_impose_plan`) hebben sinds 8 aug step
`impose`; `generate_plan` filtert op de step waarmee hij wordt aangeroepen en
`refresh_derived_data` riep hem aan met `print`: elk plan vanaf 9 sep is leeg gestampt
(0 lanes). Het material-resource-plan ís het impose-dagplan: de stap heet nu overal
`impose` (plan.steps, defaults van `get_impose_plan` en `get_plan_lanes`, refresh).

**Wat verandert.** `generate_plan` maakt naast de materiaallanes één resource lane per
impose-machine die het patroon noemt (`resource_lane`, bestaande lane van die dag
hergebruikt, achter de materiaallanes in `plan_lane`). `get_plan_lanes` (resourcemodus)
en `get_resource_plan` lezen de resource lanes van álle plantypes van de dag; bij een
impose-lane zijn de items de plan-items van de materiaallanes waarvan het patroon die
machine noemt — het patroon-item met fixed group en klassetijd van bord 76 (via
`get_plan_lanes`), de batch-items als fillers. Duur: productie-impact van de nests, anders
van het open werk van het materiaal (regel van 76), nooit onder 900. Actual-rijen blijven
leeg: het log kent de impose-machines niet. Bord 81 stuurt geen `plan_type` meer mee.
Script: `archive/sql/migrations/update_impose_lanes.sql` (functies, steps-update, backfill in een DO-blok:
lege plannen opnieuw stampen, bestaande plannen krijgen hun resource lanes).

**Breedte van een rij op 76 (7 sep):** `duration_in_seconds` en `production_impact_in_seconds`
tellen alleen het werk van de leverklasse 30 uur (`v_width_delivery_hours` in
`get_impose_plan`); de andere klassen blijven in de getallen van de rij, niet in de tijd.
Script: `archive/sql/migrations/update_impose_plan_width.sql`. De impose-lanes op 81 rekenen nog met alle klassen.


**Wat verandert.** `plan.type`: weg (de lane-soort zegt het) of hernoemd naar
`imposition-group-plan`/`resource-plan`; `lane_item.source` `material-plan` →
`lane-pattern`; de resterende plan-functies van `mock` naar `action`
(`generate_plan`, `generate_production_plan`, `get_impose_plan`,
`get_production_plan`, `crud_material_impose_plan`); `action.get_lanes`,
`get_plan_timeline` en het pv2-pad naar de archiefanalyse als 56 weg mag. Docs
(`domain-model.md` §9, `plan-lanes-boards.md`, `contracts/drag-and-drop.md`) op
de nieuwe stand.

**Raakt.** waarden (UPDATE + lezers in één transactie), `site.data_table.query`,
data_group-defaults die `plan_type` meegeven (81), docs.

**Controle.** Alle vier borden laden met identieke labels en items; geen
functie in `mock` met `plan`, `lane` of `impose` in de naam meer; `pg_stat_statements`
zonder fouten na een dag.

### volgorde en wat ik nu nodig heb

1 en 2 kunnen direct, los van elkaar; 3 daarna; 4 en 5 na 3; 6 na 2 en 3; 7 na
6; 8 als laatste. Na jouw akkoord op deze indeling begin ik met stap 1 (meten,
mirror, deploy-script) en stap 0/2. Voor stap 6 heb ik van jou de
optieset → stap-mapping en het antwoord op de pool-lane.
