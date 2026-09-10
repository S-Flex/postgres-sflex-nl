-- Which impositions sit in a lane_item. imposition_id is for now an alias of
-- legacy.nest.nest_id, the way imposition_group_id is an alias of material_id;
-- the move to production.imposition follows later (see sql/action/planned/).
--
-- Append-only, written on change only (docs/plan-lane-model.md, stap 2): a
-- set is written at the first step of an imposition and again on a split or a
-- merge; every row of one write shares its moved_at and the most recent write
-- per lane_item is the set that counts. A lane_item without rows inherits the
-- set of its predecessor(s) through lane_item_dependency — see
-- action.get_lane_item_impositions. A lane_item that lost every imposition
-- gets the explicit empty set: one row with imposition_id null, so it stops
-- inheriting. moved_at is the axis for point-in-time reconstruction.
create table imposition_lane_item
(
	imposition_lane_item_id bigint generated always as identity
		primary key,
	lane_item_id bigint not null,
	-- null = the empty set, written on purpose
	imposition_id bigint,
	-- the order of the imposition within the item
	sort_order numeric,
	moved_at timestamp with time zone default now() not null
);

comment on table imposition_lane_item is 'Membership of impositions in lane items, append-only and written on change only: first step, split, merge. The most recent write per lane_item is the set; no rows means: the same set as the predecessor (lane_item_dependency); one row with imposition_id null means: empty on purpose.';

alter table imposition_lane_item owner to xfw3;

create index idx_imposition_lane_item_lane_item_moved
	on imposition_lane_item (lane_item_id, moved_at desc);

create index idx_imposition_lane_item_imposition_id
	on imposition_lane_item (imposition_id);
