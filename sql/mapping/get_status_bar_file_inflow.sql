-- The file inflow items of the status bar (data_group 43, group file-inflow):
-- one item per cut-off window of today for the line type of the production
-- line, in cut-off order, titled with the Amsterdam cut-off time. The value is
-- the number of files received in the 24 hours before the cut-off so far
-- (legacy.get_file_inflow, the same read as board 63; a class split by unit
-- threshold is summed back into its window). No colour and no alert: the
-- inflow comes from the customers and is out of our hands, the bar only shows it.
create or replace function mapping.get_status_bar_file_inflow(p_line_id integer) returns jsonb
	stable
	language sql
as $$
    WITH line AS (
        SELECT pl.line_type
        FROM relation.production_line pl
        WHERE pl.line_id = p_line_id
    ),
    today AS (
        -- the windows closing today, the threshold tracks of one class summed
        SELECT f.cutoff_window_end_at AS end_at,
               sum(f.total_files)::integer AS files
        FROM line l
        CROSS JOIN LATERAL legacy.get_file_inflow(now(), l.line_type) f
        WHERE (f.cutoff_window_end_at AT TIME ZONE 'Europe/Amsterdam')::date
              = (now() AT TIME ZONE 'Europe/Amsterdam')::date
        GROUP BY f.cutoff_window_end_at
    )
    SELECT coalesce(jsonb_agg(jsonb_build_object(
               'code',  'cutoff-' || to_char(t.end_at AT TIME ZONE 'Europe/Amsterdam', 'HH24MI'),
               'i18n',  (SELECT jsonb_object_agg(lang, jsonb_build_object('title', to_char(t.end_at AT TIME ZONE 'Europe/Amsterdam', 'HH24:MI')))
                         FROM unnest(array['de', 'en', 'es', 'fr', 'nl', 'uk']) AS lang),
               'value', t.files
           ) ORDER BY t.end_at), '[]'::jsonb)
    FROM today t;
$$;

alter function mapping.get_status_bar_file_inflow(integer) owner to xfw3;
