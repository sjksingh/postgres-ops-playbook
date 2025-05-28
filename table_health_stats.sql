-- table_health_stats.sql
-- Description: This script queries pg_stat_user_tables to display health and activity 
-- statistics for specific user tables. It helps assess table bloat, vacuum/analyze activity,
-- and overall write activity.

SELECT
    schemaname,  
    relname AS table_name,  
    n_live_tup AS live_rows,  -- Approximate number of live rows
    n_dead_tup AS dead_rows,  -- Approximate number of dead rows (bloat indicator)
    n_tup_ins AS rows_inserted,  -- Cumulative number of rows inserted
    n_tup_upd AS rows_updated,  -- Cumulative number of rows updated
    n_tup_del AS rows_deleted,  -- Cumulative number of rows deleted
    n_mod_since_analyze AS rows_modified_since_last_analyze, 
    pg_catalog.pg_size_pretty(pg_catalog.pg_total_relation_size(relid)) AS total_table_size,  -- Human-readable size of the table (incl. indexes, TOAST)
    last_vacuum,  
    last_autovacuum,  
    last_analyze,  
    last_autoanalyze, 
    vacuum_count, 
    autovacuum_count,  
    analyze_count,  
    autoanalyze_count  
FROM
    pg_catalog.pg_stat_user_tables
--WHERE
  --  relname IN (
  --    'custom_tags', 
  --  'domain_statuses', 
  --     'domain_custom_tags', 
   --     'domain_assignees'
   -- )  -- Filter to monitor only selected tables
ORDER BY -- dead rows (bloat indicator)
    4 DESC;

