# voorstel: legacy.imposition_unit_manifest

Datum: 2026-08-26. Aanleiding: de duur op bord 76 (`impose_plan`) komt nu uit een
machineformule met losse constanten in `param_json`, niet uit een manifest.

## het probleem, aan materiaal 47

`mock.get_impose_plan` levert voor Acrylaat 5mm vandaag:

```
material_id          47
nest_count           4          (2414708, 2415019, 2415024, 2415151)
orderline_count      0
sqm                  0.00
duration_in_seconds  900        <- de bodem, niet een berekening
```

Vier imposities, dus er is werk gedaan — maar `orderline_count` is 0: de
orderregels van die nesten staan op statussequentie 700 (gedrukt), buiten het
bereik 225…450 van het bord. De duur valt terug op de ondergrens.

En `param_json` is een optelsom van drie bronnen die niets met elkaar te maken
hebben:

| key | waarde | bron |
|---|---|---|
| `specs` | […] | `material_production_line` |
| `net_sqm` | 0.00 | de aggregate |
| `waste_factor` | 0.209 | `catalog.imposition_group` |
| `imposition_sqm` | 6.26 | `catalog.imposition_group` |
| `cut_factor` | 1 | `production.resource_setting` |
| `seconds_per_sqm` | 26.9 | `production.resource_setting` |
| `setup_seconds` | 0 | `production.resource_setting` |
| `measured_over_nests` | 11139 | **een meetstatistiek** |

`measured_over_nests` is het aantal nesten waarover `seconds_per_sqm` ooit
gemeten is. Dat het als variabele in `evaluate_many_nas` meeloopt laat zien wat
deze `param_json` is: geen contract maar een verzamelbak.

## de bron is de xbom, de maat is het vel

Een impositie is een **vel**, geen verzameling orderregels. Wat het kost volgt
uit wat erop gedrukt wordt en hoe groot het vel is — en `legacy.nest` heeft
beide.

In `catalog.xbom` staan 314 actieve regels met scope `imposition`. Elf daarvan
dragen een formule, en dat zijn allemaal `print-method.*` op
`standard-print-impact`:

```
standard_print_speed_cm2_sec = 222.22
production_impact_per_unit   = width * height / standard_print_speed_cm2_sec
```

`width` en `height` zijn centimeters en komen uit `legacy.nest`. Read-only
nagerekend met de echte formule:

| nest | b × h (cm) | impact |
|---|---|---|
| 2414708 | 190 × 305 | 261 s |
| 2415019 | 203 × 301,1 | 275 s |
| 2415024 | 203 × 265,3 | 242 s |
| 2415151 | 203 × 301,3 | 275 s |

Samen **1053 s** voor materiaal 47 — ruim boven de bodem van 900 s. Het bord
krijgt dus een echte duur.

## de tabel

Gemodelleerd op `production.imposition_unit_manifest`. Korrel: **één rij per
(impositie, option_code)**. Geen `production_orderline_id`, geen amount per
orderregel — het vel wordt één keer geïmposeerd, wat er ook op ligt. Daarmee is
dit dezelfde vorm als production: één rij per impositie per xbom-regel.

Extra ten opzichte van production:

| kolom | waarom |
|---|---|
| `xbom_id` | herkomst, en de weg terug als een formule verandert en het manifest opnieuw geëvalueerd moet worden |
| `amount` | `legacy.nest.amount` — imposities van dit vel; 1 bij ~93% van de nesten |
| `param_json` | de `param_json` van de xbom-regel plus de variabelen waarmee geëvalueerd is (`width`, `height`, `amount`), zodat het getal narekenbaar is zonder terug naar het nest |

`item_code` is nullable: elke `print-method`-regel heeft er geen, de
materiaalregel wel. Sleutel `unique (imposition_id, option_code)`, foreign key
naar `legacy.nest (nest_id)` met `on delete cascade`.

## de functie

`legacy.create_imposition_unit_manifest(p_imposition_ids bigint[])`.
Delete-insert, set-based, geen loop — twee statements hoe lang de array ook is.

1. de orderregels op de impositie (`legacy.single_product`) dienen alleen om de
   option codes te vinden; niets per orderregel komt in het manifest terecht
2. per orderregel resolven de codes precies als in
   `mapping.create_spec_unit_manifest`: de api-opties, de materiaalmapping, en
   een default alleen waar die optieset nog leeg is
