-- GENERATED from json/nav/resource_menu.json: the resource menu row of
-- site.nav (nav_id 5), the one plan_timeline pulls in through
-- "nav:resource_menu" (site.resolve_nav_refs). Live differed from the mirror
-- only in the TCO -> capacity rename (2026-09-04): code resource.capacity,
-- path (sidebar:capacity), titles. Rebuild after every change to the json.

BEGIN;

UPDATE site.nav
SET    nav_json = $nav${
  "menu": [
    {
      "code": "resource.oee-area-chart",
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
      "path": "(sidebar:resource-oee-area-chart)"
    },
    {
      "code": "resource.capacity",
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
      "path": "(sidebar:capacity)",
      "environments": [
        "development"
      ]
    },
    {
      "code": "resource.production",
      "i18n": {
        "de": {
          "title": "Produktion"
        },
        "en": {
          "title": "Production"
        },
        "es": {
          "title": "Producción"
        },
        "fr": {
          "title": "Production"
        },
        "nl": {
          "title": "Productie"
        },
        "uk": {
          "title": "Виробництво"
        }
      },
      "path": "(sidebar:production)"
    },
    {
      "code": "resource.intermediate-stock",
      "i18n": {
        "de": {
          "title": "Zwischenlager"
        },
        "en": {
          "title": "Intermediate stock"
        },
        "es": {
          "title": "Stock intermedio"
        },
        "fr": {
          "title": "Stock intermédiaire"
        },
        "nl": {
          "title": "Tussenvoorraad"
        },
        "uk": {
          "title": "Проміжний запас"
        }
      },
      "path": "(sidebar:intermediate-stock)"
    },
    {
      "code": "resource.ink-heads",
      "i18n": {
        "de": {
          "title": "Tinte & Köpfe"
        },
        "en": {
          "title": "Ink & heads"
        },
        "es": {
          "title": "Tintas y cabezales"
        },
        "fr": {
          "title": "Encre et têtes"
        },
        "nl": {
          "title": "Inkt & koppen"
        },
        "uk": {
          "title": "Чорнила та головки"
        }
      },
      "path": "(sidebar:ink-heads)",
      "hidden_when": {
        "op": "not in",
        "key": "type",
        "val": [
          "printer"
        ]
      },
      "environments": [
        "development"
      ]
    }
  ],
  "on_select": {
    "params": [
      {
        "key": "resource_uids",
        "is_query_param": true
      }
    ]
  }
}$nav$::jsonb
WHERE  nav_id = 5
  AND  nav = 'resource_menu'
  AND  nav_json IS DISTINCT FROM $nav${
  "menu": [
    {
      "code": "resource.oee-area-chart",
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
      "path": "(sidebar:resource-oee-area-chart)"
    },
    {
      "code": "resource.capacity",
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
      "path": "(sidebar:capacity)",
      "environments": [
        "development"
      ]
    },
    {
      "code": "resource.production",
      "i18n": {
        "de": {
          "title": "Produktion"
        },
        "en": {
          "title": "Production"
        },
        "es": {
          "title": "Producción"
        },
        "fr": {
          "title": "Production"
        },
        "nl": {
          "title": "Productie"
        },
        "uk": {
          "title": "Виробництво"
        }
      },
      "path": "(sidebar:production)"
    },
    {
      "code": "resource.intermediate-stock",
      "i18n": {
        "de": {
          "title": "Zwischenlager"
        },
        "en": {
          "title": "Intermediate stock"
        },
        "es": {
          "title": "Stock intermedio"
        },
        "fr": {
          "title": "Stock intermédiaire"
        },
        "nl": {
          "title": "Tussenvoorraad"
        },
        "uk": {
          "title": "Проміжний запас"
        }
      },
      "path": "(sidebar:intermediate-stock)"
    },
    {
      "code": "resource.ink-heads",
      "i18n": {
        "de": {
          "title": "Tinte & Köpfe"
        },
        "en": {
          "title": "Ink & heads"
        },
        "es": {
          "title": "Tintas y cabezales"
        },
        "fr": {
          "title": "Encre et têtes"
        },
        "nl": {
          "title": "Inkt & koppen"
        },
        "uk": {
          "title": "Чорнила та головки"
        }
      },
      "path": "(sidebar:ink-heads)",
      "hidden_when": {
        "op": "not in",
        "key": "type",
        "val": [
          "printer"
        ]
      },
      "environments": [
        "development"
      ]
    }
  ],
  "on_select": {
    "params": [
      {
        "key": "resource_uids",
        "is_query_param": true
      }
    ]
  }
}$nav$::jsonb;

COMMIT;

-- check: no tco left anywhere in site.nav; expected: 0
SELECT count(*) AS navs_with_tco
FROM site.nav
WHERE nav_json::text ILIKE '%sidebar:tco%' OR nav_json::text ILIKE '%resource.tco%';
