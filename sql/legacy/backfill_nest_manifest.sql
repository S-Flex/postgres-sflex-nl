-- Backfill legacy.nest.manifest_json for the nests nested in the last p_days
-- days, p_batch_size nests per transaction, oldest nest_id first.
--
-- Why a procedure and not a DO block: the nest sync (legacy.crud_nest,
-- legacy.crud_single_product) rewrites the manifest of recent nests all day.
-- One long transaction over 50,000 nests holds its row locks until the end
-- and deadlocks with the sync (seen 12 Sep 2026 on the delete of
-- imposition_unit_manifest). So: only the fold (legacy.create_nest_manifest,
-- the rows already exist), a commit per batch, and a batch that hits a
-- deadlock is retried, up to five times.
--
-- CALL legacy.backfill_nest_manifest();          -- last 30 days, 200 a batch
-- Run it in autocommit mode: a procedure that commits cannot run inside a
-- transaction block. Rerun it after filling catalog.item_group_resource.
create or replace procedure legacy.backfill_nest_manifest(IN p_days integer DEFAULT 30, IN p_batch_size integer DEFAULT 200)
	language plpgsql
as $$
DECLARE
    v_ids     bigint[];
    v_last    bigint := 0;
    v_total   integer;
    v_done    integer := 0;
    v_retries integer := 0;
BEGIN
    SELECT count(*) INTO v_total
    FROM legacy.nest n
    WHERE n.nested_at >= current_date - p_days;
    RAISE NOTICE 'nest manifest backfill: % nests', v_total;

    LOOP
        SELECT array_agg(x.nest_id ORDER BY x.nest_id) INTO v_ids
        FROM (SELECT n.nest_id
              FROM legacy.nest n
              WHERE n.nested_at >= current_date - p_days
                AND n.nest_id > v_last
              ORDER BY n.nest_id
              LIMIT p_batch_size) x;
        EXIT WHEN v_ids IS NULL;

        BEGIN
            PERFORM legacy.create_nest_manifest(v_ids);
        EXCEPTION WHEN deadlock_detected THEN
            v_retries := v_retries + 1;
            IF v_retries > 5 THEN
                RAISE;
            END IF;
            RAISE NOTICE 'nest manifest backfill: deadlock on nests % .. %, retry %',
                v_ids[1], v_ids[cardinality(v_ids)], v_retries;
            CONTINUE;
        END;
        COMMIT;

        v_retries := 0;
        v_last    := v_ids[cardinality(v_ids)];
        v_done    := v_done + cardinality(v_ids);
        IF v_done % 5000 < p_batch_size THEN
            RAISE NOTICE 'nest manifest backfill: % of %', v_done, v_total;
        END IF;
    END LOOP;
    RAISE NOTICE 'nest manifest backfill: done, % of %', v_done, v_total;
END;
$$;

alter procedure legacy.backfill_nest_manifest(integer, integer) owner to xfw3;
