-- Versioned formulas of the schedule boards (docs/schedule-base.md):
-- the duration and lag rules per view, formula_code 'duration-<view_code>'
-- and 'lag-<view_code>', formula_json the rule list the board evaluates.
-- Same shape and versioning as catalog.formula; which version applies at a
-- moment is schedule.get_formula. Was action.formula until 13 Sep 2026
-- (moved with ALTER TABLE ... SET SCHEMA, step 1c).
create table schedule.formula
(
	formula_id integer generated always as identity
		primary key,
	-- the name a formula is known by; every version of it shares the code
	formula_code text not null,
	formula_json jsonb not null,
	formula_level integer default 0 not null,
	version integer default 1 not null,
	version_status text default 'active'::text not null
		constraint formula_version_status_check
			check (version_status in ('draft', 'pending-approval', 'active', 'archived')),
	created_at timestamp with time zone default now() not null,
	unique (formula_code, version)
);

comment on table schedule.formula is 'Versioned formulas of the schedule boards: one row per version of a code (duration-<view_code>, lag-<view_code>). Which version applies at a moment: the newest active or archived row created before it (schedule.get_formula). draft and pending-approval never apply.';

alter table schedule.formula owner to xfw3;

-- one active version per code
create unique index uq_formula_code_active
	on schedule.formula (formula_code)
	where (version_status = 'active');

-- the as-of lookup: newest applying version of a code before a moment
create index idx_formula_code_created
	on schedule.formula (formula_code, created_at desc)
	where (version_status in ('active', 'archived'));
