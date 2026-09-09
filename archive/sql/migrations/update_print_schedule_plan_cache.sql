-- One-off: mock.get_print_schedule flips between ~150 ms and 4-9 s depending
-- on which plan plpgsql cached for the session (pg_stat_statements on the
-- frontend statement: min 54 ms, max 9.351 ms, mean 520 ms over 75 calls).
-- p_only_starting_today changes the query shape; a generic plan serves both
-- values badly. Force a custom plan per call, like
-- mapping.get_production_orderline_detail already has. No drop needed: a
-- function setting is metadata.
ALTER FUNCTION mock.get_print_schedule(timestamp with time zone, text, integer[], boolean)
    SET plan_cache_mode = force_custom_plan;

-- check; expected: {plan_cache_mode=force_custom_plan}
SELECT p.proconfig
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'mock' AND p.proname = 'get_print_schedule';
