create table shift_planning
(
	shift_planning_id bigserial
		primary key,
	resource_uid text not null,
	content_id text not null
		unique,
	log_type text not null,
	plan_date date not null,
	start_at timestamp with time zone not null,
	end_at timestamp with time zone not null,
	resource_data_json jsonb not null,
	original_json jsonb,
	created_at timestamp with time zone default now() not null,
	updated_at timestamp with time zone default now() not null
);

alter table shift_planning owner to xfw3;

create index shift_planning_resource_uid_idx
	on shift_planning (resource_uid);

create index shift_planning_plan_date_idx
	on shift_planning (plan_date);

