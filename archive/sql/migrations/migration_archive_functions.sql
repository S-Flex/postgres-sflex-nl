-- Archive step 2 of docs/archive-analysis.md: drop the first batch of
-- functions that were only reachable through unused data_groups (their
-- definition files moved to archive/sql/). Signatures taken verbatim from
-- those files.

BEGIN;

DROP FUNCTION IF EXISTS job.get_job_summary(integer, integer);
DROP FUNCTION IF EXISTS relation.get_production_line_block_sum();
DROP FUNCTION IF EXISTS relation.get_production_line_conversion_margin_stats();
DROP FUNCTION IF EXISTS relation.get_production_line_oee_stats();
DROP FUNCTION IF EXISTS relation.get_production_line_production_faults();
DROP FUNCTION IF EXISTS relation.get_production_line_resources();
DROP FUNCTION IF EXISTS relation.get_production_line_status_time();
DROP FUNCTION IF EXISTS relation.get_production_line_model();
DROP FUNCTION IF EXISTS relation.get_resource_info(integer);
DROP FUNCTION IF EXISTS relation.get_resource_maintenance();
DROP FUNCTION IF EXISTS relation.get_resource_status(integer);
DROP FUNCTION IF EXISTS action.rule_path_matches(text, text[]);
DROP FUNCTION IF EXISTS action.rule_path_ancestors(text);

-- batch 4 (7 sep): two copies nobody calls. mock.get_resource_plan_batch is the
-- twin of log.get_resource_plan_batch (the one get_resource_timeline uses);
-- mock.get_print_schedule_test is the test copy of get_print_schedule
DROP FUNCTION IF EXISTS mock.get_resource_plan_batch(text, timestamp with time zone, timestamp with time zone);
DROP FUNCTION IF EXISTS mock.get_print_schedule_test(timestamp with time zone, text, integer[], boolean);

COMMIT;
