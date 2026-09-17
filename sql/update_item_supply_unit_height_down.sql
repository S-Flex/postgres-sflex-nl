-- Rollback of sql/update_item_supply_unit_height.sql: the item_json back from
-- the backup, so supply_unit_height is gone again.

BEGIN;

UPDATE catalog.item i
SET item_json = bk.item_json
FROM catalog.item_json_backup_20260917 bk
WHERE bk.item_id = i.item_id;

DROP TABLE catalog.item_json_backup_20260917;

COMMIT;
