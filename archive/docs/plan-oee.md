# OEE: counts_as in lookup_resource_state + formule-evaluatie

Status: plan. De meetdata (`log.state`, `log.data`) is goed; de OEE-cijfers
komen niet uit hardcoded SQL-deling maar uit `param_json` + `formula_array`
via `public.evaluate_many_nas`. Wat ertussen zit — `log.state_shift_agg` en de
hiërarchie in `lookup_resource_state` — moet eerst kloppen.

Alle getallen hieronder zijn geverifieerd tegen de DB op 2026-09-02.

## 0. de keten zoals hij nu is

`src` in een data_group is een **`site.data_table`-naam**, niet een
functienaam; `site.data_table.query` wijst de functie aan.

| versie | pagina | data_group | data_table | functie |
|---|---|---|---|---|
| v1 | `oee` | `resource_oee_timeline` (19) | `get_resource_oee_timeline` (111) | `log.get_resource_timeline` |
| v1 | `oee` | `resource_oee_chart` (29) | `get_resource_oee_aggregate` (121) | `log.get_resource_state_aggregate` |
| v2 | `resource-oee-area-chart` | `resource_oee_area_chart` (62) | `get_resource_state_shift_totals` (184) | `log.get_resource_state_shift_totals` |
| v2 | `resource-oee-area-chart` | `resource_oee_area_chart_filter` (64) | `get_resources` (187) | `relation.get_resources` |
| — | `production-line-overview` | `production_line_overview` | `get_resource_state_current` (122) | `log.get_resource_state_current` |

Tabellen: `log.state` (ruwe statuswissels), `log.data`
(`production_time_seconds`), **`log.state_shift_agg`** (de tellende data),
`action.dates` (`shift_json`), `action.object` (planning),
`relation.resource` / `production_line`, `relation.lookup`
(`lookup_resource_state`, `lookup_step_category`).

Builder: `log.upsert_state_shift_agg(date)`.
`mapping.get_resource_weighted_capacity` gebruikt OEE alleen als *invoer*
(`p_oee`), niet als meting.

De vier functiebestanden in `sql/log/` zijn byte-identiek aan de live
functies — de repo-dump is betrouwbaar.

## 1. welke states er echt zijn

`log.state`, laatste 60 dagen, tien codes:

| code | rijen | resources |
|---|---|---|
| `running` | 71.182 | 61 |
| `idle` | 63.031 | 62 |
| `setup` | 51.577 | 34 |
| `starved` | 17.291 | 15 |
| `blocked.operator` | 13.122 | 16 |
| `breakdown` | 9.615 | 39 |
| `offline` | 2.092 | 69 |
| `starved.operator` | 1.494 | 17 |
| `missingdata` | 1.351 | 67 |
| `blocked` | 100 | 10 |

`log.state_shift_agg` voegt daar de afgeleide `producing` en `planned` aan
toe. **Nooit voorkomend**, hoewel ze in de lookup staan: `maintenance`,
`interruption`, `breaks`, `changeovertime`, `ticket`, `data-error`,
`installation`. `maintenance = unavailable` is dus een regel voor later, geen
regel over bestaande data; `breaks` en `changeovertime` spelen nu niet.

Twee bronnen schrijven per Zünd-resource in dezelfde tijdlijn
(`zund.productions` → running/idle, `zund.interruptions` →
`blocked.operator`/`starved.operator`); ze onderbreken elkaar, ze overlappen
niet. Durst schrijft via `durst.events`.

## 2. de ruwe data partitioneert de shift netjes

Per (`shift_date`, `shift_index`, `resource_uid`), laatste 14 dagen, som van
alle níet-afgeleide states versus de shiftlengte:

| | groepen |
|---|---|
| exact gelijk (≤ 2 s) | 2.896 |
| te kort | 377 |
| te lang | 37 |
| **totaal** | **3.310** |

De 377 te korte zijn de groepen waar Durst/Zünd zélf `starved` /
`starved.operator` logt (210 ervan aantoonbaar): die tijd is in de opslag
samengevoegd met de afgeleide `starved` en valt daarom buiten deze telling.
Zie §3a.

