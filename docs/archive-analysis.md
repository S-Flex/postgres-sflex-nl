# archiverings-analyse: onnodige data_groups en functies

Datum: 2026-08-24. Criterium (afgesproken): **`json/data/block/pages.json` is de enige
waarheid** — een data_group die daar niet in voorkomt is niet nodig. Alle SQL in dit
document is read-only uitgevoerd; er is niets gewijzigd.

## samenvatting

| wat | aantal |
|---|---|
| data_groups in DB (`site.data_group`) | 71 |
| data_groups in repo (export + losse bestanden, 1-op-1 gelijk) | 60 |
| alleen in DB, niet in repo | 11 (ids 1–9, 11, 83 — de camelCase-generatie + `widget_showcase`) |
| alleen in repo, niet in DB | 0 (`rename-map.json` en `xfw3_site_data_group.json` zijn geen data_groups) |
| **gebruikt via pages.json** | **46** (na toevoeging van pagina `nest-schedule-queue`, 2026-08-24) |
| **onnodig** | **25** |
| user functions in DB (excl. extensies zoals ltree/pg_stat_statements) | 205 |
| functies bereikbaar vanuit gebruikte data_groups (keep) | ±40 direct + hun aanroepketens |
| **kandidaat te vervallen** | **25** (21 zonder voorbehoud, 4 met zware kanttekening) |
| appendix: nergens gerefereerd, handmatig verifiëren | 38 |

De resolutieketen is: `data_group` → `src` (naam) → `site.data_table` (rij met
`query`/`stored_proc`) → schema-gekwalificeerde functie. `src`-namen zijn dus geen
functienamen maar data_table-namen; de schema-disambiguatie zit in de `query`-tekst
van de data_table (bijv. src `get_nest_schedule` → data_table `get_nest_schedule` →
`mock.get_nest_schedule`, niet `action.get_nest_schedule`).

Losse notitie bij pages.json: één sectie-waarde is
`"header_data_groups/timeline-controls.json"` — een **bestandsreferentie**, geen
data_group-naam. Dat bestand bestaat niet in deze repo (vermoedelijk frontend-repo);
alleen `docs/blocks-migration-proposal.md` noemt het nog.

Update 2026-08-24 (batch 1 gearchiveerd): data_groups 17, 20, 21, 28, 32, 33,
37, 60 en 61 zijn verplaatst naar `archive/data_group/`, uit de export gehaald
en verwijderd via `archive/sql/migrations/migration_archive_data_groups.sql`. Hun data_tables en
functies volgen in een latere batch.

Update 2026-08-24 (batch 2, functies): `job.get_job_summary` en de zeven
`relation.get_production_line_*`-functies (block_sum, conversion_margin_stats,
oee_stats, production_faults, resources, status_time, model) zijn verplaatst
naar `archive/sql/` en vervallen via `archive/sql/migrations/migration_archive_functions.sql`.

Update 2026-08-24 (batch 3, functies): `relation.get_resource_info`,
`get_resource_maintenance` en `get_resource_status`, plus
`action.rule_path_matches` en `rule_path_ancestors` (uit de appendix, incl.
`sql/action/rule_path.sql`) zijn naar `archive/sql/` verplaatst en zitten in
hetzelfde drop-script.

Update 2026-09-07 (batch 4, functies): `mock.get_resource_plan_batch` (tweeling van
`log.get_resource_plan_batch`, die `get_resource_timeline` gebruikt) en
`mock.get_print_schedule_test` (testkopie van `get_print_schedule`) — geen bord, geen
aanroeper — naar `archive/sql/mock/` en in hetzelfde drop-script. Data_groups 19
(`resource_oee_timeline`, pagina `oee`) en 56 (`plan_timeline`, pagina
`production-planning`) staan in pages.json en blijven; 56 vervalt pas als de pagina op
`resource_plan` (81) staat, 19 als 81 de geproduceerde items als subniveau krijgt.

Update 2026-08-24: de pagina `nest-schedule-queue` is aan pages.json toegevoegd —
data_group `impose_plan_inflow` (79) is daarmee **gebruikt**, de sidebar-links
ernaartoe zijn niet langer kapot en `mapping.get_production_orderline_manifest`
blijft behouden.

## onnodige data_groups (25)

✓ = gearchiveerd (bestand naar `archive/data_group/`, delete in
`archive/sql/migrations/migration_archive_data_groups.sql`).

