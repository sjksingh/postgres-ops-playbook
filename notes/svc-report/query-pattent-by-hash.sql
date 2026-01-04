-- ==========================================
-- FIND QUERY HASH FOR SLOW DEDUP QUERY
-- ==========================================

-- 1️⃣ Find the query by pattern matching (PostgreSQL 13 compatible)
SELECT 
  queryid,
  to_hex(queryid) as query_hash_hex,
  '0x' || upper(to_hex(queryid)) as bash_script_format,
  calls,
  (total_time / calls)::numeric(10,2) as avg_ms,
  (max_time)::numeric(10,2) as max_ms,
  (total_time / 1000)::numeric(10,2) as total_sec,
  LEFT(query, 150) as query_preview
FROM pg_stat_statements
WHERE query LIKE '%reports.reports%'
  AND query LIKE '%completed_at IS NULL%'
  AND query LIKE '%EXTRACT%'
  AND query LIKE '%ORDER BY created_at DESC%'
  AND (total_time / calls) > 1000  -- avg > 1 second
ORDER BY (total_time / calls) DESC
LIMIT 10;

-- 2️⃣ Alternative: Find by userid (if you know which user runs it)
SELECT 
  queryid,
  '0x' || upper(to_hex(queryid)) as query_hash,
  userid::regrole as db_user,
  calls,
  (total_exec_time / calls)::numeric(10,2) as avg_ms,
  (max_exec_time)::numeric(10,2) as max_ms,
  LEFT(query, 100) as query_preview
FROM pg_stat_statements
WHERE userid::regrole::text IN ('90300', '90235', '90229', '90232', '90217')
  -- These are the userids from your earlier pg_stat_statements output
ORDER BY (total_exec_time / calls) DESC;

-- 3️⃣ Find ALL slow queries on reports table (broader search)
SELECT 
  queryid,
  '0x' || upper(to_hex(queryid)) as query_hash,
  userid::regrole as db_user,
  calls,
  (total_exec_time / calls)::numeric(10,2) as avg_ms,
  (max_exec_time)::numeric(10,2) as max_ms,
  (total_exec_time / 1000)::numeric(10,2) as total_sec,
  LEFT(query, 200) as query_preview
FROM pg_stat_statements
WHERE query LIKE '%reports.reports%'
  AND (total_exec_time / calls) > 5000  -- avg > 5 seconds
ORDER BY total_exec_time DESC
LIMIT 20;

-- ==========================================
-- EXPECTED OUTPUT FORMAT
-- ==========================================

/*
You should see something like:

 queryid           | query_hash_hex      | bash_script_format   | calls | avg_ms   | max_ms   | total_sec
-------------------+---------------------+----------------------+-------+----------+----------+-----------
 4523089743892015  | 1014A5B2C8D9E3F     | 0x1014A5B2C8D9E3F    | 52    | 12072.20 | 13323.47 | 627.75
 
Then you can use: bash 2-pg-diagnose-query.sh 0x1014A5B2C8D9E3F
*/

-- ==========================================
-- IF QUERY_HASH NOT FOUND
-- ==========================================

-- Check if pg_stat_statements is tracking this query
SELECT 
  COUNT(*) as total_queries_tracked,
  COUNT(*) FILTER (WHERE query LIKE '%reports%') as reports_queries,
  COUNT(*) FILTER (WHERE calls > 10) as frequently_called
FROM pg_stat_statements;

-- If pg_stat_statements was recently reset, you might not find old queries
SELECT 
  stats_reset,
  NOW() - stats_reset as time_since_reset
FROM pg_stat_database
WHERE datname = current_database();

-- ==========================================
-- ALTERNATIVE: GET FULL QUERY FOR SCRIPT
-- ==========================================

-- If you want to save the full query to a file:
SELECT query 
FROM pg_stat_statements
WHERE queryid = YOUR_QUERY_ID_HERE  -- Replace with the queryid you found
\g /tmp/slow_dedup_query.sql

-- Or copy it to clipboard (if you have \copy available):
\copy (SELECT query FROM pg_stat_statements WHERE queryid = YOUR_QUERY_ID_HERE) TO '/tmp/query.sql'