Voor Dürst P5-500 op 26 aug shift 1 heb ik de builder read-only nagerekend:
`running` 7,58 / `idle` 0,92 / `setup` 0,49 / `breakdown` 0,01 = **9,00 h =
exact de shiftlengte**, en elke waarde gelijk aan wat er is opgeslagen. De
meting is goed.

## 2b. waar de shift-vensters vandaan komen

Het venster is de noemer, dus dit bepaalt elk OEE-percentage.

| bron | grain | inhoud | actueel? |
|---|---|---|---|
| `action.dates.shift_json` | per datum, **geen** resource/line | statisch jaarpatroon: werkdag `06:00–15:00` + `15:00–23:59` (17,98 h), weekend `08:00–17:00`. 261 + 104 dagen, heel 2026 identiek | ja, maar het is een patroon, geen meting |
| `relation.shift_planning` | `resource_uid` = **`department-<n>`** + `plan_date` + `start_at`/`end_at` | Dyflexis-sync, echte vensters per afdeling → productielijn | **gestopt 2026-06-28** |
| `relation.shift_registered_hours` | idem, + `shift_type` (`day` / `evening`) | geregistreerde uren, gem. 9,21 h / 10,01 h | **gestopt 2026-06-14** |
| `log.hr_shift_planning` | `department_group_id` + `business_date` | `shift_json` is een **medewerkersrooster** (groepen × personen), geen tijdvensters | ja, tot 2026-09-15 |

`action.dates.shift_json` staat al op de sloopnominatie:
`sql/migration_dates_tenants_day_off.sql` §3 is BLOCKED met "dropping
shift_json breaks log.upsert_state_shift_agg ... and
log.get_resource_state_shift_totals ... Give those two a new shift source
(relation.shift_planning?) first".

De `resource_uid` in de twee shift-tabellen is `department-108`,
`department-152`, … — **geen machines**: 0 van de 37 heeft een `step`. Maar 16
ervan hebben wél een `line_id` en een `resource_path`
(`dk.textile`, `dk.sheet`, `dk.non_adhesive`, `dk.foil`, `dk.label`, `dk.paper`),
dus de weg naar de machines loopt via de lijn — `line_id` of `resource_path <@`
(dk.foil: 57 machines op de lijn, 49 onder het pad, 31 met een step).

Die vensters zijn echt, en anders dan het patroon:

| lijn | 2026-06-17 | som | envelope |
|---|---|---|---|
| `dk.non_adhesive` | `08:00–02:00` **en** `08:00–04:00` (twee afdelingen) | 38,00 h | 20,00 h |
| `dk.textile` / `dk.foil` / `dk.sheet` / `dk.label` | `08:00–02:00` | 18,00 h | 18,00 h |
| `dk` | `08:00–00:00` | 16,00 h | 16,00 h |

Twee dingen volgen daaruit. Vensters **lopen over middernacht** — precies wat de
builder nu niet kan (geen `+1 day`, en `23:59` in `shift_json` is de truc die
dat omzeilt). En een lijn kan **twee afdelingen** hebben met overlappende
vensters: die moeten tot één envelope samengevoegd worden, niet opgeteld, anders
verdubbelt de noemer (38 h tegen 20 h).

## 3. wat er wél misgaat

### 3a. de afgeleide `starved` heet hetzelfde als de gelogde `starved`

`upsert_state_shift_agg` schrijft twee dingen onder één code:

```sql
-- starved = deel van running dat niet produceerde
insert into tmp_agg (...) select ..., 'starved',
       greatest(r.duration_seconds - p.produced_seconds, 0) ...
where r.state = 'running';
```

De gelogde `starved` is een periode **naast** `running`; deze afgeleide is een
restant **binnen** `running`. De eindinsert groepeert op `state` en telt ze op.
Daarmee is `starved` niet meer op te tellen, niet te nesten en niet te
verdelen.

`log.get_resource_state_aggregate` doet exact dezelfde berekening en noemt het
resultaat `data-error` — maar dat dekt de lading niet: de machine draait en
wacht (op een operator). Besloten 2026-09-02: de builder schrijft het restant
als **`starved.running`**, een eigen code (zodat `producing + starved.running
= running` narekenbaar blijft) met `alias_of: "starved"` in de lookup, zodat
hij toont en telt als starved. De gelogde `starved` (Durst) en
`starved.operator` (Zünd) blijven onaangeraakt; v1's donut blijft zijn eigen
`data-error` afleiden tot die lezer verhuist.

