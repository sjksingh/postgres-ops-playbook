/*
WAL Disk Pressure and Archiving Health Check

Purpose:
Monitor potential causes of Write-Ahead Log (WAL) disk space exhaustion, which can halt all database writes.

Context:
- All changes in PostgreSQL are first written to WAL for durability and crash recovery.
- WAL files reside in $PGDATA/pg_wal or a custom mount point.
- WAL accumulation can occur due to:
    - High write throughput
    - Archiver or replication falling behind
    - Lack of disk space
    - Archiving failures
- If the WAL directory fills up, PostgreSQL will stop accepting writes.

What to monitor:
- Archiver status and failure trends (from pg_stat_archiver)
- WAL file count (via pg_ls_waldir if available)
- Current WAL position (via pg_current_wal_lsn)
- Disk space in pg_wal mount (requires OS-level monitoring)

*/

SELECT
    archived_count,         -- Total number of WAL files successfully archived
    last_archived_wal,      -- Name of last successfully archived WAL segment
    last_archived_time,     -- Timestamp of the last successful archive
    failed_count,           -- Total number of failed archive attempts
    last_failed_wal,        -- Name of the WAL file that last failed to archive
    last_failed_time,       -- Timestamp of the last failed archive
    stats_reset             -- When these statistics were last reset
FROM
    pg_catalog.pg_stat_archiver;

-- WAL File Count Estimate and LSN Position
-- Requires pg_ls_waldir() (PostgreSQL 10+). Privilege-sensitive.
SELECT
    pg_catalog.pg_current_wal_lsn() AS current_wal_lsn,  -- Current WAL write position
    (SELECT COUNT(*) FROM pg_catalog.pg_ls_waldir()) AS current_wal_files_count; -- Number of WAL segments

-- Optional: Track WAL growth rate
-- You can sample pg_current_wal_lsn() at intervals and use:
-- SELECT pg_wal_lsn_diff('LSN2', 'LSN1');
-- This measures bytes written between snapshots.
