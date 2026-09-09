# Production board: lijnen-array en klantfilter

Status: plan. Het production board gaat van één `p_production_line_id` naar een
array, krijgt een klantfilter, en het filter-widget krijgt de vensters en
beide filters als velden.

## 1. de functieketen

Alle vier in één drop + create-script (signatuurwijziging), zelfde patroon:

| functie | wijziging |
|---|---|
| `mapping.get_production_orderline_detail` | `p_production_line_id integer` → `p_production_line_ids integer[]` (null **of leeg** = alle): `(p_production_line_ids is null or cardinality(p_production_line_ids) = 0 or cs.first_production_line_id = any(p_production_line_ids))`; nieuw `p_customer_id integer default null`: `(p_customer_id is null or cs.customer_id = p_customer_id)` |
| `mapping.get_production_board_aggregate` | zelfde rename + `p_customer_id`, beide 1-op-1 doorgeven aan de detail |
| `mapping.get_production_orderline_aggregate` | zelfde rename + `p_customer_id` doorgeven; de forecast-tak filtert `f.production_line_id = any(...)` |
| `mapping.get_production_orderline_graph` | zelfde rename + `p_customer_id` doorgeven |

Bewust **buiten scope** (blijven enkelvoudig): `get_sitrep`, `get_status_bar`,
`get_time_on_status` en de trend-functies — geen board-filters.

Let op: de `site.data_table`-rijen van deze srcs bevatten de query-tekst met
parameternamen — `p_production_line_id` moet ook dáár `p_production_line_ids`
worden (get_production_board_aggregate, get_production_orderline_detail,
get_production_board_graph, get_production_orderline_aggregate).

## 2. mapping.customer

Eén rij per klant, gevoed vanuit de specs-stroom:

```sql
create table mapping.customer (
    customer_id  integer primary key,
    company_name text not null,
    updated_at   timestamp with time zone default now() not null
);
```

- **crud**: `mapping.crud_component_specs_orderline` krijgt een set-based
  upsert-stap: `insert … select distinct (el->>'customer_id')::integer,
  el->>'company_name' … on conflict (customer_id) do update set company_name =
  EXCLUDED.company_name, updated_at = now()` — alleen bij echt verschil
  (`is distinct from`), en alleen `EXCLUDED.*` (conventie).
- **backfill** (eenmalig): nieuwste naam per klant uit
  `mapping.component_specs`, `distinct on (customer_id) … order by
  customer_id, component_specs_id desc`, `on conflict do nothing`.

## 3. de klant-zoekfunctie

```sql
create function mapping.get_customers(p_search text default null)
returns table(customer_id integer, company_name text)
-- exists (component_specs met is_open) -- alleen klanten met werk in behandeling
-- and (p_search is null or company_name ilike '%'||p_search||'%')
-- order by company_name limit 50
```

De `is_open`-eis snoeit de lijst van 9072 naar 2093 klanten (meting
2026-08-24); de semi-join rijdt op `ix_component_specs_board` (index-only,
~33 ms zonder zoekterm).

Plus een `site.data_table`-rij `get_customers` zodat het filter hem als src
kan gebruiken. Voorwaarde frontend: het select-control moet zijn zoekterm als
`search`-param naar de src sturen; zo niet, dan is dat een kleine generieke
toevoeging (geen klant-specifiek geval in code).

## 4. de data_groups

| data_group | wijziging |
|---|---|
| production_board_filter (72) | **gedaan in de repo**: velden `production_line_ids` (multi-select, src `get_production_lines`; niets geselecteerd = lege array = alle lijnen), `customer_id` (select, src `get_customers`), `look_back_days` en `look_ahead_days` (selects via src `get_numbers` met de keuzes als `numbers`-param — geen harde data) — allemaal query-params |
| production_board (48) | param `production_line_id` → `production_line_ids`; `customer_id` optioneel erbij; de cel-nav naar de detail geeft `production_line_ids` door |
| orderinfo (49, was production_board_detail) | zelfde rename + `customer_id`; het nav-blok met `value_from` volgt mee (één lijn blijft een lijst met één element) |
| production_board_graph (70) | zelfde rename + `customer_id` |

Voor de lijnen-select is een data_table `get_production_lines` nodig
(`line_id`, naam) — `relation.get_production_lines` bestaat al en staat in de
archief-appendix als "nergens gerefereerd"; dit wordt zijn eerste echte
gebruiker (of hij wordt herschreven tot een simpele select op
`relation.production_line`).

Buiten de data_groups om: navs/menu-items die de boardpagina openen met
`?production_line_id=` gaan mee naar `production_line_ids` (zelfde moment).

## 5. volgorde

1. **Kan vooruit, breekt niets**: `mapping.customer` + backfill,
   `mapping.get_customers`, data_tables `get_customers` en
   `get_production_lines` en `get_numbers` — **klaar in de repo**:
   `archive/sql/migrations/migration_customer_table.sql` (tabel + backfill + de drie
   data_table-rijen; `query` is gewoon de schema-gekwalificeerde
   functienaam), `sql/mapping/{customer,get_customers}.sql` en
   `sql/relation/get_production_lines.sql` (herschreven naar een platte
   lijst — de oude geneste `models_json`-vorm werd nergens gebruikt).
2. **Crud**: upsert-stap in `crud_component_specs_orderline` — **klaar in de
   repo** (set-based over `_params`, nieuwste naam per klant wint, no-op
   schrijft niets; header is nu `create or replace`).
3. **Het omzetmoment, één geheel — klaar in de repo**:
   - de vier functiebestanden (droppen zichzelf, oude signatuur weg):
     `sql/mapping/get_production_orderline_detail.sql`,
     `get_production_board_aggregate.sql`,
     `get_production_orderline_aggregate.sql`,
     `get_production_orderline_graph.sql`;
   - `sql/mock/get_material_planning_aggregate.sql` — enige andere caller die
     de line-parameter doorgaf; wikkelt zijn eigen enkelvoudige id nu in een
     array (`mock.get_nest_schedule`, `mock.get_production_schedule` en de
     manifest-functie geven geen line door en blijven ongemoeid);
   - data_groups 48/49/70/72 in `sql/update_data_group_partial.sql`
     (renames + `customer_id`, ook op de cel-nav naar de detail);
   - `json/data/nav/app-nav.json`: het lijnenmenu schrijft
     `production_line_ids` **naast** het bestaande `production_line_id` —
     de andere borden lezen het enkelvoud nog.
   Data_tables hoeven níet mee: de `query` bevat alleen de functienaam,
   de parameternamen komen uit de data_group.
