SELECT
    queryid,
    left(query, 80) AS sample_query,
    calls,
    ROUND(total_exec_time::numeric / calls, 3) AS avg_latency_ms,
    ROUND((calls / GREATEST(EXTRACT(EPOCH FROM (now() - pg_postmaster_start_time())), 1))::numeric, 2) AS qps,
    ROUND((total_exec_time / GREATEST(EXTRACT(EPOCH FROM (now() - pg_postmaster_start_time())), 1))::numeric, 2) AS total_exec_ms_per_sec,

    -- Row efficiency
    ROUND((rows / NULLIF(calls, 0))::numeric, 1) AS avg_rows,
    ROUND((rows / NULLIF(total_exec_time, 0))::numeric, 1) AS rows_per_ms,

    -- I/O efficiency (index effectiveness)
    ROUND((shared_blks_hit::numeric / NULLIF(shared_blks_hit + shared_blks_read, 0) * 100), 2) AS cache_hit_pct,
    shared_blks_read AS disk_reads,

    -- Temp space usage (CRITICAL for finding memory exhaustion)
    pg_size_pretty(temp_blks_written * 8192) AS temp_space_used,

    -- Write impact (for INSERT/UPDATE/DELETE)
    shared_blks_dirtied AS pages_dirtied,

    -- Pattern detection
    CASE
        WHEN rows / NULLIF(calls, 0) < 1 THEN '⚠️ low-yield'
        WHEN rows / NULLIF(calls, 0) > 10000 THEN '🔥 high-yield'
        WHEN (shared_blks_hit::numeric / NULLIF(shared_blks_hit + shared_blks_read, 0) * 100) < 90 THEN '💾 disk-bound'
        WHEN temp_blks_written > 1000 THEN '💥 spilling-to-disk'
        ELSE '✓'
    END AS pattern
FROM pg_stat_statements
WHERE query NOT LIKE '%pg_stat_statements%'
ORDER BY total_exec_time DESC
LIMIT 25;
