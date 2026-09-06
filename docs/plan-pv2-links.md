# PV2-links vanuit de data_groups

Status: plan (2026-09-04). Doel: vanaf elke plek waar een order, orderregel
of nest getoond wordt kunnen doorklikken naar PV2, via `nav.path` op het
veld in `field_config` — het patroon dat `orderline_list`, `sitrep_detail`,
`time_on_status` en `uploader_data_list` al gebruiken.

## de drie url-patronen

| doel | pad | placeholders nodig |
|---|---|---|
| order | `https://v2.proboview.nl/orders/edit/{order_id}` | `order_id` |
| orderregel | `https://v2.proboview.nl/orders/edit/{order_id}/sales-orderlines/{sales_orderline_id}/production-orderlines` | `order_id`, `sales_orderline_id` |
| nests van een orderregel | `https://v2.proboview.nl/orders/edit/{order_id}/production-orderlines/{production_orderline_id}/nests` | `order_id`, `production_orderline_id` |

De placeholders worden gevuld uit velden van dezelfde rij; het veld met de
`nav` hoeft zelf geen placeholder te zijn. Basisdomein overal
`https://v2.proboview.nl` — als dat ooit per omgeving moet verschillen is dat
een aparte stap (lookup of env), nu hardcoded zoals de bestaande vier.

## fase 1 — doorgevoerd 2026-09-04 (id's zitten al in de functie-output)

| data_group | veld | link | opmerking |
|---|---|---|---|
| `batch` | `number` | order | `get_batch` levert `order_id` |
| `batch` | `production_orderline_id` | orderregel | `sales_orderline_id` aanwezig |
| `batch` | `nest_name` | nests | `order_id` + `production_orderline_id` aanwezig |
| `nest_schedule_queue` | `number` | order | `get_production_orderline_manifest` levert alle drie |
| `nest_schedule_queue` | `production_orderline_id` | orderregel | |
| `orderinfo` (was `production_board_detail`) | `number` | order | `get_production_orderline_detail` levert alle drie |
| `orderinfo` | `production_orderline_id` | orderregel | |
| `uploader_data_list` | `order_id` | order | orderregel-link bestaat er al |
| `time_on_status` | `production_orderline_id` | **nests** | `sales_orderline_id` ontbreekt in `get_time_on_status`, maar `order_id` + `production_orderline_id` zijn er — de nests-variant kan dus zónder functiewijziging; wil je daar de orderregel-link, dan hoort hij in fase 2 |

Doorgevoerd in de vijf data_groups (39, 44, 46, 49, 79) — draaien via
`sql/update_data_group_partial.sql`. Geen SQL-functiewijzigingen. In `batch`
zit de link op elke plek waar het veld rendert (bord, flow-kaart en child),
altijd binnen dezelfde rijcontext van `get_batch`.

## fase 2 — functie eerst uitbreiden (id's ontbreken in de output)

| data_group | veld → link | functie | toe te voegen |
|---|---|---|---|
| `nesting_queue` | `production_orderline_id` → orderregel, nest-rij → nests | `mock.get_nest_queue` | `order_id`, `sales_orderline_id` |
| `plan_batch_nests` / `plan_batch_orderline` | `production_orderline_id` → orderregel, `nest_name` → nests | `legacy.get_batch_orderlines` | `order_id`, `sales_orderline_id` |
| `status_log_duration` | `production_orderline_id` → orderregel | `mapping.get_status_log_duration` | `order_id`, `sales_orderline_id` |
| `time_on_status` | `production_orderline_id` → orderregel | `mapping.get_time_on_status` | `sales_orderline_id` (order_id is er al) |

De join-route is overal dezelfde: `production_orderline` →
`sales_orderline_id` → `order_id` (zoals `get_production_orderline_manifest`
hem al loopt). Elke uitbreiding is een extra kolom in de `RETURNS TABLE` →
drop + create, dus per functie één script samen met de data_group-update.

## niet doen (of eerst een vraag)

- **Nest-schermen zonder orderregel-context** — `nest_buckets`,
  `nest_detail`, `intermediate_stock`, `nest_filter`,
  `production_line_overview`: een nest bevat meerdere orderregels, dus er is
  geen eenduidige `{production_orderline_id}` voor de nests-url. Alleen
  zinvol als PV2 een eigen nest- of batch-pagina heeft. **Vraag: bestaat er
  een PV2-url voor een nest of batch los van de orderregel?**
- **Batch-borden** — `plan_timeline`, `resource_plan`,
  `resource_oee_timeline`, `planning_info` hebben alleen `batch_id`/`batch_name`;
  zelfde vraag als hierboven.
- `sitrep_detail` en `orderline_list` zijn al compleet (order + orderregel).

## volgorde

1. fase 1 in één keer: 5 data_groups bijwerken, partial draaien.
2. fase 2 per functie: kolommen erbij (drop + create), daarna de
   bijbehorende data_group.
3. de open vraag over nest/batch-url's in PV2 beantwoordt of de "niet
   doen"-groep alsnog meekan.
