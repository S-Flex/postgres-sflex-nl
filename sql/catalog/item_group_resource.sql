-- Which machines of a tenant can do the work of an item group: one row per
-- item group and resource path. catalog.item_group and catalog.item are
-- global; this table is the tenant's side of them: its machines and its
-- overrides of the group json. The path is a machine
-- or a branch of the resource tree (docs/resource-path.md, site.line.step.…),
-- so one row can cover every machine of a step on a line. The step is the
-- third label of the path, stored as a generated column so it can be indexed
-- and joined without relation.resource.
--
-- Read by legacy.create_nest_manifest: the item groups of the xbom rows of a
-- sheet say which steps the sheet goes through and on which machines of the
-- nest's tenant (legacy.nest.manifest_json steps[]); the planning makes the
-- step items from that. The setup and teardown seconds of a machine live in
-- legacy.imposition_group.rules_json (schedules[].lead_in / lead_out) since
-- 14 Sep 2026.
create table catalog.item_group_resource
(
	item_group_resource_id bigint generated always as identity
		primary key,
	item_group_code text not null
		references catalog.item_group (item_group_code),
	-- whose machine it is
	tenant_id integer not null
		references site.tenant,
	-- a machine or a branch: at least site.line.step
	resource_path ltree not null
		constraint item_group_resource_path_check
			check (nlevel(resource_path) >= 3),
	-- the third label of the path, the step of the work
	step text generated always as (ltree2text(subpath(resource_path, 2, 1))) stored,
	
	-- the tenant's overrides of catalog.item_group.item_group_json for this machine
	item_group_json jsonb default '{}'::jsonb not null,
	created_at timestamp with time zone default now() not null,
	updated_at timestamp with time zone default now() not null,
	unique (item_group_code, resource_path)
);

comment on table catalog.item_group_resource is 'The machines (or branches of the resource tree) of a tenant that can do the work of an item group, step is the third label of resource_path. Source of the steps and candidate machines in legacy.nest.manifest_json.';

comment on column catalog.item_group_resource.item_group_json is 'The tenant''s overrides of catalog.item_group.item_group_json for this machine; {} when none.';

alter table catalog.item_group_resource owner to xfw3;

create index idx_item_group_resource_step
	on catalog.item_group_resource (step);

create index idx_item_group_resource_path
	on catalog.item_group_resource using gist (resource_path);

create index idx_item_group_resource_tenant
	on catalog.item_group_resource (tenant_id);
