-- OEE report (docs/plan-oee-report.md), step 2: the data_groups oee_report_filter
-- and oee_report, the content of json/data_group/oee_report_filter.json and
-- json/data_group/oee_report.json (those files are the source; this script only
-- carries them into site.data_group). The page oee-report (pages.json,
-- pages-content.json, nav) shows the filter above the report and the status
-- bar in the footer.
-- Rollback: DELETE FROM site.data_group WHERE data_group IN ('oee_report', 'oee_report_filter');
BEGIN;

-- the id sequence lags behind the rows (data groups were inserted with their own
-- ids, the first run failed on id 97): put it at the highest id first
SELECT setval(pg_get_serial_sequence('site.data_group', 'data_group_id'),
              (SELECT max(data_group_id) FROM site.data_group));

INSERT INTO site.data_group (data_group, data_group_json)
VALUES ('oee_report_filter', $json$
[
  {
    "layout": "filter",
    "params": [
      { "key": "dates", "is_optional": true, "is_query_param": true },
      { "key": "line_type", "is_optional": true, "is_query_param": true },
      { "key": "tenant_ids", "is_optional": true, "is_query_param": true }
    ],
    "children": [],
    "widget_id": "oee_report_filter",
    "row_options": { "class_name": "@container grid grid-cols-12 gap-1" },
    "field_config": {
      "dates": {
        "ui": {
          "i18n": { "de": { "title": "Tage" }, "en": { "title": "Days" }, "es": { "title": "Días" }, "fr": { "title": "Jours" }, "nl": { "title": "Dagen" }, "uk": { "title": "Дні" } },
          "order": 0,
          "control": "multi-date-picker",
          "type": "datemultirange",
          "class_name": "col-span-12 @2xl:col-span-4"
        }
      },
      "line_type": {
        "ui": {
          "i18n": { "de": { "title": "Produktionslinie" }, "en": { "title": "Production line" }, "es": { "title": "Línea de producción" }, "fr": { "title": "Ligne de production" }, "nl": { "title": "Productielijn" }, "uk": { "title": "Виробнича лінія" } },
          "order": 1,
          "control": "select",
          "class_name": "col-span-12 @2xl:col-span-4",
          "input_data": {
            "data": [
              { "value": "sheet", "i18n": { "de": { "title": "Platte" }, "en": { "title": "Sheet" }, "es": { "title": "Plancha" }, "fr": { "title": "Panneau" }, "nl": { "title": "Plaat" }, "uk": { "title": "Лист" } } },
              { "value": "non-adhesive", "i18n": { "de": { "title": "UV" }, "en": { "title": "UV" }, "es": { "title": "UV" }, "fr": { "title": "UV" }, "nl": { "title": "UV" }, "uk": { "title": "UV" } } },
              { "value": "foil", "i18n": { "de": { "title": "Folie" }, "en": { "title": "Foil" }, "es": { "title": "Vinilo" }, "fr": { "title": "Film" }, "nl": { "title": "Folie" }, "uk": { "title": "Плівка" } } },
              { "value": "textile", "i18n": { "de": { "title": "Textil" }, "en": { "title": "Textile" }, "es": { "title": "Textil" }, "fr": { "title": "Textile" }, "nl": { "title": "Textiel" }, "uk": { "title": "Текстиль" } } },
              { "value": "label", "i18n": { "de": { "title": "Etiketten" }, "en": { "title": "Labels" }, "es": { "title": "Etiquetas" }, "fr": { "title": "Étiquettes" }, "nl": { "title": "Labels" }, "uk": { "title": "Етикетки" } } },
              { "value": "paper", "i18n": { "de": { "title": "Papier" }, "en": { "title": "Paper" }, "es": { "title": "Papel" }, "fr": { "title": "Papier" }, "nl": { "title": "Papier" }, "uk": { "title": "Папір" } } }
            ],
            "title_field": "title",
            "value_field": "value"
          }
        }
      },
      "tenant_ids": {
        "ui": {
          "i18n": { "de": { "title": "Standorte" }, "en": { "title": "Tenants" }, "es": { "title": "Sedes" }, "fr": { "title": "Sites" }, "nl": { "title": "Vestigingen" }, "uk": { "title": "Підрозділи" } },
          "order": 2,
          "control": "multi-select",
          "class_name": "col-span-12 @2xl:col-span-4",
          "input_data": {
            "data": [
              { "value": 1, "i18n": { "de": { "title": "Dokkum" }, "en": { "title": "Dokkum" }, "es": { "title": "Dokkum" }, "fr": { "title": "Dokkum" }, "nl": { "title": "Dokkum" }, "uk": { "title": "Доккюм" } } },
              { "value": 2, "i18n": { "de": { "title": "Bad Hersfeld" }, "en": { "title": "Bad Hersfeld" }, "es": { "title": "Bad Hersfeld" }, "fr": { "title": "Bad Hersfeld" }, "nl": { "title": "Bad Hersfeld" }, "uk": { "title": "Бад-Герсфельд" } } }
            ],
            "title_field": "title",
            "value_field": "value"
          }
        }
      }
    }
  }
]
$json$::jsonb)
ON CONFLICT (data_group) DO UPDATE SET data_group_json = EXCLUDED.data_group_json;

