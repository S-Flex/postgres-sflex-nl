-- The board scope of the resource planning (docs/schedule-base.md):
-- one row per line type and the tenants that run it. No date and no steps:
-- the lanes under it carry the day, the step and the machine.
create table schedule.plan
(
	plan_id bigint generated always as identity
		primary key,
	line_type text not null,
	-- the tenants that run this line type (relation.production_line)
	tenant_ids integer[] not null,
	unique (line_type, tenant_ids)
);

comment on table schedule.plan is 'The scope of a planning board: one row per line type and tenant set. Its lanes (schedule.lane) hold every step of every day; a board filters the lanes on date, step and resource_path.';

alter table schedule.plan owner to xfw3;
