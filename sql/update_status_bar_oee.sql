-- OEE report (docs/plan-oee-report.md), step 3: OEE in the status bar.
--   1. legacy.lookup status_bar gets the group oee (json/lookup/legacy/status_bar.json
--      is the source): src oee, nav to the window oee-report, item = the
--      oee_json key producing_oee_planned_percentage with its title.
--   2. mapping.get_status_bar_oee: the report of the business day of p_until,
--      summed over the machines of the line, the rules evaluated on the sums.
--   3. mapping.get_status_bar: the branch for src oee.
-- Needs update_oee_report.sql. Rollback: sql/update_status_bar_oee_down.sql.
BEGIN;

-- ============ legacy.lookup status_bar: group oee ============
UPDATE legacy.lookup lk
SET lookup_json = lk.lookup_json || $json$[
{
  "code": "oee",
  "src": "oee",
  "i18n": {
    "de": {
      "title": "OEE"
    },
    "en": {
      "title": "OEE"
    },
    "es": {
      "title": "OEE"
    },
    "fr": {
      "title": "OEE"
    },
    "nl": {
      "title": "OEE"
    },
    "uk": {
      "title": "OEE"
    }
  },
  "nav": {
    "path": "(window:oee-report)",
    "params": [
      {
        "key": "model",
        "is_query_param": true
      }
    ]
  },
  "items": [
    {
      "code": "producing_oee_planned_percentage",
      "i18n": {
        "de": {
          "title": "OEE geplant"
        },
        "en": {
          "title": "OEE planned"
        },
        "es": {
          "title": "OEE planificado"
        },
        "fr": {
          "title": "OEE planifié"
        },
        "nl": {
          "title": "OEE gepland"
        },
        "uk": {
          "title": "OEE заплановано"
        }
      }
    }
  ]
}
]$json$::jsonb
WHERE lk.lookup = 'status_bar'
  AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(lk.lookup_json) g WHERE g.value ->> 'code' = 'oee');

-- ============ sql/mapping/get_status_bar_oee.sql ============
DROP FUNCTION IF EXISTS mapping.get_status_bar_oee(text, timestamp with time zone, integer, jsonb);
-- The OEE items of the status bar for one production line: the report of the
-- business day of p_until (log.get_oee_report), its params summed over the
-- machines of the line, the rules of production.formula 'oee-report' evaluated
-- on the sums. p_items is the items list of the status_bar lookup group
-- (code = a key of oee_json, i18n its title); the value is that key, rounded.
create function mapping.get_status_bar_oee(p_model text, p_until timestamp with time zone, p_line_id integer, p_items jsonb) returns jsonb
    stable
    language sql
as $$
    WITH day AS (
        SELECT (coalesce(p_until, now()) AT TIME ZONE 'Europe/Amsterdam')::date AS date
    ),
    params AS (
        -- the day rows of the machines of the line, every param summed
        SELECT jsonb_object_agg(kv.key, kv.total) AS param_json
        FROM (
            SELECT kv.key, sum(kv.value::numeric) AS total
            FROM day d
            CROSS JOIN LATERAL log.get_oee_report(d.date, d.date) r
            JOIN relation.resource res ON res.resource_uid = r.resource_uid
            CROSS JOIN LATERAL jsonb_each_text(r.param_json) AS kv(key, value)
            WHERE res.line_id = p_line_id
              AND r.report_date IS NOT NULL
            GROUP BY kv.key
        ) kv
    ),
    result AS (
        SELECT public.evaluate_many_nas(gf.formula_json, p.param_json) AS oee_json
        FROM params p
        CROSS JOIN production.get_formula(array['oee-report']) gf
        WHERE p.param_json IS NOT NULL
    )
    SELECT coalesce(jsonb_agg(
               jsonb_build_object(
                   'code',  i.value ->> 'code',
                   'i18n',  i.value -> 'i18n',
                   'value', round(coalesce((res.oee_json ->> (i.value ->> 'code'))::numeric, 0), 1))
               ORDER BY i.ordinality), '[]'::jsonb)
    FROM jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) WITH ORDINALITY AS i
    LEFT JOIN result res ON true;
$$;

alter function mapping.get_status_bar_oee(text, timestamp with time zone, integer, jsonb) owner to xfw3;

-- ============ sql/mapping/get_status_bar.sql ============
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
                            WHEN 'oee'            THEN mapping.get_status_bar_oee(p_model, p_until, v_line.line_id, grp->'items')
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

-- ============ check ============
-- expected: the group oee once, with one item
SELECT g.value ->> 'code' AS code, jsonb_array_length(coalesce(g.value -> 'items', '[]'::jsonb)) AS items
FROM legacy.lookup lk, jsonb_array_elements(lk.lookup_json) g WHERE lk.lookup = 'status_bar';

-- expected: per line of the sheet model the oee item with one value, OEE planned (0 on a day without production)
SELECT s.status_json ->> 'production_line_name' AS line,
       (SELECT i.value -> 'data' FROM jsonb_array_elements(s.status_json -> 'items') i WHERE i.value ->> 'code' = 'oee') AS oee
FROM mapping.get_status_bar('sheet', now() - interval '1 day') s;