### 3b. de aggregaat-tabel houdt spoken vast

De eindinsert is een upsert met `having sum(duration_seconds) > 0`, en alleen
de `planned`-slice wordt verwijderd en opnieuw gevuld:

```sql
insert into log.state_shift_agg (...)
select ... having sum(duration_seconds) > 0
on conflict on constraint pk_state_shift_agg do update set ...;
```

Wordt de functie voor dezelfde datum opnieuw gedraaid — en dat gebeurt, want
`log.data` loopt achter op `log.state` — dan wordt een state die naar 0 zakt
door de `having` weggefilterd en dus **nooit bijgewerkt**. De oude rij blijft
staan naast de nieuwe.

Laatste 14 dagen, groepen met een `running`-rij:

| | groepen |
|---|---|
| met `running` | 1.000 |
| `producing` = `least(produced, running)` | 989 |
| `starved` = `greatest(running − produced, 0)` | 610 |
| **`starved` te hoog** | **327** |
| overschot | **775,3 h** |

Over 60 dagen: 1.241 van 4.575 groepen (27 %) hebben
`producing + starved > running`, samen **2.707,7 h** te veel. Dat is met deze
logica onmogelijk in één run — `producing` en `starved` sommeren altijd exact
tot `running` — dus komen die twee rijen uit verschillende runs.

Dürst P5-500, 26 aug shift 1: `running` 7,58 h, `producing` 7,58 h,
`starved` **5,21 h**. `log.data` geeft nu 7,89 h productie in die shift, dus
de huidige logica komt uit op `starved` = 0. Een eerdere run, toen `log.data`
nog op ± 2,37 h stond, schreef 5,21; de latere run werkte `producing` bij en
liet `starved` staan.

Zelfde oorzaak, zichtbaarder: 37 groepen tellen exact **dubbel** de
shiftlengte. Zünd Folie 4, zondag 30 aug, shift 08:00–17:00 → opgeslagen
`idle` 9,00 h **en** `running` 9,00 h. Nagerekend levert die dag precies één
event op (anchor `running` op 08:00) en dus alleen `running` 9,00 h. De
`idle`-rij is van een eerdere run, toen de laatste state vóór 08:00 nog `idle`
was.

→ de builder wordt delete-then-insert per datum, hetzelfde patroon dat
`planned` al gebruikt. Daarna een backfill over de bestaande historie.

### 3c. de lookup-hiërarchie staat schuin op de data

In `log.state` zijn `setup`, `starved`, `blocked` en `blocked.operator`
**broers** van `running`: ze delen de tijdlijn, ze zitten er niet in. In
`lookup_resource_state` staan ze als `states` **onder** `running`.
`get_resource_state_shift_totals` leest die nesting als parent/child, trekt
kinderen van de parent af en laat kinderen buiten
`total_duration_seconds`.

Dürst P5-500, 27 aug:

| shift | shiftlengte | som ruwe states | `total_duration_seconds` | `setup` | Σ `duration_percent` |
|---|---|---|---|---|---|
| 1 | 9,00 h | 9,00 h | 8,52 h | 0,48 h | **205,78 %** |
| 2 | 8,98 h | 8,98 h | 8,74 h | 0,24 h | **102,76 %** |

De noemer is in beide shifts precies de setup-tijd te laag. Shift 2 heeft geen
`starved`-spook en houdt dan nog 102,76 % over: dat is de setup-fout alleen.
Shift 1 komt op 206 % door setup plus het spook. Omdat de area-chart
`normalized: true` staat, ziet de vorm er plausibel uit terwijl elk getal fout
is.

→ `counts_as` gaat de sommen bepalen; de hiërarchie is helemaal weg. De lookup
is nu één platte array (zie §4).

### 3d. `starved.operator` staat niet in de lookup

`blocked.operator` staat er wel, `starved.operator` niet. Gevolg per lezer:

- `log.get_resource_state`: `state = NULL` (Zünd Folie 4, 28 aug: 18 rijen /
  0,34 h zonder state)
