-- Rollback of sql/update_nest_waste_chart_tooltip.sql: the data_group as it was live on 14 Sep 2026.
BEGIN;

UPDATE site.data_group
SET data_group_json = $json$
[
  {
    "src": [
      "get_nest_waste_ranges"
    ],
    "layout": "stacked-bar-chart",
    "params": [
      {
        "key": "dates",
        "is_optional": true,
        "is_query_param": true
      },
      {
        "key": "material_ids",
        "is_optional": true,
        "is_query_param": true
      },
      {
        "key": "line_type",
        "is_query_param": true
      }
    ],
    "widget_id": "nest_waste_ranges_chart",
    "field_config": {
      "sqm": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Fläche"
            },
            "en": {
              "title": "Area"
            },
            "es": {
              "title": "Superficie"
            },
            "fr": {
              "title": "Surface"
            },
            "nl": {
              "title": "Oppervlak"
            },
            "uk": {
              "title": "Площа"
            }
          },
          "suffix": "m²"
        },
        "scale": 1
      },
      "waste_sqm": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Abfallfläche"
            },
            "en": {
              "title": "Waste area"
            },
            "es": {
              "title": "Superficie de desperdicio"
            },
            "fr": {
              "title": "Surface de déchet"
            },
            "nl": {
              "title": "Afvaloppervlak"
            },
            "uk": {
              "title": "Площа відходів"
            }
          },
          "suffix": "m²"
        },
        "scale": 1
      },
      "nest_count": {
        "ui": {
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
        "scale": 0
      },
      "waste_cost": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Abfallkosten"
            },
            "en": {
              "title": "Waste cost"
            },
            "es": {
              "title": "Coste del desperdicio"
            },
            "fr": {
              "title": "Coût du déchet"
            },
            "nl": {
              "title": "Afvalkosten"
            },
            "uk": {
              "title": "Вартість відходів"
            }
          },
          "prefix": "€"
        },
        "scale": 2
      },
      "waste_range": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Abfall"
            },
            "en": {
              "title": "Waste"
            },
            "es": {
              "title": "Desperdicio"
            },
            "fr": {
              "title": "Déchet"
            },
            "nl": {
              "title": "Afval"
            },
            "uk": {
              "title": "Відходи"
            }
          },
          "suffix": "%"
        }
      },
      "material_name": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Material"
            },
            "en": {
              "title": "Material"
            },
            "es": {
              "title": "Material"
            },
            "fr": {
              "title": "Matériau"
            },
            "nl": {
              "title": "Materiaal"
            },
            "uk": {
              "title": "Матеріал"
            }
          }
        }
      },
      "avg_waste_percentage": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Gem. Abfall"
            },
            "en": {
              "title": "Avg. waste"
            },
            "es": {
              "title": "Desperdicio medio"
            },
            "fr": {
              "title": "Déchet moyen"
            },
            "nl": {
              "title": "Gem. afval"
            },
            "uk": {
              "title": "Сер. відходи"
            }
          },
          "suffix": "%"
        },
        "scale": 1
      }
    },
    "window_class_name": "p-8",
    "stacked_bar_chart_config": {
      "sort": {
        "field": "sort_order",
        "direction": "asc"
      },
      "groups": [
        {
          "i18n": {
            "de": {
              "title": "Fläche"
            },
            "en": {
              "title": "Area"
            },
            "es": {
              "title": "Superficie"
            },
            "fr": {
              "title": "Surface"
            },
            "nl": {
              "title": "Oppervlak"
            },
            "uk": {
              "title": "Площа"
            }
          },
          "segments": [
            {
              "fill": "var(--waste-area)",
              "color": "var(--waste-area-color)",
              "field": "sqm",
              "aggregate_fn": "sum"
            },
            {
              "fill": "var(--waste-loss)",
              "color": "var(--waste-loss-color)",
              "field": "waste_sqm",
              "aggregate_fn": "sum"
            }
          ]
        },
        {
          "i18n": {
            "de": {
              "title": "Abfallkosten"
            },
            "en": {
              "title": "Waste cost"
            },
            "es": {
              "title": "Coste del desperdicio"
            },
            "fr": {
              "title": "Coût du déchet"
            },
            "nl": {
              "title": "Afvalkosten"
            },
            "uk": {
              "title": "Вартість відходів"
            }
          },
          "segments": [
            {
              "fill": "var(--waste-cost)",
              "color": "var(--waste-cost-color)",
              "field": "waste_cost",
              "aggregate_fn": "sum"
            }
          ]
        }
      ],
      "height": 360,
      "tooltip": {
        "sections": [
          {
            "field_config": {
              "sqm": {
                "ui": {
                  "order": 2,
                  "class_name": "col-span-3"
                }
              },
              "waste_sqm": {
                "ui": {
                  "order": 3,
                  "class_name": "col-span-3"
                }
              },
              "nest_count": {
                "ui": {
                  "order": 1,
                  "class_name": "col-span-3"
                }
              },
              "waste_cost": {
                "ui": {
                  "order": 5,
                  "class_name": "col-span-3"
                }
              },
              "waste_range": {
                "ui": {
                  "order": 0,
                  "class_name": "col-span-3"
                }
              },
              "avg_waste_percentage": {
                "ui": {
                  "order": 4,
                  "class_name": "col-span-3"
                }
              }
            },
            "fields_class_name": "grid grid-cols-6 gap-1"
          }
        ]
      },
      "x_field": "waste_range",
      "group_by": [
        "waste_range"
      ],
      "show_grid": true,
      "show_legend": true
    }
  }
]
$json$::jsonb
WHERE data_group = 'nest_waste_ranges_chart';

COMMIT;

-- expected: one row, trigger group, five aggregated fields
SELECT data_group,
       data_group_json #> '{0,stacked_bar_chart_config,tooltip,trigger}' AS trigger,
       jsonb_object_keys(data_group_json #> '{0,stacked_bar_chart_config,tooltip,sections,0,group,field_config}') AS field
FROM site.data_group
WHERE data_group = 'nest_waste_ranges_chart';
