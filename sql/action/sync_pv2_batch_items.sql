-- The batch row of the pv2 items (docs/plan-batch-lane-item.md). A plannable
-- item of pv2 (action.object, type 'batch') is one lane item: source 'pv2',
-- source_ref <plannable_item_id>. It carries one row in
-- action.batch_lane_item: its batch, with the nests pv2 batched on it
-- (batched_amounts). An item without a batch is an empty slot (repair,
-- maintenance, test) and carries no row. The row is replaced as a whole:
-- the pv2 planning is the source of truth here, not history.
--
-- The chain runs per batch: a coater/laminator item of batch B follows the
-- printer item of B, a cutter item of B the coater/laminator of B, else the
-- printer of B. Edges of the items are replaced as a whole too.
--
-- The extra items of the old rule (source_ref <plannable_item_id>:<batch>,
-- one per other batch a nest was booked on) are removed when their main
-- item passes here; their rows and edges cascade.
--
-- Called by action.crud_object after its upsert (for the payload's items) and
-- by the backfill (for every item). Set-based, no loop.
drop function if exists action.sync_pv2_batch_items(bigint[]);

create function action.sync_pv2_batch_items(p_plannable_item_ids bigint[]) returns integer
	language plpgsql
as $$
#variable_conflict use_column
DECLARE
    v_items integer;
BEGIN
    -- the items, their batch and the nests pv2 batched on them
    CREATE TEMP TABLE pv2_item ON COMMIT DROP AS
    SELECT li.lane_item_id, li.lane_id, l.step,
           o.batch_id::bigint                 AS batch_id,
           o.action_json ->> 'machine_type'   AS machine_type,
           coalesce((SELECT array_agg(DISTINCT (ba.value ->> 'nest_id')::bigint)
                     FROM jsonb_array_elements(coalesce(o.action_json -> 'data' -> 'batched_amounts', '[]'::jsonb)) AS ba(value)
                     WHERE (ba.value ->> 'nest_id') IS NOT NULL),
                    '{}'::bigint[])           AS nest_ids
    FROM action.object o
    JOIN action.lane_item li ON li.source = 'pv2' AND li.source_ref = o.action_json ->> 'plannable_item_id'
    JOIN action.lane l ON l.lane_id = li.lane_id
    WHERE (o.action_json ->> 'plannable_item_id')::bigint = ANY (p_plannable_item_ids);

    -- the extra items of the old rule
    DELETE FROM action.lane_item li
    WHERE li.source = 'pv2'
      AND li.source_ref LIKE '%:%'
      AND split_part(li.source_ref, ':', 1)::bigint = ANY (p_plannable_item_ids);

    -- one row per item with a batch, replaced as a whole
    DELETE FROM action.batch_lane_item b
    WHERE b.lane_item_id IN (SELECT pi.lane_item_id FROM pv2_item pi);

    INSERT INTO action.batch_lane_item (lane_item_id, lane_id, step, batch_id, nest_ids)
    SELECT pi.lane_item_id, pi.lane_id, pi.step, pi.batch_id, pi.nest_ids
    FROM pv2_item pi
    WHERE pi.batch_id IS NOT NULL;

    -- the chain per batch: edges of the items replaced as a whole
    DELETE FROM action.lane_item_dependency d
    WHERE d.to_lane_item_id IN (SELECT pi.lane_item_id FROM pv2_item pi);

    INSERT INTO action.lane_item_dependency (from_lane_item_id, to_lane_item_id)
    SELECT parent.lane_item_id, pi.lane_item_id
    FROM pv2_item pi
    CROSS JOIN LATERAL (
        -- the item of batch B one step earlier
        SELECT p.lane_item_id
        FROM action.object o
        JOIN action.lane_item p
          ON p.source = 'pv2' AND p.source_ref = o.action_json ->> 'plannable_item_id'
        WHERE o.batch_id = pi.batch_id
          AND (   (pi.machine_type IN ('coater', 'laminator') AND o.action_json ->> 'machine_type' = 'printer')
               OR (pi.machine_type = 'cutter' AND o.action_json ->> 'machine_type' IN ('coater', 'laminator', 'printer')))
        ORDER BY CASE WHEN o.action_json ->> 'machine_type' IN ('coater', 'laminator') THEN 0 ELSE 1 END,
                 o.action_id DESC
        LIMIT 1
    ) parent
    WHERE pi.batch_id IS NOT NULL
      AND pi.machine_type IN ('coater', 'laminator', 'cutter')
    ON CONFLICT DO NOTHING;

    SELECT count(*) INTO v_items FROM pv2_item;
    RETURN v_items;
END;
$$;

alter function action.sync_pv2_batch_items(bigint[]) owner to xfw3;