3. `catalog.get_xbom_grouping_keys` maakt daar de **grouping key van de scope
   `imposition`** van — de codes die werkelijk een xbom-regel aansturen
4. de manifestregels zijn de actieve `imposition`-regels van die key,
   geëvalueerd tegen het vel

Voor de vier nesten van materiaal 47 levert dat 3 tot 4 regels per impositie: de
velmaterie, de dekking, en één print-regel die de tijd draagt.

De aanroep staat in `legacy.crud_nest`, na het `imposition_lane_item`-blok:

```sql
PERFORM legacy.create_imposition_unit_manifest(
    array(SELECT DISTINCT pt.nest_id
          FROM param_table pt
          WHERE pt.crud IN ('create', 'merge', 'update')
            AND pt.nest_id IS NOT NULL));
```

## multi_select: meerdere methodes op één vel

`catalog.library_option.multi_select` staat op true voor precies twee optiesets:
**`print-method`** en **`cutting-method`** (16 opties). Daar mogen meerdere
waarden naast elkaar staan — een vel kan dus echt twee printgangen of twee
snijgangen hebben. 26 open orderregels hebben er vandaag al twee.

Alle elf formuledragende `imposition`-regels in de xbom zijn multi_select-opties.
De functie collapst ze daarom niet meer: elke regel is een gang, en het manifest
is de lijst gangen. De consument telt op.

### de default in create_spec_unit_manifest was stuk

De defaultregel leidde de optieset af uit de **tekst** vóór de punt:

```sql
split_part(o.option_code, '.', 1) = split_part(c.option_code, '.', 1)
```

Dat is niet de optieset. `print-method`-codes verdelen zich over set **60, 87 en
108**, en `print-method.full-color` (de default van 32 producten) zit in set 60.
Koos een orderregel `print-method.full-color-white-full-color` (set 108), dan zag
de prefixtest twee keer `print-method` en **onderdrukte de set-60 default** —
twee verschillende gangen over hetzelfde vel, waarvan er één stil wegviel.
Samengestelde codes (`material.x;print-coverage.y`) werden om dezelfde reden
onder `material` gearchiveerd.

De set komt nu uit `catalog.library_option`. Een code kan in meerdere sets zitten
(`cutting-method.kiss-cut` in 57 én 103), dus het is een array per code en de
test is overlap. Een code die de library niet kent valt terug op zijn prefix.

Gemeten over 20 000 open orderregels verandert dit **één** orderregel. De fout is
latent, niet lopend — maar hij groeit mee met elke multi_select-optie die erbij
komt.

## de vraag: impact over meerdere items met eigen formules

Zo ziet het er nu uit, read-only nagerekend met de nieuwe regel:

| impositie | regels | impact-regels | som |
|---|---|---|---|
| 2414708 | 3 | 1 | 261 s |
| 2415019 | 5 | **2** | **550 s** |
| 2415024 | 3 | 1 | 242 s |
| 2415151 | 4 | 1 | 275 s |

2415019 houdt nu terecht `print-method.full-color` én
`print-method.full-color-white-white`, en telt op naar 550 s. **Dat is dubbel
geteld.** Beide regels evalueren namelijk dezelfde formule:

```
standard_print_speed_cm2_sec = 222.22
production_impact_per_unit   = width * height / standard_print_speed_cm2_sec
```

Die formule rekent een volledige velgang, ongeacht op welke code hij hangt.
`full-color` kost 275 s en `full-color-white-white` óók 275 s, terwijl dat er
drie gangen zijn. De `param_json` van alle elf regels is leeg, dus er is niets
dat ze onderscheidt.

### het antwoord: elke regel vult zijn eigen bijdrage in

Het manifest telt op, en verder niets. Elke regel vult
`production_impact_per_unit` met wat híj toevoegt, en een printmethode kijkt
per gang (fc, wit, neon) hoeveel er al staat. Er is geen totaal per code, want
je weet nooit welke codes er nog meer op het vel liggen.

De volledige uitwerking met de gangtabel voor alle elf codes staat in
`docs/formula-impact-per-step.md`. Read-only nagerekend, met 120 s per gang:

| codes op de impositie | per regel | som |
|---|---|---|
| `fc` + `fc-2w` | 120, 240 | 360 |
| `fc-2w` | 360 | 360 |
| `fc-2w` + `fc-neon` | 360, 120 | 480 |
| `kiss-cut` + `through-cut` | 600, 40 | 640 |