"Verwijzingen buiten pages.json" telt niet mee voor het criterium, maar staat erbij
zodat je weet wat er meebreekt. `update_data_group_inline.sql`, de export
`xfw3_site_data_group.json` en het eigen json-bestand zijn overal weggelaten (die
verwijzen per definitie).

| id | data_group | in DB | in repo | verwijzingen buiten pages.json |
|---|---|---|---|---|
| 2 | dataCardsBlockContent | ja | nee | legacy `site.block` 13 (page 1) / `json/block/block_13.json` |
| 3 | dataCardsConfiguratorProductHorizontal | ja | nee | geen |
| 4 | dataListJobSummary | ja | nee | legacy block 10 (pages 1, 14, 15, 16) |
| 11 | formulaEditor | ja | nee | legacy block 4 (page 23) |
| 1 | formulaGraphEditor | ja | nee | legacy block 20 (page 3) |
| 5 | login | ja | nee | legacy block 19 (page 1) — **zie kanttekening auth** |
| 6 | productionLinePrestationView | ja | nee | legacy blocks 23, 26 (page 4) |
| 8 | productionLineThreeView | ja | nee | legacy blocks 21, 24 (page 5) |
| 7 | resourceInfoStatus | ja | nee | legacy blocks 22, 25 (page 6) |
| 9 | testFormAddresses | ja | nee | geen |
| 83 | widget_showcase | ja | nee | legacy block 1 (page 2), `docs/data-groups-and-navigation.md` — **nieuwste id, mogelijk lopend werk** |
| 37 | ✓ nest_schedule_old | ja | ja | geen |
| 61 | ✓ plan-capacity | ja | ja | legacy block 11 (page 20), `rename-map.json`, `archive/docs/handoff-control-room.md`, `docs/data-group-governance.md`, gerefereerd door plan-capacity-overview (zelf onnodig) |
| 60 | ✓ plan-capacity-overview | ja | ja | legacy block 12 (page 21), zelfde docs/rename-map |
| 17 | ~~✓~~ production_line_overview | ja | ja | **teruggezet 2026-08-31**: toch nodig. Pagina `production-line-overview` toegevoegd aan pages.json, dus voldoet nu aan het criterium. Opgeschoond bij terugzetten: legacy `"page": 50` en block-titel eruit, twee dode sidebar-links verwijderd |
| 81 | production_schedule | ja | ja | `archive/docs/plan-production-schedule.md` — **actief voorstel, zie kanttekening** |
| 82 | production_schedule_filter | ja | ja | `archive/docs/plan-production-schedule.md` — idem |
| 28 | ✓ resource_blocked_jobs | ja | ja | geen |
| 33 | ✓ resource_plan_timeline | ja | ja | geen (src wijst al naar niet-bestaande data_table) |
| 21 | ✓ resource_production | ja | ja | geen |
| 32 | ✓ resource_queue | ja | ja | comment in `archive/sql/migrations/migration_fix_log_data_readers.sql`; doelwit van kapotte sidebar-link `queued-jobs` |
| 20 | ✓ resource_tco | ja | ja | geen |
| 74 | test_form_save_types | ja | ja | geen |
| 50 | test_get_nesting_preview | ja | ja | legacy block 5 (page 17), `sql/site/test_get_nesting_preview.sql` |
| 57 | test_get_schedule | ja | ja | legacy block 6 (page 19), `sql/site/test_get_schedule.sql` |

DB-lichaamsscan: geen enkele **gebruikte** data_group verwijst naar een onnodige.
De enige kruisverwijzingen zijn onnodig→onnodig (formulaGraphEditor→formulaEditor,
plan-capacity-overview→plan-capacity).

## te vervallen functies

Criteria per functie: (a) uitsluitend bereikt via onnodige data_groups,
(b) door geen enkele andere user function aangeroepen (prosrc-scan over alle
205 functies, plus views en triggers via pg_depend/pg_trigger),
(c) in de repo alleen in het eigen definitiebestand en/of de onnodige
data_group-json aanwezig (grep, `.history/` uitgesloten).

### zonder voorbehoud (21)

✓ = gearchiveerd (definitiebestand naar `archive/sql/`, drop in
`archive/sql/migrations/migration_archive_functions.sql`).

