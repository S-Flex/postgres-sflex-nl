-- The shift employees per production line and day (docs/plan-oee-report.md §11):
--   1. legacy.get_resource_shift_employees(p_production_line_id, p_business_date) replaces
--      the (p_model, p_until) version: the OEE report opens the sidebar shift with
--      the line and the day of the column, the status bar with the line.
--   2. mapping.get_status_bar_teams(p_production_line_id, p_business_date) and
--      mapping.get_status_bar, which now asks the teams per line.
--   3. legacy.lookup status_bar: the nav of the teams group passes
--      production_line_id and date (json/lookup/legacy/status_bar.json is the source).
--   4. data_group resource_shift_employees: params production_line_id and date
--      (json/data_group/resource_shift_employees.json is the source).
--   5. the sidebar oee is renamed production-planning-info (pages.json, the menu
--      item resource.oee, now titled Planning): the nav in production_line_overview
--      follows, in place.
-- The data_table get_resource_shift_employees must point at the legacy function
-- (the check at the end shows it).
-- Rollback: sql/update_shift_employees_line_down.sql.
BEGIN;

-- ============ sql/legacy/get_resource_shift_employees.sql ============
-- The employees planned on the department resources of one production line
-- on one day: log.hr_shift_planning by the line's resources, the shift type of
-- an employee from the clock data. p_production_line_id and p_business_date since 15 Sep
-- 2026 (the OEE report and the status bar open the sidebar with them).
drop function if exists legacy.get_resource_shift_employees(text, timestamp with time zone);
drop function if exists legacy.get_resource_shift_employees(integer, date);

create function legacy.get_resource_shift_employees(p_production_line_id integer, p_business_date date DEFAULT current_date) returns TABLE(shift_planning_id integer, shift_type text, content jsonb, department_group_id integer, start_at timestamp with time zone, group_name text, employee_id integer, personnel_number text, first_name text, infix text, last_name text, contract_type text)
	stable
	language sql
as $$
WITH matching_resources AS (
    -- the resources of the production line
    SELECT r.resource_uid
    FROM relation.resource r
    WHERE r.line_id = p_production_line_id
),
plans AS (
    -- the shift planning of the day
    SELECT
        sp.shift_planning_id,
        sp.department_group_id,
        sp.business_date,
        (sp.shift_json->>'start_at')::timestamptz AS start_at,
        sp.shift_json
    FROM log.hr_shift_planning sp
    JOIN matching_resources mr ON mr.resource_uid = sp.shift_json->>'resource_uid'
    WHERE sp.business_date = coalesce(p_business_date, current_date)
),
shift_lookup AS (
    SELECT item->>'code' AS code, item->'block'->'i18n' AS block
    FROM legacy.lookup lu
    CROSS JOIN LATERAL jsonb_array_elements(lu.lookup_json) AS item
    WHERE lu.lookup = 'lookup_shift'
)
SELECT DISTINCT
    p.shift_planning_id,
    hd.shift                        AS shift_type,
    sl.block                        AS content,
    p.department_group_id,
    p.start_at,
    grp->>'group'                   AS group_name,
    (emp->>'employee_id')::integer  AS employee_id,
    emp->>'personnel_number'        AS personnel_number,
    emp->>'first_name'              AS first_name,
    NULLIF(emp->>'infix', '')       AS infix,
    emp->>'last_name'               AS last_name,
    emp->>'contract_type'           AS contract_type
FROM plans p
CROSS JOIN LATERAL jsonb_array_elements(p.shift_json->'plan'->'groups') AS grp
CROSS JOIN LATERAL jsonb_array_elements(grp->'employees')               AS emp
-- Shift type (day/night) comes from the clock data, per employee per business date
LEFT JOIN LATERAL (
    SELECT h.shift
    FROM log.hr_data h
    WHERE h.employee_id = (emp->>'employee_id')::integer
      AND h.business_date = p.business_date
    ORDER BY h.start_at DESC
    LIMIT 1
) hd ON true
LEFT JOIN shift_lookup sl ON sl.code = hd.shift
ORDER BY p.department_group_id, group_name, last_name, first_name;
$$;

alter function legacy.get_resource_shift_employees(integer, date) owner to xfw3;

-- ============ sql/mapping/get_status_bar_teams.sql ============
drop function if exists mapping.get_status_bar_teams(text, timestamp with time zone);
drop function if exists mapping.get_status_bar_teams(integer, date);

create function mapping.get_status_bar_teams(p_production_line_id integer, p_business_date date) returns jsonb
	stable
	language plpgsql
