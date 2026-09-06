create table component_specs
(
	component_specs_id integer generated always as identity
		constraint pk_mapping_component_specs
			primary key,
	domain_id integer,
	production_order_id integer,
	production_orderline_id integer
		constraint uq_component_specs_orderline_id
			unique,
	order_id integer,
	sequence integer,
	material_id integer,
	order_type_id integer,
	product_width numeric,
	product_height numeric,
	product_amount numeric,
	product_unit_code text,
	product_unit_quantity numeric,
	first_production_line_id integer,
	internal_status_code text,
	production_company_id integer,
	logistics_date timestamp,
	orderline_updated_at timestamp,
	production_order_status text,
	production_order_sequence integer,
	order_number integer,
	sqm numeric,
	resolved_production_line_id integer,
	is_open boolean,
	number text,
	order_date timestamp,
	production_date timestamp,
	state_json jsonb default '{"state": "pending-release"}'::jsonb,
	order_location text,
	production_hours integer,
	production_location text,
	uploader_data_id integer,
	sales_orderline_id integer,
	is_dibond_override boolean default false not null,
	customer_id integer,
	production_orderline_sequence integer,
	customer_reference text,
	product_internal_title text,
	shipment_date timestamp,
	company_name text,
	team_name text,
	quality_check integer,
	binned integer,
	project_order_checked boolean,
	assembled boolean,
	assembled_production boolean,
	allow_rerouting boolean,
	unloading_forklift_available boolean,
	-- aggregated manifest of this orderline, one object per scope:
	-- {"<scope>": {"i18n": {...}, "item_code_paths": [...]}} — written by
	-- mapping.create_spec_unit_manifest in the same pass as the table,
	-- rebuilt retroactively by mapping.update_component_specs_manifest
	manifest_json jsonb,
	nest_date timestamp with time zone,
	ship_separately boolean default false,
	order_sequence integer,
	production_order_amount integer
)
with (autovacuum_vacuum_scale_factor=0.05, autovacuum_vacuum_insert_scale_factor=0.02, autovacuum_analyze_scale_factor=0.02);

alter table component_specs owner to xfw3;

create index ix_component_specs_order_id
	on component_specs (production_order_id);

create index ix_component_specs_orderline_id
	on component_specs (production_orderline_id);

create index ix_component_specs_order_id_fk
	on component_specs (order_id);

create index ix_component_specs_inflow
	on component_specs (material_id, domain_id, production_date) include (order_id, product_amount, sqm, state_json, order_location);

create index ix_component_specs_board
	on component_specs (domain_id, is_open, first_production_line_id, internal_status_code) include (production_orderline_id, logistics_date, sqm, sales_orderline_id, material_id, order_id, order_number, company_name, product_internal_title, product_amount, shipment_date, customer_id);

create index ix_component_specs_open_date
	on component_specs (logistics_date)
	where (is_open = true);

create index ix_component_specs_logistics_ordertype
	on component_specs ((logistics_date::date), order_type_id)
	where (internal_status_code <> ALL (ARRAY['cancelled'::text, 'file_error'::text]));

create index ix_component_specs_is_open_logistics
	on component_specs ((logistics_date::date), order_type_id)
	where (is_open AND (internal_status_code <> ALL (ARRAY['cancelled'::text, 'file_error'::text])));

create index idx_component_specs_uploader_data_id
	on component_specs (uploader_data_id);

create index idx_component_specs_uploader_data_id_cov
	on component_specs (uploader_data_id) include (material_id, product_amount, sqm);

create index idx_component_specs_status_nest_date
	on component_specs (internal_status_code, nest_date);


-- the forecast readers (mock.get_production_forecast_material, behind
-- get_print_schedule and get_impose_plan) sum sqm per production day over a
-- date window; without a date-led index that was a bitmap over the whole
-- material range (~50 ms), with it an index-only scan
create index ix_component_specs_production_date
	on component_specs (production_date) include (first_production_line_id, material_id, sqm, internal_status_code);
