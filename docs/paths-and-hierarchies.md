# Paden en hiërarchieën

Vier bomen in dit model, alle vier anders van vorm en bedoeling. Ze lijken op
elkaar omdat er punten in staan — dat is precies waarom het loont om ze uit
elkaar te houden.

| kolom | type | diepte | labels zijn | waarvoor |
|---|---|---|---|---|
| `relation.resource.resource_path` | `ltree` | **vast 8** | namen (kebab) | welke machine/resource is dit |
| `catalog.item.item_code_path` | `ltree` | **variabel 2–9** | itemcode-segmenten | wat is dit voor product |
| `action.cutoff_time.rule_path` | `ltree` | variabel 1–3 | **id's** | voor wie geldt deze regel |
| medewerkers | *geen pad* | — | — | wie doet wat, wanneer |

Stand: 2026-08-25, gemeten in de database.

---

## `relation.resource.resource_path`

**Vast aantal segmenten: 8.** Elke positie betekent altijd hetzelfde:

```
site . material . step . width . medium . brand . type . serial
dk   . sheet    . print . 320   . uv     . durst . p5-350hs-automat . 473363
```

Zie `docs/resource-path.md` voor de posities in detail.

**Bedoeling: identiteit en classificatie van een resource.** `resource_uid`
blijft de stabiele sleutel waar logs en plannen naar verwijzen; het pad zegt
*wat* het ding is en waar het hoort. Het mag veranderen als een machine
verhuist of hernoemd wordt.

**Gebruik: prefix afkappen is groeperen.** Elk prefix is een groep, en dat is
de hele bedieningslogica:

```sql
where r.resource_path <@ 'dk.sheet.print'        -- alle sheetprinters van dk
where r.resource_path ~ '*.print.*.uv.durst.*'   -- alle uv-Dursts, waar dan ook
```

Een resource hoeft niet alle acht niveaus te hebben: hij stopt op het niveau
waarop hij bestaat. Een impose-resource zit op de breedte
(`dk.sheet.impose.320`) tenzij één machine apart imposeert, dan gaat hij dieper
(`dk.sheet.impose.320.uv.swissq.kudu`). Queues en stocks stoppen al bij
`site.material` en delen dat pad — daarom kan er geen unique index op.

**Wie wijst hierheen:** `action.lane.resource_path` (welke machine een
planlane plant) en `mock.material_impose_plan.resource_path` (op welke
impose-resource een patroonrij staat). Geen foreign keys: het pad is een
verwijzing naar een niveau, niet naar een rij.

---

## `catalog.item.item_code_path`

**Variabele diepte, 2 tot 9 niveaus, twee wortels: `roll` en `sheet`.**

```
roll.acoustic.felt
roll.3m.480.mc
roll.acrylic.blockout.film
```

**Bedoeling: classificatie van wat er verkocht en gemaakt wordt.** De diepte is
niet betekenisloos maar ook niet vast: een item krijgt zoveel niveaus als
nodig om zich te onderscheiden. Er is geen positie-tabel zoals bij
`resource_path` — het pad volgt de itemcodes zelf.

**Gebruik: het meest specifieke prefix wint.** Daar hangt de prijsketen aan:

- `catalog.item_base_price.item_code_path` — basisprijs per (deel van de) boom
- `catalog.item_price_formula.item_code_path` — formule per (deel van de) boom
- `catalog.imposition_group.item_code_paths` (`ltree[]`) — welke item-codepaden
  samen op één plaat mogen

Een prijs of formule op `roll.3m` geldt dus voor alles daaronder, tenzij er
een specifiekere rij is. Dat is het hele mechanisme: regels zet je zo hoog
mogelijk en je verfijnt alleen waar het afwijkt.

**Let op — de impositiegroepen zijn nog een tussenstand.** Alle 407 groepen
hebben precies één pad in `item_code_paths`, en `imposition_group_id` is
voorlopig een **alias van `material_id`**. De array is er al voor wat komt:
meerdere item-codepaden die samen imposeren.

---

## `action.cutoff_time.rule_path`

**Een pad van id's, geen namen:**

```
tenant . production_line . material
1      . 22              . 53
```

