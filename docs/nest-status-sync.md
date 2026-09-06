# nest-status uit de machinelog

Datum: 2026-09-06. Script: `sql/update_nest_status_sync.sql`.

## het probleem

`intermediate_stock` leest `legacy.get_nest_list`: nests met
`nest_json.internal_status_code = 'printed'`. Die code komt alleen uit de
legacy-payload (`crud_nest`) en blijft vaak hangen: op 6 sep stonden 29.964
nests sinds mei op `printed`, 3.246 daarvan met een snij-regel in `log.data`, en
9.953 op `nested` waarvan 5.992 al geprint. In de lijst van lijn 5 op
PRdY9CJuOfyB: 162 nests, 101 al gesneden volgens de log.

## de regel

**De status van een nest volgt de machines.** `legacy.sync_nest_status_from_log`
tilt `internal_status_code` naar de verste stap die `log.data` van het nest kent,
vertaald via `lookup_step_category` (print → `printed` 700, cut → `cut` 801).
Alleen omhoog, nooit terug, een geannuleerd nest blijft staan. Elke stap
schrijft een regel in `legacy.nest_log` met de machines en het moment van de
eerste logregel van die stap.

- `log.crud_data_log` roept de functie na elke batch aan voor de nests in de
  payload, zoals hij ook `upsert_state_shift_agg` bijhoudt.
- De backfill is dezelfde functie zonder argument: 10.520 nests (dry run 6 sep),
  waarvan 6.157 `nested` → `printed` en 3.246 `printed` → `cut`.

**Wat de log niet weet, zegt de orderregel.** `get_nest_list` laat een nest weg
waarvan alle orderregels al voorbij de nest-status zijn: gesneden op een machine
zonder log, of handmatig afgehandeld. Eén detail-aanroep per lijst
(`get_production_orderline_detail` met `p_nest_ids`), 0,3 s voor 162 nests. Een
nest zonder vindbare orderregels blijft staan: de orderregel is de bron, niet
zijn afwezigheid.

## besluit: alleen via crud_data_log

Na de backfill uit de log stonden er nog 24.135 nests ouder dan twee weken op
`printed`, en geen enkele daarvan heeft een snij-regel in `log.data`: niet
onder dezelfde naam, niet hoofdletter-ongevoelig, niet via de bestandsnaam (de
20.154 snij-regels zonder nest-naam zijn testpatronen). Gesneden op een machine
zonder log, of nooit gesneden; lijn 9 logt geen enkele snijder. Hun orderregels
zijn wel allemaal verder.

Een regel die de nest-status uit de orderregels afleidde is dezelfde dag
gebouwd, gedraaid (17.526 nests) en weer verwijderd (6 sep, Cees): **de
nest-status wordt alleen via `log.crud_data_log` bijgewerkt, nooit anders.**
Wat geen machine logt, blijft staan zoals legacy het achterliet; opruimen van
oude nests gaat op leeftijd (`sql/delete_old_nests.sql`), niet via
de status. De opgetilde statussen van die ene run blijven staan, herkenbaar aan
`nest_log`-regels met `resource_uids = '{}'`.

## wat er overblijft: geschiedenis zonder afloop

Na de log-backfill is de tussenvoorraad tussen twee weken en twee maanden oud
overal leeg: lijn 5 toont 372 nests van de laatste twee weken en 1.164 van vóór
juli, niets ertussen. Die oude nests (13.989 op `printed`, plus 149 op calender,
laminated, coated, applied, nested) hebben een print-log maar nooit een snij-log,
en komen nooit meer in een machine-event. Ze zijn geen voorraad. Weg ermee, samen
met de 85.036 nests die nooit gelogd zijn: `sql/delete_old_nests.sql`
(nests met orderregel-delen blijven staan, 449).
