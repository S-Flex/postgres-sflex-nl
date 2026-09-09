-- Step 1 + 2 of archive/docs/plan-production-board-customer-filter.md: the customer
-- table, its backfill, the search function and the crud hook. Safe to run
-- ahead of the board changes — nothing reads the table yet.

BEGIN;

-- 1. the table: one row per customer, fed by the specs stream
CREATE TABLE mapping.customer
(
    customer_id integer NOT NULL
        CONSTRAINT pk_mapping_customer
            PRIMARY KEY,
    company_name text NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE mapping.customer OWNER TO xfw3;

-- 2. backfill: the newest known name per customer
INSERT INTO mapping.customer (customer_id, company_name)
SELECT DISTINCT ON (cs.customer_id) cs.customer_id, cs.company_name
FROM mapping.component_specs cs
WHERE cs.customer_id IS NOT NULL
  AND cs.company_name IS NOT NULL
ORDER BY cs.customer_id, cs.orderline_updated_at DESC NULLS LAST
ON CONFLICT (customer_id) DO NOTHING;

-- 3. data_table rows so the filter selects can use these as src
--    (query is just the schema-qualified function name, like every row)
INSERT INTO site.data_table (data_table, query, stored_proc, description, do_cache)
VALUES
    ('get_customers',        'mapping.get_customers',         '', 'get_customers',        false),
    ('get_production_lines', 'relation.get_production_lines', '', 'get_production_lines', false),
    ('get_numbers',          'site.get_numbers',              '', 'get_numbers',          false)
ON CONFLICT (data_table) DO NOTHING;

COMMIT;

-- >>> now run:
--     sql/mapping/get_customers.sql
--     sql/mapping/crud_component_specs_orderline.sql  (gains the customer upsert)
--     sql/relation/get_production_lines.sql           (drops itself first: new flat return type)
