/*
Transaction ID Wraparound Risk Analysis (XID Freeze Monitoring)

Purpose:
This query reports the age of the oldest unfrozen transaction ID (XID) in each user-accessible database.
It compares this age against:
  1. autovacuum_freeze_max_age — when PostgreSQL triggers aggressive autovacuums.
  2. 2 billion — the critical hard shutdown limit to prevent transaction ID wraparound.

Why it matters:
- PostgreSQL uses 32-bit transaction IDs, which can wrap around.
- If XIDs aren't frozen in time, PostgreSQL will forcibly shut down to avoid data corruption.
- This query helps you proactively monitor and tune autovacuum to prevent outages.

What to watch for:
- percent_towards_autovac_freeze > 70%: Indicates databases approaching aggressive autovacuum threshold.
- percent_towards_critical_wraparound_limit > 80%: Dangerous! Requires immediate manual VACUUM or VACUUM FREEZE.
*/

SELECT
    d.datname AS database_name,                            -- Name of the database
    pg_catalog.age(d.datfrozenxid) AS current_oldest_xid_age, -- Age of the oldest unfrozen XID
    s.setting::bigint AS autovac_freeze_max_age,           -- Configured freeze age threshold
    ROUND(
        (pg_catalog.age(d.datfrozenxid)::numeric * 100 / s.setting::numeric),
        2
    ) AS percent_towards_autovac_freeze,                   -- % towards autovacuum threshold
    ROUND(
        (pg_catalog.age(d.datfrozenxid)::numeric * 100 / 2000000000::numeric),
        2
    ) AS percent_towards_critical_wraparound_limit,        -- % towards shutdown risk
    pg_catalog.pg_size_pretty(pg_catalog.pg_database_size(d.datname)) AS db_size -- Database size
FROM
    pg_catalog.pg_database d
JOIN
    pg_catalog.pg_settings s
    ON s.name = 'autovacuum_freeze_max_age'
WHERE
    d.datallowconn  -- Only include databases that allow connections
ORDER BY
    pg_catalog.age(d.datfrozenxid) DESC;  -- Show highest-risk DBs first
