/*
Subtransaction Pressure: Long-Running Top-Level XIDs

Purpose:
Identify long-lived transactions that may be delaying the cleanup of subtransaction state
(pg_subtrans), which tracks savepoints and nested transactions.

Context:
- PostgreSQL stores subtransaction metadata in a separate SLRU area: pg_subtrans.
- Long-running transactions delay VACUUM from marking their XIDs as frozen.
- As a result, pg_subtrans can grow uncontrollably, leading to disk bloat or eventual exhaustion.
- This is especially important in workloads with frequent savepoints, PL/pgSQL exception blocks,
  or deeply nested logic.

Why it matters:
- Unlike regular XID wraparound, pg_subtrans overflow is not well-monitored but can result in:
    * Write stalls
    * Disk pressure on PGDATA/pg_subtrans
    * Unrecoverable database shutdown in extreme edge cases

What to watch for:
- High `backend_xid_age` or `backend_xmin_age` indicates stalled XID advancement.
- Long `transaction_duration` means the backend may be holding multiple subtransactions alive.

*/

SELECT
    pid,                                    -- Backend process ID
    datname,                                -- Database name
    usename,                                -- Username running the transaction
    pg_catalog.age(backend_xid) AS backend_xid_age,     -- Age of the top-level XID (long age = VACUUM blocked)
    pg_catalog.age(backend_xmin) AS backend_xmin_age,   -- Age of the oldest XID the backend still needs
    NOW() - xact_start AS transaction_duration,         -- How long this transaction has been open
    state,                                  -- Backend state (active, idle in transaction, etc.)
    query                                   -- Currently running query (for correlation/diagnosis)
FROM
    pg_catalog.pg_stat_activity
WHERE
    backend_xid IS NOT NULL                 -- Filter to only include transactions with active XIDs
    AND state <> 'idle'                     -- Ignore idle sessions (not doing work)
ORDER BY
    GREATEST(
        pg_catalog.age(backend_xid),
        pg_catalog.age(backend_xmin)
    ) DESC,
    transaction_duration DESC
LIMIT 10;