as $$
BEGIN
    RETURN (
        WITH shift AS (
            SELECT group_name, COUNT(employee_id)::integer AS amount, start_at
            FROM legacy.get_resource_shift_employees(p_production_line_id, COALESCE(p_business_date, current_date))
            GROUP BY shift_type, start_at, group_name
        ),
        latest AS (
            SELECT DISTINCT ON (group_name) group_name, amount
            FROM shift
            ORDER BY group_name, start_at DESC
        ),
        teams AS (
            SELECT
                grp->>'code'  AS code,
                grp->'i18n'   AS i18n,
                grp->>'order' AS order_key,
                COALESCE(SUM(l.amount), 0)::integer AS value
            FROM relation.lookup rl
            CROSS JOIN jsonb_array_elements(rl.lookup_json) AS grp
            LEFT JOIN latest l
                ON grp->'codes' @> to_jsonb(public.to_kebab(l.group_name))
            WHERE rl.lookup = 'lookup_teams'
            GROUP BY grp->>'code', grp->'i18n', grp->>'order'
        )
        SELECT COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'code', code,
                    'i18n', i18n,
                    'value', value
                ) ORDER BY order_key
            ),
            '[]'::jsonb
        )
        FROM teams
    );
END;
$$;

alter function mapping.get_status_bar_teams(integer, date) owner to xfw3;

-- ============ sql/mapping/get_status_bar.sql ============
create or replace function mapping.get_status_bar(p_model text DEFAULT NULL::text, p_until timestamp with time zone DEFAULT (CURRENT_DATE)::timestamp with time zone, p_production_line_id integer DEFAULT NULL::integer) returns TABLE(status_json jsonb)
	language plpgsql
as $$
#variable_conflict use_column
DECLARE
    v_line       record;
    v_bar_config jsonb;
BEGIN
    SELECT rl.lookup_json INTO v_bar_config
    FROM legacy.lookup rl
    WHERE rl.lookup = 'status_bar';

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
                            WHEN 'teams'          THEN mapping.get_status_bar_teams(v_line.line_id, (p_until AT TIME ZONE 'Europe/Amsterdam')::date)
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