- `log.get_resource_state_aggregate`: `where gs.state is not null` → die tijd
  **verdwijnt**
- `log.get_resource_state_shift_totals`: gerepareerd met een hardcoded
  `CASE ... 'starved.operator' THEN 'starved'`

→ `alias_of` in de lookup; de `CASE` verdwijnt uit de SQL.

### 3e. `planned` heeft geen percentage

`v_excluded_states = array['offline','planned']`, en `duration_percent` wordt
alleen berekend voor states die daar niet in staan — terwijl de `where` de
`planned`-rijen wél doorlaat (`or c.state = 'planned'`). De area-chart plot
`planned` als losse lijn (`set_overrides.planned = {type: line}`) op
`y_field: duration_percent` en krijgt dus niets. De planning zit in de data
sinds 15 mei (6.259 rijen, 62 resources, 34.755,9 h) maar is nooit zichtbaar
geweest.

### 3f. `missingdata` is geen machinestatus

31.589 h in 30 dagen, 3.241 rijen, **elke rij een volle shift**, allemaal op
resources met `step = null` (67 van 193). Geen enkele resource met een echte
step krijgt het ooit: `print` 58 resources (28 met productie), `cut` 23 (18),
`impose` 17, `calander` 3, `laminate` 2, `coat` 1.

Het is de anchor-state van apparatuur die niets rapporteert: geen events in de
dag → de anchor vult de hele shift. In `breakdown_time` stoppen maakt
`breakdown_percentage` ≈ 100 % voor die hele groep.

### 3g. de twee versies meten een andere noemer

v2 telt alleen shift-uren, v1 telt het hele venster. `action.dates.shift_json`
is `06:00–15:00` + `15:00–23:59`: **17,98 van 24 uur**, de nacht
23:59–06:00 zit in geen shift.

Dürst P5-500, 27 aug: shift-basis **17,98 h**, venster-basis **24,00 h**,
verschil **6,02 h**. `log.state` stuurt geen idle/offline bij shift-einde, dus
de laatste state loopt door: de running-envelope wordt 22,39 h en v1's donut
toont `data-error` 8,52 h voor die dag — dat is vooral onbewaakte nacht.

De builder rekent `shift_end` bovendien zónder de `+1 day` die
`get_resource_state_shift_totals` wél toepast; zodra een shift over
middernacht loopt, lopen builder en lezer uiteen.

## 4. de nieuwe lookup: `counts_as`

Besloten 2026-09-02: **precies vier buckets, meer niet**. Een state zonder
`counts_as` zit wél in `production_hours` (de noemer) maar wordt nergens
gesommeerd — dat is het niet-producerende verlies. `running` heeft er ook
geen: het is de envelope van `producing + starved.running` en zou dubbeltellen.

| `counts_as` | states |
|---|---|
| `producing` | `producing`, `setup` |
| `breakdown` | `breakdown`, `maintenance`, `interruption` |
| `offline` | `offline`, `installation`, `missingdata` |
| `planned` | `planned` |
| *(geen)* | `running`, `idle`, `starved(.operator, .running)`, `blocked(.operator)`, `changeovertime`, `ticket`, `breaks`, en alle plan-keten-codes |

De versimpelde vorm leeft in een **nieuwe tabel `log.lookup`** (zelfde vorm
als `relation.lookup`; mirror `json/lookup/log/lookup_resource_state.json`,
script `sql/update_log_lookup_resource_state.sql`), zodat niets in één keer
om hoeft: `relation.lookup` houdt de oude geneste vorm en alle bestaande
lezers — de hele v1-pagina incluis — blijven ongewijzigd draaien. Alleen de
OEE-read (`get_resource_state_shift_totals`) leest `log.lookup`; de rest
verhuist later één voor één, en dan kan de oude eruit.

De vorm zelf: **één platte array van 31 nodes**, per node `code`, `i18n`
(direct op de node, geen `block`-wrapper meer, geen `title`-kopie), `group`,
`order`, `class_name`, `counts_as` en waar nodig `alias_of`. `color` is weg —
`class_name` draagt de styling. Verder:

