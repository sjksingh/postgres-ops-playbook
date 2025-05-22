/*
Purpose:
Identify long-running transactions that may be holding back VACUUM progress
and preventing the cleanup of old MultiXact IDs and their members.

Context:
Long-lived transactions keep the xmin horizon from advancing, which can block
the removal of dead tuples and MultiXact member slots. These slots are limited
and exhaustion leads to outages.

What to watch for:
- High xmin_age_interval: Indicates old transaction snapshots.
- Long transaction_duration: Long-lived transactions that can delay cleanup.

How it relates:
These sessions may be blocking autovacuum from reclaiming old data, even if
mxid_age isn't at emergency levels (see previous query).

Operational Insight:
In update/delete active environments  MultiXact member space exhaustion occurred
even when overall mxid_age looked healthy, due to shared-row locking pressure.
*/

SELECT
    pid,                                -- Process ID of the backend
    datname,                            -- Database name
    usename,                            -- Username of the connected role
    pg_catalog.age(backend_xmin) AS xmin_age_interval,  -- Age of snapshot horizon (xid)
    NOW() - xact_start AS transaction_duration,         -- How long transaction has been open
    NOW() - query_start AS query_duration,              -- How long the current query has been running
    state,                              -- Current backend state (active, idle, etc.)
    wait_event_type,                    -- Category of event backend is waiting on
    wait_event,                         -- Specific event being waited on
    query                               -- Text of the active query
FROM
    pg_catalog.pg_stat_activity
WHERE
    backend_xmin IS NOT NULL            -- Only include backends holding an xmin snapshot
ORDER BY
    pg_catalog.age(backend_xmin) DESC,
    transaction_duration DESC
LIMIT 20;
