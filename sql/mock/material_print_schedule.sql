-- The schedule of a material on a line for a tenant: the settings the print
-- schedule (75) computes its cards with and mock.generate_plan stamps the day
-- plans from -- the interval (interval_start_date, interval_days), the nest
-- moments (nest_moment_codes, lookup_nest_moments), the impose resource the
-- moments are stamped on (resource_path, site.line.impose.width or deeper;
-- null: no lane yet) and the rank of the material on the nest boards
-- (sort_order). The weekly pattern (mock.material_impose_plan) folded into
-- these two columns on 10 Sep 2026.
create table material_print_schedule
(
	material_print_schedule_id bigint generated always as identity
		constraint material_print_schedule_pkey
			primary key,
	material_id integer,
	material_code text,
	line text not null,
	material_name text not null,
	interval_days integer,
	interval_start_date date,
	delivery_hours integer,
	resource_uids jsonb,
	valid_resources_json jsonb,
	production_line_id integer,
	is_manualy_set boolean default false not null,
	nest_moment_codes text[],
	tenant_id integer,
	min_delivery_hours integer,
	resource_path ltree,
	sort_order numeric,
	constraint material_print_schedule_material_line_tenant_uq
		unique (material_id, production_line_id, tenant_id)
);

comment on column material_print_schedule.resource_path is 'The impose resource the nest moments of the material are stamped on (relation.resource, site.line.impose.width or deeper); the lane takes the first four labels. Null: the material has no lane yet.';
comment on column material_print_schedule.sort_order is 'The rank of the material on the nest boards: plan_lane.sort_order of its lane and the base of lane_item.sort_order of its items.';

alter table material_print_schedule owner to xfw3;

create index ix_material_print_schedule_material_id
	on material_print_schedule (material_id);
