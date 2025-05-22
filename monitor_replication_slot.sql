-- Query: Monitor replication slot WAL retention for pg13 and below
-- This shows how much WAL is being retained due to each replication slot.
-- Useful for detecting slots that may be preventing WAL recycling and causing disk bloat.

SELECT
    rs.slot_name,
    rs.plugin,
    rs.slot_type,
    d.datname AS database_name,
    rs.active,
    rs.active_pid,
    rs.xmin,
    rs.catalog_xmin,
    rs.restart_lsn,
    rs.confirmed_flush_lsn,
    pg_catalog.pg_size_pretty(
        pg_catalog.pg_wal_lsn_diff(
            pg_catalog.pg_current_wal_lsn(),
            COALESCE(rs.restart_lsn, rs.confirmed_flush_lsn, '0/0')
        )
    ) AS wal_retained_for_slot_approx_size,
    rs.wal_status       
FROM
    pg_catalog.pg_replication_slots rs
LEFT JOIN
    pg_catalog.pg_database d ON rs.datoid = d.oid
ORDER BY
    rs.active DESC,
    pg_catalog.pg_wal_lsn_diff(
        pg_catalog.pg_current_wal_lsn(),
        COALESCE(rs.restart_lsn, rs.confirmed_flush_lsn, '0/0')
    ) DESC;
