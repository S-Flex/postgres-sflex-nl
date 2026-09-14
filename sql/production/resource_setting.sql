-- How long a resource takes over an imposition, per imposition group. The
-- setting hangs on a resource_path, so it can cover a whole branch
-- (dk.sheet.impose.320) or one machine; the longest matching path wins, and a
-- row naming the group beats a row with imposition_group_id null.
-- Waste is not here: that depends on format and group, not on the machine —
-- it lives in legacy.imposition_group.imposition_group_json.
create table resource_setting
(
	resource_setting_id bigint generated always as identity
		primary key,
	resource_path ltree not null,
	imposition_group_id integer,
	setting_json jsonb default '{}'::jsonb not null,
	moved_at timestamp with time zone default now() not null
);

comment on table resource_setting is 'Time settings per resource branch and imposition group. setting_json holds the formula array plus its constants; append-only, newest moved_at wins.';

alter table resource_setting owner to xfw3;

create index ix_resource_setting_lookup
	on resource_setting (resource_path, imposition_group_id, moved_at desc);

create index ix_resource_setting_path_gist
	on resource_setting using gist (resource_path);
