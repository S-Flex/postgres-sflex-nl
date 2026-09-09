# resource_path — de resource-boom

`relation.resource.resource_path` is een `ltree` die zegt waar een resource in
de boom zit, van grof naar fijn. `resource_uid` blijft de stabiele sleutel
waar logs, plannen en lookups naar verwijzen; het pad is de classificatie en
mag veranderen als een machine verhuist of hernoemd wordt.

## basisregels

1. Een punt is **alleen** een niveauscheiding. Nooit een punt binnen een waarde.
2. Binnen een segment: kebab-case, alles lowercase (hyphens in ltree-labels
   vereisen PostgreSQL 16+).
3. Vast aantal segmenten: **8**. Elke positie betekent altijd hetzelfde, voor
   elk type resource.
4. Breedte in centimeters, altijd 3 cijfers.
5. Elk prefix is een groep. Groeperen = prefix afkappen. Wisselen van stap =
   één segment vervangen.
6. Een pad verandert nooit terwijl de machine ingepland staat: een verhuizing
   is offline → demonteren → transport → pad dagen later bijwerken. Zo lopen
   de snapshot van een lane en de live resource binnen een plandag nooit
   uiteen.

## posities

```
dk . sheet . print . 320 . uv . durst . p5-350hs-automat . 473363
1     2       3       4     5    6       7                  8
```

| # | positie | betekenis | voorbeelden |
|---|---------|-----------|-------------|
| 1 | site | vestiging (de `abb` van de tenant uit `lookup_tenants`) | `dk`, `bh` |
| 2 | material | materiaalsoort | `foil`, `sheet`, `non-adhesive`, `textile`, `label`, `paper` |
| 3 | step | processtap — hetzelfde woord als `resource.step` | `print`, `cut`, `impose` |
| 4 | width | max. breedte in cm, 3 cijfers | `090`, `120`, `210`, `250`, `320`, `500` |
| 5 | medium | hoe het materiaal bewerkt wordt | print: `uv`, `latex`, `solvent`, `dye-sub`, `electro-ink` · cut: `knife`, `laser` |
| 6 | brand | fabrikant | `durst`, `epson`, `hp`, `zund`, `swissq`, `aristomat`, `bullmer`, `eurolaser`, `sei` |
| 7 | type | modelnaam, kebab-case | `p5-350hs-automat`, `g3-xl`, `sc-9100` |
| 8 | serial | serienummer, lowercase | `473363`, `g300l320060` |

### impose-resources: breedte, of dieper als een machine apart imposeert

Imposeren gebeurt meestal per materiaalbreedte, niet per machine: één resource
per unieke `site.material.width` die printers heeft, met `impose` op positie 3
(`dk.sheet.impose.210`). Die basis wordt **afgeleid uit de printerpaden**
(`archive/sql/migrations/migration_impose_resources.sql`), zodat een nieuwe printerbreedte
vanzelf zijn impose-resource oplevert.

Imposeert één machine op zijn eigen manier, dan krijgt die een **dieper**
impose-pad, tot en met het model: `dk.sheet.impose.320.uv.swissq.kudu`. Dat is
geen uitzondering maar hetzelfde principe — het pad loopt door tot het niveau
waarop het imposeren echt verschilt. Zulke resources zijn niet af te leiden en
worden bewust aangemaakt. `mock.material_impose_plan.resource_path` wijst naar
het niveau dat van toepassing is; deze resources zijn de lanes van
`resource_plan` (voorheen `impose_resource_plan`).

### positie 5 is de sleutel voor cutters

Voor printers is dit het inkttype. Voor cutters is het de snijmethode. Het is
dezelfde vraag — *hoe wordt het materiaal bewerkt* — dus dezelfde positie.
Geen lege segmenten of `none` nodig, en `dk.sheet.cut.320.laser.` werkt
precies zoals `dk.sheet.print.320.uv.`.

### positie 7: haal de breedte uit de modelnaam

Fabrikanten zetten de breedte vaak in het model (`g3l2500`, `d3xl3200`,
`eurolaser3xl3200`). Die staat nu in positie 4. Laat hem uit de modelnaam weg,
anders staat hij er dubbel in en kunnen de twee gaan afwijken.

- `g3l2500` → width `250`, type `g3-l`
- `d3xl3200` → width `320`, type `d3-xl`
- `eurolaser3xl3200` → width `320`, brand `eurolaser`, type `3xl`

## voorbeelden

Printers:

