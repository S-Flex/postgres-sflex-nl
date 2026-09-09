-- Which nests sit in a lane item, per batch (docs/plan-batch-lane-item.md).
-- One row per batch on the item; batch_id null is the row of the nests not
-- batched yet, and there is one such row per item. nest_ids holds the nests
-- of the item's own plan date only: a batch across days is one row per day.
-- An impose item carries many batches (one material, several manifest
-- item_code_paths); on every other step an item carries one row. A pv2 item
-- without a batch carries no row: an empty slot.
--
-- lane_id and step are copies, held true by the two composite foreign keys,
-- so the partial unique indexes below can enforce the rules without a
-- trigger. Current state only; the append-only history comes back later.
create table action.batch_lane_item
(
	batch_lane_item_id bigint generated always as identity
		primary key,
	lane_item_id bigint not null,
	lane_id bigint not null,
	step text not null,
	-- null = the nests of this item that have no batch yet
	batch_id bigint,
	nest_ids bigint[] default '{}'::bigint[] not null,
	foreign key (lane_item_id, lane_id) references action.lane_item (lane_item_id, lane_id)
		on delete cascade,
	foreign key (lane_id, step) references action.lane (lane_id, step),
	unique (lane_item_id, batch_id)
);

comment on table action.batch_lane_item is 'The nests of a lane item per batch: one row per batch on the item, batch_id null for the nests not batched yet (one such row per item), nest_ids the nests of the item''s own plan date. Impose items carry many batches, every other step one row, an empty pv2 slot none.';
comment on column action.batch_lane_item.lane_id is 'Copy of lane_item.lane_id, held true by the composite foreign key; carries the uniqueness rules.';
comment on column action.batch_lane_item.step is 'Copy of lane.step, held true by the composite foreign key; one row per item on every step but impose.';

alter table action.batch_lane_item owner to xfw3;

-- one null-batch row per item
create unique index batch_lane_item_one_null_batch_uq
	on action.batch_lane_item (lane_item_id)
	where batch_id is null;

-- one batch per item on every step but impose
create unique index batch_lane_item_one_batch_outside_impose_uq
	on action.batch_lane_item (lane_item_id)
	where step <> 'impose';

create index idx_batch_lane_item_lane_id
	on action.batch_lane_item (lane_id);

create index idx_batch_lane_item_batch_id
	on action.batch_lane_item (batch_id);

-- which item holds a nest: nest_ids @> array[nest_id]
create index idx_batch_lane_item_nest_ids
	on action.batch_lane_item using gin (nest_ids);
