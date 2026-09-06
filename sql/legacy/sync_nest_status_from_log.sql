-- The status of a nest follows the machines. legacy.nest.nest_json.internal_status_code
-- comes from the legacy payload (crud_nest) and often stops at 'printed' or even
-- 'nested' while log.data already shows the nest printed or cut (6 sep: 10.520
-- nests behind, 3.246 of them 'printed' with a cut in the log). This lifts the
-- status to the furthest step the log knows, through lookup_step_category
-- (step -> internal_status_code, sequence): print -> printed (700), cut -> cut
-- (801). Only upwards, never back; a cancelled nest is left alone. Every lift
-- writes a legacy.nest_log row with the machines and the moment of the first
-- log row of that step, so the history says who did it and when.
--
-- p_nest_names null = every nest the log knows (the backfill); log.crud_data_log
-- calls it with the nest names of its payload after every batch. Set-based.
drop function if exists legacy.sync_nest_status_from_log(text[]);

create function legacy.sync_nest_status_from_log(p_nest_names text[] DEFAULT NULL::text[]) returns integer
    language sql
as $$
    WITH step_status AS (
        SELECT l.step, l.sequence, l.internal_status_code
        FROM relation.lookup rl
        CROSS JOIN LATERAL jsonb_to_recordset(rl.lookup_json) AS l(step text, sequence integer, internal_status_code text)
        WHERE rl.lookup = 'lookup_step_category'
    ),
    -- per nest and step: when the step first ran and on which machines
    log_step AS (
        SELECT d.nest_name, ss.sequence, ss.internal_status_code,
               min(d.start_at)                    AS first_at,
               array_agg(DISTINCT d.resource_uid) AS resource_uids
        FROM log.data d
        JOIN step_status ss ON ss.step = d.step
        WHERE d.nest_name IS NOT NULL
          AND (p_nest_names IS NULL OR d.nest_name = ANY (p_nest_names))
        GROUP BY d.nest_name, ss.sequence, ss.internal_status_code
    ),
    furthest AS (
        SELECT DISTINCT ON (ls.nest_name) ls.*
        FROM log_step ls
        ORDER BY ls.nest_name, ls.sequence DESC
    ),
    -- the nests the log is ahead of
    target AS (
        SELECT n.nest_id, n.batch_id, n.amount,
               cur.sequence AS from_sequence,
               f.sequence AS to_sequence, f.internal_status_code, f.first_at, f.resource_uids
        FROM furthest f
        JOIN legacy.nest n ON n.nest_name = f.nest_name
        LEFT JOIN mapping.internal_status cur
               ON cur.code = n.nest_json ->> 'internal_status_code' AND cur.domain_id = n.domain_id
        WHERE coalesce(cur.sequence, -1) < f.sequence
          AND lower(coalesce(n.nest_json ->> 'status', '')) NOT LIKE 'cancel%'
    ),
    lifted AS (
        UPDATE legacy.nest n
        SET nest_json  = n.nest_json || jsonb_build_object('internal_status_code', t.internal_status_code),
            updated_at = greatest(n.updated_at, t.first_at)
        FROM target t
        WHERE n.nest_id = t.nest_id
        RETURNING n.nest_id
    ),
    logged AS (
        INSERT INTO legacy.nest_log
            (batch_id, nest_id, from_status_sequence, to_status_sequence, amount, remaining_impact_delta, resource_uids, moved_at)
        SELECT t.batch_id, t.nest_id, t.from_sequence, t.to_sequence, coalesce(t.amount, 1), NULL, t.resource_uids, t.first_at
        FROM target t
        WHERE NOT EXISTS (SELECT 1 FROM legacy.nest_log nl
                          WHERE nl.nest_id = t.nest_id AND nl.to_status_sequence = t.to_sequence)
        RETURNING nest_id
    )
    SELECT count(*)::integer FROM lifted;
$$;

alter function legacy.sync_nest_status_from_log(text[]) owner to xfw3;
