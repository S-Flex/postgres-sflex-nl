-- Which machines can do the work of an item group: one row per item group
-- and resource path. The path is a machine or a branch of the resource tree
-- (docs/resource-path.md, site.line.step.…), so one row can cover every
-- machine of a step on a line. The step is the third label of the path,
-- stored as a generated column so it can be indexed and joined without
-- relation.resource.
--
-- Read by legacy.create_imposition_unit_manifest: the item groups of the xbom
-- rows of a sheet say which steps the sheet goes through and on which
-- machines (legacy.nest.manifest_json steps[]); the planning makes the step
-- items from that (docs/plan-planning-schema.md §3.2).
create table catalog.item_group_resource
(
	item_group_resource_id bigint generated always as identity
		primary key,
	item_group_code text not null
		references catalog.item_group (item_group_code),
	-- a machine or a branch: at least site.line.step
	resource_path ltree not null
		constraint item_group_resource_path_check
			check (nlevel(resource_path) >= 3),
	-- the third label of the path, the step of the work
	step text generated always as (ltree2text(subpath(resource_path, 2, 1))) stored,
	created_at timestamp with time zone default now() not null,
	unique (item_group_code, resource_path)
);

comment on table catalog.item_group_resource is 'The machines (or branches of the resource tree) that can do the work of an item group. step is the third label of resource_path. Source of the steps and candidate machines in legacy.nest.manifest_json.';

alter table catalog.item_group_resource owner to xfw3;

create index idx_item_group_resource_step
	on catalog.item_group_resource (step);

create index idx_item_group_resource_path
	on catalog.item_group_resource using gist (resource_path);
