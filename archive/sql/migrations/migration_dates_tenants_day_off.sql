-- ============================================================
-- Migration: action.dates gets tenants_mandatory_day_off; every
-- reader of is_mandatory_day_off becomes tenant-aware and gains
-- p_tenant_ids where it was missing. The parameter name is
-- p_include_mandatory_days_off everywhere (the _dates variant
-- is renamed). A date is a mandatory day off for the caller when
-- every requested tenant has it off:
--   coalesce(p_tenant_ids, tenants_mandatory_day_off)
--       <@ tenants_mandatory_day_off
--   and tenants_mandatory_day_off <> '{}'
-- (no tenant scope: off as soon as any tenant is off).
--
-- The boolean is_mandatory_day_off column STAYS for now; it can
-- be dropped once nothing outside this migration reads it.
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- 1. action.dates: the tenant day-off list
--    (backfill: ARRAY[1,2] on every mandatory day off, to be
--    refined by hand afterwards)
-- ------------------------------------------------------------
ALTER TABLE action.dates RENAME COLUMN tenant_id TO tenants_mandatory_day_off;

ALTER TABLE action.dates
    ALTER COLUMN tenants_mandatory_day_off TYPE integer[]
    USING CASE WHEN is_mandatory_day_off THEN ARRAY[1,2] ELSE '{}'::integer[] END;

ALTER TABLE action.dates ALTER COLUMN tenants_mandatory_day_off SET DEFAULT '{}'::integer[];
ALTER TABLE action.dates ALTER COLUMN tenants_mandatory_day_off SET NOT NULL;

COMMENT ON COLUMN action.dates.tenants_mandatory_day_off IS
    'The tenants that have this day off; replaces the boolean is_mandatory_day_off, which stays until every reader is adapted.';

-- ------------------------------------------------------------
-- 2. drop the changed functions (files without their own drop
--    header; signatures are the pre-migration ones)
-- ------------------------------------------------------------
DROP FUNCTION action.get_date_window(timestamp with time zone, integer, integer, boolean, boolean);
DROP FUNCTION action.get_interval_dates(date, date, integer, integer, boolean, boolean, integer);
DROP FUNCTION action.get_nest_schedule_test(timestamp with time zone, text, integer, integer, numeric);
DROP FUNCTION log.get_resource_state_shift_totals(text[], timestamp with time zone, integer, text, text[], boolean, boolean, boolean, text);
DROP FUNCTION mapping.calculate_nest_date(date, integer);
DROP FUNCTION mapping.get_time_on_status(text, timestamp with time zone, integer, integer);
DROP FUNCTION IF EXISTS mock.get_print_schedule(timestamp with time zone, text, integer[], boolean);
DROP FUNCTION IF EXISTS mock.get_print_schedule_materials(timestamp with time zone, text, text, integer[], boolean);
DROP FUNCTION mock.get_print_schedule_test(timestamp with time zone, text, integer[], boolean);
DROP FUNCTION production.get_timeline_view_segments(text, timestamp with time zone, integer, integer);
DROP FUNCTION site.refresh_derived_data();

-- >>> now run (the mapping files drop themselves; order is free):
--     sql/action/get_date_window.sql
--     sql/action/get_interval_dates.sql
--     sql/action/get_nest_schedule_test.sql
--     sql/log/get_resource_state_shift_totals.sql
--     sql/mapping/calculate_nest_date.sql
--     sql/mapping/get_production_orderline_detail.sql
--     sql/mapping/get_production_orderline_aggregate.sql
--     sql/mapping/get_production_orderline_manifest.sql
--     sql/mapping/get_time_on_status.sql
--     sql/mock/get_print_schedule.sql
--     sql/mock/get_print_schedule_materials.sql
--     sql/mock/get_print_schedule_test.sql
--     sql/production/get_timeline_view_segments.sql
--     sql/site/refresh_derived_data.sql

COMMIT;

-- ============================================================
-- 3. BLOCKED — do NOT run yet: dropping shift_json breaks
--    log.upsert_state_shift_agg (runs daily via
--    site.refresh_derived_data) and
--    log.get_resource_state_shift_totals, which both read
--    action.dates.shift_json. Give those two a new shift source
--    (relation.shift_planning?) first, then:
--
--   ALTER TABLE action.dates DROP COLUMN shift_json;
-- ============================================================
