-- OEE report (docs/plan-oee-report.md), steps 2 and 4: the data_groups oee_report_filter
-- and oee_report, the content of json/data_group/oee_report_filter.json and
-- json/data_group/oee_report.json (those files are the source, refreshed from the live
-- rows 99 and 100 on 14 Sep 2026 after edits on the server; this script only
-- carries them into site.data_group). The page oee-report (pages.json,
-- pages-content.json, nav) shows the filter above the report and the status
-- bar in the footer.
-- Rollback: DELETE FROM site.data_group WHERE data_group IN ('oee_report', 'oee_report_filter');
BEGIN;

-- the id lags behind the rows: data groups were inserted with their own ids,
-- and the column has two sequences, the old serial one (which
-- pg_get_serial_sequence returns) and the identity one (seq1) the inserts
-- draw from. Both to the highest id first.
SELECT setval('site.data_group_data_group_id_seq1', (SELECT max(data_group_id) FROM site.data_group)),
       setval('site.data_group_data_group_id_seq',  (SELECT max(data_group_id) FROM site.data_group));

INSERT INTO site.data_group (data_group, data_group_json)
VALUES ('oee_report_filter', $json$
[
  {
    "layout": "filter",
    "params": [
      {
        "key": "date",
        "is_optional": true,
        "is_query_param": true
      },
      {
        "key": "step",
        "default_value": "print",
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
    "widget_id": "oee_report_filter",
    "row_options": {
      "class_name": "@container grid grid-cols-12 gap-1"
    },
    "field_config": {
      "date": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Datum"
            },
            "en": {
              "title": "Date"
            },
            "es": {
              "title": "Fecha"
            },
            "fr": {
              "title": "Date"
            },
            "nl": {
              "title": "Datum"
            },
            "uk": {
              "title": "Дата"
            }
          },
          "type": "date",
          "order": 0,
          "control": "date-picker",
          "class_name": "col-span-12 @2xl:col-span-2"
        }
      },
      "step": {
        "ui": {
          "i18n": {
            "nl": {
              "title": "Stap"
            },
            "en": {
              "title": "Step"
            },
            "de": {
              "title": "Schritt"
            },
            "fr": {
              "title": "Étape"
            },
            "es": {
              "title": "Paso"
            },
            "uk": {
              "title": "Крок"
            }
          },
          "order": 1,
          "control": "select",
          "class_name": "col-span-12 @2xl:col-span-2",
          "input_data": {
            "data": [
              {
                "value": "print",
                "i18n": {
                  "nl": {
                    "title": "Printen"
                  },
                  "en": {
                    "title": "Print"
                  },
                  "de": {
                    "title": "Drucken"
                  },
                  "fr": {
                    "title": "Impression"
                  },
                  "es": {
                    "title": "Impresión"
                  },
                  "uk": {
                    "title": "Друк"
                  }
                }
              },
              {
                "value": "coat",
                "i18n": {
                  "nl": {
                    "title": "Coaten"
                  },
                  "en": {
                    "title": "Coat"
                  },
                  "de": {
                    "title": "Beschichten"
                  },
                  "fr": {
                    "title": "Enduction"
                  },
                  "es": {
                    "title": "Recubrimiento"
                  },
                  "uk": {
                    "title": "Покриття"
                  }
                }
              },
              {
                "value": "cut",
                "i18n": {
                  "nl": {
                    "title": "Snijden"
                  },
                  "en": {
                    "title": "Cut"
                  },
                  "de": {
                    "title": "Schneiden"
                  },
                  "fr": {
                    "title": "Découpe"
                  },
                  "es": {
                    "title": "Corte"
                  },
                  "uk": {
                    "title": "Різання"
                  }
                }
              }
            ],
            "title_field": "title",
            "value_field": "value"
          }
        }
      },
      "line_type": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Produktionslinie"
            },
            "en": {
              "title": "Production line"
            },
            "es": {
              "title": "Línea de producción"
            },
            "fr": {
              "title": "Ligne de production"
            },
            "nl": {
              "title": "Productielijn"
            },
            "uk": {
              "title": "Виробнича лінія"
            }
          },
          "order": 2,
          "control": "select",
          "class_name": "col-span-12 @2xl:col-span-2",
          "input_data": {
            "data": [
              {
                "i18n": {
                  "de": {
                    "title": "Platte"
                  },
                  "en": {
                    "title": "Sheet"
                  },
                  "es": {
                    "title": "Plancha"
                  },
                  "fr": {
                    "title": "Panneau"
                  },
                  "nl": {
                    "title": "Plaat"
                  },
                  "uk": {
                    "title": "Лист"
                  }
                },
                "value": "sheet"
              },
              {
                "i18n": {
                  "de": {
                    "title": "UV"
                  },
                  "en": {
                    "title": "UV"
                  },
                  "es": {
                    "title": "UV"
                  },
                  "fr": {
                    "title": "UV"
                  },
                  "nl": {
                    "title": "UV"
                  },
                  "uk": {
                    "title": "UV"
                  }
                },
                "value": "non-adhesive"
              },
              {
                "i18n": {
                  "de": {
                    "title": "Folie"
                  },
                  "en": {
                    "title": "Foil"
                  },
                  "es": {
                    "title": "Vinilo"
                  },
                  "fr": {
                    "title": "Film"
                  },
                  "nl": {
                    "title": "Folie"
                  },
                  "uk": {
                    "title": "Плівка"
                  }
                },
                "value": "foil"
              },
              {
                "i18n": {
                  "de": {
                    "title": "Textil"
                  },
                  "en": {
                    "title": "Textile"
                  },
                  "es": {
                    "title": "Textil"
                  },
                  "fr": {
                    "title": "Textile"
                  },
                  "nl": {
                    "title": "Textiel"
                  },
                  "uk": {
                    "title": "Текстиль"
                  }
                },
                "value": "textile"
              },
              {
                "i18n": {
                  "de": {
                    "title": "Etiketten"
                  },
                  "en": {
                    "title": "Labels"
                  },
                  "es": {
                    "title": "Etiquetas"
                  },
                  "fr": {
                    "title": "Étiquettes"
                  },
                  "nl": {
                    "title": "Labels"
                  },
                  "uk": {
                    "title": "Етикетки"
                  }
                },
                "value": "label"
              },
              {
                "i18n": {
                  "de": {
                    "title": "Papier"
                  },
                  "en": {
                    "title": "Paper"
                  },
                  "es": {
                    "title": "Papel"
                  },
                  "fr": {
                    "title": "Papier"
                  },
                  "nl": {
                    "title": "Papier"
                  },
                  "uk": {
                    "title": "Папір"
                  }
                },
                "value": "paper"
              }
            ],
            "title_field": "title",
            "value_field": "value"
          }
        }
      },
      "tenant_ids": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Standorte"
            },
            "en": {
              "title": "Tenants"
            },
            "es": {
              "title": "Sedes"
            },
            "fr": {
              "title": "Sites"
            },
            "nl": {
              "title": "Vestigingen"
            },
            "uk": {
              "title": "Підрозділи"
            }
          },
          "order": 3,
          "control": "multi-select",
          "class_name": "col-span-12 @2xl:col-span-2",
          "input_data": {
            "data": [
              {
                "i18n": {
                  "de": {
                    "title": "Dokkum"
                  },
                  "en": {
                    "title": "Dokkum"
                  },
                  "es": {
                    "title": "Dokkum"
                  },
                  "fr": {
                    "title": "Dokkum"
                  },
                  "nl": {
                    "title": "Dokkum"
                  },
                  "uk": {
                    "title": "Доккюм"
                  }
                },
                "value": 1
              },
              {
                "i18n": {
                  "de": {
                    "title": "Bad Hersfeld"
                  },
                  "en": {
                    "title": "Bad Hersfeld"
                  },
                  "es": {
                    "title": "Bad Hersfeld"
                  },
                  "fr": {
                    "title": "Bad Hersfeld"
                  },
                  "nl": {
                    "title": "Bad Hersfeld"
                  },
                  "uk": {
                    "title": "Бад-Герсфельд"
                  }
                },
                "value": 2
              }
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
        "key": "date",
        "is_optional": true,
        "is_query_param": true
      },
      {
        "key": "step",
        "is_optional": true,
        "default_value": "print",
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
      },
      {
        "key": "resource_uids",
        "value_from": "resource_uid",
        "is_query_param": true
      },
      {
        "key": "nest_date",
        "value_from": "business_date",
        "is_query_param": true
      },
      {
        "key": "error_date",
        "value_from": "business_date",
        "is_query_param": true
      }
    ],
    "children": [],
    "widget_id": "oee_report",
    "field_config": {
      "set": {
        "ui": {
          "hidden": true
        }
      },
      "until": {
        "ui": {
          "type": "datetime",
          "hidden": true
        }
      },
      "tenant_id": {
        "ui": {
          "hidden": true
        }
      },
      "report_key": {
        "ui": {
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
            "de": {
              "title": "Standort"
            },
            "en": {
              "title": "Tenant"
            },
            "es": {
              "title": "Sede"
            },
            "fr": {
              "title": "Site"
            },
            "nl": {
              "title": "Vestiging"
            },
            "uk": {
              "title": "Підрозділ"
            }
          }
        }
      },
      "business_date": {
        "ui": {
          "type": "date",
          "hidden": true
        }
      },
      "resource_name": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Maschine"
            },
            "en": {
              "title": "Machine"
            },
            "es": {
              "title": "Máquina"
            },
            "fr": {
              "title": "Machine"
            },
            "nl": {
              "title": "Machine"
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
      "resource_uids": {
        "ui": {
          "hidden": true
        }
      },
      "param_json.shifts": {
        "ui": {
          "hidden": true
        }
      },
      "param_json.offline": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Offline"
            },
            "en": {
              "title": "Offline"
            },
            "es": {
              "title": "Fuera de línea"
            },
            "fr": {
              "title": "Hors ligne"
            },
            "nl": {
              "title": "Offline"
            },
            "uk": {
              "title": "Офлайн"
            }
          },
          "type": "duration",
          "format": "hh:mm"
        }
      },
      "param_json.planned": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Geplante Verfügbarkeit"
            },
            "en": {
              "title": "Planned availability"
            },
            "es": {
              "title": "Disponibilidad planificada"
            },
            "fr": {
              "title": "Disponibilité planifiée"
            },
            "nl": {
              "title": "Geplande beschikbaarheid"
            },
            "uk": {
              "title": "Планова доступність"
            }
          },
          "type": "duration",
          "format": "hh:mm"
        }
      },
      "production_line_id": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Schichten"
            },
            "en": {
              "title": "Shifts"
            },
            "es": {
              "title": "Turnos"
            },
            "fr": {
              "title": "Postes"
            },
            "nl": {
              "title": "Diensten"
            },
            "uk": {
              "title": "Зміни"
            }
          },
          "hidden": true,
          "control": "link"
        }
      },
      "param_json.producing": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Produzierend / OEE"
            },
            "en": {
              "title": "Producing / OEE"
            },
            "es": {
              "title": "Produciendo / OEE"
            },
            "fr": {
              "title": "En production / OEE"
            },
            "nl": {
              "title": "Producerend / OEE"
            },
            "uk": {
              "title": "Виробництво / OEE"
            }
          },
          "type": "duration",
          "format": "hh:mm"
        }
      },
      "param_json.break_times": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Pausen"
            },
            "en": {
              "title": "Breaks"
            },
            "es": {
              "title": "Pausas"
            },
            "fr": {
              "title": "Pauses"
            },
            "nl": {
              "title": "Pauzes"
            },
            "uk": {
              "title": "Перерви"
            }
          },
          "type": "duration",
          "format": "hh:mm",
          "hidden": true
        }
      },
      "param_json.not_planned": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Nicht geplant"
            },
            "en": {
              "title": "Not planned"
            },
            "es": {
              "title": "No planificado"
            },
            "fr": {
              "title": "Non planifié"
            },
            "nl": {
              "title": "Niet gepland"
            },
            "uk": {
              "title": "Не заплановано"
            }
          },
          "type": "duration",
          "format": "hh:mm"
        }
      },
      "param_json.availability": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Verfügbarkeit"
            },
            "en": {
              "title": "Availability"
            },
            "es": {
              "title": "Disponibilidad"
            },
            "fr": {
              "title": "Disponibilité"
            },
            "nl": {
              "title": "Beschikbaarheid"
            },
            "uk": {
              "title": "Доступність"
            }
          },
          "type": "duration",
          "format": "hh:mm"
        }
      },
      "param_json.overcapacity": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Überkapazität (m²)"
            },
            "en": {
              "title": "Overcapacity (m²)"
            },
            "es": {
              "title": "Sobrecapacidad (m²)"
            },
            "fr": {
              "title": "Surcapacité (m²)"
            },
            "nl": {
              "title": "Overcapaciteit (m²)"
            },
            "uk": {
              "title": "Надлишкова потужність (m²)"
            }
          }
        },
        "scale": 0
      },
      "param_json.shift_duration": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Schichtzeit"
            },
            "en": {
              "title": "Shift time"
            },
            "es": {
              "title": "Tiempo de turno"
            },
            "fr": {
              "title": "Temps de poste"
            },
            "nl": {
              "title": "Shift tijd"
            },
            "uk": {
              "title": "Час зміни"
            }
          },
          "type": "duration",
          "format": "hh:mm",
          "hidden": false
        }
      },
      "param_json.has_break_times": {
        "ui": {
          "hidden": true
        }
      },
      "param_json.plan_calibrated": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Plan kalibriert"
            },
            "en": {
              "title": "Plan calibrated"
            },
            "es": {
              "title": "Plan calibrado"
            },
            "fr": {
              "title": "Plan calibré"
            },
            "nl": {
              "title": "Plan gekalibreerd"
            },
            "uk": {
              "title": "План калібрований"
            }
          },
          "type": "duration",
          "format": "hh:mm"
        }
      },
      "param_json.planned_operators": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Druckmaschinenführer"
            },
            "en": {
              "title": "Print operators"
            },
            "es": {
              "title": "Operarios de impresión"
            },
            "fr": {
              "title": "Opérateurs impression"
            },
            "nl": {
              "title": "Print operators"
            },
            "uk": {
              "title": "Оператори друку"
            }
          },
          "type": "number",
          "hidden": true,
          "control": "input"
        }
      },
      "param_json.technical_failure": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Störung"
            },
            "en": {
              "title": "Technical failure"
            },
            "es": {
              "title": "Avería"
            },
            "fr": {
              "title": "Panne"
            },
            "nl": {
              "title": "Storing"
            },
            "uk": {
              "title": "Технічна несправність"
            }
          },
          "type": "duration",
          "format": "hh:mm"
        }
      },
      "param_json.planned_output_sqm": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Geplanter Output (m²)"
            },
            "en": {
              "title": "Planned output (m²)"
            },
            "es": {
              "title": "Producción planificada (m²)"
            },
            "fr": {
              "title": "Production planifiée (m²)"
            },
            "nl": {
              "title": "Geplande output (m²)"
            },
            "uk": {
              "title": "Плановий випуск (m²)"
            }
          }
        },
        "scale": 0
      },
      "param_json.output_per_operator": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Output / Bediener (m²)"
            },
            "en": {
              "title": "Output / operator (m²)"
            },
            "es": {
              "title": "Producción / operario (m²)"
            },
            "fr": {
              "title": "Production / opérateur (m²)"
            },
            "nl": {
              "title": "Output / operator (m²)"
            },
            "uk": {
              "title": "Випуск / оператор (m²)"
            }
          },
          "hidden": true
        },
        "scale": 0
      },
      "param_json.actual_net_output_sqm": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Output Kundenaufträge (m²)"
            },
            "en": {
              "title": "Output customer orders (m²)"
            },
            "es": {
              "title": "Producción pedidos de clientes (m²)"
            },
            "fr": {
              "title": "Production commandes clients (m²)"
            },
            "nl": {
              "title": "Output klantorders (m²)"
            },
            "uk": {
              "title": "Випуск замовлень клієнтів (m²)"
            }
          }
        },
        "scale": 0
      },
      "param_json.operator_cost_per_sqm": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Bedienerkosten (€/m²)"
            },
            "en": {
              "title": "Operator cost (€/m²)"
            },
            "es": {
              "title": "Coste de operarios (€/m²)"
            },
            "fr": {
              "title": "Coût opérateurs (€/m²)"
            },
            "nl": {
              "title": "Operatorkosten (€/m²)"
            },
            "uk": {
              "title": "Витрати на операторів (€/m²)"
            }
          },
          "hidden": true
        },
        "scale": 2
      },
      "param_json.operator_working_time": {
        "ui": {
          "type": "duration",
          "format": "hh:mm",
          "hidden": true
        }
      },
      "param_json.planned_operator_cost": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Bedienerkosten (€)"
            },
            "en": {
              "title": "Operator cost (€)"
            },
            "es": {
              "title": "Coste de operarios (€)"
            },
            "fr": {
              "title": "Coût opérateurs (€)"
            },
            "nl": {
              "title": "Operatorkosten (€)"
            },
            "uk": {
              "title": "Витрати на операторів (€)"
            }
          },
          "hidden": true
        },
        "scale": 0
      },
      "param_json.actual_output_per_hour": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Output / Produktionsstunde (m²)"
            },
            "en": {
              "title": "Output / producing hour (m²)"
            },
            "es": {
              "title": "Producción / hora produciendo (m²)"
            },
            "fr": {
              "title": "Production / heure de production (m²)"
            },
            "nl": {
              "title": "Output / producerend uur (m²)"
            },
            "uk": {
              "title": "Випуск / година виробництва (m²)"
            }
          }
        },
        "scale": 2
      },
      "param_json.not_planned_calibrated": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Nicht geplant kalibriert"
            },
            "en": {
              "title": "Not planned calibrated"
            },
            "es": {
              "title": "No planificado calibrado"
            },
            "fr": {
              "title": "Non planifié calibré"
            },
            "nl": {
              "title": "Niet gepland gekalibreerd"
            },
            "uk": {
              "title": "Не заплановано калібровано"
            }
          },
          "type": "duration",
          "format": "hh:mm"
        }
      },
      "param_json.not_planned_percentage": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Nicht geplant %"
            },
            "en": {
              "title": "Not planned %"
            },
            "es": {
              "title": "No planificado %"
            },
            "fr": {
              "title": "Non planifié %"
            },
            "nl": {
              "title": "Niet gepland %"
            },
            "uk": {
              "title": "Не заплановано %"
            }
          },
          "type": "percent"
        },
        "scale": 1
      },
      "param_json.technical_availability": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Technische Verfügbarkeit"
            },
            "en": {
              "title": "Technical availability"
            },
            "es": {
              "title": "Disponibilidad técnica"
            },
            "fr": {
              "title": "Disponibilité technique"
            },
            "nl": {
              "title": "Technische beschikbaarheid"
            },
            "uk": {
              "title": "Технічна доступність"
            }
          },
          "type": "duration",
          "format": "hh:mm"
        }
      },
      "param_json.actual_gross_output_sqm": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Output (m²)"
            },
            "en": {
              "title": "Output (m²)"
            },
            "es": {
              "title": "Producción (m²)"
            },
            "fr": {
              "title": "Production (m²)"
            },
            "nl": {
              "title": "Output (m²)"
            },
            "uk": {
              "title": "Випуск (m²)"
            }
          }
        },
        "scale": 0
      },
      "param_json.output_per_planned_hour": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Output / Stunde (m²)"
            },
            "en": {
              "title": "Output / hour (m²)"
            },
            "es": {
              "title": "Producción / hora (m²)"
            },
            "fr": {
              "title": "Production / heure (m²)"
            },
            "nl": {
              "title": "Output / uur (m²)"
            },
            "uk": {
              "title": "Випуск / година (m²)"
            }
          }
        },
        "scale": 2
      },
      "param_json.operator_cost_per_second": {
        "ui": {
          "hidden": true
        }
      },
      "param_json.planned_operator_duration": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Bedienerzeit geplant"
            },
            "en": {
              "title": "Operator time planned"
            },
            "es": {
              "title": "Tiempo de operario planificado"
            },
            "fr": {
              "title": "Temps opérateur planifié"
            },
            "nl": {
              "title": "Operatortijd gepland"
            },
            "uk": {
              "title": "Час операторів заплановано"
            }
          },
          "type": "duration",
          "format": "hh:mm",
          "hidden": true
        }
      },
      "param_json.technical_failure_percentage": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Störung %"
            },
            "en": {
              "title": "Technical failure %"
            },
            "es": {
              "title": "Avería %"
            },
            "fr": {
              "title": "Panne %"
            },
            "nl": {
              "title": "Storing %"
            },
            "uk": {
              "title": "Несправність %"
            }
          },
          "type": "percent"
        },
        "scale": 1
      },
      "param_json.planned_printers_per_operator": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Drucker / Bediener"
            },
            "en": {
              "title": "Printers / operator"
            },
            "es": {
              "title": "Impresoras / operario"
            },
            "fr": {
              "title": "Imprimantes / opérateur"
            },
            "nl": {
              "title": "Printers / operator"
            },
            "uk": {
              "title": "Принтери / оператор"
            }
          },
          "hidden": true
        },
        "scale": 2
      },
      "param_json.period_output_per_planned_hour": {
        "ui": {
          "hidden": true
        }
      },
      "param_json.planned_print_operator_duration": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Druckmaschinenführer geplant"
            },
            "en": {
              "title": "Print operators planned"
            },
            "es": {
              "title": "Operarios de impresión planificados"
            },
            "fr": {
              "title": "Opérateurs impression planifiés"
            },
            "nl": {
              "title": "Print operators gepland"
            },
            "uk": {
              "title": "Оператори друку заплановано"
            }
          },
          "type": "duration",
          "format": "hh:mm"
        }
      },
      "param_json.producing_oee_planned_percentage": {
        "ui": {
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
          },
          "type": "percent"
        },
        "scale": 1
      },
      "param_json.technical_availability_percentage": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Technische Verfügbarkeit %"
            },
            "en": {
              "title": "Technical availability %"
            },
            "es": {
              "title": "Disponibilidad técnica %"
            },
            "fr": {
              "title": "Disponibilité technique %"
            },
            "nl": {
              "title": "Technische beschikbaarheid %"
            },
            "uk": {
              "title": "Технічна доступність %"
            }
          },
          "type": "percent"
        },
        "scale": 1
      },
      "param_json.producing_oee_plan_calibrated_percentage": {
        "ui": {
          "i18n": {
            "de": {
              "title": "OEE kalibriert"
            },
            "en": {
              "title": "OEE calibrated"
            },
            "es": {
              "title": "OEE calibrado"
            },
            "fr": {
              "title": "OEE calibré"
            },
            "nl": {
              "title": "OEE gekalibreerd"
            },
            "uk": {
              "title": "OEE калібровано"
            }
          },
          "type": "percent"
        },
        "scale": 1
      }
    },
    "flow_board_config": {
      "sort": {
        "field": "sort_order",
        "direction": "asc"
      },
      "layout": "flow-grid",
      "children": [
        {
          "sort": {
            "field": "tenant_id",
            "direction": "asc"
          },
          "layout": "flow-container",
          "children": [
            {
              "items": {
                "key_field": "shift",
                "data_field": "param_json.shifts",
                "title_field": "i18n"
              },
              "layout": "flow-cards",
              "evaluate": {
                "params_field": "param_json",
                "formula_field": "formula_json"
              },
              "group_by": [
                "resource_uid"
              ],
              "set_field": "set",
              "row_options": {
                "colexp": false,
                "checkable": false,
                "class_name": "rounded-none border-0 p-1 shadow-none",
                "selectable": false
              },
              "field_config": {
                "resource_name": {
                  "ui": {
                    "order": 0,
                    "no_items": true,
                    "no_label": true,
                    "class_name": "col-span-2 font-semibold"
                  }
                },
                "param_json.offline": {
                  "ui": {
                    "order": 2,
                    "class_name": "col-start-1 text-right"
                  }
                },
                "param_json.planned": {
                  "ui": {
                    "order": 10,
                    "class_name": "col-start-1 text-right mt-2"
                  },
                  "nav": {
                    "on_select": {
                      "path": "(sidebar:production-planning-info)",
                      "params": [
                        {
                          "key": "resource_uids",
                          "is_query_param": true
                        },
                        {
                          "key": "until",
                          "is_query_param": true
                        }
                      ]
                    }
                  }
                },
                "production_line_id": {
                  "ui": {
                    "order": 19,
                    "hidden": true,
                    "no_items": true,
                    "class_name": "mt-2"
                  },
                  "nav": {
                    "on_click": {
                      "path": "(sidebar:shift)",
                      "params": [
                        {
                          "key": "production_line_id",
                          "is_query_param": true
                        },
                        {
                          "key": "business_date",
                          "is_query_param": true
                        }
                      ]
                    }
                  }
                },
                "param_json.producing": {
                  "ui": {
                    "order": 11,
                    "class_name": "col-start-1 text-right border-b border-gray-300 pb-1"
                  }
                },
                "param_json.not_planned": {
                  "ui": {
                    "order": 8,
                    "class_name": "col-start-1 text-right border-b border-gray-300 pb-1"
                  }
                },
                "param_json.availability": {
                  "ui": {
                    "order": 3,
                    "class_name": "col-start-1 text-right"
                  }
                },
                "param_json.overcapacity": {
                  "ui": {
                    "order": 17,
                    "class_name": "col-start-1 text-right mt-2"
                  }
                },
                "param_json.shift_duration": {
                  "ui": {
                    "order": 1,
                    "class_name": "col-start-1 text-right"
                  }
                },
                "param_json.planned_operators": {
                  "ui": {
                    "order": 18,
                    "hidden": true,
                    "no_items": true,
                    "class_name": "col-start-1 text-right mt-2"
                  }
                },
                "param_json.technical_failure": {
                  "ui": {
                    "order": 4,
                    "class_name": "col-start-1 text-right border-b border-gray-300 pb-1"
                  },
                  "nav": {
                    "on_select": {
                      "path": "(sidebar:error-log)",
                      "params": [
                        {
                          "key": "resource_uid",
                          "is_query_param": true
                        },
                        {
                          "key": "error_date",
                          "value_from": "business_date",
                          "is_query_param": true
                        }
                      ]
                    }
                  }
                },
                "param_json.output_per_operator": {
                  "ui": {
                    "order": 22,
                    "hidden": true,
                    "no_items": true,
                    "class_name": "col-start-1 text-right mt-2"
                  }
                },
                "param_json.actual_net_output_sqm": {
                  "ui": {
                    "order": 13,
                    "class_name": "col-start-1 text-right mt-2"
                  }
                },
                "param_json.operator_cost_per_sqm": {
                  "ui": {
                    "order": 21,
                    "hidden": true,
                    "no_items": true,
                    "class_name": "col-start-1 text-right"
                  }
                },
                "param_json.planned_operator_cost": {
                  "ui": {
                    "order": 20,
                    "hidden": true,
                    "no_items": true,
                    "class_name": "col-start-1 text-right"
                  }
                },
                "param_json.actual_output_per_hour": {
                  "ui": {
                    "order": 16,
                    "class_name": "col-start-1 text-right text-gray-400"
                  }
                },
                "param_json.not_planned_percentage": {
                  "ui": {
                    "order": 9,
                    "no_items": true,
                    "no_label": true,
                    "class_name": "border-b border-gray-300 pb-1"
                  }
                },
                "param_json.technical_availability": {
                  "ui": {
                    "order": 6,
                    "class_name": "col-start-1 text-right mt-2"
                  }
                },
                "param_json.actual_gross_output_sqm": {
                  "ui": {
                    "order": 14,
                    "class_name": "col-start-1 text-right"
                  },
                  "nav": {
                    "on_select": {
                      "path": "(sidebar:resource-nest-waste)",
                      "params": [
                        {
                          "key": "resource_uids",
                          "value_from": "resource_uid",
                          "is_query_param": true
                        },
                        {
                          "key": "nest_date",
                          "value_from": "business_date",
                          "is_query_param": true
                        }
                      ]
                    }
                  }
                },
                "param_json.output_per_planned_hour": {
                  "ui": {
                    "order": 15,
                    "class_name": "col-start-1 text-right"
                  }
                },
                "param_json.technical_failure_percentage": {
                  "ui": {
                    "order": 5,
                    "no_items": true,
                    "no_label": true,
                    "class_name": "border-b border-gray-300 pb-1"
                  }
                },
                "param_json.planned_printers_per_operator": {
                  "ui": {
                    "order": 23,
                    "hidden": true,
                    "no_items": true,
                    "class_name": "col-start-1 text-right"
                  }
                },
                "param_json.producing_oee_planned_percentage": {
                  "ui": {
                    "order": 12,
                    "no_items": true,
                    "no_label": true,
                    "class_name": "border-b border-gray-300 pb-1"
                  }
                },
                "param_json.technical_availability_percentage": {
                  "ui": {
                    "order": 7,
                    "no_items": true,
                    "no_label": true,
                    "class_name": "mt-2"
                  }
                }
              },
              "set_overrides": {
                "summary": {
                  "row_options": {
                    "class_name": "rounded-none border-0 p-1 shadow-none flow-card-summary font-semibold"
                  },
                  "field_config": {
                    "resource_name": {
                      "ui": {
                        "i18n": {
                          "de": {
                            "template": "Gesamt ${tenant_name}"
                          },
                          "en": {
                            "template": "Total ${tenant_name}"
                          },
                          "es": {
                            "template": "Total ${tenant_name}"
                          },
                          "fr": {
                            "template": "Total ${tenant_name}"
                          },
                          "nl": {
                            "template": "Totaal ${tenant_name}"
                          },
                          "uk": {
                            "template": "Разом ${tenant_name}"
                          }
                        },
                        "control": "template"
                      }
                    },
                    "production_line_id": {
                      "ui": {
                        "hidden": false
                      }
                    },
                    "param_json.planned_operators": {
                      "ui": {
                        "hidden": false,
                        "class_name": "col-start-1 col-span-1"
                      }
                    },
                    "param_json.output_per_operator": {
                      "ui": {
                        "hidden": false,
                        "class_name": "col-start-1 text-right mt-2"
                      }
                    },
                    "param_json.operator_cost_per_sqm": {
                      "ui": {
                        "hidden": false,
                        "class_name": "col-start-1 text-right"
                      }
                    },
                    "param_json.planned_operator_cost": {
                      "ui": {
                        "hidden": false,
                        "class_name": "col-start-1 text-right"
                      }
                    },
                    "param_json.planned_printers_per_operator": {
                      "ui": {
                        "hidden": false,
                        "class_name": "col-start-1 text-right"
                      }
                    }
                  }
                }
              },
              "fields_class_name": "grid gap-x-2"
            }
          ],
          "group_by": [
            "tenant_id"
          ],
          "row_options": {
            "colexp": false,
            "checkable": false,
            "class_name": "rounded-none border-0 shadow-none",
            "selectable": false
          },
          "field_config": {
            "tenant_name": {
              "ui": {
                "i18n": {
                  "de": {
                    "template": "Standort ${tenant_name}"
                  },
                  "en": {
                    "template": "Tenant ${tenant_name}"
                  },
                  "es": {
                    "template": "Sede ${tenant_name}"
                  },
                  "fr": {
                    "template": "Site ${tenant_name}"
                  },
                  "nl": {
                    "template": "Vestiging ${tenant_name}"
                  },
                  "uk": {
                    "template": "Підрозділ ${tenant_name}"
                  }
                },
                "order": 0,
                "control": "template",
                "no_label": true,
                "class_name": "col-span-1 font-semibold"
              }
            }
          },
          "fields_class_name": "grid grid-cols-1 gap-1"
        }
      ],
      "group_by": [
        "report_key"
      ],
      "row_options": {
        "colexp": false,
        "checkable": false,
        "class_name": "border-0 divide-y-0 shadow-none",
        "selectable": false,
        "label_column": true,
        "full_grid_scroll": true,
        "label_column_width": 240,
        "label_column_sticky": true
      },
      "column_max_width": 320,
      "column_min_width": 260,
      "fields_class_name": "grid grid-cols-1 gap-1",
      "group_title_fields": [
        "i18n"
      ]
    },
    "window_class_name": "p-8"
  }
]
$json$::jsonb)
ON CONFLICT (data_group) DO UPDATE SET data_group_json = EXCLUDED.data_group_json;

COMMIT;

-- expected: two rows, layouts filter and flow-board
SELECT data_group_id, data_group, data_group_json -> 0 ->> 'layout' AS layout, data_group_json -> 0 -> 'src' AS src
FROM site.data_group WHERE data_group IN ('oee_report', 'oee_report_filter') ORDER BY data_group;
