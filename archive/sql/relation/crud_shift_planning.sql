create function relation.crud_shift_planning(p_param_json jsonb, p_no_results boolean DEFAULT false) returns TABLE(o_param_id integer, o_track_by integer, o_crud text, o_content_id text, o_log_type text, o_resource_uid text, o_plan_date date, o_start_at timestamp with time zone, o_end_at timestamp with time zone, o_resource_data_json jsonb, o_original_json jsonb)
	language plpgsql
as $$
  DECLARE
      rec RECORD;
  BEGIN
      CREATE TEMP TABLE param_table (
          param_id           serial PRIMARY KEY,
          track_by           integer,
          crud               text,
          content_id         text,
          log_type           text,
          resource_uid       text,
          plan_date          date,
          start_at           timestamptz,
          end_at             timestamptz,
          resource_data_json jsonb,
          original_json      jsonb
      ) ON COMMIT DROP;

      INSERT INTO param_table (
          track_by, crud, content_id, log_type,
          resource_uid, plan_date, start_at, end_at,
          resource_data_json, original_json
      )
      SELECT
          COALESCE(t.track_by, 0),
          t.crud,
          t.content_id,
          t.log_type,
          t.log_json ->> 'resource_uid',
          (t.log_json -> 'plan' ->> 'date')::date,
          (t.log_json ->> 'start_at')::timestamptz,
          (t.log_json ->> 'end_at')::timestamptz,
          t.log_json,
          t.original_json
      FROM jsonb_to_recordset(p_param_json) AS t(
          track_by      integer,
          crud          text,
          content_id    text,
          log_type      text,
          log_json      jsonb,
          original_json jsonb
      );

      FOR rec IN
          SELECT p.param_id, p.crud
          FROM param_table p
          ORDER BY p.param_id
      LOOP
          IF rec.crud = 'create' THEN
              INSERT INTO relation.shift_planning (
                  resource_uid, content_id, log_type, plan_date,
                  start_at, end_at, resource_data_json, original_json
              )
              SELECT
                  p.resource_uid, p.content_id, p.log_type, p.plan_date,
                  p.start_at, p.end_at, p.resource_data_json, p.original_json
              FROM param_table p
              WHERE p.param_id = rec.param_id
              ON CONFLICT (content_id) DO NOTHING;

          ELSIF rec.crud = 'merge' THEN
              INSERT INTO relation.shift_planning (
                  resource_uid, content_id, log_type, plan_date,
                  start_at, end_at, resource_data_json, original_json
              )
              SELECT
                  p.resource_uid, p.content_id, p.log_type, p.plan_date,
                  p.start_at, p.end_at, p.resource_data_json, p.original_json
              FROM param_table p
              WHERE p.param_id = rec.param_id
              ON CONFLICT (content_id) DO UPDATE
              SET log_type           = EXCLUDED.log_type,
                  plan_date          = EXCLUDED.plan_date,
                  start_at           = EXCLUDED.start_at,
                  end_at             = EXCLUDED.end_at,
                  resource_data_json = EXCLUDED.resource_data_json,
                  original_json      = EXCLUDED.original_json,
                  updated_at         = now();
          END IF;
      END LOOP;

      IF NOT p_no_results THEN
          RETURN QUERY
          SELECT pt.param_id, pt.track_by, pt.crud, pt.content_id, pt.log_type,
                 pt.resource_uid, pt.plan_date, pt.start_at, pt.end_at,
                 pt.resource_data_json, pt.original_json
          FROM param_table pt
          ORDER BY pt.param_id;
      END IF;
  END;
  $$;

alter function relation.crud_shift_planning(jsonb, boolean) owner to xfw3;

