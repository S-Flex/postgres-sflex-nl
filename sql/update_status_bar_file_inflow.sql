-- The status bar (43) gets a group file-inflow: one item per cut-off window of
-- today for the line type of the production line, the files received so far.
-- No colour and no alert: the inflow comes from the customers and is out of
-- our hands, the bar only shows it. The items come from legacy.get_file_inflow,
-- the read of board 63, so bar and board agree; a click opens that board.
-- Mirror: json/lookup/legacy/status_bar.json.
BEGIN;

-- the group in the bar
UPDATE legacy.lookup SET lookup_json = $json$[
  {
    "nav": {
      "path": "(sidebar:shift)",
      "params": [
        {
          "key": "model",
          "is_query_param": true
        },
        {
          "key": "until",
          "is_optional": true,
          "is_query_param": true
        }
      ]
    },
    "src": "teams",
    "code": "teams",
    "i18n": {
      "de": {
        "title": "Teams"
      },
      "en": {
        "title": "Teams"
      },
      "es": {
        "title": "Equipos"
      },
      "fr": {
        "title": "Équipes"
      },
      "nl": {
        "title": "Teams"
      },
      "uk": {
        "title": "Команди"
      }
    }
  },
  {
    "nav": {
      "path": "(sidebar:time-on-status)",
      "params": [
        {
          "key": "model",
          "is_query_param": true
        },
        {
          "key": "from",
          "is_optional": true,
          "is_query_param": true
        }
      ]
    },
    "src": "time_on_status",
    "code": "time-on-status",
    "i18n": {
      "de": {
        "title": "Zeit im Status"
      },
      "en": {
        "title": "Time on status"
      },
      "es": {
        "title": "Tiempo en estado"
      },
      "fr": {
        "title": "Temps sur statut"
      },
      "nl": {
        "title": "Tijd op status"
      },
      "uk": {
        "title": "Час у статусі"
      }
    }
  },
  {
    "nav": {
      "path": "(sidebar:capacity)",
      "params": [
        {
          "key": "model",
          "is_query_param": true
        }
      ]
    },
    "src": "capacity",
    "code": "capacity",
    "i18n": {
      "de": {
        "title": "Kapazität"
      },
      "en": {
        "title": "Capacity"
      },
      "es": {
        "title": "Capacidad"
      },
      "fr": {
        "title": "Capacité"
      },
      "nl": {
        "title": "Capaciteit"
      },
      "uk": {
        "title": "Потужність"
      }
    },
    "steps": [
      {
        "i18n": {
          "de": {
            "title": "Druck"
          },
          "en": {
            "title": "Print"
          },
          "es": {
            "title": "Impresión"
          },
          "fr": {
            "title": "Impression"
          },
          "nl": {
            "title": "Print"
          },
          "uk": {
            "title": "Друк"
          }
        },
        "step": "print"
      },
      {
        "i18n": {
          "de": {
            "title": "Schnitt"
          },
          "en": {
            "title": "Cut"
          },
          "es": {
            "title": "Corte"
          },
          "fr": {
            "title": "Coupe"
          },
          "nl": {
            "title": "Snij"
          },
          "uk": {
            "title": "Різка"
          }
        },
        "step": "cut"
      }
    ]
  },
  {
    "nav": {
      "path": "(sidebar:rework-trend)",
      "params": [
        {
          "key": "model",
          "is_query_param": true
        },
        {
          "key": "production_line_id",
          "is_query_param": true
        }
      ]
    },
    "src": "rework",
    "code": "rework",
    "i18n": {
      "de": {
        "title": "Nacharbeit"
      },
      "en": {
        "title": "Rework"
      },
      "es": {
        "title": "Reproceso"
      },
      "fr": {
        "title": "Reprise"
      },
      "nl": {
        "title": "Herstel"
      },
      "uk": {
        "title": "Переробка"
      }
    }
  },
  {
    "nav": {
      "path": "(window:file-inflow)",
      "params": [
        {
          "key": "model",
          "is_query_param": true
        }
      ]
    },
    "src": "file_inflow",
    "code": "file-inflow",
    "i18n": {
      "de": {
        "title": "Dateieingang"
      },
      "en": {
        "title": "File inflow"
      },
      "es": {
        "title": "Entrada de archivos"
      },
      "fr": {
        "title": "Entrée de fichiers"
      },
      "nl": {
        "title": "Bestandsinstroom"
      },
      "uk": {
        "title": "Надходження файлів"
      }
    }
  }
]$json$::jsonb WHERE lookup = 'status_bar';

-- ============ sql/mapping/get_status_bar_file_inflow.sql ============
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

-- check: the items of line 5 (sheet), and the bar of the sheet model
SELECT mapping.get_status_bar_file_inflow(5);
SELECT status_json -> 'production_line_name' AS line, jsonb_path_query_array(status_json, '$.items[*] ? (@.code == "file-inflow").data') AS file_inflow
FROM mapping.get_status_bar(p_model => (SELECT model FROM relation.production_line WHERE line_id = 5));
