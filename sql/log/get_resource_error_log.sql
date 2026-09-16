-- The error log of one resource (log.error) for the day of p_error_date and the days
-- before it: p_look_back_days days in all, 5 by default (p_error_date and the four
-- before). One row per error, newest first; error_date is the Amsterdam day of
-- start_at, the group of the board. duration is end_at - start_at in seconds,
-- null while the error is open. context_json is passed as it is (subsystem,
-- description, instance_info, and for interruptions detail_type, mapped_state,
-- fw_error_code, interruption_uuid); the board reads it with dot notation.
drop function if exists log.get_resource_error_log(text, date, integer);

create function log.get_resource_error_log(p_resource_uid text, p_error_date date DEFAULT (now() AT TIME ZONE 'Europe/Amsterdam')::date, p_look_back_days integer DEFAULT 5)
    returns TABLE(error_log_id bigint, resource_uid text, error_date date, start_at timestamp with time zone, end_at timestamp with time zone, duration numeric, code text, severity text, message text, context_json jsonb, source text, source_ref text, source_ts timestamp with time zone, ingested_at timestamp with time zone)
    stable
    language sql
as $$
    SELECT e.error_log_id, e.resource_uid,
           (e.start_at AT TIME ZONE 'Europe/Amsterdam')::date AS error_date,
           e.start_at, e.end_at,
           extract(epoch FROM (e.end_at - e.start_at))::numeric AS duration,
           e.code, e.severity, e.message,
           coalesce(e.context_json, '{}'::jsonb) AS context_json,
           e.source, e.source_ref, e.source_ts, e.ingested_at
    FROM log.error e
    WHERE e.resource_uid = p_resource_uid
      AND (e.start_at AT TIME ZONE 'Europe/Amsterdam')::date
          BETWEEN coalesce(p_error_date, (now() AT TIME ZONE 'Europe/Amsterdam')::date) - (greatest(coalesce(p_look_back_days, 5), 1) - 1)
              AND coalesce(p_error_date, (now() AT TIME ZONE 'Europe/Amsterdam')::date)
    ORDER BY e.start_at DESC, e.error_log_id DESC;
$$;

alter function log.get_resource_error_log(text, date, integer) owner to xfw3;