**Bedoeling: bereik van een regel.** Niet "wat is dit ding", maar "voor wie
geldt deze afspraak". Een cutoff op `1` geldt voor de hele tenant; wil je voor
één materiaal op één lijn iets anders, dan zet je een rij op `1.22.53`
ernaast. Beide tabellen zijn append-only met `moved_at`, dus de geschiedenis
blijft staan.

**Gebruik: langste match wint.** Zoek alle voorouderpaden van het meest
specifieke pad en neem de diepste die bestaat.

**Stand van zaken:** alle 98 cutoff-rijen staan op niveau 1 (alleen de
tenant). De diepere niveaus zijn ontworpen maar nog niet in gebruik.
`action.non_working_times.rule_path` gebruikt dezelfde vorm wél tot drie
niveaus (`2.22.53`), maar staat daar als **`text`** in plaats van `ltree` —
dezelfde boom, twee types. Dat is een op te ruimen inconsistentie.

**Waarom id's en geen namen?** Omdat een regel aan de administratie hangt, niet
aan de fysieke werkelijkheid: een tenant of lijn kan hernoemd worden zonder dat
de regel verschuift. Precies andersom dan `resource_path`, waar de naam juist
de betekenis draagt.

---

## medewerkers — bewust geen pad

Voor mensen bestaat **geen** `*_path`. De hiërarchie loopt langs twee lijnen:

**1. Teams (`relation.team`)** — 49 teams, elk met `production_line_id`,
`tenant_id` en een `steps[]`-array met de stappen die het team doet
(`{print,cut,bin,pack}`). Er ís een `parent_team_id` voor een echte boom, maar
die is **nergens gevuld**: alle teams staan plat naast elkaar.
`action.week_team` (795 rijen) koppelt een team aan een week.

**2. Shifts via de resource-boom** — `log.hr_shift_planning.shift_json ->> 'resource_uid'` (was `relation.shift_planning.resource_uid`)
wijst naar **department-resources** (`department-108`, `department-162`), en die
staan gewoon in `relation.resource` met een kort pad (`dk`, `bh.non_adhesive`).
Een ploegendienst hangt dus aan een afdeling in de resource-boom, niet aan een
aparte organisatieboom.

**Wat er (nog) niet is:** `relation.team_contact` is leeg, `contact.team_id` is
overal null, en `contact.competences` ook. Wie in welk team zit komt dus nu
niet uit deze database. `relation.contact.roles` is wel gevuld
(`["user","employee"]`).

**Consequentie voor het ontwerp:** wil je straks plannen op mensen zoals we op
machines plannen, dan zijn er twee wegen. Óf de teamboom echt gebruiken
(`parent_team_id` vullen en dezelfde "langste match wint"-regel toepassen als
bij `rule_path`), óf medewerkers als resources in de resource-boom opnemen —
wat voor afdelingen feitelijk al gebeurt. De tweede weg maakt één boom voor
alles wat capaciteit heeft; de eerste houdt organisatie en machines gescheiden.
Nu gebeurt half het een, half het ander.

---

## de drie regels die de bomen onderscheiden

1. **Vast versus variabel.** `resource_path` heeft acht vaste posities: positie
   4 is altijd breedte. `item_code_path` heeft dat niet — daar zegt de diepte
   alleen "specifieker".
2. **Namen versus id's.** `resource_path` en `item_code_path` dragen namen en
   zijn dus leesbaar en hernoembaar; `rule_path` draagt id's en is stabiel bij
   hernoemen.
3. **Wat is dit versus voor wie geldt dit.** De eerste twee classificeren een
   ding, de derde begrenst een regel. Daarom werkt bij de eerste twee
   "prefix = groep" en bij de derde "langste match wint".

## op te ruimen

- `action.non_working_times.rule_path` is `text` maar hoort `ltree` te zijn,
  zoals `action.cutoff_time.rule_path`.
- `relation.team.parent_team_id` is een boom die niemand vult: gebruiken of
  weghalen.
- `relation.team_contact` en `contact.team_id` zijn leeg — beslis waar
  teamlidmaatschap thuishoort voordat er iets op gebouwd wordt.
- De unique index op `resource_path` kan niet met de huidige data, omdat
  groepsresources hun prefix delen.
