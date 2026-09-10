-- The weekly pattern: one row per planned imposing moment. resource_path
-- points at an impose resource in relation.resource (site.material.impose.width) —
-- imposing happens per material width, not per printer. No foreign key:
-- uq_resource_path is a partial index and cannot back one.
create table material_impose_plan
(
	material_impose_plan_id bigint generated always as identity
		primary key,
	weekday smallint not null
		constraint material_impose_plan_weekday_check
			check ((weekday >= 1) AND (weekday <= 7)),
	step text not null,
	resource_path ltree,
	sort_order numeric not null
		constraint material_impose_plan_sort_order_check
			check (sort_order >= (0)::numeric),
	material_id integer,
	next_start_offset_in_seconds integer default 0 not null,
	moved_at timestamp with time zone default now() not null,
	-- the repeat of a moment within its lane; 0 is the original
	instance integer default 0 not null,
	production_line_id integer,
	tenant_id integer,
	start_offset_in_seconds integer,
	is_pinned boolean
);

alter table material_impose_plan owner to xfw3;

create index ix_material_impose_plan
	on material_impose_plan (weekday asc, step asc, resource_path asc, sort_order asc, moved_at desc);
