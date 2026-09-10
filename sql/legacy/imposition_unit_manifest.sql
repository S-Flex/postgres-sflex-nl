-- The manifest of an impositie: which xbom lines apply to this imposition and
-- what each costs. Modelled on production.imposition_unit_manifest; the legacy
-- twin exists because imposition_id is still an alias of legacy.nest.nest_id,
-- the way imposition_group_id is an alias of material_id (see
-- sql/action/batch_lane_item.sql).
--
-- Source: catalog.xbom, scope 'imposition', version_status 'active' — the xbom
-- itself, not mapping.spec_unit_manifest. An imposition is a sheet, not a
-- collection of orderlines: its cost follows from what is printed on that sheet
-- and how big the sheet is, and legacy.nest carries both. The 11 imposition
-- rows that hold a formula are all print-method.* on 'standard-print-impact':
--
--     standard_print_speed_cm2_sec = 222.22
--     production_impact_per_unit   = width * height / standard_print_speed_cm2_sec
--
-- width and height are centimetres and come from legacy.nest, so the impact is
-- the press time of that one sheet. Nest 2415019 (203 x 301.1) evaluates to
-- 275 s; material 47's four impositions add up to 1053 s.
--
-- Grain: one row per (imposition, option_code). No production_orderline_id and
-- no per-orderline amount — the sheet is imposed once whatever sits on it. That
-- is also what makes this the same shape as production.imposition_unit_manifest,
-- one row per imposition per xbom line.
create table legacy.imposition_unit_manifest
(
	imposition_unit_manifest_id bigint generated always as identity
		primary key,
	-- alias of legacy.nest.nest_id until production.imposition takes over
	imposition_id bigint not null
		references legacy.nest (nest_id)
			on delete cascade,
	-- the xbom line this row was stamped from; provenance, and the way back
	-- when a formula changes and the manifest has to be re-evaluated
	xbom_id integer,
	option_code text not null,
	-- null on an option row (every print-method line has none); set on the
	-- material item the sheet is made of
	item_code text,
	-- impositions of this sheet: legacy.nest.amount, 1 for ~93% of nests
	amount integer default 1 not null,
	-- the xbom param_json plus the variables the formula was evaluated with
	-- (width, height, amount), so the number below can be recomputed and
	-- checked without going back to the nest
	param_json jsonb default '{}'::jsonb not null,
	config_json jsonb default '{}'::jsonb not null,
	possible_status_sequence jsonb default '[]'::jsonb not null,
	-- seconds for one imposition of this sheet; 0 when the xbom line carries
	-- no formula
	production_impact_per_unit integer default 0 not null,
	sort_order integer default 0 not null,
	created_at timestamp with time zone default now() not null,
	updated_at timestamp with time zone default now() not null,
	constraint imposition_unit_manifest_uq
		unique (imposition_id, option_code)
);

alter table legacy.imposition_unit_manifest owner to xfw3;

create index ix_imposition_unit_manifest_imposition_id
	on legacy.imposition_unit_manifest (imposition_id);
