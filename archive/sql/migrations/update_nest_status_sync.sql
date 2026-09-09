-- ============================================================
-- De status van een nest volgt de machines (docs/nest-status-sync.md).
--   1. legacy.sync_nest_status_from_log: tilt nest_json.internal_status_code
--      naar de verste stap in log.data (lookup_step_category), alleen omhoog,
--      met een regel in legacy.nest_log.
--   2. log.crud_data_log roept hem na elke batch aan voor de nests in de payload.
--   3. legacy.get_nest_list laat een nest weg waarvan alle orderregels al
--      voorbij de nest-status zijn (gesneden zonder log, of handmatig).
-- Daarna de backfill over alle nests: dry run 6 sep 10.520 nests, waarvan
-- 6.157 nested -> printed en 3.246 printed -> cut.
-- ============================================================

BEGIN;

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

DROP FUNCTION IF EXISTS log.crud_data_log(jsonb, boolean);
create function log.crud_data_log(p_param_json jsonb, p_no_results boolean DEFAULT false) returns TABLE(track_by integer, crud text, data_log_id bigint, resource_uid text, filename text, nest_id integer, spec_id integer, amount numeric, sub_set text, start_at timestamp with time zone, end_at timestamp with time zone, metrics_json jsonb, source text, source_ref text, source_ts timestamp with time zone, nest_name text, production_time_seconds integer, page_number integer, data_json jsonb)
	language plpgsql
as $$
#variable_conflict use_column
declare
  rec jsonb;
  v_data jsonb;
  v_param integer;
begin

  for rec in
    select value from jsonb_array_elements(p_param_json) as e(value)
    where e.value ->> 'crud' is distinct from 'delete'
  loop

    v_data := rec -> 'data';

    v_param := case when v_data ->> 'step' = 'print'
                    then legacy.get_print_duration_according_to_specs(v_data ->> 'resource_uid', v_data ->> 'nest_name')::integer
                    else null
               end;

    return query
    insert into log.data as d (
      resource_uid, filename, nest_id, spec_id, amount, sub_set,
      start_at, end_at, metrics_json,
      source, source_ref, source_ts,
      nest_name, production_time_seconds, page_number, step, data_json
    )
    values (
      v_data ->> 'resource_uid',
      v_data ->> 'filename',
      (v_data ->> 'nest_id')::int,
      (v_data ->> 'spec_id')::int,
      nullif(v_data ->> 'amount', '')::numeric,
      v_data ->> 'sub_set',
      (v_data ->> 'start_at')::timestamptz,
      (v_data ->> 'end_at')::timestamptz,
      coalesce(v_data -> 'metrics_json', '[]'::jsonb),
      v_data ->> 'source',
      v_data ->> 'source_ref',
      (v_data ->> 'source_ts')::timestamptz,
      v_data ->> 'nest_name',
      coalesce(v_param, nullif(v_data ->> 'production_time_seconds', '')::integer),
      (v_data ->> 'page_number')::integer,
      v_data ->> 'step',
      v_data -> 'data_json'
    )
    on conflict (source, source_ref) where source_ref is not null do update set
      end_at = coalesce(excluded.end_at, d.end_at),
      metrics_json = excluded.metrics_json,
      nest_name = coalesce(excluded.nest_name, d.nest_name),
      production_time_seconds = coalesce(excluded.production_time_seconds, d.production_time_seconds),
      page_number = coalesce(excluded.page_number, d.page_number),
      step = coalesce(excluded.step, d.step),
      source_ts = coalesce(excluded.source_ts, d.source_ts),
      data_json = coalesce(excluded.data_json, d.data_json)
    returning
      (rec ->> 'track_by')::integer,
      rec ->> 'crud',
      d.data_log_id,
      d.resource_uid,
      d.filename,
      d.nest_id,
      d.spec_id,
      d.amount,
      d.sub_set,
      d.start_at,
      d.end_at,
      d.metrics_json,
      d.source,
      d.source_ref,
      d.source_ts,
      d.nest_name,
      d.production_time_seconds,
      d.page_number,
      d.data_json;

  end loop;

  -- keep the shift aggregate current: rebuild the machine-days this batch
  -- touched. The date is the Amsterdam day of start_at, and the day before
  -- as well, because a night window of yesterday runs into today
  perform log.upsert_state_shift_agg(d.shift_date, d.resource_uids)
  from (
      select dd.shift_date,
             array_agg(distinct (e.value -> 'data' ->> 'resource_uid')) as resource_uids
      from jsonb_array_elements(p_param_json) as e(value)
      cross join lateral (
          values (((e.value -> 'data' ->> 'start_at')::timestamptz at time zone 'Europe/Amsterdam')::date),
                 (((e.value -> 'data' ->> 'start_at')::timestamptz at time zone 'Europe/Amsterdam')::date - 1)
      ) as dd(shift_date)
      where e.value ->> 'crud' is distinct from 'delete'
        and e.value -> 'data' ->> 'resource_uid' is not null
        and e.value -> 'data' ->> 'start_at' is not null
      group by dd.shift_date
  ) d;

  -- the nests this batch touched follow the machines: a print lifts the nest to
  -- printed, a cut to cut (legacy.sync_nest_status_from_log, lookup_step_category)
  perform legacy.sync_nest_status_from_log(
      (select array_agg(distinct e.value -> 'data' ->> 'nest_name')
       from jsonb_array_elements(p_param_json) as e(value)
       where e.value ->> 'crud' is distinct from 'delete'
         and e.value -> 'data' ->> 'nest_name' is not null))
  where exists (select 1 from jsonb_array_elements(p_param_json) as e(value)
                where e.value ->> 'crud' is distinct from 'delete'
                  and e.value -> 'data' ->> 'nest_name' is not null);

  if p_no_results then return; end if;

