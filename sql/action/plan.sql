create table plan
(
	plan_id bigint generated always as identity
		primary key,
	-- the steps this plan covers, e.g. {print} or {print,coat,cut}; the
	-- vocabulary is relation.lookup 'lookup_step_category'
	steps text[] not null,
	plan_date date not null,
	type text default 'material-resource-plan'::text not null,
	line_type text,
	-- the tenants this plan covers: the tenants that run this line_type
	-- (relation.production_line); null on rows from before tenant scoping
	tenant_ids integer[]
);

comment on column plan.steps is 'The planning steps this plan covers (nest, rip, print, coat, laminate, embellish, route, cut, package, ship, mount, ...); vocabulary in relation.lookup lookup_step_category. A board asks for one step: p_step = any (steps).';
comment on column plan.type is 'material-resource-plan: the nest boards (lanes are the materials of mock.material_print_schedule and their impose resources); production-plan: the production schedule (lanes are resources, lane.resource_path).';

alter table plan owner to xfw3;

create index idx_plan_date_type
	on plan (plan_date, type);
