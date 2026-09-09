drop function if exists legacy.get_nest_detail(bigint, integer, bigint[]);

create function legacy.get_nest_detail(p_nest_id bigint DEFAULT NULL::bigint, p_batch_id integer DEFAULT NULL::integer, p_nest_ids bigint[] DEFAULT NULL::bigint[]) returns TABLE(batch_id integer, nest_id bigint, nest_name text, nest_json jsonb, nested_at timestamp with time zone, updated_at timestamp with time zone, start_at timestamp with time zone)
	language plpgsql
as $$
    #variable_conflict use_column
DECLARE
    v_batch_id integer;
    v_nest_id bigint;
BEGIN
    -- a set of nests resolves through its first nest; a single nest through itself
    v_nest_id  := COALESCE(p_nest_id, p_nest_ids[1]);
    v_batch_id := p_batch_id;

    IF v_batch_id IS NULL THEN
        SELECT n.batch_id
        INTO v_batch_id
        FROM legacy.nest n
        WHERE n.nest_id = v_nest_id;
    END IF;

    RETURN QUERY
    SELECT
        n.batch_id,
        n.nest_id,
        n.nest_name,
        -- job_thumbnail as the Backblaze object key the board's template
        -- expects (printfactory/jobs/<guid>/thumbnails/page-1.png): older nests
        -- carry the hub-relative /thumbnails/<guid>-1.png; an empty string or an
        -- upload-error object (564 nests) is none
        CASE WHEN jsonb_typeof(n.nest_json -> 'job_thumbnail') = 'object'
               OR n.nest_json ->> 'job_thumbnail' = ''
             THEN n.nest_json || '{"job_thumbnail": null}'::jsonb
             WHEN n.nest_json ->> 'job_thumbnail' LIKE '/thumbnails/%'
             THEN jsonb_set(n.nest_json, '{job_thumbnail}',
                            to_jsonb('printfactory/jobs/'
                                     || regexp_replace(n.nest_json ->> 'job_thumbnail', '^/thumbnails/(.*)-1\.png$', '\1')
                                     || '/thumbnails/page-1.png'))
             ELSE n.nest_json END,
        n.nested_at,
        n.updated_at,
        rdl.start_at
    FROM legacy.nest n
    -- log.data replaced legacy.resource_data_log; a nest can have several
    -- rows there (print and cut, reruns) — one start per nest: the latest
    LEFT JOIN LATERAL (
        SELECT max(d.start_at) AS start_at
        FROM log.data d
        WHERE d.nest_name = n.nest_name
    ) rdl ON true
    -- batch found: every nest of the batch; no batch: every nest of the
    -- given set, or just the single nest when no set was given
    WHERE (n.batch_id = v_batch_id)
       OR (v_batch_id IS NULL AND p_nest_ids IS NOT NULL AND n.nest_id = ANY (p_nest_ids))
       OR (v_batch_id IS NULL AND p_nest_ids IS NULL AND n.nest_id = v_nest_id)
    ORDER BY rdl.start_at DESC;
END;
$$;

alter function legacy.get_nest_detail(bigint, integer, bigint[]) owner to xfw3;
