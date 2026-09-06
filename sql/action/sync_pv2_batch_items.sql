-- One batch per lane item for the pv2 planning (docs/plan-lane-model.md,
-- stap 3b). A plannable item of pv2 (action.object, type 'batch') is one lane
-- item: source 'pv2', source_ref <plannable_item_id>. Its batched_amounts name
-- the nests; when legacy.nest meanwhile books a nest on another batch, that
-- nest may not stay on the item of the other batch. A nest without a batch
-- yet (nests are made first and batched later) counts as the item's own. A
-- nest on another batch gets its own item next to the main one: source 'pv2',
-- source_ref <plannable_item_id>:<batch>, same lane and start, the block's
-- duration shared by nest count (the main item keeps its share). Extra items
-- whose batch left are removed again.
--
-- Sets and edges of the main and extra items are replaced as a whole, the
-- way crud_object did for the main item: the pv2 planning is the source of
-- truth here, not history. The chain runs per batch: a coater/laminator item
-- of batch B follows the printer item of batch B, a cutter item of batch B
-- follows the coater/laminator of B, else the printer of B — where "the item
-- of batch B" is the extra item <id>:<B> when the parent object holds B as an
-- extra, else its main item.
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
    -- every nest of every item, with the batch legacy.nest books it on
    CREATE TEMP TABLE pv2_nest ON COMMIT DROP AS
    SELECT (o.action_json ->> 'plannable_item_id')                AS source_ref,
           coalesce(o.batch_id, 0)                                 AS item_batch,
           o.action_json ->> 'machine_type'                        AS machine_type,
           GREATEST(COALESCE(EXTRACT(EPOCH FROM ((o.action_json ->> 'end_date')::timestamp
                                                 - (o.action_json ->> 'start_date')::timestamp))::integer, 0), 0)
                                                                   AS block_duration,
           (ba.value ->> 'nest_id')::bigint                        AS nest_id,
           (ba.value ->> 'sequence')::numeric                      AS sequence,
           -- a nest without a batch yet belongs to the item's batch (nests are
           -- made first and batched later); only a nest on another batch leaves
           coalesce(n.batch_id, o.batch_id, 0)                     AS batch_key
    FROM action.object o
    CROSS JOIN LATERAL jsonb_array_elements(COALESCE(o.action_json -> 'data' -> 'batched_amounts', '[]'::jsonb)) AS ba(value)
    JOIN legacy.nest n ON n.nest_id = (ba.value ->> 'nest_id')::bigint
    WHERE (o.action_json ->> 'plannable_item_id')::bigint = ANY (p_plannable_item_ids)
      AND (ba.value ->> 'nest_id') IS NOT NULL;

    -- per (item, batch) the lane item it belongs to: the main item for the
    -- item's own batch (also when none of the nests is on it any more), an
    -- extra item per other batch
    CREATE TEMP TABLE pv2_item ON COMMIT DROP AS
    WITH batch AS (
        SELECT source_ref, item_batch AS batch_key FROM pv2_nest
        UNION
        SELECT source_ref, batch_key FROM pv2_nest
    ),
    cnt AS (
        SELECT source_ref, batch_key, count(*) AS nests FROM pv2_nest GROUP BY 1, 2
    ),
    total AS (
        SELECT source_ref, count(*) AS all_nests, max(block_duration) AS block_duration, max(item_batch) AS item_batch
        FROM pv2_nest GROUP BY 1
    )
    SELECT b.source_ref, b.batch_key,
           CASE WHEN b.batch_key = t.item_batch THEN b.source_ref
                ELSE b.source_ref || ':' || b.batch_key END               AS item_ref,
           coalesce(c.nests, 0)                                          AS nests,
           t.all_nests,
           round(t.block_duration::numeric * coalesce(c.nests, 0) / nullif(t.all_nests, 0))::integer AS duration_in_seconds,
           main.lane_item_id                                             AS main_item_id,
           main.lane_id, main.sort_order AS main_sort_order,
           main.start_offset_in_seconds, main.is_pinned
    FROM batch b
    JOIN total t ON t.source_ref = b.source_ref
    LEFT JOIN cnt c ON c.source_ref = b.source_ref AND c.batch_key = b.batch_key
    JOIN action.lane_item main ON main.source = 'pv2' AND main.source_ref = b.source_ref;

    -- the extra items, next to the main item in its lane
    INSERT INTO action.lane_item AS li
        (lane_id, sort_order, start_offset_in_seconds, duration_in_seconds,
         is_pinned, no_split, type, source, source_ref)
    SELECT pi.lane_id,
           pi.main_sort_order + row_number() OVER (PARTITION BY pi.source_ref ORDER BY pi.batch_key),
           pi.start_offset_in_seconds, pi.duration_in_seconds, pi.is_pinned, true, 'plan', 'pv2', pi.item_ref
    FROM pv2_item pi
    WHERE pi.item_ref <> pi.source_ref
    ON CONFLICT (source, source_ref) DO UPDATE SET
        lane_id                 = EXCLUDED.lane_id,
        sort_order              = EXCLUDED.sort_order,
        start_offset_in_seconds = EXCLUDED.start_offset_in_seconds,
        duration_in_seconds     = EXCLUDED.duration_in_seconds,
        is_pinned               = EXCLUDED.is_pinned;

    -- the main item keeps its share of the block
    UPDATE action.lane_item li
    SET duration_in_seconds = pi.duration_in_seconds
    FROM pv2_item pi
    WHERE pi.item_ref = pi.source_ref
      AND li.lane_item_id = pi.main_item_id
      AND li.duration_in_seconds IS DISTINCT FROM pi.duration_in_seconds;

    -- extra items whose batch left: their sets, edges (cascade) and the item
    DELETE FROM action.imposition_lane_item x
    USING action.lane_item li
    WHERE x.lane_item_id = li.lane_item_id
      AND li.source = 'pv2'
      AND split_part(li.source_ref, ':', 1)::bigint = ANY (p_plannable_item_ids)
      AND li.source_ref LIKE '%:%'
      AND NOT EXISTS (SELECT 1 FROM pv2_item pi WHERE pi.item_ref = li.source_ref);

    DELETE FROM action.lane_item li
    WHERE li.source = 'pv2'
      AND split_part(li.source_ref, ':', 1)::bigint = ANY (p_plannable_item_ids)
      AND li.source_ref LIKE '%:%'
      AND NOT EXISTS (SELECT 1 FROM pv2_item pi WHERE pi.item_ref = li.source_ref);

    -- the sets of main and extra items, replaced as a whole
    DELETE FROM action.imposition_lane_item x
    USING action.lane_item li
    WHERE x.lane_item_id = li.lane_item_id
      AND li.source = 'pv2'
      AND split_part(li.source_ref, ':', 1)::bigint = ANY (p_plannable_item_ids);

    INSERT INTO action.imposition_lane_item (imposition_id, lane_item_id, sort_order)
    SELECT DISTINCT ON (pn.nest_id, li.lane_item_id)
           pn.nest_id, li.lane_item_id, pn.sequence
    FROM pv2_nest pn
    JOIN pv2_item pi ON pi.source_ref = pn.source_ref AND pi.batch_key = pn.batch_key
    JOIN action.lane_item li ON li.source = 'pv2' AND li.source_ref = pi.item_ref
    ORDER BY pn.nest_id, li.lane_item_id, pn.sequence;

    -- the chain per batch: edges of main and extra items replaced as a whole
    DELETE FROM action.lane_item_dependency d
    USING action.lane_item li
    WHERE d.to_lane_item_id = li.lane_item_id
      AND li.source = 'pv2'
      AND split_part(li.source_ref, ':', 1)::bigint = ANY (p_plannable_item_ids);

    INSERT INTO action.lane_item_dependency (from_lane_item_id, to_lane_item_id)
    SELECT parent.lane_item_id, child.lane_item_id
    FROM pv2_item pi
    JOIN pv2_nest pn0 ON pn0.source_ref = pi.source_ref
    JOIN action.lane_item child ON child.source = 'pv2' AND child.source_ref = pi.item_ref
    CROSS JOIN LATERAL (
        -- the object of batch B one step earlier, and its item that holds B:
        -- the extra item <id>:<B> when B is an extra there, else the main item
        SELECT p.lane_item_id
        FROM action.object o
        JOIN action.lane_item p
          ON p.source = 'pv2'
         AND p.source_ref = CASE WHEN coalesce(o.batch_id, 0) = pi.batch_key
                                 THEN o.action_json ->> 'plannable_item_id'
                                 ELSE (o.action_json ->> 'plannable_item_id') || ':' || pi.batch_key END
        WHERE (o.batch_id = pi.batch_key
               OR EXISTS (SELECT 1 FROM action.lane_item e
                          WHERE e.source = 'pv2'
                            AND e.source_ref = (o.action_json ->> 'plannable_item_id') || ':' || pi.batch_key))
          AND (   (pn0.machine_type IN ('coater', 'laminator') AND o.action_json ->> 'machine_type' = 'printer')
               OR (pn0.machine_type = 'cutter' AND o.action_json ->> 'machine_type' IN ('coater', 'laminator', 'printer')))
        ORDER BY CASE WHEN o.action_json ->> 'machine_type' IN ('coater', 'laminator') THEN 0 ELSE 1 END,
                 o.action_id DESC
        LIMIT 1
    ) parent
    WHERE pi.nests > 0
      AND pi.batch_key <> 0
      AND pn0.machine_type IN ('coater', 'laminator', 'cutter')
      AND pn0.nest_id = (SELECT min(x.nest_id) FROM pv2_nest x WHERE x.source_ref = pi.source_ref)
    ON CONFLICT DO NOTHING;

    SELECT count(*) INTO v_items FROM pv2_item;
    RETURN v_items;
END;
$$;

alter function action.sync_pv2_batch_items(bigint[]) owner to xfw3;
