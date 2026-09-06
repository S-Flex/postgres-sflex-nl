-- GENERATED from json/lookup/legacy/status_bar.json: the groups of the status
-- bar (mapping.get_status_bar reads this lookup and hands each group's nav
-- to the frontend). Live differed from the mirror in one path: the capacity
-- group still opened (sidebar:tco), the page is called capacity since
-- 2026-09-04. Rebuild after every change to the json.

BEGIN;

UPDATE legacy.lookup
SET    lookup_json = $sb$[
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
  }
]$sb$::jsonb
WHERE  lookup = 'status_bar'
  AND  lookup_json IS DISTINCT FROM $sb$[
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
  }
]$sb$::jsonb;

COMMIT;

-- check: no tco left in any lookup table; expected: 0
SELECT count(*) AS lookups_with_tco
FROM (SELECT lookup_json FROM legacy.lookup
      UNION ALL SELECT lookup_json FROM relation.lookup
      UNION ALL SELECT lookup_json FROM production.lookup
      UNION ALL SELECT lookup_json FROM log.lookup) l
WHERE l.lookup_json::text ILIKE '%sidebar:tco%';
