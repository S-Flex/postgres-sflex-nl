# project conventions

Stack: PostgreSQL (owner `xfw3`), React 19.2, Tailwind 4.2, UntitledUI/react, Figma MCP.

## algemeen
- altijd de simpelste, kortste oplossing
- semantiek in data, niet in code — business logic in JSON, niet hardcoded
- generieke componenten, geen speciale gevallen in code
- geen kolom of key genaamd `id` — altijd beschrijvend (`nest_group_id`, `resource_uid`, ...)
- geen aannames — vragen bij twijfel

## database-toegang
- ik heb directe verbinding met postgres, maar alleen om te lezen:
  `select`, `explain`, catalogus/definities opvragen — dat doe ik zelf
- alles wat iets verandert voer ik nooit zelf uit: ddl, dml, `create/alter/drop`,
  grants, `vacuum`, functies en views — ook niet via een omweg of hulpscript
- wijzigen gaat altijd zo: ik lever het volledige script, jij controleert en draait het
- ik wacht met verder werken tot jij zegt dat het gedraaid is, en verzin nooit
  een uitslag van iets dat nog niet is uitgevoerd
- twijfel of iets leest of schrijft? dan lever ik het als script

## sql
- functies altijd met schema-naam (`mapping.crud_ticket`), ook bij `ALTER FUNCTION ... OWNER TO xfw3`
- crud-functies altijd set-based: geen FOR loop, geen temp table
  gebruik `jsonb_array_elements(p_param_json) AS el`, velden via `(el->>'field')::type`
- `ON CONFLICT DO UPDATE`: alleen `EXCLUDED.*`, nooit `rec.*`
- `RETURNS TABLE`: eerste regel na `AS $$` is altijd `#variable_conflict use_column`
- comments in sql altijd in het engels
- breaks/non-working-time rekken de job op (nooit losse spacer-rows)
- non_working_times gaan als JSON naar de frontend/timeline; nooit server-side start/duur berekenen
- resources: `resource_uid` is de sleutel, `resource_path` (ltree) de boom —
  8 vaste posities `site.material.step.width.medium.brand.type.serial`,
  zie `docs/resource-path.md`

## json
- snake_case voor keys, kebab-case voor code-waardes
- `i18n` (niet `ml`) voor meertalige blokken
- `template` (niet `text_formula`) voor template strings
- bij "code" als hoofd-key: property `content` voor alle tekst, plus een property voor wat je maakt
- property-namen zijn eenduidig, helder en generiek: geen overlappende of dubbele
  namen voor hetzelfde begrip, zodat elke key overal hetzelfde betekent en herbruikbaar is.
  Voor je een key bedenkt: zoek hoe de andere data_groups het noemen en gebruik dat
  (`node`-inventaris van alle `_field`/`_config`-keys in `xfw3_site_data_group.json`)
- vast vocabulaire in een `<layout>_config`: de soort van een rij is een **set**
  (`set_field`, `set_order_field`); wat per soort verschilt staat in `set_overrides`
  met de set-waarde als key; een formule rekent via `evaluate {formula_field, params_field}`;
  het subniveau van een rij heet `items` met `data_field` voor de array
- een key die een veld aanwijst eindigt op `_field` en draagt geen eenheid
  (`duration_field: "duration_in_seconds"`, niet `duration_in_seconds_field`);
  het tekst-slot heet overal `title_field` (ook als de waarde `i18n` is); de titel van
  een set heet `set_title_field` (naast de globale `title_field`); de x-as van een chart
  `x_field`; een string met `${...}` heet `template`, geen `field`

## lookup json
- de inhoud van een lookup staat in `json/lookup/<schema>/<lookup>.json`
- de map is het schema, de bestandsnaam is de lookup-naam, het bestand bevat de `lookup_json` zelf
- voorbeeld: `SELECT lookup_json FROM production.lookup WHERE lookup = 'lookup_nest_moments'`
  staat in `json/lookup/production/lookup_nest_moments.json`
- schrijf of herschrijf je een functie die `lookup_json` leest en het bestand staat er niet:
  vraag of het toegevoegd wordt, nooit zelf de inhoud verzinnen

## data_group json
zie `docs/data-group-governance.md` voor de volledige analyse

- een key heeft overal dezelfde vorm — een lijst blijft een lijst, ook met één element
  (`children`, `hidden_when`, `src` zijn altijd een array)
- config-keys staan nooit tussen veldnamen: `field_config` bevat alleen velden,
  de grid van de velden heet `fields_class_name` en staat ernaast;
  `class_name` is altijd de class van het element zelf (`ui.class_name` op een veld)
- field_config-keys ondersteunen dot-notatie in jsonb-kolommen
  (`impact_json.rework_count`), ook in combinatie met `aggregate_fn` —
  geen platte kolom toevoegen aan de functie als het veld al in een json zit
- `ui.type` zegt wat de waarde ís, `ui.control` hoe hij getoond wordt
- `title` is het standaard tekst-slot in `i18n` (niet `text` of `label`); andere slots
  (`subtitle`, `abb`, ...) alleen als het echt iets anders is dan de titel
- `<naam>_field` betekent "de naam van een veld", zonder suffix is het de waarde zelf
- eenheid in de key, niet in een aparte property: `duration_in_seconds`, niet `duration` + `unit`
- percentages altijd `_percentage` (niet `_perc`, `_pct`, `_percent`)
- één conditie-vorm: `{field, op, value}`, vergelijk je twee velden dan `value_field`
- sorteren: `sort: {field, direction}`; groeperen: `group_by`, altijd een array van id-kolommen;
  de titel per niveau staat in `group_title_fields` (zelfde volgorde)
- drag & drop: `docs/contracts/drag-and-drop.md` is leidend (`drop`-blok, `order_field`;
  `within_fields` ⊆ `group_by`, id's)
- chart-config keys heten `<chart>_chart_config`, varianten zijn properties of een prefix
  (`stacked_bar_chart_config`), geen losse key per variant
- booleans met `no_*` / `hide_*` staan default op false

## overig
- titels: alleen eerste woord met hoofdletter
- geen technisch jargon, korte uitleg

## frontend
- de frontend is een meta-data-driven ui-renderer: er is data en een data_group,
  de data_group heeft per layout een `<layout>_config` (`timeline_config`, ...)
  die zegt welk veld wat is (`offset_field`, `type_field`, ...)
- een handoff voor de frontend beschrijft alleen wat er in die config en in de
  velden veranderd is (nieuwe/hernoemde `_field`-keys, nieuwe velden), compact
  en to-the-point — geen uitleg van het domein, geen voorbeelden die al in de
  data_group staan
