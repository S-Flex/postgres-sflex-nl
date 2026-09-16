create table state_shift_agg
(
	shift_date date not null,
	shift_index integer not null,
	resource_uid text not null,
	state text not null,
	shift_start timestamp with time zone not null,
	shift_end timestamp with time zone not null,
	duration_seconds numeric not null,
	-- nest sheet area planned on the resource in this shift (pv2 items starting
	-- in it, batched_amounts x nest width x height): on the planned row only
	planned_output_sqm numeric,
	-- nest sheet area produced in this shift (log.data jobs starting in it,
	-- amount x nest width x height): on the producing row only
	actual_gross_output_sqm numeric,
	-- the same area less the waste of the nest (nest_json waste_percentage):
	-- the area of the customer orders in it
	actual_net_output_sqm numeric,
	-- the code of the shift window (shift_json code: day, evening, night)
	shift_code text,
	constraint pk_state_shift_agg
		primary key (shift_date, shift_index, resource_uid, state)
);

alter table state_shift_agg owner to xfw3;

