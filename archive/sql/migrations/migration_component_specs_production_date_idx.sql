-- One-off: the date-led index for the forecast readers, see the comment in
-- sql/mapping/component_specs.sql. CONCURRENTLY, so it cannot run inside a
-- transaction block: run this file on its own, not with BEGIN/COMMIT.
-- Read-only check afterwards: the actual CTE of
-- mock.get_production_forecast_material should show an Index Only Scan.
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_component_specs_production_date
    ON mapping.component_specs (production_date)
    INCLUDE (first_production_line_id, material_id, sqm, internal_status_code);

ANALYZE mapping.component_specs;
