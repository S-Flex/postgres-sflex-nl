# Overdracht naar Cowork

Cowork heeft geen toegang tot de Claude.ai chatgeschiedenis. Alle content die eruit gehaald kon worden staat daarom al in deze zip. Dit document zegt wat klaar is, wat gedeeltelijk is, en wat nog handmatig uit een chat gekopieerd moet worden.

## Volledig klaar, niets aan doen
- `sql/relation/get_resource_printer_settings.sql`
- `sql/action/cutoff_time.sql` (tabel + index)
- `sql/action/lane_item.sql` (lane_item, lane_item_dependency, lane_item_event, order_lane_item, nest_lane_item)
- `sql/action/rule_path.sql` (rule_path_matches, rule_path_ancestors)
- `sql/relation/team.sql` (relation.team, action.week_team)

## Gedeeltelijk — bevat een TODO in het bestand zelf
- `sql/log/get_resource_shift_employees.sql` — de functie-body was afgekapt in de bron. Signatuur en tabellen staan er, de query-body niet. Moet handmatig opgehaald worden uit:
  `https://claude.ai/chat/c5fe2d02-da15-4f94-8cea-671345cbc84f`

## Gedeeltelijk gedaan zonder chat, kan verder zonder gebruiker
- `docs/database-erd.md` — concept met de tabellen die al in de repo staan. Nog aan te vullen zodra de onderstaande punten (met name 3, 6 en 8) geoogst zijn.

## Nog volledig te doen (staat nog niet in deze zip)
Werk `docs/inventory.md` verder af, van boven naar beneden. Elke regel heeft een chat-link nodig — die moet **de gebruiker zelf plakken**, Cowork kan er niet bij:

1. `mock.get_print_schedule_materials_test`, `mock.update_material_resource_plan_sort_order`, `mock.crud_material_resource_plan`, `mock.get_nest_schedule` — chat was op moment van inpakken nog actief, niet oogsten voor die chat is afgerond
2. `mock.get_print_schedule`, `mock.get_print_schedule_materials`, timeline JSON config
3. `mapping.crud_component_specs_orderline` + update statement
4. `relation.lookup` structuur voor productielijnen/hallen
5. `database-erd.md` (mermaid ERD) — concept staat er al, zie hierboven
6. `action.lane` zelf (ontbreekt nog, alleen lane_item e.v. zijn gevonden)
7. `mock.material_resource_plan_lane`
8. `relation.tenant`, `tenant_domain` DDL
9. `relation.team_contact` — voorstel staat als commentaar in `sql/relation/team.sql`, nog niet bevestigd of definitief

Zie ook de sectie "nog te doorzoeken" onderaan `docs/inventory.md` voor oudere onderwerpen (FlowBoard, OEE, catalog/configurator, PrintFactory/Zünd/Durst, cart/outsourcing, resource allocation ledger) — die zijn nog niet doorzocht.

## Werkwijze per item
1. Gebruiker plakt de relevante content uit de chat (of Claude-chat-export)
2. Cowork zet het weg naar `sql/<schema>/<naam>.sql` of `json/<naam>.json`
3. Vinkje in `docs/inventory.md`
4. Chat kan daarna verwijderd worden

Houd je aan `CLAUDE.md` in de root voor alle conventies.
