-- Nest waste chart (14 Sep 2026): the chart was invisible. The stacked-bar-chart
-- layout draws positional groups (bars per x position, each a stack of
-- segments {field, aggregate_fn, class_names_field}); y_field, stacked and
-- template are not part of it, and the tooltip is the sections form. Now: one x
-- position per waste bucket in lookup order, two bars (area, waste area), a
-- tooltip with the bucket's figures. No filter: the 0-100 total row is gone
-- from the lookup and the function. Bars paint in the neutral fill until the
-- rows carry class names.
-- Content of json/data_group/nest_waste_ranges_chart.json (the file is the source).
-- Rollback: sql/update_nest_waste_chart_groups_down.sql.
BEGIN;
UPDATE site.data_group SET data_group_json = $json$
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
      }
    },
    "stacked_bar_chart_config": {
      "height": 360,
      "x_field": "waste_range",
      "group_by": [
        "waste_range"
      ],
      "sort": {
        "field": "sort_order",
        "direction": "asc"
      },
      "show_grid": true,
      "show_legend": true,
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
              "field": "sqm",
              "aggregate_fn": "sum",
              "class_names_field": "class_names"
            }
          ]
        },
        {
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
          "segments": [
            {
              "field": "waste_sqm",
              "aggregate_fn": "sum",
              "class_names_field": "class_names"
            }
          ]
        }
      ],
      "tooltip": {
        "sections": [
          {
            "fields_class_name": "grid grid-cols-6 gap-1",
            "field_config": {
              "waste_range": {
                "ui": {
                  "order": 0,
                  "class_name": "col-span-3"
                }
              },
              "nest_count": {
                "ui": {
                  "order": 1,
                  "class_name": "col-span-3"
                }
              },
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
              "avg_waste_percentage": {
                "ui": {
                  "order": 4,
                  "class_name": "col-span-3"
                }
              },
              "waste_cost": {
                "ui": {
                  "order": 5,
                  "class_name": "col-span-3"
                }
              }
            }
          }
        ]
      }
    }
  }
]
$json$::jsonb WHERE data_group = 'nest_waste_ranges_chart';

COMMIT;

SELECT data_group, jsonb_pretty(data_group_json -> 0 -> 'stacked_bar_chart_config' -> 'groups') FROM site.data_group WHERE data_group = 'nest_waste_ranges_chart';
