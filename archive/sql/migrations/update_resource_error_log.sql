-- The error log of a resource in the sidebar (15 Sep 2026): the read
-- log.get_resource_error_log(p_resource_uid, p_error_date, p_look_back_days), its
-- data_table, and the data_group resource_error_log (json/data_group/resource_error_log.json
-- is the source): a container per day, newest first, a card per error with
-- every column of log.error. The page error-log and the menu item
-- resource.error-log live in json/data (pages.json, menu-items.json).
-- Rollback: sql/update_resource_error_log_down.sql.
BEGIN;

-- ============ sql/log/get_resource_error_log.sql ============
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

-- ============ site.data_table ============
INSERT INTO site.data_table (data_table, query, stored_proc, description, data_table_json, do_cache)
VALUES ('get_resource_error_log', 'log.get_resource_error_log', '',
        'the error log of one resource: the errors of the day and the days before it, newest first',
        '{"primary_keys": ["error_log_id"]}'::jsonb, false)
ON CONFLICT (data_table) DO UPDATE
    SET query           = EXCLUDED.query,
        description     = EXCLUDED.description,
        data_table_json = EXCLUDED.data_table_json;

-- ============ the data_group ============
SELECT setval('site.data_group_data_group_id_seq1', (SELECT max(data_group_id) FROM site.data_group)),
       setval('site.data_group_data_group_id_seq',  (SELECT max(data_group_id) FROM site.data_group));