| functie | alleen gebruikt door (onnodige) data_group(s) | definitiebestand |
|---|---|---|
| ✓ job.get_job_summary | dataListJobSummary | archive/sql/job/get_job_summary.sql |
| site.get_all_formula_graphs | formulaGraphEditor | sql/site/get_all_formula_graphs.sql |
| site.crud_formula_graph | formulaGraphEditor (data_table `getFormulaGraphs`) | sql/site/crud_formula_graph.sql |
| site.get_plan_capacity | plan-capacity | sql/site/get_plan_capacity.sql |
| site.get_plan_capacity_overview | plan-capacity-overview | sql/site/get_plan_capacity_overview.sql |
| ✓ relation.get_production_line_block_sum | productionLinePrestationView | archive/sql/relation/get_production_line_block_sum.sql |
| ✓ relation.get_production_line_conversion_margin_stats | productionLinePrestationView | archive/sql/relation/get_production_line_conversion_margin_stats.sql |
| ✓ relation.get_production_line_oee_stats | productionLinePrestationView | archive/sql/relation/get_production_line_oee_stats.sql |
| ✓ relation.get_production_line_production_faults | productionLinePrestationView | archive/sql/relation/get_production_line_production_faults.sql |
| ✓ relation.get_production_line_resources | productionLinePrestationView + productionLineThreeView (beide onnodig) | archive/sql/relation/get_production_line_resources.sql |
| ✓ relation.get_production_line_status_time | productionLinePrestationView | archive/sql/relation/get_production_line_status_time.sql |
| ✓ relation.get_production_line_model | productionLineThreeView | archive/sql/relation/get_production_line_model.sql |
| ✓ relation.get_resource_info | resourceInfoStatus (data_table `resourceInfo`; de gebruikte pagina `info` draait op `legacy.get_info`) | archive/sql/relation/get_resource_info.sql |
| ✓ relation.get_resource_maintenance | resourceInfoStatus | archive/sql/relation/get_resource_maintenance.sql |
| ✓ relation.get_resource_status | resourceInfoStatus | archive/sql/relation/get_resource_status.sql |
| legacy.get_resource_queue | resource_queue | sql/legacy/get_resource_queue.sql |
| site.get_address_entry | testFormAddresses + test_form_save_types (data_table `testFormAddr`) | sql/site/get_address_entry.sql |
| site.test_get_nesting_printfactory | test_get_nesting_preview | sql/site/test_get_nesting_printfactory.sql |
| site.test_get_nesting_printfactory_meta | test_get_nesting_preview | sql/site/test_get_nesting_printfactory_meta.sql |
| site.test_get_nesting_preview | geen enkele data_group-src; alleen legacy block 5 en data_table `test_get_nesting_preview` | sql/site/test_get_nesting_preview.sql |
| site.test_get_schedule | test_get_schedule | sql/site/test_get_schedule.sql |

### met zware kanttekening (4) — beslissing bij jou

| functie | gebruikt door | waarom oppassen |
|---|---|---|
| relation.get_login | login (data_table `getLogin`) | als de login-flow van de frontend/API dit endpoint direct aanroept (buiten het data_group-systeem om) breekt inloggen; externe callers zijn vanaf hier onzichtbaar |
| mock.get_production_plan (was get_production_schedule) | production_schedule | `archive/docs/plan-production-schedule.md` is een **actief voorstel** dat hier juist naartoe bouwt (vervangt plan_timeline); weggooien = het voorstel weggooien |
| site.get_widget_showcase | widget_showcase | data_group 83 is het nieuwste id; oogt als dev/showcase-werk, geen repo-bestand |
| site.save_widget_showcase | widget_showcase (ook als `stored_proc` van de data_table) | idem |

### uitdrukkelijk NIET vervallen (wel via onnodige groepen bereikt)

- `log.get_resource_state_current` — ook aangeroepen door `mapping.get_resource_capacity`
  (gebruikte pagina tco) en `mapping.get_status_bar_capacity`.
- `legacy.get_info` — deelt data_tables met gebruikte resource-pagina's (info,
  ink-heads, consumption-waste, material-specs, quality-management, tooling-wear).
- `production.get_timeline_view_segments`, `mock.get_nest_schedule`,
  `mock.get_print_schedule_materials` — dragen de gebruikte agenda-borden.
