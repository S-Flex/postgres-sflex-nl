-- The status bar (43) gets a group nests: the nests of today on the lines of
-- the production line's line type, how many, their m2 and the average waste,
-- plain figures without colour, like the file inflow. A click opens the nest
-- waste page. Carries the whole status_bar lookup (so it includes the
-- file-inflow group of sql/update_status_bar_file_inflow.sql as well) and the
-- dispatch in mapping.get_status_bar. Mirror: json/lookup/legacy/status_bar.json.
BEGIN;

-- the groups of the bar
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
  },
  {
    "nav": {
      "path": "(window:nest-waste)",
      "params": [
        {
          "key": "model",
          "is_query_param": true
        }
      ]
    },
    "src": "nests",
    "code": "nests",
    "i18n": {
      "de": {
        "title": "Nester"
      },
      "en": {
        "title": "Nests"
      },
      "es": {
        "title": "Nidos"
      },
      "fr": {
        "title": "Imbrications"
      },
      "nl": {
        "title": "Nesten"
      },
      "uk": {
        "title": "Нести"
      }
    }
  }
]$json$::jsonb WHERE lookup = 'status_bar';

-- ============ sql/mapping/get_status_bar_nests.sql ============
-- The nest items of the status bar (data_group 43, group nests): the nests
-- nested today (Amsterdam day of nested_at) on the production lines of the
-- line type of the production line: how many, their area in m2 (width x
-- height x amount, the dimensions are cm) and the average waste percentage.
-- No colour: plain figures, like the file inflow. A click on the group opens
-- the nest waste page (the nav of the group in the status_bar lookup).
create or replace function mapping.get_status_bar_nests(p_line_id integer) returns jsonb
	stable
	language sql
as $$
    WITH nest AS (
        SELECT coalesce(n.amount, 1)                              AS amount,
               n.width * n.height / 10000 * coalesce(n.amount, 1) AS sqm,
               (n.nest_json ->> 'waste_percentage')::numeric      AS waste_percentage
        FROM legacy.nest n
        JOIN relation.production_line pl ON pl.line_id = (n.nest_json ->> 'production_line_id')::integer
        WHERE (n.nested_at AT TIME ZONE 'Europe/Amsterdam')::date = (now() AT TIME ZONE 'Europe/Amsterdam')::date
          AND pl.line_type = (SELECT l.line_type FROM relation.production_line l WHERE l.line_id = p_line_id)
    ),
    total AS (
        SELECT count(*)::integer                       AS nests,
               round(coalesce(sum(sqm), 0))::integer   AS sqm,
               round(avg(waste_percentage), 1)         AS avg_waste_percentage
        FROM nest
    )
    SELECT jsonb_build_array(
               jsonb_build_object('code', 'nests',
                                  'i18n', jsonb_build_object('de', jsonb_build_object('title', 'Nester'),
                                                             'en', jsonb_build_object('title', 'Nests'),
                                                             'es', jsonb_build_object('title', 'Nidos'),
                                                             'fr', jsonb_build_object('title', 'Imbrications'),
                                                             'nl', jsonb_build_object('title', 'Nesten'),
                                                             'uk', jsonb_build_object('title', 'Нести')),
                                  'value', t.nests),
               jsonb_build_object('code', 'sqm',
                                  'i18n', jsonb_build_object('de', jsonb_build_object('title', 'm²'),
                                                             'en', jsonb_build_object('title', 'm²'),
                                                             'es', jsonb_build_object('title', 'm²'),
                                                             'fr', jsonb_build_object('title', 'm²'),
                                                             'nl', jsonb_build_object('title', 'm²'),
                                                             'uk', jsonb_build_object('title', 'м²')),
                                  'value', t.sqm),
               jsonb_build_object('code', 'avg-waste',
                                  'i18n', jsonb_build_object('de', jsonb_build_object('title', 'Gem. Abfall %'),
                                                             'en', jsonb_build_object('title', 'Avg. waste %'),
                                                             'es', jsonb_build_object('title', 'Desperdicio medio %'),
                                                             'fr', jsonb_build_object('title', 'Déchet moyen %'),
                                                             'nl', jsonb_build_object('title', 'Gem. afval %'),
                                                             'uk', jsonb_build_object('title', 'Сер. відходи %')),
                                  'value', coalesce(t.avg_waste_percentage, 0)))
    FROM total t;
$$;

alter function mapping.get_status_bar_nests(integer) owner to xfw3;

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

-- check: the items of line 5 (sheet)
SELECT mapping.get_status_bar_nests(5);