- `alias_of` op `starved.operator` → `starved` en `blocked.operator` →
  `blocked` (§3d); `starved.operator` is toegevoegd
- `order` staat op één schaal (10…310, in OEE-volgorde); de oude waardes
  mengden twee schalen, waardoor de area-chart-stapeling willekeurig was
- `group` (`state`/`plan`) staat er nog, maar geen lezer van de nieuwe lookup
  mag er op filteren — dat filter is precies wat `maintenance`/`breaks`/…
  onzichtbaar maakte; `counts_as` beslist voortaan
- `lookup_resource_group_state` — `log.get_resource_plan_impact` leest die
  lookup en er is geen bestand in `json/lookup/`; die moet mee zodra die
  lezer verhuist

## 5. `param_json` + `v_formula_json` + `evaluate_many_nas`

Besloten 2026-09-02: de formules staan als **jsonb-variabele in de functie**
(`v_formula_json`, zelfde patroon als `action.get_plan_timeline`), de
bucket-totalen gaan per groep in een `param_json`, en
`public.evaluate_many_nas` rekent alles uit. Doorgevoerd in
`sql/log/get_resource_state_shift_totals.sql`.

Per (`shift_date`, `shift_index`, `line`, `step`, `resource_uid`):

```json
{
  "total_shift_in_seconds": 32400, "producing_in_seconds": 24480,
  "breakdown_in_seconds": 1440, "offline_in_seconds": 0, "planned_in_seconds": 27000,
  "shown_loss_in_seconds": 0, "shown_unavailable_in_seconds": 1440
}
```

Alle tijden zijn hele **seconden** (`*_in_seconds`, besloten 2026-09-04); de
frontend maakt er hh:mm van. `total_shift_in_seconds` is de
**vensterlengte × resources in de groep** (uit
`shift_def` × `resources`), nooit een som van gelogde states — een gat in de
logging drukt zo de OEE in plaats van de noemer stil te verkleinen.

```json
[
  "unavailable_in_seconds = breakdown_in_seconds + offline_in_seconds",
  "production_in_seconds = total_shift_in_seconds - unavailable_in_seconds",
  "unavailable_rest_in_seconds = max(unavailable_in_seconds - shown_unavailable_in_seconds, 0)",
  "available_in_seconds = max(production_in_seconds - producing_in_seconds - shown_loss_in_seconds, 0)",
  "producing_oee = production_in_seconds > 0 ? producing_in_seconds / production_in_seconds * 100 : 0",
  "breakdown_percentage = total_shift_in_seconds > 0 ? breakdown_in_seconds / total_shift_in_seconds * 100 : 0",
  "offline_percentage = total_shift_in_seconds > 0 ? offline_in_seconds / total_shift_in_seconds * 100 : 0",
  "planned_percentage = total_shift_in_seconds > 0 ? planned_in_seconds / total_shift_in_seconds * 100 : 0"
]
```

De stapel (besloten 2026-09-04): onderin producing (incl. setup, via
`counts_as`), dan de `available`-band, bovenop altijd `unavailable`.
`available_in_seconds` is het productievenster minus producing minus de
verliezen die als eigen vlak getekend worden (`shown_loss_in_seconds`: de
aangevinkte states zonder `counts_as` — starved, blocked, idle); aangevinkte
breakdown/offline gaan uit de `unavailable`-rest. Zo sluit de stapel bij elke
selectie op het venster. Een sub-state van een bucket (setup, missingdata) is
alleen een eigen rij als hij zelf is aangevinkt; anders vouwt hij in de
bucket-rij, zodat de tooltip-regel producing gelijk is aan
`producing_in_seconds` (besloten 4 sep: setup hoort bij producing). `running` wordt in de functie overgeslagen — het is
de envelope van `producing + starved.running` en zou dubbeltellen — en staat
daarom ook niet meer in het filter (64), net als `missingdata`.

De evaluator kent `? :` en `max()`, dus de nuldelingen zitten in de formule en
niet in de SQL. De functie geeft per rij `param_json` en `oee_json` (het
evaluatieresultaat) terug; `duration_percentage` per state is het aandeel in
het venster. `v_excluded_states` is weg. Planning blijft een eigen lijn
(geschatte productietijd) en gaat nooit in `total_shift_hours`.