- `site.noop_function` — generiek, ook in `searchInvoice`.
- `mapping.get_production_orderline_manifest` — sinds de pagina `nest-schedule-queue`
  in pages.json staat gewoon in gebruik (menu van de toekomstige lane items).
- `catalog.get_formula` — naamgenoot: de data_table `get_formula` (van formulaEditor)
  wijst naar het niet-bestaande `site.get_formula`; `catalog.get_formula` hoort bij
  het formula/xbom-ontwerp (`docs/catalog-formula.md`, comments in
  `sql/catalog/formula.sql` en `xbom.sql`) en blijft.

## kapotte nav-links (sidebar-pad → pagina die niet in pages.json staat)

| nav-pad | staat in | opmerking |
|---|---|---|
| `(sidebar:material-forecast)` | print_schedule, nest_schedule, nest_resource_schedule (**alle drie gebruikt**) | pagina `material-forecast` bestaat niet |
| ~~`(sidebar:nest-schedule-queue)`~~ | nest_schedule, nest_resource_schedule, production_schedule | **opgelost 2026-08-24**: pagina toegevoegd aan pages.json |
| ~~`(sidebar:queued-jobs)`~~ | production_line_overview | **opgelost 2026-08-31**: menu-item verwijderd bij het terugzetten van de data_group |
| `(sidebar:xfw)` | `json/nav/xfw.main-menu-right.json` | pagina `xfw` staat niet in pages.json; in het menu-bestand mogelijk een top-level route i.p.v. een pagina — nakijken. Het pad `(sidebar:xfw/nl/sidebar/productielijn-machine)` in production_line_overview is 2026-08-31 verwijderd |

Alle overige sidebar-doelen (in `json/nav/*.json`, `json/data/nav/menu-items.json` en
de data_group-lichamen) bestaan in pages.json. `json/data/block/pages-content.json`
bevat geen data_group-verwijzingen (alleen titels per pagina-code).

## appendix: functies nergens gerefereerd (38) — handmatig verifiëren

Door geen data_table, geen data_group, geen andere functie (prosrc), geen view en
geen trigger gerefereerd. **Onverifieerbaar vanaf hier:** externe callers (pv2,
uploader, API-jobs, cron) zien we niet; dit is een verdenkingslijst, geen vonnis.

Zonder enig repo-bestand (alleen in de DB):
- configurator.get_product_pricing, configurator.product_row_create
- fulfilment.get_package_specifics, fulfilment.get_shipment_prices
- public.camel_to_snake_json, public.evaluate_formula_array, public.search_xfw3, public.string_agg_sort
- raw.get_printfactory_nesting_candidates, raw.merge_printfactory_nest_data — **let op: raw.* oogt als extern ingest-werk**

Alleen eigen definitiebestand in de repo:
- action.get_lanes
- catalog.get_xbom_grouping_keys
- job.get_components_inflow_aggregated — de data_table heet `get_components_inflow_aggregate` en roept `job.get_components_inflow_aggregate` (zonder "d") aan: **naam-mismatch, dus kapot**; repareren of samen opruimen
- legacy.backfill_print_duration, legacy.get_batch_status, legacy.get_material_buckets, legacy.get_nest_status_by_bucket, legacy.get_print_plan_duration_according_to_specs
- mock.batch_info, mock.generate_production_plan, mock.get_panel_production_impact, mock.get_resource_state_per_day
- relation.get_pricing_formula
- ~~relation.get_production_lines~~ — krijgt per
  `archive/docs/plan-production-board-customer-filter.md` alsnog een gebruiker
  (herschreven tot platte lijst voor het board-filter)
- site.create_data_table_sync_json, site.get_formula_graph_with_subgraphs (hoort bij formulaGraphEditor-familie)
- job.crud_specs_log, job.get_cart_statuses (beide ook genoemd in `archive/sql/migrations/migration_rename_log_to_event.sql` — mogelijk bewust achtergelaten aliassen)

