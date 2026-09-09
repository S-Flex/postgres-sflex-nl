-- ============================================================
-- Update: log.lookup / lookup_resource_state — the simplified, flat
-- form, used ONLY by the OEE read (log.get_resource_state_shift_totals)
-- for now. relation.lookup keeps the old nested form untouched, so
-- every other reader keeps running; they move over later.
--
-- Source of truth: json/lookup/log/lookup_resource_state.json
-- (this script is generated from that file — edit the values THERE,
-- then regenerate; do not edit the JSON below by hand).
--
-- Structure: one flat array, 33 nodes, no hierarchy. Per node: code,
-- i18n (directly on the node, no block wrapper), group, order,
-- class_name, and where applicable counts_as and alias_of. color is
-- gone; fill and color carry css variables (docs/css_variables.css),
-- because svg cannot be styled through class_names.
--
-- counts_as has exactly four values, nothing else:
--   producing  producing, setup
--   breakdown  breakdown, maintenance, interruption
--   offline    offline, installation, missingdata
--   planned    planned
-- A state without counts_as (idle, starved(.operator, .running),
-- blocked, ...) sits inside production_hours without being summed
-- anywhere: it is the not-producing loss. running has no counts_as
-- either — it is the envelope of producing + starved.running and
-- would double count.
--
-- order: every group='plan' code (the whole plan lane, maintenance and
-- breaks included) sorts below every machine state, so the timeline
-- shows the plan row above the state row.

BEGIN;