INSERT INTO site.data_group (data_group, data_group_json)
VALUES ('resource_error_log', $json$
[
  {
    "src": [
      "get_resource_error_log"
    ],
    "layout": "flow-board",
    "params": [
      {
        "key": "resource_uid",
        "is_query_param": true
      },
      {
        "key": "error_date",
        "is_optional": true,
        "is_query_param": true
      },
      {
        "key": "look_back_days",
        "is_optional": true,
        "is_query_param": true
      }
    ],
    "children": [],
    "widget_id": "resource_error_log",
    "window_class_name": "p-8",
    "field_config": {
      "error_log_id": {
        "ui": {
          "hidden": true
        }
      },
      "resource_uid": {
        "ui": {
          "hidden": true
        }
      },
      "error_date": {
        "ui": {
          "type": "date",
          "i18n": {
            "nl": {
              "title": "Datum"
            },
            "en": {
              "title": "Date"
            },
            "de": {
              "title": "Datum"
            },
            "fr": {
              "title": "Date"
            },
            "es": {
              "title": "Fecha"
            },
            "uk": {
              "title": "Дата"
            }
          }
        }
      },
      "start_at": {
        "ui": {
          "type": "datetime",
          "i18n": {
            "nl": {
              "title": "Begin"
            },
            "en": {
              "title": "Start"
            },
            "de": {
              "title": "Beginn"
            },
            "fr": {
              "title": "Début"
            },
            "es": {
              "title": "Inicio"
            },
            "uk": {
              "title": "Початок"
            }
          }
        }
      },
      "end_at": {
        "ui": {
          "type": "datetime",
          "i18n": {
            "nl": {
              "title": "Einde"
            },
            "en": {
              "title": "End"
            },
            "de": {
              "title": "Ende"
            },
            "fr": {
              "title": "Fin"
            },
            "es": {
              "title": "Fin"
            },
            "uk": {
              "title": "Кінець"
            }
          }
        }
      },
      "duration": {
        "ui": {
          "type": "duration",
          "format": "hh:mm",
          "i18n": {
            "nl": {
              "title": "Duur"
            },
            "en": {
              "title": "Duration"
            },
            "de": {
              "title": "Dauer"
            },
            "fr": {
              "title": "Durée"
            },
            "es": {
              "title": "Duración"
            },
            "uk": {
              "title": "Тривалість"
            }
          }
        }
      },
      "severity": {
        "ui": {
          "control": "badge",
          "i18n": {
            "nl": {
              "title": "Ernst"
            },
            "en": {
              "title": "Severity"
            },
            "de": {
              "title": "Schwere"
            },
            "fr": {
              "title": "Gravité"
            },
            "es": {
              "title": "Gravedad"
            },
            "uk": {
              "title": "Серйозність"
            }
          }
        }
      },
      "code": {
        "ui": {
          "i18n": {
            "nl": {
              "title": "Code"
            },
            "en": {
              "title": "Code"
            },
            "de": {
              "title": "Code"
            },
            "fr": {
              "title": "Code"
            },
            "es": {
              "title": "Código"
            },
            "uk": {
              "title": "Код"
            }
          }
        }
      },
      "message": {
        "ui": {
          "i18n": {
            "nl": {
              "title": "Melding"
            },
            "en": {
              "title": "Message"
            },
            "de": {
              "title": "Meldung"
            },
            "fr": {
              "title": "Message"
            },
            "es": {
              "title": "Mensaje"
            },
            "uk": {
              "title": "Повідомлення"
            }
          }
        }
      },
      "context_json.subsystem": {
        "ui": {
          "i18n": {
            "nl": {
              "title": "Subsysteem"
            },
            "en": {
              "title": "Subsystem"
            },
            "de": {
              "title": "Subsystem"
            },
            "fr": {
              "title": "Sous-système"
            },
            "es": {
              "title": "Subsistema"
            },
            "uk": {
              "title": "Підсистема"
            }
          }
        }
      },
      "context_json.description": {
        "ui": {
          "i18n": {
            "nl": {
              "title": "Omschrijving"
            },
            "en": {
              "title": "Description"
            },
            "de": {
              "title": "Beschreibung"
            },
            "fr": {
              "title": "Description"
            },
            "es": {
              "title": "Descripción"
            },
            "uk": {
              "title": "Опис"
            }
          }
        }
      },
      "context_json.instance_info": {
        "ui": {
          "i18n": {
            "nl": {
              "title": "Instantie"
            },
            "en": {
              "title": "Instance"
            },
            "de": {
              "title": "Instanz"
            },
            "fr": {
              "title": "Instance"
            },
            "es": {
              "title": "Instancia"
            },
            "uk": {
              "title": "Екземпляр"
            }
          }
        }
      },
      "context_json.detail_type": {
        "ui": {
          "i18n": {
            "nl": {
              "title": "Soort"
            },
            "en": {
              "title": "Detail type"
            },
            "de": {
              "title": "Art"
            },
            "fr": {
              "title": "Type"
            },
            "es": {
              "title": "Tipo"
            },
            "uk": {
              "title": "Тип"
            }
          }
        }
      },
      "context_json.mapped_state": {
        "ui": {
          "i18n": {
            "nl": {
              "title": "Status"
            },
            "en": {
              "title": "Mapped state"
            },
            "de": {
              "title": "Status"
            },
            "fr": {
              "title": "État"
            },
            "es": {
              "title": "Estado"
            },
            "uk": {
              "title": "Стан"
            }
          }
        }
      },
      "context_json.fw_error_code": {
        "ui": {
          "i18n": {
            "nl": {
              "title": "Firmware code"
            },
            "en": {
              "title": "Firmware code"
            },
            "de": {
              "title": "Firmware-Code"
            },
            "fr": {
              "title": "Code firmware"
            },
            "es": {
              "title": "Código firmware"
            },
            "uk": {
              "title": "Код прошивки"
            }
          }
        }
      },
      "context_json.interruption_uuid": {
        "ui": {
          "i18n": {
            "nl": {
              "title": "Onderbreking"
            },
            "en": {
              "title": "Interruption"
            },
            "de": {
              "title": "Unterbrechung"
            },
            "fr": {
              "title": "Interruption"
            },
            "es": {
              "title": "Interrupción"
            },
            "uk": {
              "title": "Переривання"
            }
          }
        }
      },
      "source": {
        "ui": {
          "i18n": {
            "nl": {
              "title": "Bron"
            },
            "en": {
              "title": "Source"
            },
            "de": {
              "title": "Quelle"
            },
            "fr": {
              "title": "Source"
            },
            "es": {
              "title": "Origen"
            },
            "uk": {
              "title": "Джерело"
            }
          }
        }
      },
      "source_ref": {
        "ui": {
          "i18n": {
            "nl": {
              "title": "Bronreferentie"
            },
            "en": {
              "title": "Source reference"
            },
            "de": {
              "title": "Quellreferenz"
            },
            "fr": {
              "title": "Référence source"
            },
            "es": {
              "title": "Referencia"
            },
            "uk": {
              "title": "Посилання джерела"
            }
          }
        }
      },
      "source_ts": {
        "ui": {
          "type": "datetime",
          "i18n": {
            "nl": {
              "title": "Brontijd"
            },
            "en": {
              "title": "Source time"
            },
            "de": {
              "title": "Quellzeit"
            },
            "fr": {
              "title": "Heure source"
            },
            "es": {
              "title": "Hora origen"
            },
            "uk": {
              "title": "Час джерела"
            }
          }
        }
      },
      "ingested_at": {
        "ui": {
          "type": "datetime",
          "i18n": {
            "nl": {
              "title": "Ontvangen"
            },
            "en": {
              "title": "Ingested"
            },
            "de": {
              "title": "Empfangen"
            },
            "fr": {
              "title": "Reçu"
            },
            "es": {
              "title": "Recibido"
            },
            "uk": {
              "title": "Отримано"
            }
          }
        }
      }
    },
    "flow_board_config": {
      "layout": "flow-container",
      "group_by": [
        "error_date"
      ],
      "sort": {
        "field": "error_date",
        "direction": "desc"
      },
      "row_options": {
        "colexp": true,
        "checkable": false,
        "selectable": false,
        "first_row_expanded": true
      },
      "fields_class_name": "grid grid-cols-1 gap-1",
      "field_config": {
        "error_date": {
          "ui": {
            "order": 0,
            "no_label": true,
            "class_name": "font-semibold"
          }
        }
      },
      "children": [
        {
          "layout": "flow-cards",
          "group_by": [
            "error_log_id"
          ],
          "sort": {
            "field": "start_at",
            "direction": "desc"
          },
          "row_options": {
            "colexp": false,
            "checkable": false,
            "selectable": false
          },
          "fields_class_name": "@container grid grid-cols-6 gap-1 @xl:grid-cols-12",
          "field_config": {
            "start_at": {
              "ui": {
                "order": 0,
                "class_name": "col-span-3"
              }
            },
            "end_at": {
              "ui": {
                "order": 1,
                "class_name": "col-span-3"
              }
            },
            "duration": {
              "ui": {
                "order": 2,
                "class_name": "col-span-3"
              }
            },
            "severity": {
              "ui": {
                "order": 3,
                "class_name": "col-span-3"
              }
            },
            "code": {
              "ui": {
                "order": 4,
                "class_name": "col-span-3"
              }
            },
            "message": {
              "ui": {
                "order": 5,
                "class_name": "col-span-9"
              }
            },
            "context_json.subsystem": {
              "ui": {
                "order": 6,
                "class_name": "col-span-3"
              }
            },
            "context_json.description": {
              "ui": {
                "order": 7,
                "class_name": "col-span-9"
              }
            },
            "context_json.instance_info": {
              "ui": {
                "order": 8,
                "class_name": "col-span-3"
              }
            },
            "context_json.detail_type": {
              "ui": {
                "order": 9,
                "class_name": "col-span-3"
              }
            },
            "context_json.mapped_state": {
              "ui": {
                "order": 10,
                "class_name": "col-span-3"
              }
            },
            "context_json.fw_error_code": {
              "ui": {
                "order": 11,
                "class_name": "col-span-3"
              }
            },
            "context_json.interruption_uuid": {
              "ui": {
                "order": 12,
                "class_name": "col-span-6"
              }
            },
            "source": {
              "ui": {
                "order": 13,
                "class_name": "col-span-3"
              }
            },
            "source_ref": {
              "ui": {
                "order": 14,
                "class_name": "col-span-3"
              }
            },
            "source_ts": {
              "ui": {
                "order": 15,
                "class_name": "col-span-3"
              }
            },
            "ingested_at": {
              "ui": {
                "order": 16,
                "class_name": "col-span-3"
              }
            }
          }
        }
      ]
    }
  }
]
$json$::jsonb)
ON CONFLICT (data_group) DO UPDATE SET data_group_json = EXCLUDED.data_group_json;

COMMIT;

-- expected: the errors of the resource with the most errors today, the last five days, newest first
SELECT error_date, start_at, end_at, duration, severity, code, left(message, 60) AS message, context_json ->> 'subsystem' AS subsystem
FROM log.get_resource_error_log(
         (SELECT e.resource_uid FROM log.error e WHERE e.start_at >= now() - interval '1 day' GROUP BY 1 ORDER BY count(*) DESC LIMIT 1))
LIMIT 20;

SELECT data_group_id, data_group, data_group_json -> 0 -> 'params' AS params FROM site.data_group WHERE data_group = 'resource_error_log';
