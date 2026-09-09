# log.state_shift_agg actueel na elke crud_state_log

Datum: 2026-09-05. Hoort bij `archive/docs/plan-oee-donut.md` §3 "actualiteit".
Gebouwd aan de databasekant (zie "draaien" onderaan); de frontend hoeft
niets te doen, dat deel staat er voor de volledigheid.

## het probleem

`log.state_shift_agg` is de tellende tabel achter de OEE-reads
(`get_resource_state_shift_totals`: area-chart 62, straks de donut 29). Hij
wordt gebouwd door `log.upsert_state_shift_agg(date)`, en die draait nu alleen
in `site.refresh_derived_data()`, één keer per dag. De donut moet het actuele
beeld tonen, dus de tabel moet mee na elke schrijfactie op de bron:

- `log.crud_state_log` (data_table 167, `crud_state_log`) — de statuswissels
- `log.crud_data_log` — de productietijd per interval (`log.data`), die
  bepaalt hoeveel van `running` `producing` is

Gemeten vandaag (zaterdag): ~6 batches per uur, mediaan 2 rijen per batch,
max 34; op een werkdag een veelvoud daarvan, per bron (Zünd, Durst) los van
elkaar.

## besluit: de database bouwt zelf bij, in de schrijfactie

De herbouw hoort niet in de frontend. De bron van de wijziging is de
crud-functie, dus die sluit af met het bijwerken van precies de slices die de
batch raakt. De frontend hoeft daarvoor niets te doen en kan niets vergeten.

Wat er aan de databasekant is gebouwd (`archive/sql/migrations/update_state_refresh.sql`):

1. `log.upsert_state_shift_agg(p_date date, p_resource_uids text[] default null)`
   — de builder krijgt een resource-bereik. `null` blijft de hele dag (de
   dagelijkse run); met een lijst verwijdert en herbouwt hij alleen die
   resources voor die datum. Per resource een `pg_advisory_xact_lock`, zodat
   twee bronnen die dezelfde machine raken (Zünd schrijft productie én
   onderbrekingen apart) elkaar netjes afwachten in plaats van te racen.
2. `log.crud_state_log` en `log.crud_data_log` eindigen met één set-based
   aanroep per geraakte datum:
   ```sql
   perform log.upsert_state_shift_agg(d.shift_date, d.resource_uids)
   from (select date, array_agg(distinct resource_uid) ...) d;
   ```
   De geraakte datums zijn de datum van `start_at` (Europe/Amsterdam) **en de
   dag ervoor**: een nachtvenster loopt over middernacht, dus een event om
   00:30 telt ook in de vensters van gisteren.
3. `site.refresh_derived_data()` houdt `upsert_state_shift_agg(current_date - 1)`
   als dagelijkse afronding en veiligheidsnet; de regel voor `current_date`
   mag blijven (idempotent) of weg.

Kosten: de builder leest per datum alleen de `log.state`/`log.data` van dat
venster; met een resource-bereik is dat één machine-dag, ruim onder 100 ms.
Dat past in de ingest-transactie.

## wat de frontend moet weten en doen

1. **Niets aan de aanroep veranderen.** `crud_state_log` en `crud_data_log`
   blijven via hun data_table lopen, met dezelfde payload. Het bijwerken zit
   ín de functie.
2. **Eén transactie per batch houden.** De herbouw draait in dezelfde
   transactie als de insert. Splits een batch niet op in losse aanroepen per
   rij: dat vermenigvuldigt het aantal herbouwen. Een batch van 34 rijen is
   nu één aanroep en blijft dat.
3. **De dagelijkse job blijft.** `refresh_derived_data` blijft één keer per
   dag draaien (afronden van gisteren, de materialized views). Niet vaker
   inplannen om het actualiteitsprobleem op te lossen; dat doet de
   crud-functie nu zelf.
4. **Geen eigen refresh-aanroep na een crud.** Als er in de backend al een
   plek is die na `crud_state_log` iets bijwerkt of `refresh_derived_data`
   aanroept: weghalen, anders wordt dezelfde dag twee keer gebouwd.
5. **Foutafhandeling.** Faalt de herbouw, dan faalt de hele aanroep en rolt
   de insert terug — de bron en de telling lopen zo nooit uiteen. De
   bestaande retry van de sync-job dekt dat; er is geen aparte
   "refresh mislukt"-afhandeling nodig.
6. **De donut (29) en area-chart (62) hoeven niets te pollen.** Ze lezen bij
   elke load de tabel; die is dan bij tot en met de laatste batch.

## als je het toch buiten de database wilt

Alleen als de ingest-transactie om een andere reden kort moet blijven:
dezelfde builder met resource-bereik, aangeroepen door de backend direct na
een geslaagde `crud_state_log`/`crud_data_log`, gedebounced per (datum,
resource) op bijvoorbeeld 30 s. Dat kost een tweede aanroep, een debounce
en een plek waar het mis kan gaan zonder dat de bron het merkt. Daarom niet
de voorkeur.

## draaien

1. `archive/sql/migrations/update_state_refresh.sql` — dropt en maakt de builder (nieuwe
   signatuur), `crud_state_log`, `crud_data_log` en `refresh_derived_data`;
   met twee checks eronder (signatuur, en een scoped herbouw van één
   machine-dag die alleen die machine raakt).
2. frontend: punten 3 en 4 hierboven nalopen; verder niets.
3. daarna de donut: `sql/update_data_group_partial.sql` met 29, zodra de
   widget de nieuwe config kent (`archive/docs/handoff-oee-donut-frontend.md`).