end;
$$;

alter function log.crud_data_log(jsonb, boolean) owner to xfw3;

-- The nests in a status, for the intermediate stock board (intermediate_stock):
-- the nest's own status (nest_json.internal_status_code, kept current from the
-- machine log by legacy.sync_nest_status_from_log), on a batch of the line,
-- and — when machines are named — with a log row on one of them. A nest whose
-- orderlines are all past the nest's own status is no stock any more (cut on a
-- machine without a log, or handled by hand) and stays out; a nest whose
-- orderlines are not found stays in, the orderline is the source for that
-- conclusion, not its absence.
drop function if exists legacy.get_nest_list(integer, text[], text[], boolean);

create function legacy.get_nest_list(p_production_line_id integer DEFAULT NULL::integer, p_resource_uids text[] DEFAULT NULL::text[], p_internal_status text[] DEFAULT ARRAY['printed'::text], p_require_thumbnail boolean DEFAULT true) returns TABLE(nest_name text, nest_id bigint, nested_at timestamp with time zone, printed_at timestamp with time zone, nest_json jsonb, sqm numeric, material_name text)
	stable
	language sql
as $$
    WITH candidate AS (
        SELECT DISTINCT ON (n.nest_name)
            n.nest_name,
            n.nest_id,
            n.nested_at,
            rdl.start_at AS printed_at,
            n.nest_json,
            (n.nest_json->>'amount')::numeric
                * (n.nest_json->>'width')::numeric
                * (n.nest_json->>'height')::numeric / 10000 AS sqm,
            mpl.line_json->>'name' AS material_name,
            ist.sequence AS status_sequence
        FROM legacy.nest n
        JOIN legacy.batch b
          ON b.batch_uid = n.batch_uid
         AND (p_production_line_id IS NULL
              OR (b.batch_json->>'production_line_id')::int = p_production_line_id)
        LEFT JOIN mapping.material_production_line mpl
          ON mpl.material_id = (n.nest_json->>'material_id')::int
        LEFT JOIN mapping.internal_status ist
          ON ist.code = n.nest_json->>'internal_status_code' AND ist.domain_id = n.domain_id
        LEFT JOIN LATERAL (
            -- log.data replaced legacy.resource_data_log
            SELECT d.start_at
            FROM log.data d
            WHERE d.nest_name = n.nest_name
              AND (p_resource_uids IS NULL OR d.resource_uid = ANY (p_resource_uids))
            ORDER BY d.start_at DESC NULLS LAST
            LIMIT 1
        ) rdl ON true
        WHERE n.nest_json->>'internal_status_code' = ANY (p_internal_status)
          AND (p_resource_uids IS NULL OR rdl.start_at IS NOT NULL)
          AND (NOT p_require_thumbnail
            OR NULLIF(n.nest_json->>'job_thumbnail', '') IS NOT NULL)
        ORDER BY n.nest_name, n.nested_at DESC NULLS LAST
    ),
    -- the least advanced orderline part per candidate nest, one detail call for the set
    orderline_floor AS (
        SELECT x.nest_id, min(o.status_sequence) AS min_sequence
        FROM (SELECT array_agg(c.nest_id) AS nest_ids FROM candidate c) ids
        CROSS JOIN LATERAL mapping.get_production_orderline_detail(
                 p_date => now(), p_date_type => 'nest', p_nest_ids => ids.nest_ids,
                 p_status_sequences => NULL, p_is_open => NULL) o
        CROSS JOIN LATERAL unnest(o.nest_ids) AS x(nest_id)
        WHERE x.nest_id = ANY (ids.nest_ids)
        GROUP BY x.nest_id
    )
    SELECT c.nest_name, c.nest_id, c.nested_at, c.printed_at, c.nest_json, c.sqm, c.material_name
    FROM candidate c
    LEFT JOIN orderline_floor f ON f.nest_id = c.nest_id
    WHERE f.min_sequence IS NULL
       OR c.status_sequence IS NULL
       OR f.min_sequence <= c.status_sequence
    ORDER BY c.nest_name;
