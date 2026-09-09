create function legacy.crud_single_product(p_param_json jsonb, p_no_results boolean DEFAULT false) returns TABLE(r_param_id integer, r_track_by integer, r_crud text, r_nestline_id integer, r_nest_id integer, r_production_orderline_id integer, r_filename text, r_amount integer, r_vertical_position jsonb, r_horizontal_position jsonb, r_width numeric, r_height numeric)
	language plpgsql
as $$
    #variable_conflict use_column
DECLARE
    last_updated_at timestamp;
BEGIN
    CREATE TEMP TABLE param_table ON COMMIT DROP AS
    SELECT
        row_number() OVER ()::integer               AS param_id,
        (el->>'track_by')::integer                  AS track_by,
        el->>'crud'                                 AS crud,
        (el->>'nestline_id')::integer               AS nestline_id,
        (el->>'nest_id')::integer                   AS nest_id,
        (el->>'production_orderline_id')::integer   AS production_orderline_id,
        el->>'filename'                             AS filename,
        (el->>'amount')::integer                    AS amount,
        el->'vertical_position'                     AS vertical_position,
        el->'horizontal_position'                   AS horizontal_position,
        CASE WHEN el->>'source' = 'esko'
            THEN (el->>'width')::numeric(8,1) * 10
            ELSE (el->>'width')::numeric(8,1) END   AS width,
        CASE WHEN el->>'source' = 'esko'
            THEN (el->>'height')::numeric(8,1) * 10
            ELSE (el->>'height')::numeric(8,1) END   AS height,
        el->>'source'                               AS source,
        (el->>'updated_at')::timestamp              AS updated_at
    FROM jsonb_array_elements(
        CASE
            WHEN jsonb_typeof(p_param_json) = 'array'
            THEN p_param_json
            ELSE jsonb_build_array(p_param_json)
        END
    ) AS el;

    -- Serialize parallel calls on overlapping nest_id's.
    -- One lock per unique nest_id in this batch, in a fixed order,
    -- prevents deadlocks between sessions touching multiple nests.
    PERFORM pg_advisory_xact_lock(hashtext('crud_single_product'), nest_id)
    FROM (SELECT DISTINCT nest_id FROM param_table WHERE nest_id IS NOT NULL ORDER BY nest_id) d;

    INSERT INTO legacy.single_product (nest_id, filename, amount, single_product_json)
    SELECT DISTINCT ON (p.nest_id, p.filename, p.amount)
        p.nest_id,
        p.filename,
        p.amount,
        jsonb_build_object(
            'filename',                p.filename,
            -- original_amount: the full ordered quantity from the orderline
            'original_amount',         cs.product_amount,
            -- nest_amount: the run length of the nest itself
            'nest_amount',             n.amount,
            'x_position',              x_pos.val,
            'y_position',              y_pos.val,
            'width',                   p.width,
            'height',                  p.height,
            'source',                  p.source,
            'nestline_id',             p.nestline_id,
            'production_orderline_id', p.production_orderline_id
        )
    FROM param_table p
    LEFT JOIN legacy.nest n
        ON n.nest_id = p.nest_id
    -- Resolve the ordered quantity for this orderline
    LEFT JOIN LATERAL (
        SELECT cs.product_amount
        FROM mapping.component_specs cs
        WHERE cs.production_orderline_id = p.production_orderline_id
        LIMIT 1
    ) cs ON true
    CROSS JOIN LATERAL (
        SELECT CASE
            WHEN p.horizontal_position IS NULL OR p.horizontal_position = 'null'::jsonb THEN NULL
            WHEN jsonb_typeof(p.horizontal_position) = 'string' AND (p.horizontal_position #>> '{}') = '' THEN NULL
            WHEN jsonb_typeof(p.horizontal_position) = 'number' THEN (p.horizontal_position)::numeric(18,8)
            WHEN jsonb_typeof(p.horizontal_position) = 'array'  THEN (p.horizontal_position->>0)::numeric(18,8)
            ELSE NULLIF(
                (regexp_split_to_array(regexp_replace(p.horizontal_position::text,'[\[\]"]','','g'),','))[1],
                ''
            )::numeric(18,8)
        END AS val
    ) x_pos
    CROSS JOIN LATERAL (
        SELECT CASE
            WHEN p.vertical_position IS NULL OR p.vertical_position = 'null'::jsonb THEN NULL
            WHEN jsonb_typeof(p.vertical_position) = 'string' AND (p.vertical_position #>> '{}') = '' THEN NULL
            WHEN jsonb_typeof(p.vertical_position) = 'number' THEN (p.vertical_position)::numeric(18,8)
            WHEN jsonb_typeof(p.vertical_position) = 'array'  THEN (p.vertical_position->>0)::numeric(18,8)
            ELSE NULLIF(
                (regexp_split_to_array(regexp_replace(p.vertical_position::text,'[\[\]"]','','g'),','))[1],
                ''
            )::numeric(18,8)
        END AS val
    ) y_pos
    WHERE p.crud IN ('create', 'merge')
    ORDER BY p.nest_id, p.filename, p.amount, p.updated_at DESC
    ON CONFLICT (nest_id, filename, amount)
    DO UPDATE SET
        single_product_json = EXCLUDED.single_product_json
    WHERE legacy.single_product.single_product_json
          IS DISTINCT FROM EXCLUDED.single_product_json;

    -- The nest of a single product need not be here yet: legacy.single_product
    -- carries no foreign key to legacy.nest (the nest sync runs behind, and a
    -- backfill of the nests is slower). A nest that is here gets its
    -- commercial waste and its sheet manifest refreshed; one that arrives
    -- later does both itself (legacy.crud_nest).
    PERFORM legacy.update_nest_commercial_waste(
        array(SELECT DISTINCT p.nest_id::bigint FROM param_table p WHERE p.nest_id IS NOT NULL));

    PERFORM legacy.create_imposition_unit_manifest(
        array(SELECT n.nest_id
              FROM legacy.nest n
              WHERE n.nest_id IN (SELECT p.nest_id FROM param_table p)));

    SELECT MAX(updated_at) INTO last_updated_at FROM param_table;

    IF last_updated_at IS NOT NULL THEN
        UPDATE mapping.persistent_vars
        SET value = last_updated_at
        WHERE key = 'last_nestline_updated_at';
    END IF;

    IF NOT p_no_results THEN
        RETURN QUERY
        SELECT
            pt.param_id, pt.track_by, pt.crud, pt.nestline_id, pt.nest_id,
            pt.production_orderline_id, pt.filename, pt.amount,
            pt.vertical_position, pt.horizontal_position, pt.width, pt.height
        FROM param_table pt
        ORDER BY pt.param_id;
    END IF;
END;
$$;

alter function legacy.crud_single_product(jsonb, boolean) owner to xfw3;