-- ============ legacy.lookup status_bar ============
UPDATE legacy.lookup
SET lookup_json = $json$
[
  {
    "nav": {
      "path": "(sidebar:shift)",
      "params": [
        {
          "key": "production_line_id",
          "is_query_param": true
        },
        {
          "key": "business_date",
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
        },
        {
          "key": "line_type",
          "is_optional": true,
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
  },
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
]
$json$::jsonb
WHERE lookup = 'status_bar';

-- ============ data_group resource_shift_employees ============
UPDATE site.data_group
SET data_group_json = $json$
[
  {
    "src": [
      "get_resource_shift_employees"
    ],
    "layout": "flow-board",
    "params": [
      {
        "key": "production_line_id",
        "is_optional": true,
        "is_query_param": true
      },
      {
        "key": "business_date",
        "is_optional": true,
        "is_query_param": true
      }
    ],
    "widget_id": "resource_shift_employees",
    "field_config": {
      "infix": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Präfix"
            },
            "en": {
              "title": "Infix"
            },
            "es": {
              "title": "Partícula"
            },
            "fr": {
              "title": "Particule"
            },
            "nl": {
              "title": "Tussenvoegsel"
            },
            "uk": {
              "title": "Префікс"
            }
          },
          "order": 6
        }
      },
      "content": {
        "ui": {
          "order": 0,
          "control": "i18n-text"
        }
      },
      "start_at": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Startzeit"
            },
            "en": {
              "title": "Start time"
            },
            "es": {
              "title": "Hora de inicio"
            },
            "fr": {
              "title": "Heure de début"
            },
            "nl": {
              "title": "Starttijd"
            },
            "uk": {
              "title": "Час початку"
            }
          },
          "order": 2,
          "type": "datetime"
        }
      },
      "last_name": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Nachname"
            },
            "en": {
              "title": "Last name"
            },
            "es": {
              "title": "Apellido"
            },
            "fr": {
              "title": "Nom"
            },
            "nl": {
              "title": "Achternaam"
            },
            "uk": {
              "title": "Прізвище"
            }
          },
          "order": 7
        }
      },
      "first_name": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Vorname"
            },
            "en": {
              "title": "First name"
            },
            "es": {
              "title": "Nombre"
            },
            "fr": {
              "title": "Prénom"
            },
            "nl": {
              "title": "Voornaam"
            },
            "uk": {
              "title": "Ім'я"
            }
          },
          "order": 5
        }
      },
      "group_name": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Funktion"
            },
            "en": {
              "title": "Role"
            },
            "es": {
              "title": "Función"
            },
            "fr": {
              "title": "Rôle"
            },
            "nl": {
              "title": "Functie"
            },
            "uk": {
              "title": "Роль"
            }
          },
          "order": 3
        }
      },
      "shift_type": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Schicht"
            },
            "en": {
              "title": "Shift"
            },
            "es": {
              "title": "Turno"
            },
            "fr": {
              "title": "Équipe"
            },
            "nl": {
              "title": "Dienst"
            },
            "uk": {
              "title": "Зміна"
            }
          },
          "order": 0
        }
      },
      "employee_id": {
        "ui": {
          "hidden": true
        }
      },
      "contract_type": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Vertragstyp"
            },
            "en": {
              "title": "Contract type"
            },
            "es": {
              "title": "Tipo de contrato"
            },
            "fr": {
              "title": "Type de contrat"
            },
            "nl": {
              "title": "Contracttype"
            },
            "uk": {
              "title": "Тип контракту"
            }
          },
          "order": 8,
          "control": "badge"
        }
      },
      "personnel_number": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Personalnummer"
            },
            "en": {
              "title": "Personnel number"
            },
            "es": {
              "title": "Número de personal"
            },
            "fr": {
              "title": "Numéro de personnel"
            },
            "nl": {
              "title": "Personeelsnummer"
            },
            "uk": {
              "title": "Табельний номер"
            }
          },
          "order": 4
        }
      },
      "department_group_id": {
        "ui": {
          "hidden": true
        }
      },
      "resource_data_log_id": {
        "ui": {
          "hidden": true
        }
      },
      "department_group_name": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Abteilung"
            },
            "en": {
              "title": "Department"
            },
            "es": {
              "title": "Departamento"
            },
            "fr": {
              "title": "Département"
            },
            "nl": {
              "title": "Afdeling"
            },
            "uk": {
              "title": "Відділ"
            }
          },
          "order": 1
        }
      }
    },
    "flow_board_config": {
      "layout": "flow-grid",
      "children": [
        {
          "layout": "flow-container",
          "children": [
            {
              "layout": "flow-cards",
              "group_by": [
                "employee_id"
              ],
              "row_options": {
                "colexp": false,
                "checkable": false,
                "selectable": true
              },
              "field_config": {
                "infix": {
                  "ui": {
                    "i18n": {
                      "de": {
                        "title": "Präfix"
                      },
                      "en": {
                        "title": "Infix"
                      },
                      "es": {
                        "title": "Partícula"
                      },
                      "fr": {
                        "title": "Particule"
                      },
                      "nl": {
                        "title": "Tussenvoegsel"
                      },
                      "uk": {
                        "title": "Префікс"
                      }
                    },
                    "order": 1,
                    "class_name": "col-span-1"
                  }
                },
                "last_name": {
                  "ui": {
                    "i18n": {
                      "de": {
                        "title": "Nachname"
                      },
                      "en": {
                        "title": "Last name"
                      },
                      "es": {
                        "title": "Apellido"
                      },
                      "fr": {
                        "title": "Nom"
                      },
                      "nl": {
                        "title": "Achternaam"
                      },
                      "uk": {
                        "title": "Прізвище"
                      }
                    },
                    "order": 2,
                    "class_name": "col-span-3"
                  }
                },
                "first_name": {
                  "ui": {
                    "i18n": {
                      "de": {
                        "title": "Vorname"
                      },
                      "en": {
                        "title": "First name"
                      },
                      "es": {
                        "title": "Nombre"
                      },
                      "fr": {
                        "title": "Prénom"
                      },
                      "nl": {
                        "title": "Voornaam"
                      },
                      "uk": {
                        "title": "Ім'я"
                      }
                    },
                    "order": 0,
                    "class_name": "col-span-2"
                  }
                },
                "contract_type": {
                  "ui": {
                    "i18n": {
                      "de": {
                        "title": "Vertragstyp"
                      },
                      "en": {
                        "title": "Contract type"
                      },
                      "es": {
                        "title": "Tipo de contrato"
                      },
                      "fr": {
                        "title": "Type de contrat"
                      },
                      "nl": {
                        "title": "Contracttype"
                      },
                      "uk": {
                        "title": "Тип контракту"
                      }
                    },
                    "order": 4,
                    "control": "badge",
                    "class_name": "col-span-3  text-right"
                  }
                },
                "personnel_number": {
                  "ui": {
                    "i18n": {
                      "de": {
                        "title": "Personalnummer"
                      },
                      "en": {
                        "title": "Personnel number"
                      },
                      "es": {
                        "title": "Número de personal"
                      },
                      "fr": {
                        "title": "Numéro de personnel"
                      },
                      "nl": {
                        "title": "Personeelsnummer"
                      },
                      "uk": {
                        "title": "Табельний номер"
                      }
                    },
                    "order": 3,
                    "class_name": "col-span-3"
                  }
                }
              },
              "fields_class_name": "@container grid grid-cols-6 gap-1 @xl:grid-cols-12"
            }
          ],
          "group_by": [
            "group_name"
          ],
          "row_options": {
            "colexp": true,
            "checkable": false,
            "selectable": false
          },
          "field_config": {
            "group_name": {
              "ui": {
                "i18n": {
                  "de": {
                    "title": "Funktion"
                  },
                  "en": {
                    "title": "Role"
                  },
                  "es": {
                    "title": "Función"
                  },
                  "fr": {
                    "title": "Rôle"
                  },
                  "nl": {
                    "title": "Functie"
                  },
                  "uk": {
                    "title": "Роль"
                  }
                },
                "order": 0,
                "class_name": "col-span-4"
              }
            },
            "employee_id": {
              "ui": {
                "i18n": {
                  "de": {
                    "title": "Anzahl"
                  },
                  "en": {
                    "title": "Count"
                  },
                  "es": {
                    "title": "Cantidad"
                  },
                  "fr": {
                    "title": "Nombre"
                  },
                  "nl": {
                    "title": "Aantal"
                  },
                  "uk": {
                    "title": "Кількість"
                  }
                },
                "order": 1,
                "control": "chip",
                "class_name": "col-span-2  text-right"
              },
              "aggregate_fn": "count"
            }
          },
          "fields_class_name": "grid grid-cols-6 gap-1"
        }
      ],
      "group_by": [
        "shift_type"
      ],
      "row_options": {
        "colexp": false,
        "checkable": false,
        "selectable": false
      },
      "field_config": {
        "content": {
          "ui": {
            "i18n": {
              "de": {
                "title": "Schicht"
              },
              "en": {
                "title": "Shift"
              },
              "es": {
                "title": "Turno"
              },
              "fr": {
                "title": "Équipe"
              },
              "nl": {
                "title": "Dienst"
              },
              "uk": {
                "title": "Зміна"
              }
            },
            "order": 0,
            "control": "i18n-text",
            "class_name": "col-span-4"
          }
        },
        "shift_type": {
          "ui": {
            "hidden": true
          }
        },
        "employee_id": {
          "ui": {
            "i18n": {
              "de": {
                "title": "Anzahl"
              },
              "en": {
                "title": "Count"
              },
              "es": {
                "title": "Cantidad"
              },
              "fr": {
                "title": "Nombre"
              },
              "nl": {
                "title": "Aantal"
              },
              "uk": {
                "title": "Кількість"
              }
            },
            "order": 1,
            "control": "chip",
            "class_name": "col-span-2  text-right"
          },
          "aggregate_fn": "count"
        }
      },
      "fields_class_name": "grid grid-cols-6 gap-1"
    },
    "window_class_name": "p-8"
  }
]
$json$::jsonb
WHERE data_group = 'resource_shift_employees';

-- ============ the renamed sidebar in the data_groups ============
UPDATE site.data_group
SET data_group_json = replace(data_group_json::text, '(sidebar:oee)', '(sidebar:production-planning-info)')::jsonb
WHERE data_group_json::text LIKE '%(sidebar:oee)%';

COMMIT;

-- expected: the data_table points at legacy.get_resource_shift_employees; the sheet line's employees of yesterday; the status bar of the line
SELECT data_table, query FROM site.data_table WHERE data_table = 'get_resource_shift_employees';

SELECT group_name, count(*) AS employees
FROM legacy.get_resource_shift_employees((SELECT min(line_id) FROM relation.production_line WHERE line_type = 'sheet' AND tenant_id = 1), current_date - 1)
GROUP BY 1 ORDER BY 1;

SELECT s.status_json ->> 'production_line_name' AS line,
       (SELECT i -> 'data' FROM jsonb_array_elements(s.status_json -> 'items') i WHERE i ->> 'code' = 'teams') AS teams
FROM mapping.get_status_bar(p_production_line_id := (SELECT min(line_id) FROM relation.production_line WHERE line_type = 'sheet' AND tenant_id = 1)) s;