Wel in ontwerp-docs genoemd (waarschijnlijk bedoeld voor het nieuwe model — niet opruimen zonder die docs te herzien):
- action.get_nest_moments (`docs/inventory.md`)
- ✓ action.rule_path_ancestors, action.rule_path_matches (`archive/docs/handoff-cowork.md`, `docs/inventory.md`) — gearchiveerd in batch 3, incl. `sql/action/rule_path.sql`
- catalog.crud_line_item_resource (`docs/domain-model.md`)
- catalog.get_item_prices (`docs/pricing-chain.md`, `sql/catalog/item_price_formula.sql`)
- legacy.insert_nest_log (`docs/domain-model.md`)
- mock.crud_material_resource_plan (`archive/docs/handoff-cowork.md` — en centraal in het lane-items-plan)
- production.compute_imposition_manifest_production_impact (`docs/domain-model.md`)
- production.imposition_unit_status_update (`docs/domain-model.md`, `docs/spec-status-flow.md`)
- mapping.get_component_specs_with_manifest — `docs/inventory.md` zegt expliciet **vervallen** (vervangen door `mapping.get_production_orderline_manifest`); dit is de veiligste kandidaat van de hele appendix

## kanttekeningen (alles wat onzeker is)

1. **Externe callers onzichtbaar.** Alles wat de API op data_table-naam aanroept
   (de `sync_*`-endpoints, `search*`, `getLogin`, `getMainMenu`, `get_search_nav`,
   lookups) kan gebruikt worden zonder dat een data_group ernaar verwijst. De
   analyse dekt alleen wat vanuit `site.data_group`, `pg_proc`, views, triggers en
   deze repo zichtbaar is.
2. **Het legacy blok/pagina-systeem leeft nog in de DB** (`site.page`, `site.block`,
   `site.page_block`): 15 blocks verwijzen naar 15 van de 26 onnodige data_groups
   (o.a. `login` op page 1). Als het nieuwe systeem (pages.json) het oude volledig
   vervangt kan die hele keten mee in het archief, maar dat is een aanname — de
   `json/block/block_*.json` bestanden zijn er de export van.
3. **Actief werk tussen de "onnodige" groepen:** production_schedule (81) +
   production_schedule_filter (82) en widget_showcase (83) zijn de nieuwste ids en
   komen voor in actieve plannen (`archive/docs/plan-production-schedule.md`).
   Onnodig volgens het criterium van vandaag, maar archiveren betekent dat die
   plannen ze straks terug moeten halen. (impose_plan_inflow (79) stond hier ook,
   maar staat sinds 2026-08-24 in pages.json en is gebruikt.)
4. **Kapotte src op een gebruikte pagina:** data_group `resource_ink` (pagina
   ink-heads) heeft src `get_resource_ink` waarvoor **geen data_table bestaat** (en
   geen functie). Ofwel de pagina is deels kapot, ofwel er bestaat een
   resolutie-fallback die ik niet kan zien. Eerst begrijpen, dan pas opruimen.
   Zelfde patroon bij `resource_plan_timeline` (onnodig) en `impose_plan_inflow`
   (src zonder data_table; de functie bestaat daar wél — en die pagina is sinds
   2026-08-24 **in gebruik**, dus dit verdient een echte fix of de fallback-uitleg).
5. **Kapotte data_table-verwijzingen:** `get_formula` → niet-bestaand
   `site.get_formula`; `get_components_inflow_aggregate` → niet-bestaand
   `job.get_components_inflow_aggregate` (functie heet `..._aggregated`);
   stored_procs `Configurator.ProductCRUD`, `Job.ContainerCRUD`, `Site.ObjectCRUD`
   bestaan niet (camelCase-erfenis).
6. **Wees-data_tables.** Na het schrappen van de onnodige groepen raken hun
   data_tables (o.a. `getFormulaGraphs`, `getLogin`, `testFormAddr`,
   `plan-capacity(-overview)`, `productionLine*`, `resourceInfo/Maintenance/Status`,
   `get_resource_queue`, `test_get_*`, `widget_showcase`, `dataCards*`,
   `getBlockObject`, `dataListJobSummary`, `get_formula`) hun laatste interne
   verwijzing kwijt — die horen in hetzelfde archief-script, met dezelfde
   externe-caller-slag om de arm.
7. **Naamgenoten:** `get_nest_schedule` bestaat in `action` én `mock` — de
   data_table kiest `mock.get_nest_schedule`; `action.get_nest_schedule` blijkt
   bij nacontrole (2026-08-24, prosrc-scan + data_tables) **nergens aangeroepen**
   en is dus alsnog archiefkandidaat. `relation.get_resource_info`
   (kandidaat) is een andere functie dan de gebruikte data_table `get_resource_info`
   (die op `legacy.get_info` draait).
