/*
Concurrent Shared Row Locks Overview (Non-System Tables)

Purpose:
Identify rows in user-defined tables that are locked by *multiple* concurrent transactions 
using "shared" row-level lock modes (e.g., from SELECT ... FOR SHARE or FOR KEY SHARE).

Context:
- When multiple transactions acquire shared locks on the same row, PostgreSQL groups them
  into a single MultiXact. Each participant uses one slot in the MultiXact member space.
- High numbers of such shared locks can rapidly exhaust member slots, especially in high-concurrency workloads.
- This was a contributing factor in the MultiXact exhaustion outage reported by Metronome.

What to Watch For:
- High `concurrent_locking_transactions`: Indicates rows being accessed concurrently under shared locks.
- Use `locking_pids` to trace individual sessions (e.g., in `pg_stat_activity`).
- Optionally enable query tracking to correlate lock contention to application-level behavior.

Optional:
- You can join `pg_stat_activity` to retrieve active queries, but this may be heavy in production.

NOTE:
- Tuple-level lock visibility depends on your workload and timing.
*/

SELECT
    ns.nspname AS schema_name,                         -- Schema name
    c.relname AS table_name,                           -- Table name
    l.page AS page_number,                             -- Page number of the tuple
    l.tuple AS tuple_on_page_idx,                      -- Index of the tuple on the page
    l.mode AS lock_mode,                               -- Lock mode (e.g., RowShareLock, ShareLock)
    COUNT(DISTINCT l.pid) AS concurrent_locking_transactions, -- How many PIDs hold this lock
    array_agg(DISTINCT l.pid) AS locking_pids          -- List of backend PIDs holding this lock
    -- Optionally include locking queries; be cautious on production systems:
    -- , array_agg(DISTINCT psa.query) FILTER (WHERE psa.query IS NOT NULL AND psa.query <> '') AS distinct_locking_queries
FROM
    pg_catalog.pg_locks l
JOIN
    pg_catalog.pg_class c ON l.relation = c.oid
JOIN
    pg_catalog.pg_namespace ns ON c.relnamespace = ns.oid
-- LEFT JOIN pg_catalog.pg_stat_activity psa ON l.pid = psa.pid -- Uncomment if including queries
WHERE
    ns.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')  -- Ignore system schemas
    AND c.relkind IN ('r', 'm', 'p')  -- Ordinary, materialized view, partitioned tables
    AND l.locktype = 'tuple'         -- Only interested in row-level locks
    AND l.granted = true             -- Only locks currently granted
    AND l.mode IN (
        'RowShareLock',              -- SELECT FOR KEY SHARE / FOR UPDATE
        'ShareLock'                  -- SELECT FOR SHARE
    )
GROUP BY
    ns.nspname,
    c.relname,
    l.page,
    l.tuple,
    l.mode
HAVING
    COUNT(DISTINCT l.pid) > 1  -- Only show tuples locked by more than one transaction
ORDER BY
    concurrent_locking_transactions DESC,
    schema_name,
    table_name,
    page_number,
    tuple_on_page_idx;
