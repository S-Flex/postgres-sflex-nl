-- Rollback of sql/update_waste_percentage.sql: the waste arrays back to
-- waste_factor and the gross imposition_sqm, straight from the backup.
--
-- Put the two readers back on the old key as well, from the repo at the commit
-- before the rename:
--   sql/action/get_plan_lanes_imposition_group.sql
--   sql/mapping/get_production_orderline_manifest.sql

BEGIN;

UPDATE legacy.imposition_group g
SET rules_json = bk.rules_json
FROM legacy.imposition_group_rules_backup_20260916 bk
WHERE (g.tenant_id, g.imposition_group_id) = (bk.tenant_id, bk.imposition_group_id);

DROP TABLE legacy.imposition_group_rules_backup_20260916;

COMMIT;
