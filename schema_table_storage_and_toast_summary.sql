-- schema_table_storage_and_toast_summary.sql
-- 
-- Purpose:
-- Summarizes storage characteristics of all regular tables in the 'public' schema,
-- including estimated row count, total table size, average row length,
-- and any associated TOAST table usage.

SELECT
    main.relname AS table_name,  -- Name of the table
    main.reltuples AS estimated_live_rows,  -- Estimated number of live rows (from stats)
    
    -- Total storage size of the table (in bytes)
    pg_catalog.pg_relation_size(main.oid) AS table_size_bytes,
    
    -- Human-readable size of the table
    pg_catalog.pg_size_pretty(pg_catalog.pg_relation_size(main.oid)) AS table_size_pretty,

    -- Average size per row (bytes), based on estimated rows
    CASE
        WHEN main.reltuples > 0 THEN pg_catalog.pg_relation_size(main.oid) / main.reltuples
        ELSE 0
    END AS average_row_length_bytes,

    -- Size of associated TOAST table if exists, or fallback message
    COALESCE(pg_catalog.pg_size_pretty(pg_catalog.pg_relation_size(toast.oid)), 'No TOAST table') AS toast_table_size_pretty,

    -- Estimated number of TOAST chunks, if any
    COALESCE(toast.reltuples, 0) AS toast_table_chunks

FROM
    pg_catalog.pg_class main  -- Main table metadata
JOIN
    pg_catalog.pg_namespace nsp ON main.relnamespace = nsp.oid  -- Join to get schema name
LEFT JOIN
    pg_catalog.pg_class toast ON main.reltoastrelid = toast.oid  -- Join TOAST table metadata if present

WHERE
    nsp.nspname = 'public'  -- Limit to tables in the 'public' schema
    AND main.relkind = 'r'  -- Only include ordinary tables (exclude indexes, views, etc.)

ORDER BY
    pg_catalog.pg_relation_size(main.oid) DESC;  -- Order by size, largest tables first