```
was:  dk.sheet.print.durst.p5.350hsautomat.450272
werd: dk.sheet.print.320.uv.durst.p5-350hs-automat.450272

was:  dk.textile.print.hp.stitch.sg37c1f001
werd: dk.textile.print.320.dye-sub.hp.stitch.sg37c1f001

was:  dk.paper.print.hp.indigo12000.il20110235
werd: dk.paper.print.075.electro-ink.hp.indigo-12000.il20110235
```

Cutters:

```
was:  dk.foil.cut.zund.d3l3200.d300l320060
werd: dk.foil.cut.320.knife.zund.d3-l.d300l320060

was:  dk.textile.cut.zund.eurolaser3xl3200.1727s5021p
werd: dk.textile.cut.320.laser.eurolaser.3xl.1727s5021p

was:  dk.non-adhesive.cut.bullmer.sav300d.16020037
werd: dk.non-adhesive.cut.300.knife.bullmer.sav-300-d.16020037
```

## wat níet in het pad hoort

Het pad is identiteit. Alles wat kan veranderen of waar je op wil rekenen,
staat als veld op het record:

```json
{
  "resource_path": "dk.sheet.print.320.uv.durst.p5-350hs-automat.450272",
  "width_mm": 3500,
  "ink_type": "uv",
  "options": ["automat", "roll-to-roll"],
  "status": "active"
}
```

`width` en `medium` staan dus dubbel: in het pad voor de groepering, als veld
voor de exacte waarde. Dat is bewust. De breedte in het pad is een klasse
(320), het veld is de werkelijke maat (3500 mm).

## bevragen

```sql
-- everything under a branch
where r.resource_path <@ 'dk.sheet.print'
-- every uv printer of one vendor, on any site or material
where r.resource_path ~ '*.print.*.uv.durst.*'
-- how deep
nlevel(r.resource_path)
-- the site of a resource
subpath(r.resource_path, 0, 1)
```

Indexes: `uq_resource_path` (btree, partial op not null) voor gelijkheid en
sorteren, `idx_resource_path_gist` voor `<@`, `@>`, `~`. Let op: zolang
groepsresources (queues/stocks) een gedeeld prefix-pad dragen kan de unique
index niet aan.

## waar het pad nog meer leeft

- `action.lane.resource_path` — de machine die een productieplan-lane plant,
  waar hij ook fysiek staat: het pad houdt de fysieke afdeling, het plan de
  orderkant, en `action.plan_lane` hangt de lane onder beide borden. Eén lane
  per machine per dag (`uq_lane_date_resource_path`), snapshot op het moment
  van plannen. Material-lanes van het nestplan laten hem null.
- `action.cutoff_time.rule_path` is **niet** deze boom: een ltree van id's
  (`tenant.line.material`); zelfde type, andere boom.
- `action.non_working_times.rule_path` is nog text met dezelfde id-vorm.

## op te lossen in de huidige data

De hele bestaande boom volgt nog de oude volgorde
(`site.material.step.brand.model….serial`, zonder width/medium) — de migratie
naar de 8 posities is nog te doen. Daarbinnen:

- `dk.non_adhesive.print` naast `dk.non-adhesive.print...` — underscore moet
  kebab worden (zelfde inconsistentie bij de queues/stocks op `site.material`).
- `durst.p5350hs` naast `durst.p5.350hs` — zelfde machine, twee schrijfwijzen.
- `dk.textile.cut.zund.eurolaser3xl3200...` — eurolaser is een eigen
  fabrikant, geen Zünd.
- `dk.sheet.cut.sei` en `dk.foil.print` — onvolledige paden. Prefix als groep
  is prima, maar dit lijken machines zonder type en serienummer.
- Serienummers van de Zünd G3 XL wisselen van vorm: `g3xl321089`,
  `g30xl320532`, `g33xl320185`. Controleren of dat echt zo op de machines
  staat.
- Inkttype nog vast te stellen voor: `epson.sc9100`, `epson.sc80600`,
  `epson.scg6000`, `swissq.karibu`, `swissq.kudu`.
- Breedte nog vast te stellen voor vrijwel alle machines waar hij niet in de
  modelnaam zit.
- Een migratie voor de nest-resources is er nog niet (dat script is nooit
  geschreven): omzetten naar 8 posities zodra width/medium per printergroep
  bekend zijn.
- Het kolom-comment op `relation.resource.resource_path` beschrijft de oude
  volgorde — bijwerken bij de padmigratie.