8. De prosrc-scan matcht op naam (ongekwalificeerd); een functie die alleen in
   dynamische SQL (EXECUTE met samengestelde naam) wordt aangeroepen zou een vals
   "nergens gerefereerd" kunnen opleveren. Niet aangetroffen, wel mogelijk.

Update 2026-09-08 (opruiming `sql/`): 46 losse eenmalige scripts die gedraaid
zijn — `update_*`, `backfill_*`, `repair_*` en de `migration_*` van eerdere
batches — zijn naar `archive/sql/migrations/` verplaatst; hun definities staan
in de canonieke bestanden onder `sql/<schema>/`. Alle verwijzingen in `docs/`
zijn meeverhuisd. Wat direct in `sql/` blijft staan:

| bestand | waarom |
|---|---|
| `update_impose_plan_day_window.sql` | nog te draaien |
| `update_lane_item_type_titles.sql` | nog te draaien: de i18n van `lookup_lane_item_type` staat in de repo, niet in de database |
| `update_data_group.sql`, `update_data_group_inline.sql`, `update_data_group_partial.sql` | het deploy-mechanisme van de data_groups (gegenereerd door `scripts/build_update_data_group.js`) |
| `check_data_group.sql`, `check_plan_reads.sql`, `check_state_shift_agg.sql`, `verify_plan_lanes_material.sql`, `test_impact_formulas.sql`, `test_production_impact_formula.sql` | read-only checks die bruikbaar blijven |
| `delete_old_nests.sql`, `backfill_spec_unit_manifest.sql` | onderhoud, opnieuw te draaien wanneer nodig |

Bij die opruiming zijn ook alle 29 lookups van de database gespiegeld naar
`json/lookup/<schema>/<lookup>.json`, zoals de conventie vraagt — dat was de
enige plek waar de inhoud van bijvoorbeeld `lookup_resource_state`,
`lookup_internal_status` en `lookup_production_line` in de repo alleen nog in
een gedraaid update-script stond. De vier bestanden die er al waren zijn niet
overschreven: `action/lookup_lane_item_type.json` loopt bewust voor op de
database (de i18n hierboven), de andere drie waren inhoudelijk gelijk.

Update 2026-09-08 (opruiming `docs/`): twaalf documenten waarvan het werk in de
database staat zijn naar `archive/docs/` verplaatst, met alle verwijzingen mee:

| document | waarom af |
|---|---|
| `plan-lanes-boards.md` | de drie borden lopen; `get_plan_lanes` is inmiddels zelfs gesplitst in twee reads |
| `plan-production-schedule.md` | voorstel voor `mock.get_production_plan`, die niet meer bestaat — `action.get_resource_plan` doet het |
| `plan-oee.md` | `counts_as`, `log.state_shift_agg` en de shift-totalen staan in de database |
| `plan-oee-donut.md` | de donut leest dezelfde keten; de handoff is eruit |
| `plan-production-board-customer-filter.md` | lijnen-array en klantfilter zitten in de functies en in het bord |
| `plan-pv2-links.md` | de `nav.path`-links naar pv2 staan in acht data_groups |
| `handoff-control-room.md`, `handoff-cowork.md`, `handoff-data-group-vocabulary.md`, `handoff-oee-frontend.md`, `handoff-oee-donut-frontend.md`, `handoff-state-refresh.md` | overgedragen en gebouwd |

Wat in `docs/` blijft: de referentiedocumenten (`domain-model`, `resource-path`,
`paths-and-hierarchies`, `pricing-chain`, `spec-status-flow`, `catalog-formula`,
`database-erd`, `data-group-governance`, `data-group-layout`,
`data-groups-and-navigation`, `legacy-planning-chain`, `nest-status-sync`,
`imposition-unit-manifest` + `formula-impact-per-step`, `contracts/`), de
plannen die nog open staan (`plan-date-parameters`, `plan-help-mode`,
`plan-lookup-block-i18n` — er staan nog `block`-wrappers in zes lookups,
`blocks-migration-proposal` — `pages.json` is nog niet gevouwen), de twee
handoffs waar de frontend nog op moet antwoorden
(`handoff-resource-plan-frontend`, `handoff-time-scale-frontend`), het levende
`plan-lane-model.md`, deze analyse, en de twee oogstlijsten (`inventory.md`
heeft nog zestien open regels, `chats-to-archive.md` hangt daaraan).