De som hangt niet van de volgorde af; `formula_level` bepaalt alleen wie de
gang op zijn conto krijgt.

## waar de optiecodes vandaan komen

Uit de orderregels, via `catalog.get_xbom_grouping_keys`. Verder is er niets:
`nest_json` en zijn `grouping_key3` vervallen, dus alleen de xbom en de
manifests blijven over.

Een gevolg om te kennen: `print-coverage.unprinted` komt in het manifest van
2415019 en 2415151 terecht - de default van orderregels zonder dekkingsoptie.
Die regel draagt geen formule en kost dus niets, maar hij staat er wel. Zodra de
set-bewuste default van `create_spec_unit_manifest` draait verdwijnt een deel
daarvan vanzelf; wat overblijft is een kwestie van de optiemapping aanvullen.

## herschreven 4 sep: de regels komen uit de orderregelmanifests

Gemeten: de tabel was **leeg**. Twee oorzaken. De `PERFORM` in `crud_nest` was
nooit gedraaid (live versie zonder), en de functie zelf faalde op elke
print-regel: `Unknown variable: standard_print_speed_cm2_sec`. De live formule
`standard-print-impact` (v1) leest `standard_print_speed_cm2_sec`,
`neon_speed_cm2_sec`, `print_impact` en `neon_impact`; die constanten staan
in `catalog.item` bij de print-method-items (`item_json.params`), niet in de
xbom-`param_json` (leeg), en de accumulatoren moeten van regel naar regel
meelopen. De functie evalueerde elke regel los, met alleen de xbom-constanten.

Daarnaast matchte de functie de grouping key **per losse code** op
`xbom.option_code`, terwijl 80 van de 314 impositie-regels een samengestelde
code hebben (`laminate.x;material.y`): die matchten nooit, en een enkele code
matchte ook als er een specifiekere samengestelde regel was.

De functie doet nu wat `mapping.create_spec_unit_manifest` al doet, en leent
het resultaat daarvan:

1. de regels van het vel zijn de `scope = 'imposition'`-regels van de
   orderregelmanifests op het vel (`mapping.spec_unit_manifest`), distinct per
   (impositie, option_code) — één resolutie in plaats van twee verschillende
2. per regel de xbom-rij erachter (formule, constanten, `xbom_id`)
3. evaluatie als in het orderregelmanifest: op `formula_level`-volgorde, de
   variabelen reizen mee (recursieve fold), start: `width`/`height` van het
   nest in cm, `amount`, en 0 voor elke linkerkant van elke formule; constanten
   van het item (`item_json` en `params`) en van de xbom-rij

Read-only nagerekend op 300 recente nesten: 676 regels, 214 met impact,
nest 2431178 (152 × 643,6 cm) → `print-method.full-color` 440 s
(= 152 × 643,6 / 222,2). Dekking laatste 30 dagen: 44.145 van 44.989 nesten
krijgen regels, 19.249 een formule-regel; de rest heeft geen print-method op
de orderregels.

`catalog.get_xbom_grouping_keys` speelt hier geen rol meer; de sectie "waar de
optiecodes vandaan komen" hierboven beschrijft de oude weg.

## veroudering

`mapping.create_spec_unit_manifest` herbouwt het manifest van een orderregel.
Dat raakt dit manifest niet meer: de bron is de xbom en het nest, niet de
orderregel. Verandert een **formule**, dan is `xbom_id` op de rij de weg terug om
gericht te herbouwen.

## draaivolgorde (4 sep)

De tabel en de set-bewuste default staan er al. Nog te draaien:

1. `sql/legacy/create_imposition_unit_manifest.sql` — de herschreven functie
2. `sql/legacy/crud_nest.sql` — de `PERFORM`-aanroep (repo-versie, live ontbreekt hij)
3. `archive/sql/migrations/backfill_imposition_unit_manifest.sql` — backfill 60 dagen als DO-blok,
   batches van 500 nesten, met de verificatie eronder

De aftrekregels per print-method-code (`docs/formula-impact-per-step.md`) zijn
een formule-kwestie in `catalog.formula`; de fold in de functie draagt
`print_impact`/`neon_impact` al mee, dus zodra de formules kloppen tellen
meerdere gangen goed.

Daarna verder met `get_impose_plan` en `get_plan_lanes_imposition_group`: `param_json` opruimen en
de duur uit het manifest halen in plaats van uit de machineformule.