INSERT INTO log.lookup (lookup, lookup_json)
VALUES ('lookup_resource_state', $json$
[
  {
    "code": "not_released",
    "i18n": {
      "de": {
        "title": "Nicht freigegeben"
      },
      "en": {
        "title": "Not released"
      },
      "es": {
        "title": "No liberado"
      },
      "fr": {
        "title": "Non libéré"
      },
      "nl": {
        "title": "Niet vrijgegeven"
      },
      "uk": {
        "title": "Не випущено"
      }
    },
    "group": "plan",
    "order": 10,
    "class_name": "plan-not-released",
    "fill": "var(--plan-not_released)",
    "color": "var(--plan-not_released-color)"
  },
  {
    "code": "nesting",
    "i18n": {
      "de": {
        "title": "Verschachtelung"
      },
      "en": {
        "title": "Nesting"
      },
      "es": {
        "title": "Anidando"
      },
      "fr": {
        "title": "Imbrication"
      },
      "nl": {
        "title": "Nesten"
      },
      "uk": {
        "title": "Вкладання"
      }
    },
    "group": "plan",
    "order": 20,
    "class_name": "plan-nesting",
    "fill": "var(--plan-nesting)",
    "color": "var(--plan-nesting-color)"
  },
  {
    "code": "nested",
    "i18n": {
      "de": {
        "title": "Verschachtelt"
      },
      "en": {
        "title": "Nested"
      },
      "es": {
        "title": "Anidado"
      },
      "fr": {
        "title": "Imbriqué"
      },
      "nl": {
        "title": "Genest"
      },
      "uk": {
        "title": "Вкладено"
      }
    },
    "group": "plan",
    "order": 30,
    "class_name": "plan-nested",
    "fill": "var(--plan-nested)",
    "color": "var(--plan-nested-color)"
  },
  {
    "code": "ripping",
    "i18n": {
      "de": {
        "title": "Verarbeitet"
      },
      "en": {
        "title": "Ripped"
      },
      "es": {
        "title": "Procesado"
      },
      "fr": {
        "title": "Traité"
      },
      "nl": {
        "title": "Geript"
      },
      "uk": {
        "title": "Оброблено"
      }
    },
    "group": "plan",
    "order": 40,
    "class_name": "plan-ripping",
    "fill": "var(--plan-ripping)",
    "color": "var(--plan-ripping-color)"
  },
  {
    "code": "ripped",
    "i18n": {
      "de": {
        "title": "Verarbeitet"
      },
      "en": {
        "title": "Ripped"
      },
      "es": {
        "title": "Procesado"
      },
      "fr": {
        "title": "Traité"
      },
      "nl": {
        "title": "Geript"
      },
      "uk": {
        "title": "Оброблено"
      }
    },
    "group": "plan",
    "order": 50,
    "class_name": "plan-ripped",
    "fill": "var(--plan-ripped)",
    "color": "var(--plan-ripped-color)"
  },
  {
    "code": "cut",
    "i18n": {
      "de": {
        "title": "Geschnitten"
      },
      "en": {
        "title": "Cut"
      },
      "es": {
        "title": "Cortado"
      },
      "fr": {
        "title": "Découpé"
      },
      "nl": {
        "title": "Gesneden"
      },
      "uk": {
        "title": "Розрізано"
      }
    },
    "group": "plan",
    "order": 60,
    "class_name": "plan-cut",
    "fill": "var(--plan-cut)",
    "color": "var(--plan-cut-color)"
  },
  {
    "code": "printed",
    "i18n": {
      "de": {
        "title": "Gedruckt"
      },
      "en": {
        "title": "Printed"
      },
      "es": {
        "title": "Impreso"
      },
      "fr": {
        "title": "Imprimé"
      },
      "nl": {
        "title": "Geprint"
      },
      "uk": {
        "title": "Надруковано"
      }
    },
    "group": "plan",
    "order": 70,
    "class_name": "plan-printed",
    "fill": "var(--plan-printed)",
    "color": "var(--plan-printed-color)"
  },
  {
    "code": "laminated",
    "i18n": {
      "de": {
        "title": "Laminiert"
      },
      "en": {
        "title": "Laminated"
      },
      "es": {
        "title": "Laminado"
      },
      "fr": {
        "title": "Laminé"
      },
      "nl": {
        "title": "Gelamineerd"
      },
      "uk": {
        "title": "Ламіновано"
      }
    },
    "group": "plan",
    "order": 80,
    "class_name": "plan-laminated",
    "fill": "var(--plan-laminated)",
    "color": "var(--plan-laminated-color)"
  },
  {
    "code": "batch-reserved",
    "i18n": {
      "de": {
        "title": "Stapel reserviert"
      },
      "en": {
        "title": "Batch reserved"
      },
      "es": {
        "title": "Lote reservado"
      },
      "fr": {
        "title": "Lot réservé"
      },
      "nl": {
        "title": "Batch gereserveerd"
      },
      "uk": {
        "title": "Партію зарезервовано"
      }
    },
    "group": "plan",
    "order": 90,
    "class_name": "plan-batch-reserved",
    "fill": "var(--plan-batch-reserved)",
    "color": "var(--plan-batch-reserved-color)"
  },
  {
    "code": "batch-initiated",
    "i18n": {
      "de": {
        "title": "Stapel initiiert"
      },
      "en": {
        "title": "Batch initiated"
      },
      "es": {
        "title": "Lote iniciado"
      },
      "fr": {
        "title": "Lot initié"
      },
      "nl": {
        "title": "Batch geïnitieerd"
      },
      "uk": {
        "title": "Партію ініційовано"
      }
    },
    "group": "plan",
    "order": 100,
    "class_name": "plan-batch-initiated",
    "fill": "var(--plan-batch-initiated)",
    "color": "var(--plan-batch-initiated-color)"
  },
  {
    "code": "batch",
    "i18n": {
      "de": {
        "title": "Stapel"
      },
      "en": {
        "title": "Batch"
      },
      "es": {
        "title": "Lote"
      },
      "fr": {
        "title": "Lot"
      },
      "nl": {
        "title": "Batch"
      },
      "uk": {
        "title": "Партія"
      }
    },
    "group": "plan",
    "order": 110,
    "class_name": "plan-batch",
    "fill": "var(--plan-batch)",
    "color": "var(--plan-batch-color)"
  },
  {
    "code": "impact",
    "i18n": {
      "de": {
        "title": "Produktionsauswirkung"
      },
      "en": {
        "title": "Production impact"
      },
      "es": {
        "title": "Impacto de producción"
      },
      "fr": {
        "title": "Impact de production"
      },
      "nl": {
        "title": "Productie impact"
      },
      "uk": {
        "title": "Вплив на виробництво"
      }
    },
    "group": "plan",
    "order": 120,
    "class_name": "plan-impact",
    "fill": "var(--plan-impact)",
    "color": "var(--plan-impact-color)"
  },
  {
    "code": "planned",
    "i18n": {
      "de": {
        "title": "Geplant"
      },
      "en": {
        "title": "Planned"
      },
      "es": {
        "title": "Planificado"
      },
      "fr": {
        "title": "Planifié"
      },
      "nl": {
        "title": "Gepland"
      },
      "uk": {
        "title": "Заплановано"
      }
    },
    "group": "state",
    "order": 130,
    "class_name": "plan",
    "counts_as": "planned",
    "fill": "var(--plan)",
    "color": "var(--plan-color)"
  },
  {
    "code": "breaks",
    "i18n": {
      "de": {
        "title": "Pause"
      },
      "en": {
        "title": "Break"
      },
      "es": {
        "title": "Pausa"
      },
      "fr": {
        "title": "Pause"
      },
      "nl": {
        "title": "Break"
      },
      "uk": {
        "title": "Перерва"
      }
    },
    "group": "plan",
    "order": 140,
    "class_name": "plan-breaks",
    "fill": "var(--plan-breaks)",
    "color": "var(--plan-breaks-color)"
  },
  {
    "code": "changeovertime",
    "i18n": {
      "de": {
        "title": "Umrüstzeit"
      },
      "en": {
        "title": "Changeover time"
      },
      "es": {
        "title": "Tiempo de cambio"
      },
      "fr": {
        "title": "Temps de changement"
      },
      "nl": {
        "title": "Changeover time"
      },
      "uk": {
        "title": "Час переналагодження"
      }
    },
    "group": "plan",
    "order": 150,
    "class_name": "plan-changeovertime",
    "fill": "var(--plan-changeovertime)",
    "color": "var(--plan-changeovertime-color)"
  },
  {
    "code": "ticket",
    "i18n": {
      "de": {
        "title": "Ticket"
      },
      "en": {
        "title": "Ticket"
      },
      "es": {
        "title": "Ticket"
      },
      "fr": {
        "title": "Ticket"
      },
      "nl": {
        "title": "Ticket"
      },
      "uk": {
        "title": "Заявка"
      }
    },
    "group": "plan",
    "order": 160,
    "class_name": "plan-ticket",
    "fill": "var(--plan-ticket)",
    "color": "var(--plan-ticket-color)"
  },
  {
    "code": "maintenance",
    "i18n": {
      "de": {
        "title": "Wartung"
      },
      "en": {
        "title": "Maintenance"
      },
      "es": {
        "title": "Mantenimiento"
      },
      "fr": {
        "title": "Maintenance"
      },
      "nl": {
        "title": "Maintenance"
      },
      "uk": {
        "title": "Обслуговування"
      }
    },
    "group": "plan",
    "order": 170,
    "class_name": "plan-maintenance",
    "counts_as": "breakdown",
    "fill": "var(--plan-maintenance)",
    "color": "var(--plan-maintenance-color)"
  },
  {
    "code": "interruption",
    "i18n": {
      "de": {
        "title": "Unterbrechung"
      },
      "en": {
        "title": "Interruption"
      },
      "es": {
        "title": "Interrupción"
      },
      "fr": {
        "title": "Interruption"
      },
      "nl": {
        "title": "Onderbreking"
      },
      "uk": {
        "title": "Перерва у роботі"
      }
    },
    "group": "plan",
    "order": 180,
    "class_name": "plan-interruption",
    "counts_as": "breakdown",
    "fill": "var(--plan-interruption)",
    "color": "var(--plan-interruption-color)"
  },
  {
    "code": "producing",
    "i18n": {
      "de": {
        "title": "Produziert"
      },
      "en": {
        "title": "Producing"
      },
      "es": {
        "title": "Produciendo"
      },
      "fr": {
        "title": "En production"
      },
      "nl": {
        "title": "Producing"
      },
      "uk": {
        "title": "Виробництво"
      }
    },
    "group": "state",
    "order": 190,
    "class_name": "state-producing",
    "counts_as": "producing",
    "fill": "var(--state-producing)",
    "color": "var(--state-producing-color)"
  },
  {
    "code": "setup",
    "i18n": {
      "de": {
        "title": "Rüsten"
      },
      "en": {
        "title": "Setup"
      },
      "es": {
        "title": "Configuración"
      },
      "fr": {
        "title": "Configuration"
      },
      "nl": {
        "title": "Setup"
      },
      "uk": {
        "title": "Налаштування"
      }
    },
    "group": "state",
    "order": 200,
    "class_name": "state-setup",
    "counts_as": "producing",
    "fill": "var(--state-setup)",
    "color": "var(--state-setup-color)"
  },
  {
    "code": "running",
    "i18n": {
      "de": {
        "title": "Läuft"
      },
      "en": {
        "title": "Running"
      },
      "es": {
        "title": "En marcha"
      },
      "fr": {
        "title": "En marche"
      },
      "nl": {
        "title": "Running"
      },
      "uk": {
        "title": "В роботі"
      }
    },
    "group": "state",
    "order": 210,
    "class_name": "state-running",
    "fill": "var(--state-running)",
    "color": "var(--state-running-color)"
  },
  {
    "code": "idle",
    "i18n": {
      "de": {
        "title": "Leerlauf"
      },
      "en": {
        "title": "Idle"
      },
      "es": {
        "title": "Inactivo"
      },
      "fr": {
        "title": "Inactif"
      },
      "nl": {
        "title": "Idle"
      },
      "uk": {
        "title": "Неактивний"
      }
    },
    "group": "state",
    "order": 220,
    "class_name": "state-idle",
    "fill": "var(--state-idle)",
    "color": "var(--state-idle-color)"
  },
  {
    "code": "starved",
    "i18n": {
      "de": {
        "title": "Materialmangel"
      },
      "en": {
        "title": "Starved"
      },
      "es": {
        "title": "Sin material"
      },
      "fr": {
        "title": "Sous-alimenté"
      },
      "nl": {
        "title": "Starved"
      },
      "uk": {
        "title": "Голодування"
      }
    },
    "group": "state",
    "order": 230,
    "class_name": "state-starved",
    "fill": "var(--state-starved)",
    "color": "var(--state-starved-color)"
  },
  {
    "code": "starved.operator",
    "i18n": {
      "de": {
        "title": "Materialmangel"
      },
      "en": {
        "title": "Starved"
      },
      "es": {
        "title": "Sin material"
      },
      "fr": {
        "title": "Sous-alimenté"
      },
      "nl": {
        "title": "Starved"
      },
      "uk": {
        "title": "Голодування"
      }
    },
    "group": "state",
    "order": 240,
    "class_name": "state-starved",
    "alias_of": "starved",
    "fill": "var(--state-starved-operator)",
    "color": "var(--state-starved-operator-color)"
  },
  {
    "code": "blocked",
    "i18n": {
      "de": {
        "title": "Blockiert"
      },
      "en": {
        "title": "Blocked"
      },
      "es": {
        "title": "Bloqueado"
      },
      "fr": {
        "title": "Bloqué"
      },
      "nl": {
        "title": "Blocked"
      },
      "uk": {
        "title": "Заблоковано"
      }
    },
    "group": "state",
    "order": 250,
    "class_name": "state-blocked",
    "fill": "var(--state-blocked)",
    "color": "var(--state-blocked-color)"
  },
  {
    "code": "blocked.operator",
    "i18n": {
      "de": {
        "title": "Blockiert"
      },
      "en": {
        "title": "Blocked"
      },
      "es": {
        "title": "Bloqueado"
      },
      "fr": {
        "title": "Bloqué"
      },
      "nl": {
        "title": "Blocked"
      },
      "uk": {
        "title": "Заблоковано"
      }
    },
    "group": "state",
    "order": 260,
    "class_name": "state-blocked",
    "alias_of": "blocked",
    "fill": "var(--state-blocked-operator, var(--state-blocked))",
    "color": "var(--state-blocked-operator-color, var(--state-blocked-color))"
  },
  {
    "code": "starved.running",
    "i18n": {
      "de": {
        "title": "Materialmangel"
      },
      "en": {
        "title": "Starved"
      },
      "es": {
        "title": "Sin material"
      },
      "fr": {
        "title": "Sous-alimenté"
      },
      "nl": {
        "title": "Starved"
      },
      "uk": {
        "title": "Голодування"
      }
    },
    "group": "state",
    "order": 270,
    "class_name": "state-starved",
    "alias_of": "starved",
    "fill": "var(--state-starved-running, var(--state-starved))",
    "color": "var(--state-starved-running-color, var(--state-starved-color))"
  },
  {
    "code": "available",
    "i18n": {
      "de": {
        "title": "Verfügbar"
      },
      "en": {
        "title": "Available"
      },
      "es": {
        "title": "Disponible"
      },
      "fr": {
        "title": "Disponible"
      },
      "nl": {
        "title": "Beschikbaar"
      },
      "uk": {
        "title": "Доступно"
      }
    },
    "group": "state",
    "order": 275,
    "class_name": "state-available",
    "fill": "var(--state-available, transparent)",
    "color": "var(--state-available-color, #111111)"
  },
  {
    "code": "breakdown",
    "i18n": {
      "de": {
        "title": "Störung"
      },
      "en": {
        "title": "Breakdown"
      },
      "es": {
        "title": "Avería"
      },
      "fr": {
        "title": "Panne"
      },
      "nl": {
        "title": "Breakdown"
      },
      "uk": {
        "title": "Поломка"
      }
    },
    "group": "state",
    "order": 280,
    "class_name": "state-breakdown",
    "counts_as": "breakdown",
    "fill": "var(--state-breakdown)",
    "color": "var(--state-breakdown-color)"
  },
  {
    "code": "missingdata",
    "i18n": {
      "de": {
        "title": "Fehlende Daten"
      },
      "en": {
        "title": "Missing data"
      },
      "es": {
        "title": "Datos faltantes"
      },
      "fr": {
        "title": "Données manquantes"
      },
      "nl": {
        "title": "Missing data"
      },
      "uk": {
        "title": "Відсутні дані"
      }
    },
    "group": "state",
    "order": 290,
    "class_name": "state-missingdata",
    "counts_as": "offline",
    "fill": "var(--state-missingdata)",
    "color": "var(--state-missingdata-color)"
  },
  {
    "code": "offline",
    "i18n": {
      "de": {
        "title": "Offline"
      },
      "en": {
        "title": "Offline"
      },
      "es": {
        "title": "Sin conexión"
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
    "group": "state",
    "order": 300,
    "class_name": "state-offline",
    "counts_as": "offline",
    "fill": "var(--state-offline)",
    "color": "var(--state-offline-color)"
  },
  {
    "code": "installation",
    "i18n": {
      "de": {
        "title": "Installation"
      },
      "en": {
        "title": "Installation"
      },
      "es": {
        "title": "Instalación"
      },
      "fr": {
        "title": "Installation"
      },
      "nl": {
        "title": "Installation"
      },
      "uk": {
        "title": "Інсталяція"
      }
    },
    "group": "state",
    "order": 310,
    "class_name": "state-installation",
    "counts_as": "offline",
    "fill": "var(--state-installation)",
    "color": "var(--state-installation-color)"
  },
  {
    "code": "unavailable",
    "i18n": {
      "de": {
        "title": "Nicht verfügbar"
      },
      "en": {
        "title": "Unavailable"
      },
      "es": {
        "title": "No disponible"
      },
      "fr": {
        "title": "Indisponible"
      },
      "nl": {
        "title": "Niet beschikbaar"
      },
      "uk": {
        "title": "Недоступно"
      }
    },
    "group": "state",
    "order": 320,
    "class_name": "state-unavailable",
    "fill": "var(--state-unavailable, var(--state-offline))",
    "color": "var(--state-unavailable-color, var(--state-offline-color))"
  }
]
$json$::jsonb)
ON CONFLICT (lookup) DO UPDATE
SET lookup_json = EXCLUDED.lookup_json;

COMMIT;


-- ============================================================
-- verification
-- ============================================================

-- 1. flat and clean: 33 nodes, none nested, no old-form keys, no
--    counts_as outside the four buckets; expected: 33 | 0 | 0 | 0
SELECT jsonb_array_length(l.lookup_json)                                       AS nodes,
       count(*) FILTER (WHERE g.value ? 'states')                              AS nested,
       count(*) FILTER (WHERE NOT (g.value ? 'i18n') OR g.value ? 'block'
                           OR g.value ? 'color')                              AS old_form,
       count(*) FILTER (WHERE g.value ? 'counts_as'
                          AND g.value ->> 'counts_as' NOT IN
                              ('producing', 'breakdown', 'offline', 'planned')) AS bad_counts_as
FROM log.lookup l,
     jsonb_array_elements(l.lookup_json) AS g(value)
WHERE l.lookup = 'lookup_resource_state'
GROUP BY l.lookup_json;

-- 2. bucket overview, to check the counts_as choices in one go
SELECT coalesce(g.value ->> 'counts_as', '(none: loss inside production_hours)') AS counts_as,
       string_agg(g.value ->> 'code', ', ' ORDER BY (g.value ->> 'order')::int)  AS states
FROM log.lookup l,
     jsonb_array_elements(l.lookup_json) AS g(value)
WHERE l.lookup = 'lookup_resource_state'
GROUP BY 1
ORDER BY 1;

-- 3. states in the data without a node in the new lookup; expected: no rows
WITH lookup_codes AS (
    SELECT g.value ->> 'code' AS code
    FROM log.lookup l,
         jsonb_array_elements(l.lookup_json) AS g(value)
    WHERE l.lookup = 'lookup_resource_state'
),
used AS (
    SELECT DISTINCT state FROM log.state
    UNION
    SELECT DISTINCT state FROM log.state_shift_agg
)
SELECT u.state
FROM used u
LEFT JOIN lookup_codes lc ON lc.code = u.state
WHERE lc.code IS NULL
ORDER BY u.state;

-- 4. the old lookup in relation.lookup is untouched; expected: 4
--    top-level nodes, still nested
SELECT jsonb_array_length(l.lookup_json) AS top_level_nodes,
       l.lookup_json::text LIKE '%"states"%' AS still_nested
FROM relation.lookup l
WHERE l.lookup = 'lookup_resource_state';
