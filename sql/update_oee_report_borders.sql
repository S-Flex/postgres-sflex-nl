-- OEE report (docs/plan-oee-report.md): a trial of the rules of the sheet
-- docs/images/oee-overall.png. The second line of each pair (technical failure,
-- not planned, producing / OEE) gets a bottom border on both cells:
-- border-b border-gray-300 pb-1. The rest of the data_group is the live row
-- 100 of 14 Sep 2026. Rollback: sql/update_oee_report_borders_down.sql.
BEGIN;

UPDATE site.data_group
SET data_group_json = $json$
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
        "default_value": "now()",
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
    "field_config": {
      "set": {
        "ui": {
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
      "report_date": {
        "ui": {
          "type": "date",
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
              "title": "Diensttijd"
            },
            "uk": {
              "title": "Час зміни"
            }
          },
          "type": "duration",
          "format": "hh:mm",
          "hidden": true
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
      "param_json.actual_output_sqm": {
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
        }
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
        }
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
        }
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
        }
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
                    "no_label": true,
                    "class_name": "col-span-2 font-semibold"
                  }
                },
                "param_json.planned": {
                  "ui": {
                    "order": 8,
                    "class_name": "col-start-1 text-right mt-2"
                  }
                },
                "param_json.producing": {
                  "ui": {
                    "order": 9,
                    "class_name": "col-start-1 text-right border-b border-gray-300 pb-1"
                  }
                },
                "param_json.not_planned": {
                  "ui": {
                    "order": 6,
                    "class_name": "col-start-1 text-right border-b border-gray-300 pb-1"
                  }
                },
                "param_json.availability": {
                  "ui": {
                    "order": 1,
                    "class_name": "col-start-1 text-right"
                  }
                },
                "param_json.overcapacity": {
                  "ui": {
                    "order": 13,
                    "class_name": "col-start-1 text-right mt-2"
                  }
                },
                "param_json.actual_output_sqm": {
                  "ui": {
                    "order": 11,
                    "class_name": "col-start-1 text-right mt-2"
                  }
                },
                "param_json.planned_operators": {
                  "ui": {
                    "order": 14,
                    "hidden": true,
                    "class_name": "col-start-1 text-right mt-2"
                  }
                },
                "param_json.technical_failure": {
                  "ui": {
                    "order": 2,
                    "class_name": "col-start-1 text-right border-b border-gray-300 pb-1"
                  }
                },
                "param_json.operator_cost_per_sqm": {
                  "ui": {
                    "order": 16,
                    "hidden": true,
                    "class_name": "col-start-1 text-right"
                  }
                },
                "param_json.planned_operator_cost": {
                  "ui": {
                    "order": 15,
                    "hidden": true,
                    "class_name": "col-start-1 text-right"
                  }
                },
                "param_json.actual_output_per_hour": {
                  "ui": {
                    "order": 12,
                    "class_name": "col-start-1 text-right"
                  }
                },
                "param_json.not_planned_percentage": {
                  "ui": {
                    "order": 7,
                    "no_label": true,
                    "class_name": "border-b border-gray-300 pb-1"
                  }
                },
                "param_json.technical_availability": {
                  "ui": {
                    "order": 4,
                    "class_name": "col-start-1 text-right mt-2"
                  }
                },
                "param_json.technical_failure_percentage": {
                  "ui": {
                    "order": 3,
                    "no_label": true,
                    "class_name": "border-b border-gray-300 pb-1"
                  }
                },
                "param_json.producing_oee_planned_percentage": {
                  "ui": {
                    "order": 10,
                    "no_label": true,
                    "class_name": "border-b border-gray-300 pb-1"
                  }
                },
                "param_json.technical_availability_percentage": {
                  "ui": {
                    "order": 5,
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
                    "param_json.planned_operators": {
                      "ui": {
                        "hidden": false,
                        "class_name": "col-start-1 col-span-1"
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
                    }
                  }
                }
              },
              "fields_class_name": "grid grid-cols-2 gap-x-2"
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
      "column_max_width": 260,
      "column_min_width": 200,
      "fields_class_name": "grid grid-cols-1 gap-1",
      "group_title_fields": [
        "i18n"
      ]
    },
    "window_class_name": "p-8"
  }
]
$json$::jsonb
WHERE data_group = 'oee_report';

COMMIT;

-- expected: the class of the technical failure row on the cards
SELECT data_group_json #>> '{0,flow_board_config,children,0,children,0,field_config,param_json.technical_failure,ui,class_name}' AS technical_failure_class
FROM site.data_group WHERE data_group = 'oee_report';