$$;

alter function legacy.get_nest_list(integer, text[], text[], boolean) owner to xfw3;

COMMIT;

-- check 1: the intermediate stock of line 5 on PRdY9CJuOfyB before the backfill;
-- expected: 80 (162 minus the 82 whose orderlines are all further)
SELECT count(*) AS nests_in_list FROM legacy.get_nest_list(5, array['PRdY9CJuOfyB'], array['printed'], true);

-- the backfill: every nest the log is ahead of; expected: 10.520 lifted
DO $$
DECLARE v_n integer;
BEGIN
    v_n := legacy.sync_nest_status_from_log(NULL);
    RAISE NOTICE 'nests lifted: %', v_n;
END $$;

-- check 2: nothing left behind; expected: 0
WITH step_status AS (
    SELECT l.step, l.sequence FROM relation.lookup rl
    CROSS JOIN LATERAL jsonb_to_recordset(rl.lookup_json) AS l(step text, sequence integer)
    WHERE rl.lookup = 'lookup_step_category')
SELECT count(*) AS nests_still_behind
FROM (SELECT d.nest_name, max(ss.sequence) AS log_sequence FROM log.data d JOIN step_status ss ON ss.step = d.step WHERE d.nest_name IS NOT NULL GROUP BY 1) f
JOIN legacy.nest n ON n.nest_name = f.nest_name
LEFT JOIN mapping.internal_status cur ON cur.code = n.nest_json ->> 'internal_status_code' AND cur.domain_id = n.domain_id
WHERE coalesce(cur.sequence, -1) < f.log_sequence
  AND lower(coalesce(n.nest_json ->> 'status', '')) NOT LIKE 'cancel%';

-- check 3: the list after the backfill; expected: 43 (the nests without a cut in
-- the log whose orderlines are not found or not all further)
SELECT count(*) AS nests_in_list_after FROM legacy.get_nest_list(5, array['PRdY9CJuOfyB'], array['printed'], true);