## 6. draaivolgorde — uitgevoerd

Alles hieronder is gedraaid en geverifieerd (sep 2026); de eenmalige
migratiescripts zijn daarna opgeruimd. Wat blijft:

| blijvend script | rol |
|---|---|
| `sql/log/*.sql`, `sql/action/*.sql` | de object-mirrors — dit is de bron; deployen = drop + file draaien |
| `sql/update_log_lookup_resource_state.sql` | gegenereerd uit `json/lookup/log/lookup_resource_state.json`; na elke wijziging in de JSON opnieuw genereren en draaien |
| `sql/update_shift_totals.sql` | gegenereerde drop + create van de OEE-read, uit de mirror |
| `sql/update_data_group_partial.sql` | gegenereerd met `node scripts/build_update_data_group.js <ids>` |
| `sql/check_state_shift_agg.sql` | blijvende read-only checks op de tellende data |

Wat er stond (en wat het deed) in volgorde van uitvoering:

1. builder herbouwd: delete-then-insert per datum, restant `starved.running`
   (eigen code, alias naar starved), productie gespreid over
   `[start_at, start_at + production_time_seconds]`, left join zodat running
   zonder productie volledig restant wordt, nachtvensters (+1 day, v_until)
2. backfill over de hele historie — **altijd als DO-blok**, zie
   [[backfill-do-block]]-les: een per-rij SELECT wordt door client-paginering
   afgekapt
3. `log.lookup` + platte lookup (32 nodes, `counts_as`, `alias_of`,
   `fill`/`color` uit `docs/css_variables.css`); `relation.lookup` bleef
   onaangeraakt voor de nog niet verhuisde lezers
4. `get_resource_state_shift_totals`: buckets → `param_json`,
   `v_formula_json`, `evaluate_many_nas`, synthetische `available`-rij die de
   stapel op het venster laat sluiten, `counts_as` als platte kolom,
   `unavailable_rest_in_seconds` voor de tooltip
5. v1 verhuisd: `get_resource_state`, `_aggregate` (restant →
   `starved.running`), `_produced`, `_plan_batch` naar `log.lookup`
6. shiftdefinitie `23:59` → `00:00` (werkdag = exact 18 h) + backfill
7. data_groups 19/29/62/64 op de nieuwe vorm; het frontend-contract staat in
   `docs/handoff-oee-frontend.md`

## 7. open beslissingen

Besloten 2026-09-02: vier buckets (§4); formule als jsonb-variabele in de
functie + `param_json` + `evaluate_many_nas` (§5); `v_excluded_states` leeg;
`starved.running` (het restant, voorheen `data-error`) telt nergens en zit dus als verlies in `production_hours`;
`missingdata` → `offline` (aanpasbaar in de JSON-file). Nog open:

1. **De Dyflexis-sync** — wordt `relation.shift_planning` /
   `shift_registered_hours` weer gevuld? Zo ja, dan komt het venster per lijn
   daaruit (`SWAP POINT` in `sql/log/upsert_state_shift_agg.sql` én `shift_def`
   in `get_resource_state_shift_totals`) en kan `action.dates.shift_json` weg,
   zoals de geblokkeerde migratie al vraagt. Zo nee, dan blijft de noemer een
   bedrijfsbreed patroon en is OEE per resource niet beter te maken dan dat.
2. **Overlappende afdelingsvensters** samenvoegen tot één envelope per lijn
   (20 h) in plaats van optellen (38 h) — en dan: is de envelope het venster,
   of blijven het twee vensters met een eigen `shift_index`?
3. **Resources zonder `step`** — moet de builder daar rijen voor schrijven?
   193 resources, waarvan 67 alleen volle-shift `missingdata` produceren.
4. **Backfill-bereik** — `log.state_shift_agg` begint op 2026-05-01, `planned`
   op 2026-05-15; vanaf 2026-05-01 opnieuw opbouwen?
5. **v1's venster** — ook op shiftgrenzen leggen (dan zijn v1 en v2 gelijk), of
   het volle venster houden en de 6,02 h nacht als eigen `unmonitored_time`
   rapporteren in plaats van als `data-error`?
