-- Archive step 1 of docs/archive-analysis.md: delete the first batch of
-- unused data_groups (not referenced by json/data/block/pages.json).
-- The repo files moved to archive/data_group/ and the site export no longer
-- carries them, so json and table stay in step after this runs.
-- Scope: site.data_group only — their orphaned data_tables and functions
-- follow in a later batch (see the report's caveats on external callers).

BEGIN;

DELETE FROM site.data_group
WHERE data_group_id IN (17, 20, 21, 28, 32, 33, 37, 60, 61)
RETURNING data_group_id, data_group;

COMMIT;
