-- jsonb_toast_footprint_report.sql
--
-- Purpose:
-- List all tables with `jsonb` columns (regular or partitioned) across non-system schemas,
-- along with the presence and size of associated TOAST tables.
-- Helps identify tables with potentially large external TOAST storage caused by oversized JSONB fields.

SELECT
    n.nspname AS table_schema,  -- Schema name
    c.relname AS table_name,    -- Table name
    a.attname AS jsonb_column_name,  -- Name of the jsonb column

    -- TOAST status: does the table use external TOAST storage?
    CASE 
        WHEN c.reltoastrelid = 0 THEN 'No TOAST table (or all values fit inline)'
        ELSE 'Has TOAST table (OID: ' || c.reltoastrelid::text || ' - ' || tc.relname || ')'
    END AS toast_status,

    -- Total size of the table including TOAST and indexes
    pg_catalog.pg_total_relation_size(c.oid) AS total_table_size_bytes,
    pg_catalog.pg_size_pretty(pg_catalog.pg_total_relation_size(c.oid)) AS total_table_size_pretty,

    -- Size of the TOAST table (if present)
    CASE 
        WHEN c.reltoastrelid != 0 THEN pg_catalog.pg_total_relation_size(c.reltoastrelid)
        ELSE 0
    END AS toast_table_size_bytes,

    -- Human-readable size of TOAST table
    CASE 
        WHEN c.reltoastrelid != 0 THEN pg_catalog.pg_size_pretty(pg_catalog.pg_total_relation_size(c.reltoastrelid))
        ELSE 'N/A'
    END AS toast_table_size_pretty

FROM
    pg_catalog.pg_class c  -- Main table metadata
JOIN
    pg_catalog.pg_namespace n ON n.oid = c.relnamespace  -- Schema join
JOIN
    pg_catalog.pg_attribute a ON a.attrelid = c.oid  -- Table attributes (columns)
JOIN
    pg_catalog.pg_type t ON t.oid = a.atttypid  -- Data types
LEFT JOIN
    pg_catalog.pg_class tc ON tc.oid = c.reltoastrelid  -- Join to TOAST table (if any)

WHERE
    c.relkind IN ('r', 'p')  -- Include regular and partitioned tables
    AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')  -- Exclude system schemas
    AND t.typname = 'jsonb'  -- Focus on jsonb columns
    AND NOT a.attisdropped  -- Skip dropped columns

ORDER BY
    total_table_size_bytes DESC,
    toast_table_size_bytes DESC;
