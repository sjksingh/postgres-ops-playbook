/*
This query checks the multixact ID age across all databases
to identify potential wraparound risks related to autovacuum.
It helps determine whether VACUUM tuning is needed.

What to watch for:
- percent_towards_autovac_freeze_limit:
    * >75–80% = serious concern; risk of forced autovacuum wraparound.
    * >50% on large/busy DBs = needs investigation
*/

SELECT
    d.datname,  -- Database name
    pg_catalog.mxid_age(d.datminmxid) AS current_oldest_mxid_age,  -- Age of the oldest multixact ID
    s.setting::bigint AS autovac_mxid_freeze_max_age,  -- Configured autovacuum freeze age threshold
    ROUND(
        (pg_catalog.mxid_age(d.datminmxid)::numeric * 100 / s.setting::numeric), 
        2
    ) AS percent_towards_autovac_freeze_limit,  -- % usage towards freeze limit
    pg_catalog.pg_size_pretty(pg_catalog.pg_database_size(d.datname)) AS db_size  -- Human-readable DB size
FROM
    pg_catalog.pg_database d
JOIN
    pg_catalog.pg_settings s 
    ON s.name = 'autovacuum_multixact_freeze_max_age'
WHERE
    d.datallowconn  -- Only include databases that allow connections
ORDER BY
    percent_towards_autovac_freeze_limit DESC;  -- Show most at-risk databases first
