-- ============================================================
-- Antwoorden aan de frontend (6 sep): een titel per soort rij in
-- lookup_lane_item_type (set_title_field = type_json.i18n op bord 81), en de
-- primary keys van get_resource_plan zonder start_offset_in_seconds — die kolom
-- verandert bij het ketenen en slepen. plan en progress zijn uniek op
-- type + lane_item_id, actual op type + resource_uid + start_at.
-- Daarna sql/update_data_group_partial.sql (19, 56, 75, 81) draaien.
-- ============================================================

BEGIN;

UPDATE action.lookup
SET lookup_json = $lk$[
  {
    "type": "plan",
    "i18n": {
      "de": {
        "title": "Plan"
      },
      "en": {
        "title": "Plan"
      },
      "es": {
        "title": "Plan"
      },
      "fr": {
        "title": "Plan"
      },
      "nl": {
        "title": "Plan"
      },
      "uk": {
        "title": "План"
      }
    },
    "sort_order": 0,
    "class_names": [],
    "formula": [
      "start_offset_in_seconds=planned_start_offset_in_seconds",
      "duration_in_seconds=production_impact_in_seconds"
    ],
    "placement": "chain"
  },
  {
    "type": "progress",
    "i18n": {
      "de": {
        "title": "Fortschritt"
      },
      "en": {
        "title": "Progress"
      },
      "es": {
        "title": "Progreso"
      },
      "fr": {
        "title": "Avancement"
      },
      "nl": {
        "title": "Voortgang"
      },
      "uk": {
        "title": "Прогрес"
      }
    },
    "sort_order": 1,
    "class_names": [],
    "formula": [
      "start_offset_in_seconds=planned_start_offset_in_seconds",
      "duration_in_seconds=remaining_impact_in_seconds"
    ],
    "placement": "offset"
  },
  {
    "type": "actual",
    "i18n": {
      "de": {
        "title": "Ist"
      },
      "en": {
        "title": "Actual"
      },
      "es": {
        "title": "Real"
      },
      "fr": {
        "title": "Réel"
      },
      "nl": {
        "title": "Werkelijk"
      },
      "uk": {
        "title": "Факт"
      }
    },
    "sort_order": 2,
    "class_names": [],
    "gap_split_in_seconds": 900,
    "formula": [
      "start_offset_in_seconds=actual_start_offset_in_seconds",
      "duration_in_seconds=actual_duration_in_seconds"
    ],
    "placement": "offset"
  }
]$lk$::jsonb
WHERE lookup = 'lookup_lane_item_type';

UPDATE site.data_table
SET data_table_json = '{"primary_keys": ["type", "lane_item_id", "resource_uid", "start_at"]}'::jsonb
WHERE data_table = 'get_resource_plan';

COMMIT;

-- check: the keys are unique over a day; expected: 0
SELECT count(*) AS duplicate_keys
FROM (SELECT type, lane_item_id, resource_uid, start_at
      FROM action.get_resource_plan('2026-09-04 10:00+02', 'sheet')
      GROUP BY 1, 2, 3, 4 HAVING count(*) > 1) d;
