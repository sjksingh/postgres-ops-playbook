-- toast_io_access_profile_top20.sql
--
-- Purpose:
-- Show I/O access patterns for user tables with TOAST storage,
-- highlighting how much block-level I/O (read and cache hits) is spent on TOAST data.
-- Helps identify large or frequently accessed TOAST-heavy tables for performance tuning or schema review.

SELECT 
    s.schemaname,  -- Schema name the table belongs to

    s.relname AS table_name,  -- Table name

    -- Total disk size of the table including TOAST, indexes, and auxiliary data
    pg_catalog.pg_size_pretty(pg_catalog.pg_total_relation_size(s.relid)) AS total_size,

    -- Number of blocks read from disk for main table heap
    s.heap_blks_read AS main_table_disk_reads,

    -- Number of blocks served from shared buffers (cache) for main table
    s.heap_blks_hit AS main_table_buffer_hits,

    -- Number of blocks read from disk for TOAST data
    s.toast_blks_read AS toast_table_disk_reads,

    -- Number of TOAST blocks served from shared buffers (cache)
    s.toast_blks_hit AS toast_table_buffer_hits,

    -- Total block accesses (disk + cache) for main table heap
    (s.heap_blks_read + s.heap_blks_hit) AS total_main_blocks_accessed,

    -- Total block accesses (disk + cache) for TOAST table
    (s.toast_blks_read + s.toast_blks_hit) AS total_toast_blocks_accessed,

    -- Percentage of total block activity attributable to TOAST data
    CASE 
        WHEN (s.heap_blks_read + s.heap_blks_hit + s.toast_blks_read + s.toast_blks_hit) > 0 
        THEN ROUND(((s.toast_blks_read + s.toast_blks_hit)::numeric * 100) /
                   (s.heap_blks_read + s.heap_blks_hit + s.toast_blks_read + s.toast_blks_hit)::numeric, 2)
        ELSE 0 
    END AS toast_access_percentage_of_total_blocks

FROM 
    pg_catalog.pg_statio_user_tables s  -- System view with per-table I/O stats

JOIN
    pg_catalog.pg_class c ON c.oid = s.relid  -- To filter on presence of TOAST table

WHERE 
    c.reltoastrelid != 0  -- Only include tables that actually use TOAST storage

ORDER BY 
    total_toast_blocks_accessed DESC  -- Focus on TOAST-intensive tables

LIMIT 20;  -- Top 20 tables by TOAST block access
