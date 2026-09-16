-- Nest waste per production line type (14 Sep 2026): the nest-waste window
-- showed every material of every line. Now
--   1. legacy.get_nest_waste_ranges takes p_line_type: only the nests of the
--      production lines of that type, the material name from such a line first
--   2. mapping.get_materials takes p_line_type next to p_production_line_ids:
--      the material select of the filter lists the materials of those lines
--   3. the data_groups nest_waste_ranges, nest_waste_ranges_chart and
--      nest_waste_ranges_filter pass line_type (the filter's material select
--      too; production_line_ids is gone there)
--      the material container of the board shows the first and last nest day
--      of its rows (min and max of nest_date; one date when they are equal)
--   4. the status bar nav to the nest-waste window passes line_type along with
--      model (legacy.lookup status_bar, group nests)
-- The json files under json/data_group and json/lookup/legacy are the source.
-- Rollback: sql/update_nest_waste_line_type_down.sql.
BEGIN;

-- ============ sql/legacy/get_nest_waste_ranges.sql ============
-- The waste of the nests in ranges: per material, per day and per range of
-- waste_percentage (between 70 and 60, 60 and 50, ... 10 and 0, and above the
-- top bound) the nests, their area, the average waste and what that waste
-- costs, over the nests nested on the days of p_dates (a datemultirange; the
-- day of nested_at in Amsterdam time). A nest of a material whose imposition
-- group has a parent counts with the parent
-- (legacy.imposition_group.parent_imposition_group_id), as the queue and the
-- print schedule do. The ranges are legacy.lookup lookup_nest_waste_ranges
-- (json/lookup/legacy/lookup_nest_waste_ranges.json): code, range_min,
-- range_max and sort_order, is_total on the row that spans everything (the
-- board's total, the chart leaves it out), class_names for the board (the
-- total carries aggregate); a range takes range_min <= waste < range_max. Every range of a material and day is a row, also an empty one.
--
-- nest_count is the sum of legacy.nest.amount (the impositions of the sheet),
-- sqm is width * height * amount in m2 (the dimensions are cm), waste_sqm is
-- the sqm times the waste of the nest, waste_cost is waste_sqm times the
-- purchase price per m2 of the material: the active catalog.item_base_price
-- row of the material item for the tenant of the nest's production line (the
-- newest version), the first price tier (price_tiers_json -> 0 ->>
-- 'purchase_price'). Null when the material has no price for that tenant.
-- p_line_type keeps to the nests of the production lines of that type
-- (relation.production_line.line_type of the nest's line); null is every line.
-- Set-based, one statement.
drop function if exists legacy.get_nest_waste_percentiles(datemultirange, integer[], numeric[]);
drop function if exists legacy.get_nest_waste_ranges(datemultirange, integer[], numeric[]);
drop function if exists legacy.get_nest_waste_ranges(datemultirange, integer[]);
drop function if exists legacy.get_nest_waste_ranges(datemultirange, integer[], text);

create function legacy.get_nest_waste_ranges(p_dates datemultirange DEFAULT datemultirange(daterange(current_date, current_date, '[]')), p_material_ids integer[] DEFAULT NULL::integer[], p_line_type text DEFAULT NULL::text) returns TABLE(material_id integer, material_name text, nest_date date, range_min numeric, range_max numeric, waste_range text, is_total boolean, sort_order integer, class_names text[], nest_count integer, sqm numeric, avg_waste_percentage numeric, waste_sqm numeric, purchase_price_per_sqm numeric, waste_cost numeric)
	stable
	language sql
as $$
    WITH nest AS (
        -- the material (the parent for a child) and the tenant of a nest live
        -- in its json and its production line; legacy.nest has no columns for them
        SELECT coalesce(g.parent_imposition_group_id, (n.nest_json ->> 'material_id')::integer) AS material_id,
               pl.tenant_id,
               (n.nested_at AT TIME ZONE 'Europe/Amsterdam')::date AS nest_date,
               (n.nest_json ->> 'waste_percentage')::numeric         AS waste_percentage,
               coalesce(n.amount, 1)                                  AS amount,
               n.width * n.height / 10000 * coalesce(n.amount, 1)     AS sqm
        FROM legacy.nest n
        LEFT JOIN legacy.imposition_group g ON g.imposition_group_id = (n.nest_json ->> 'material_id')::integer
        LEFT JOIN relation.production_line pl ON pl.line_id = (n.nest_json ->> 'production_line_id')::integer
        WHERE (n.nested_at AT TIME ZONE 'Europe/Amsterdam')::date <@ p_dates
          AND n.nest_json ? 'waste_percentage'
          AND (p_line_type IS NULL OR pl.line_type = p_line_type)
          AND (p_material_ids IS NULL
               OR coalesce(g.parent_imposition_group_id, (n.nest_json ->> 'material_id')::integer) = ANY (p_material_ids))
    ),
    range AS (
        -- the ranges of the lookup: [range_min, range_max), the top one open
        SELECT (v.value ->> 'range_min')::numeric AS range_min,
               (v.value ->> 'range_max')::numeric AS range_max,
               v.value ->> 'code'                 AS waste_range,
               coalesce((v.value ->> 'is_total')::boolean, false) AS is_total,
               (v.value ->> 'sort_order')::integer AS sort_order,
               coalesce((SELECT array_agg(c.value) FROM jsonb_array_elements_text(coalesce(v.value -> 'class_names', '[]'::jsonb)) AS c(value)),
                        '{}'::text[]) AS class_names
        FROM legacy.lookup l
        CROSS JOIN LATERAL jsonb_array_elements(l.lookup_json) AS v(value)
        WHERE l.lookup = 'lookup_nest_waste_ranges'
    ),
    material AS (
        SELECT DISTINCT n.material_id, n.nest_date FROM nest n
    ),
    material_item AS (
        -- the material item of the group: the path in item group material
        SELECT g.imposition_group_id AS material_id, i.item_code
        FROM legacy.imposition_group g
        JOIN catalog.item i ON i.item_code_path = ANY (g.item_code_paths) AND i.item_group_code = 'material'
        WHERE g.imposition_group_id IN (SELECT m.material_id FROM material m)
    ),
    price AS (
        -- the purchase price per m2 of every material item, per tenant: the
        -- newest active base price of the tenant itself
        SELECT DISTINCT ON (bp.tenant_id, mi.material_id)
               bp.tenant_id, mi.material_id,
               (bp.price_tiers_json -> 0 ->> 'purchase_price')::numeric AS purchase_price_per_sqm
        FROM material_item mi
        JOIN catalog.item_base_price bp ON bp.item_code = mi.item_code
                                       AND bp.version_status = 'active'
        ORDER BY bp.tenant_id, mi.material_id, bp.created_at DESC, bp.version DESC
    )
    SELECT m.material_id,
           -- the name on a line of the type in view first
           (SELECT mpl.material_name
            FROM mapping.material_production_line mpl
            LEFT JOIN relation.production_line pl ON pl.line_id = mpl.production_line_id
            WHERE mpl.material_id = m.material_id
            ORDER BY (pl.line_type = p_line_type) DESC NULLS LAST, mpl.production_line_id
            LIMIT 1) AS material_name,
           m.nest_date,
           r.range_min,
           r.range_max,
           r.waste_range,
           r.is_total,
           r.sort_order,
           r.class_names,
           coalesce(sum(n.amount), 0)::integer                      AS nest_count,
           round(coalesce(sum(n.sqm), 0), 2)                        AS sqm,
           round(avg(n.waste_percentage), 1)                        AS avg_waste_percentage,
           round(coalesce(sum(n.sqm * n.waste_percentage / 100), 0), 2) AS waste_sqm,
           min(pr.purchase_price_per_sqm)                            AS purchase_price_per_sqm,
           round(sum(n.sqm * n.waste_percentage / 100 * pr.purchase_price_per_sqm), 2) AS waste_cost
    FROM material m
    CROSS JOIN range r
    LEFT JOIN nest n ON n.material_id = m.material_id
                    AND n.nest_date = m.nest_date
                    AND n.waste_percentage >= r.range_min
                    AND (r.range_max IS NULL OR n.waste_percentage < r.range_max)
    LEFT JOIN price pr ON pr.material_id = n.material_id AND pr.tenant_id = n.tenant_id
    GROUP BY m.material_id, m.nest_date, r.range_min, r.range_max, r.waste_range, r.is_total, r.sort_order, r.class_names
    ORDER BY m.material_id, m.nest_date, r.sort_order;
$$;

alter function legacy.get_nest_waste_ranges(datemultirange, integer[], text) owner to xfw3;

-- ============ sql/mapping/get_materials.sql ============
-- The materials a board can filter on: the materials with a print schedule
-- (mock.material_print_schedule) on the production lines given, one row per
-- material, ordered by name. A material whose imposition group has a parent
-- is not listed on its own: it nests, queues and counts with the parent
-- (legacy.imposition_group.parent_imposition_group_id). p_production_line_ids
-- null is every line; p_line_type keeps to the lines of that type
-- (relation.production_line.line_type). The one material list for every
-- material select.
drop function if exists mapping.get_materials(text);
drop function if exists mapping.get_materials(integer[]);
drop function if exists mapping.get_materials(integer[], text);

create function mapping.get_materials(p_production_line_ids integer[] DEFAULT NULL::integer[], p_line_type text DEFAULT NULL::text) returns TABLE(material_id integer, material_name text, production_line_ids integer[])
	stable
	language sql
as $$
    SELECT mps.material_id,
           min(mps.material_name)                                    AS material_name,
           array_agg(DISTINCT mps.production_line_id ORDER BY mps.production_line_id) AS production_line_ids
    FROM mock.material_print_schedule mps
    LEFT JOIN legacy.imposition_group g ON g.imposition_group_id = mps.material_id
    WHERE g.parent_imposition_group_id IS NULL
      AND (p_production_line_ids IS NULL OR mps.production_line_id = ANY (p_production_line_ids))
      AND (p_line_type IS NULL OR mps.production_line_id IN (SELECT pl.line_id FROM relation.production_line pl WHERE pl.line_type = p_line_type))
    GROUP BY mps.material_id
    ORDER BY min(mps.material_name), mps.material_id;
$$;

alter function mapping.get_materials(integer[], text) owner to xfw3;

-- ============ site.data_group nest_waste_ranges ============
UPDATE site.data_group SET data_group_json = $json$
[
  {
    "src": [
      "get_nest_waste_ranges"
    ],
    "layout": "flow-board",
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
    "children": [],
    "widget_id": "nest_waste_ranges",
    "window_class_name": "p-8",
    "field_config": {
      "material_id": {
        "ui": {
          "hidden": true
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
      "nest_date": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Nestdatum"
            },
            "en": {
              "title": "Nest date"
            },
            "es": {
              "title": "Fecha de anidado"
            },
            "fr": {
              "title": "Date d'imbrication"
            },
            "nl": {
              "title": "Nestdatum"
            },
            "uk": {
              "title": "Дата нестингу"
            }
          },
          "type": "date"
        }
      },
      "range_min": {
        "ui": {
          "hidden": true
        }
      },
      "range_max": {
        "ui": {
          "hidden": true
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
      "purchase_price_per_sqm": {
        "ui": {
          "hidden": true
        }
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
      "is_total": {
        "ui": {
          "hidden": true
        }
      },
      "sort_order": {
        "ui": {
          "hidden": true
        }
      },
      "class_names": {
        "ui": {
          "hidden": true
        }
      }
    },
    "flow_board_config": {
      "layout": "flow-container",
      "group_by": [
        "material_id"
      ],
      "row_options": {
        "colexp": true,
        "checkable": false,
        "selectable": false
      },
      "fields_class_name": "@container grid grid-cols-7 gap-1",
      "field_config": {
        "material_name": {
          "ui": {
            "order": 0,
            "class_name": "col-span-1"
          }
        },
        "nest_date_from": {
          "field": "nest_date",
          "aggregate_fn": "min",
          "ui": {
            "order": 1,
            "type": "date",
            "class_name": "col-span-1",
            "i18n": {
              "nl": {
                "title": "Van"
              },
              "en": {
                "title": "From"
              },
              "de": {
                "title": "Von"
              },
              "fr": {
                "title": "Du"
              },
              "es": {
                "title": "Desde"
              },
              "uk": {
                "title": "З"
              }
            }
          }
        },
        "nest_date_until": {
          "field": "nest_date",
          "aggregate_fn": "max",
          "ui": {
            "order": 2,
            "type": "date",
            "class_name": "col-span-1",
            "hidden_when": [
              {
                "field": "nest_date_until",
                "op": "==",
                "value_field": "nest_date_from"
              }
            ],
            "i18n": {
              "nl": {
                "title": "Tot"
              },
              "en": {
                "title": "Until"
              },
              "de": {
                "title": "Bis"
              },
              "fr": {
                "title": "Au"
              },
              "es": {
                "title": "Hasta"
              },
              "uk": {
                "title": "До"
              }
            }
          }
        },
        "nest_count": {
          "ui": {
            "order": 3,
            "class_name": "col-span-1"
          },
          "scale": 0,
          "aggregate_fn": "sum"
        },
        "sqm": {
          "ui": {
            "order": 4,
            "class_name": "col-span-1",
            "suffix": "m²"
          },
          "scale": 1,
          "aggregate_fn": "sum"
        },
        "waste_sqm": {
          "ui": {
            "order": 5,
            "class_name": "col-span-1",
            "suffix": "m²"
          },
          "scale": 1,
          "aggregate_fn": "sum"
        },
        "waste_cost": {
          "ui": {
            "order": 6,
            "class_name": "col-span-1",
            "prefix": "€"
          },
          "scale": 2,
          "aggregate_fn": "sum"
        }
      },
      "children": [
        {
          "layout": "flow-table",
          "group_by": [
            "sort_order"
          ],
          "row_options": {
            "colexp": true,
            "checkable": false,
            "selectable": false,
            "class_names_field": "class_names"
          },
          "fields_class_name": "grid grid-cols-6 gap-1",
          "field_config": {
            "waste_range": {
              "ui": {
                "order": 0,
                "class_name": "col-span-1",
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
                "order": 1,
                "class_name": "col-span-1",
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
              "scale": 0,
              "aggregate_fn": "sum"
            },
            "sqm": {
              "ui": {
                "order": 2,
                "class_name": "col-span-1",
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
              "scale": 1,
              "aggregate_fn": "sum"
            },
            "avg_waste_percentage": {
              "ui": {
                "order": 3,
                "class_name": "col-span-1",
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
              "scale": 1,
              "aggregate_fn": "avg"
            },
            "waste_sqm": {
              "ui": {
                "order": 4,
                "class_name": "col-span-1",
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
              "scale": 1,
              "aggregate_fn": "sum"
            },
            "waste_cost": {
              "ui": {
                "order": 5,
                "class_name": "col-span-1 text-right",
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
              "scale": 2,
              "aggregate_fn": "sum"
            }
          },
          "children": [
            {
              "layout": "flow-table",
              "group_by": [
                "nest_date"
              ],
              "row_options": {
                "colexp": false,
                "checkable": false,
                "selectable": false,
                "class_names_field": "class_names"
              },
              "fields_class_name": "grid grid-cols-6 gap-1",
              "field_config": {
                "nest_date": {
                  "ui": {
                    "order": 0,
                    "class_name": "col-span-1",
                    "i18n": {
                      "de": {
                        "title": "Nestdatum"
                      },
                      "en": {
                        "title": "Nest date"
                      },
                      "es": {
                        "title": "Fecha de anidado"
                      },
                      "fr": {
                        "title": "Date d'imbrication"
                      },
                      "nl": {
                        "title": "Nestdatum"
                      },
                      "uk": {
                        "title": "Дата нестингу"
                      }
                    },
                    "type": "date"
                  }
                },
                "nest_count": {
                  "ui": {
                    "order": 1,
                    "class_name": "col-span-1",
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
                    "order": 2,
                    "class_name": "col-span-1",
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
                    "order": 3,
                    "class_name": "col-span-1",
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
                    "order": 4,
                    "class_name": "col-span-1",
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
                    "order": 5,
                    "class_name": "col-span-1 text-right",
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
              }
            }
          ]
        }
      ]
    }
  }
]
$json$::jsonb WHERE data_group = 'nest_waste_ranges';

-- ============ site.data_group nest_waste_ranges_chart ============
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
      "stacked": true,
      "x_field": "waste_range",
      "y_field": "sqm",
      "group_by": [
        "material_id"
      ],
      "template": "${material_name}",
      "show_grid": true,
      "show_legend": true,
      "filter": [
        [
          {
            "op": "==",
            "field": "is_total",
            "value": false
          }
        ]
      ],
      "tooltip": {
        "fields_class_name": "grid grid-cols-6 gap-1",
        "field_config": {},
        "groups": [
          {
            "title": {
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
            },
            "fields": {
              "material_name": {
                "ui": {
                  "order": 0,
                  "class_name": "col-span-4"
                }
              },
              "waste_range": {
                "ui": {
                  "order": 1,
                  "class_name": "col-span-2"
                }
              }
            }
          },
          {
            "title": {
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
            "fields": {
              "nest_count": {
                "ui": {
                  "order": 0,
                  "class_name": "col-span-2"
                }
              },
              "sqm": {
                "ui": {
                  "order": 1,
                  "class_name": "col-span-2"
                }
              },
              "avg_waste_percentage": {
                "ui": {
                  "order": 2,
                  "class_name": "col-span-2"
                }
              },
              "waste_sqm": {
                "ui": {
                  "order": 3,
                  "class_name": "col-span-3"
                }
              },
              "waste_cost": {
                "ui": {
                  "order": 4,
                  "class_name": "col-span-3"
                }
              }
            }
          }
        ],
        "sort": {
          "field": "sqm",
          "direction": "desc"
        }
      }
    }
  }
]
$json$::jsonb WHERE data_group = 'nest_waste_ranges_chart';

-- ============ site.data_group nest_waste_ranges_filter ============
UPDATE site.data_group SET data_group_json = $json$
[
  {
    "layout": "filter",
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
    "children": [],
    "widget_id": "nest_waste_ranges_filter",
    "row_options": {
      "class_name": "@container grid grid-cols-12 gap-1"
    },
    "field_config": {
      "dates": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Nesttage"
            },
            "en": {
              "title": "Nest days"
            },
            "es": {
              "title": "Días de anidado"
            },
            "fr": {
              "title": "Jours d'imbrication"
            },
            "nl": {
              "title": "Nestdagen"
            },
            "uk": {
              "title": "Дні нестингу"
            }
          },
          "order": 0,
          "control": "multi-date-picker",
          "type": "datemultirange",
          "class_name": "col-span-12 @2xl:col-span-4"
        }
      },
      "material_ids": {
        "ui": {
          "i18n": {
            "de": {
              "title": "Materialien"
            },
            "en": {
              "title": "Materials"
            },
            "es": {
              "title": "Materiales"
            },
            "fr": {
              "title": "Matériaux"
            },
            "nl": {
              "title": "Materialen"
            },
            "uk": {
              "title": "Матеріали"
            }
          },
          "order": 1,
          "control": "multi-select",
          "class_name": "col-span-12 @2xl:col-span-4",
          "input_data": {
            "src": [
              "get_materials"
            ],
            "params": [
              {
                "key": "line_type",
                "is_query_param": true
              }
            ],
            "title_field": "material_name",
            "value_field": "material_id"
          }
        }
      }
    }
  }
]
$json$::jsonb WHERE data_group = 'nest_waste_ranges_filter';

-- ============ legacy.lookup status_bar: nav of nests ============
UPDATE legacy.lookup lk
SET lookup_json = (
    SELECT jsonb_agg(
               CASE WHEN g.value ->> 'code' = 'nests'
                     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(g.value -> 'nav' -> 'params') p WHERE p.value ->> 'key' = 'line_type')
                    THEN jsonb_set(g.value, '{nav,params}',
                                   (g.value -> 'nav' -> 'params') || '[{"key": "line_type", "is_optional": true, "is_query_param": true}]'::jsonb)
                    ELSE g.value END
               ORDER BY g.ordinality)
    FROM jsonb_array_elements(lk.lookup_json) WITH ORDINALITY AS g)
WHERE lk.lookup = 'status_bar';

COMMIT;

-- ============ check ============
-- expected: only sheet materials, none of another line type
SELECT DISTINCT r.material_id, r.material_name
FROM legacy.get_nest_waste_ranges(datemultirange(daterange(current_date - 7, current_date - 1, '[]')), NULL, 'sheet') r
ORDER BY 2 LIMIT 20;

-- expected: fewer materials than without the type
SELECT (SELECT count(*) FROM mapping.get_materials(NULL, 'sheet')) AS sheet_materials,
       (SELECT count(*) FROM mapping.get_materials()) AS all_materials;

-- expected: three data groups with line_type in params; the nests nav with model and line_type
SELECT data_group, data_group_json -> 0 -> 'params' FROM site.data_group WHERE data_group LIKE 'nest_waste_ranges%';
SELECT g.value -> 'nav' -> 'params' FROM legacy.lookup lk, jsonb_array_elements(lk.lookup_json) g WHERE lk.lookup = 'status_bar' AND g.value ->> 'code' = 'nests';
