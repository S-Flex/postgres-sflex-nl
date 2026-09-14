-- Versioned formulas of the production side, the twin of catalog.formula
-- (the schedule boards have their own: schedule.formula). Same shape and same versioning as catalog.formula;
-- which version applies at a moment is production.get_formula.
create table production.formula
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

comment on table production.formula is 'Versioned formulas of production: one row per version of a code. Which version applies at a moment: the newest active or archived row created before it (production.get_formula). draft and pending-approval never apply. ';
comment on column production.formula.version_status is 'draft -> pending-approval -> active -> archived. At most one active version per code; archived versions stay valid for what was created in their time.';
comment on column production.formula.created_at is 'The moment this version starts to apply. Set it when the version becomes active, not when the draft is typed.';

alter table production.formula owner to xfw3;

-- one active version per code
create unique index uq_production_formula_code_active
	on production.formula (formula_code)
	where (version_status = 'active');

-- the as-of lookup: newest applying version of a code before a moment
create index idx_production_formula_code_created
	on production.formula (formula_code, created_at desc)
	where (version_status in ('active', 'archived'));
