-- Rollback of sql/update_status_bar_oee.sql: the group oee out of the lookup,
-- the oee function gone, mapping.get_status_bar the version before.
BEGIN;

UPDATE legacy.lookup lk
SET lookup_json = (SELECT coalesce(jsonb_agg(g.value ORDER BY g.ordinality), '[]'::jsonb)
                   FROM jsonb_array_elements(lk.lookup_json) WITH ORDINALITY g
                   WHERE g.value ->> 'code' <> 'oee')
WHERE lk.lookup = 'status_bar';

DROP FUNCTION IF EXISTS mapping.get_status_bar_oee(text, timestamp with time zone, integer, jsonb);

-- ============ sql/mapping/get_status_bar.sql (before) ============
create or replace function mapping.get_status_bar(p_model text DEFAULT NULL::text, p_until timestamp with time zone DEFAULT (CURRENT_DATE)::timestamp with time zone, p_production_line_id integer DEFAULT NULL::integer) returns TABLE(status_json jsonb)
	language plpgsql
as $$
#variable_conflict use_column
DECLARE
    v_line       record;
    v_teams      jsonb;
    v_bar_config jsonb;
BEGIN
    SELECT rl.lookup_json INTO v_bar_config
    FROM legacy.lookup rl
    WHERE rl.lookup = 'status_bar';

    v_teams := mapping.get_status_bar_teams(p_model, p_until);

    FOR v_line IN
        SELECT pl.line_id, pl.line AS line_name
        FROM relation.production_line pl
        WHERE (p_production_line_id IS NOT NULL AND pl.line_id = p_production_line_id)
           OR (p_production_line_id IS NULL AND p_model IS NOT NULL AND pl.model = p_model)
        ORDER BY pl.line
    LOOP
        status_json := jsonb_build_object(
            'production_line_id',   v_line.line_id,
            'production_line_name', v_line.line_name,
            'items', (
                SELECT jsonb_agg(
                    jsonb_build_object(
                        'code', grp->>'code',
                        'i18n', grp->'i18n',
                        'nav',  grp->'nav',
                        'data', CASE grp->>'src'
                            WHEN 'teams'          THEN v_teams
                            WHEN 'time_on_status' THEN mapping.get_status_bar_time_on_status(p_model, p_until, v_line.line_id)
                            WHEN 'capacity'       THEN mapping.get_status_bar_capacity(p_model, p_until, v_line.line_id, grp->'steps')
                            WHEN 'rework'         THEN mapping.get_status_bar_rework(v_line.line_id)
                            WHEN 'file_inflow'    THEN mapping.get_status_bar_file_inflow(v_line.line_id)
                            WHEN 'nests'          THEN mapping.get_status_bar_nests(v_line.line_id)
                        END
                    )
                )
                FROM jsonb_array_elements(v_bar_config) AS grp
            )
        );
        RETURN NEXT;
    END LOOP;
END;
$$;

alter function mapping.get_status_bar(text, timestamp with time zone, integer) owner to xfw3;


COMMIT;