INSERT INTO site.data_group (data_group, data_group_json)
VALUES ('oee_report', $json$
[
  {
    "src": [
      "get_oee_report"
    ],
    "layout": "flow-board",
    "params": [
      {
        "key": "dates",
        "is_optional": true,
        "is_query_param": true
      },
      {
        "key": "from",
        "is_optional": true,
        "is_query_param": true
      },
      {
        "key": "until",
        "is_optional": true,
        "is_query_param": true
      },
      {
        "key": "line_type",
        "is_optional": true,
        "is_query_param": true
      },
      {
        "key": "tenant_ids",
        "is_optional": true,
        "is_query_param": true
      }
    ],
    "children": [],
    "widget_id": "oee_report",
    "window_class_name": "p-8",
    "field_config": {
      "report_date": {
        "ui": {
          "type": "date",
          "hidden": true
        }
      },
      "sort_order": {
        "ui": {
          "hidden": true
        }
      },
      "tenant_name": {
        "ui": {
          "i18n": {
            "nl": {
              "title": "Vestiging"
            },
            "en": {
              "title": "Tenant"
            },
            "de": {
              "title": "Standort"
            },
            "fr": {
              "title": "Site"
            },
            "es": {
              "title": "Sede"
            },
            "uk": {
              "title": "Підрозділ"
            }
          }
        }
      },
      "resource_name": {
        "ui": {
          "i18n": {
            "nl": {
              "title": "Machine"
            },
            "en": {
              "title": "Machine"
            },
            "de": {
              "title": "Maschine"
            },
            "fr": {
              "title": "Machine"
            },
            "es": {
              "title": "Máquina"
            },
            "uk": {
              "title": "Машина"
            }
          }
        }
      },
      "resource_path": {
        "ui": {
          "hidden": true
        }
      },
      "param_json.shift_duration": {
        "ui": {
          "type": "duration",
          "i18n": {
            "nl": {
              "title": "Diensttijd"
            },
            "en": {
              "title": "Shift time"
            },
            "de": {
              "title": "Schichtzeit"
            },
            "fr": {
              "title": "Temps de poste"
            },
            "es": {
              "title": "Tiempo de turno"
            },
            "uk": {
              "title": "Час зміни"
            }
          }
        }
      },
      "param_json.break_times": {
        "ui": {
          "type": "duration",
          "i18n": {
            "nl": {
              "title": "Pauzes"
            },
            "en": {
              "title": "Breaks"
            },
            "de": {
              "title": "Pausen"
            },
            "fr": {
              "title": "Pauses"
            },
            "es": {
              "title": "Pausas"
            },
            "uk": {
              "title": "Перерви"
            }
          }
        }
      },
      "param_json.has_break_times": {
        "ui": {
          "hidden": true
        }
      },
      "oee_json.availability": {
        "ui": {
          "type": "duration",
          "i18n": {
            "nl": {
              "title": "Beschikbaarheid"
            },
            "en": {
              "title": "Availability"
            },
            "de": {
              "title": "Verfügbarkeit"
            },
            "fr": {
              "title": "Disponibilité"
            },
            "es": {
              "title": "Disponibilidad"
            },
            "uk": {
              "title": "Доступність"
            }
          }
        }
      },
      "param_json.technical_failure": {
        "ui": {
          "type": "duration",
          "i18n": {
            "nl": {
              "title": "Storing"
            },
            "en": {
              "title": "Technical failure"
            },
            "de": {
              "title": "Störung"
            },
            "fr": {
              "title": "Panne"
            },
            "es": {
              "title": "Avería"
            },
            "uk": {
              "title": "Технічна несправність"
            }
          }
        }
      },
      "oee_json.technical_failure_percentage": {
        "ui": {
          "type": "percent",
          "i18n": {
            "nl": {
              "title": "Storing %"
            },
            "en": {
              "title": "Technical failure %"
            },
            "de": {
              "title": "Störung %"
            },
            "fr": {
              "title": "Panne %"
            },
            "es": {
              "title": "Avería %"
            },
            "uk": {
              "title": "Несправність %"
            }
          }
        }
      },
      "oee_json.technical_availability": {
        "ui": {
          "type": "duration",
          "i18n": {
            "nl": {
              "title": "Technische beschikbaarheid"
            },
            "en": {
              "title": "Technical availability"
            },
            "de": {
              "title": "Technische Verfügbarkeit"
            },
            "fr": {
              "title": "Disponibilité technique"
            },
            "es": {
              "title": "Disponibilidad técnica"
            },
            "uk": {
              "title": "Технічна доступність"
            }
          }
        }
      },
      "oee_json.technical_availability_percentage": {
        "ui": {
          "type": "percent",
          "i18n": {
            "nl": {
              "title": "Technische beschikbaarheid %"
            },
            "en": {
              "title": "Technical availability %"
            },
            "de": {
              "title": "Technische Verfügbarkeit %"
            },
            "fr": {
              "title": "Disponibilité technique %"
            },
            "es": {
              "title": "Disponibilidad técnica %"
            },
            "uk": {
              "title": "Технічна доступність %"
            }
          }
        }
      },
      "param_json.planned": {
        "ui": {
          "type": "duration",
          "i18n": {
            "nl": {
              "title": "Gepland"
            },
            "en": {
              "title": "Planned"
            },
            "de": {
              "title": "Geplant"
            },
            "fr": {
              "title": "Planifié"
            },
            "es": {
              "title": "Planificado"
            },
            "uk": {
              "title": "Заплановано"
            }
          }
        }
      },
      "oee_json.not_planned": {
        "ui": {
          "type": "duration",
          "i18n": {
            "nl": {
              "title": "Niet gepland"
            },
            "en": {
              "title": "Not planned"
            },
            "de": {
              "title": "Nicht geplant"
            },
            "fr": {
              "title": "Non planifié"
            },
            "es": {
              "title": "No planificado"
            },
            "uk": {
              "title": "Не заплановано"
            }
          }
        }
      },
      "oee_json.not_planned_percentage": {
        "ui": {
          "type": "percent",
          "i18n": {
            "nl": {
              "title": "Niet gepland %"
            },
            "en": {
              "title": "Not planned %"
            },
            "de": {
              "title": "Nicht geplant %"
            },
            "fr": {
              "title": "Non planifié %"
            },
            "es": {
              "title": "No planificado %"
            },
            "uk": {
              "title": "Не заплановано %"
            }
          }
        }
      },
      "param_json.producing": {
        "ui": {
          "type": "duration",
          "i18n": {
            "nl": {
              "title": "Producerend"
            },
            "en": {
              "title": "Producing"
            },
            "de": {
              "title": "Produzierend"
            },
            "fr": {
              "title": "En production"
            },
            "es": {
              "title": "Produciendo"
            },
            "uk": {
              "title": "Виробництво"
            }
          }
        }
      },
      "param_json.plan_calibrated": {
        "ui": {
          "type": "duration",
          "i18n": {
            "nl": {
              "title": "Plan gekalibreerd"
            },
            "en": {
              "title": "Plan calibrated"
            },
            "de": {
              "title": "Plan kalibriert"
            },
            "fr": {
              "title": "Plan calibré"
            },
            "es": {
              "title": "Plan calibrado"
            },
            "uk": {
              "title": "План калібрований"
            }
          }
        }
      },
      "oee_json.not_planned_calibrated": {
        "ui": {
          "type": "duration",
          "i18n": {
            "nl": {
              "title": "Niet gepland gekalibreerd"
            },
            "en": {
              "title": "Not planned calibrated"
            },
            "de": {
              "title": "Nicht geplant kalibriert"
            },
            "fr": {
              "title": "Non planifié calibré"
            },
            "es": {
              "title": "No planificado calibrado"
            },
            "uk": {
              "title": "Не заплановано калібровано"
            }
          }
        }
      },
      "oee_json.producing_oee_planned_percentage": {
        "ui": {
          "type": "percent",
          "i18n": {
            "nl": {
              "title": "OEE gepland"
            },
            "en": {
              "title": "OEE planned"
            },
            "de": {
              "title": "OEE geplant"
            },
            "fr": {
              "title": "OEE planifié"
            },
            "es": {
              "title": "OEE planificado"
            },
            "uk": {
              "title": "OEE заплановано"
            }
          }
        }
      },
      "oee_json.producing_oee_plan_calibrated_percentage": {
        "ui": {
          "type": "percent",
          "i18n": {
            "nl": {
              "title": "OEE gekalibreerd"
            },
            "en": {
              "title": "OEE calibrated"
            },
            "de": {
              "title": "OEE kalibriert"
            },
            "fr": {
              "title": "OEE calibré"
            },
            "es": {
              "title": "OEE calibrado"
            },
            "uk": {
              "title": "OEE калібровано"
            }
          }
        }
      },
      "param_json.actual_output_sqm": {
        "ui": {
          "suffix": "m²",
          "i18n": {
            "nl": {
              "title": "Geproduceerd"
            },
            "en": {
              "title": "Actual output"
            },
            "de": {
              "title": "Produziert"
            },
            "fr": {
              "title": "Production réelle"
            },
            "es": {
              "title": "Producción real"
            },
            "uk": {
              "title": "Фактичний випуск"
            }
          }
        },
        "scale": 0
      },
      "param_json.planned_output_sqm": {
        "ui": {
          "suffix": "m²",
          "i18n": {
            "nl": {
              "title": "Gepland"
            },
            "en": {
              "title": "Planned output"
            },
            "de": {
              "title": "Geplant"
            },
            "fr": {
              "title": "Production planifiée"
            },
            "es": {
              "title": "Producción planificada"
            },
            "uk": {
              "title": "Плановий випуск"
            }
          }
        },
        "scale": 0
      },
      "oee_json.actual_output_per_second": {
        "ui": {
          "suffix": "m²/s",
          "i18n": {
            "nl": {
              "title": "Snelheid"
            },
            "en": {
              "title": "Output per second"
            },
            "de": {
              "title": "Leistung pro Sekunde"
            },
            "fr": {
              "title": "Production par seconde"
            },
            "es": {
              "title": "Producción por segundo"
            },
            "uk": {
              "title": "Випуск за секунду"
            }
          }
        },
        "scale": 4
      },
      "oee_json.overcapacity": {
        "ui": {
          "suffix": "m²",
          "i18n": {
            "nl": {
              "title": "Overcapaciteit"
            },
            "en": {
              "title": "Overcapacity"
            },
            "de": {
              "title": "Überkapazität"
            },
            "fr": {
              "title": "Surcapacité"
            },
            "es": {
              "title": "Sobrecapacidad"
            },
            "uk": {
              "title": "Надлишкова потужність"
            }
          }
        },
        "scale": 0
      },
      "param_json.planned_print_operator_duration": {
        "ui": {
          "type": "duration",
          "i18n": {
            "nl": {
              "title": "Print operators gepland"
            },
            "en": {
              "title": "Print operators planned"
            },
            "de": {
              "title": "Druckmaschinenführer geplant"
            },
            "fr": {
              "title": "Opérateurs impression planifiés"
            },
            "es": {
              "title": "Operarios de impresión planificados"
            },
            "uk": {
              "title": "Оператори друку заплановано"
            }
          }
        }
      }
    },
    "flow_board_config": {
      "layout": "flow-grid",
      "group_by": [
        "i18n.title"
      ],
      "sort": {
        "field": "sort_order",
        "direction": "asc"
      },
      "column_min_width": 320,
      "column_max_width": 420,
      "fields_class_name": "grid grid-cols-1 gap-1",
      "row_options": {
        "colexp": false
      },
      "children": [
        {
          "layout": "flow-container",
          "group_by": [
            "i18n.title"
          ],
          "evaluate": {
            "formula_field": "formula_json",
            "params_field": "param_json"
          },
          "row_options": {
            "colexp": true
          },
          "fields_class_name": "grid grid-cols-6 gap-1",
          "field_config": {
            "param_json.shift_duration": {
              "ui": {
                "order": 0,
                "class_name": "col-span-2"
              },
              "aggregate_fn": "sum"
            },
            "param_json.break_times": {
              "ui": {
                "order": 9,
                "class_name": "col-span-2"
              },
              "aggregate_fn": "sum"
            },
            "oee_json.availability": {
              "ui": {
                "order": 10,
                "class_name": "col-span-2"
              }
            },
            "param_json.producing": {
              "ui": {
                "order": 1,
                "class_name": "col-span-2"
              },
              "aggregate_fn": "sum"
            },
            "param_json.planned": {
              "ui": {
                "order": 2,
                "class_name": "col-span-2"
              },
              "aggregate_fn": "sum"
            },
            "param_json.plan_calibrated": {
              "ui": {
                "order": 3,
                "class_name": "col-span-2"
              },
              "aggregate_fn": "sum"
            },
            "param_json.technical_failure": {
              "ui": {
                "order": 4,
                "class_name": "col-span-2"
              },
              "aggregate_fn": "sum"
            },
            "param_json.actual_output_sqm": {
              "ui": {
                "order": 5,
                "class_name": "col-span-2"
              },
              "aggregate_fn": "sum"
            },
            "oee_json.technical_availability_percentage": {
              "ui": {
                "order": 6,
                "class_name": "col-span-2"
              }
            },
            "oee_json.producing_oee_planned_percentage": {
              "ui": {
                "order": 7,
                "class_name": "col-span-2"
              }
            },
            "oee_json.producing_oee_plan_calibrated_percentage": {
              "ui": {
                "order": 8,
                "class_name": "col-span-2"
              }
            }
          },
          "children": [
            {
              "layout": "flow-cards",
              "group_by": [
                "resource_path"
              ],
              "row_options": {
                "colexp": true,
                "colexp_field": "${resource_name}"
              },
              "fields_class_name": "@container grid grid-cols-6 gap-1 @xl:grid-cols-12",
              "field_config": {
                "resource_name": {
                  "ui": {
                    "order": 0,
                    "no_label": true,
                    "class_name": "col-span-3"
                  }
                },
                "tenant_name": {
                  "ui": {
                    "order": 1,
                    "no_label": true,
                    "class_name": "col-span-3"
                  }
                },
                "oee_json.producing_oee_planned_percentage": {
                  "ui": {
                    "order": 2,
                    "class_name": "col-span-2"
                  }
                },
                "oee_json.technical_availability_percentage": {
                  "ui": {
                    "order": 3,
                    "class_name": "col-span-2"
                  }
                },
                "param_json.producing": {
                  "ui": {
                    "order": 4,
                    "class_name": "col-span-2"
                  }
                }
              },
              "children": [
                {
                  "layout": "flow-table",
                  "fields_class_name": "grid grid-cols-4 gap-1",
                  "field_config": {
                    "param_json.shift_duration": {
                      "ui": {
                        "order": 0
                      }
                    },
                    "param_json.break_times": {
                      "ui": {
                        "order": 1
                      }
                    },
                    "oee_json.availability": {
                      "ui": {
                        "order": 2
                      }
                    },
                    "param_json.technical_failure": {
                      "ui": {
                        "order": 1
                      }
                    },
                    "oee_json.technical_failure_percentage": {
                      "ui": {
                        "order": 2
                      }
                    },
                    "oee_json.technical_availability": {
                      "ui": {
                        "order": 3
                      }
                    },
                    "oee_json.technical_availability_percentage": {
                      "ui": {
                        "order": 4
                      }
                    },
                    "param_json.planned": {
                      "ui": {
                        "order": 5
                      }
                    },
                    "oee_json.not_planned": {
                      "ui": {
                        "order": 6
                      }
                    },
                    "oee_json.not_planned_percentage": {
                      "ui": {
                        "order": 7
                      }
                    },
                    "param_json.producing": {
                      "ui": {
                        "order": 8
                      }
                    },
                    "param_json.plan_calibrated": {
                      "ui": {
                        "order": 9
                      }
                    },
                    "oee_json.not_planned_calibrated": {
                      "ui": {
                        "order": 10
                      }
                    },
                    "oee_json.producing_oee_planned_percentage": {
                      "ui": {
                        "order": 11
                      }
                    },
                    "oee_json.producing_oee_plan_calibrated_percentage": {
                      "ui": {
                        "order": 12
                      }
                    },
                    "param_json.actual_output_sqm": {
                      "ui": {
                        "order": 13
                      }
                    },
                    "param_json.planned_output_sqm": {
                      "ui": {
                        "order": 14
                      }
                    },
                    "oee_json.actual_output_per_second": {
                      "ui": {
                        "order": 15
                      }
                    },
                    "oee_json.overcapacity": {
                      "ui": {
                        "order": 16
                      }
                    },
                    "param_json.planned_print_operator_duration": {
                      "ui": {
                        "order": 17
                      }
                    }
                  }
                }
              ]
            }
          ]
        }
      ]
    }
  }
]
$json$::jsonb)
ON CONFLICT (data_group) DO UPDATE SET data_group_json = EXCLUDED.data_group_json;

COMMIT;

-- expected: two rows, layouts filter and flow-board
SELECT data_group_id, data_group, data_group_json -> 0 ->> 'layout' AS layout, data_group_json -> 0 -> 'src' AS src
FROM site.data_group WHERE data_group IN ('oee_report', 'oee_report_filter') ORDER BY data_group;
