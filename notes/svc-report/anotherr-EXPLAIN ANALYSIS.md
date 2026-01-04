-- ==========================================
-- EXPLAIN ANALYSIS
-- Get query execution plan to understand bottleneck
-- ==========================================

-- First, check existing indexes on reports.reports
SELECT
  schemaname,
  relname as table_name,
  indexrelname as index_name,
  idx_scan as times_used,
  idx_tup_read,
  idx_tup_fetch,
  pg_size_pretty(pg_relation_size(indexrelid)) as index_size
FROM pg_stat_user_indexes
WHERE schemaname = 'reports'
  AND relname = 'reports'  -- Note: relname not tablename
ORDER BY idx_scan DESC;

-- Check table structure and existing indexes
\d reports.reports

-- Get table size and row count
SELECT 
  schemaname,
  relname,
  n_live_tup as row_count,
  pg_size_pretty(pg_total_relation_size(schemaname||'.'||relname)) as total_size,
  pg_size_pretty(pg_relation_size(schemaname||'.'||relname)) as table_size,
  pg_size_pretty(pg_total_relation_size(schemaname||'.'||relname) - pg_relation_size(schemaname||'.'||relname)) as index_size
FROM pg_stat_user_tables
WHERE schemaname = 'reports'
  AND relname = 'reports';

-- ==========================================
-- Run EXPLAIN ANALYZE with realistic parameters
-- ==========================================

-- IMPORTANT: Replace these with actual values from your application
-- You can find common values by checking recent queries:
SELECT 
  report_type,
  title,
  format,
  organization_id,
  COUNT(*) as frequency
FROM reports.reports
WHERE completed_at IS NULL
  AND created_at > NOW() - INTERVAL '7 days'
GROUP BY report_type, title, format, organization_id
ORDER BY frequency DESC
LIMIT 10;

-- Now run EXPLAIN ANALYZE with common values
-- Example (adjust these based on your data):
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, COSTS)
SELECT id, report_type, params, created_at, created_by, title, format, 
       started_at, completed_at, result 
FROM reports.reports 
WHERE report_type = 'sales_report'  -- Replace with real value
  AND title = 'Monthly Sales'       -- Replace with real value
  AND format = 'pdf'                -- Replace with real value
  AND user_id = 12345               -- Replace with real user_id
  AND params = '{"period":"monthly"}'::jsonb  -- Replace with real params
  AND organization_id = 100         -- Replace with real org_id
  AND EXTRACT(EPOCH FROM current_timestamp - created_at)/60 < 1440  -- 24 hours
  AND completed_at IS NULL 
ORDER BY created_at DESC 
LIMIT 10;

-- ==========================================
-- Alternative: Simpler EXPLAIN without specific params
-- ==========================================

-- If you don't have real params handy, at least check the plan shape
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, report_type, params, created_at, created_by, title, format, 
       started_at, completed_at, result 
FROM reports.reports 
WHERE completed_at IS NULL 
  AND created_at > NOW() - INTERVAL '1 day'
  AND organization_id IS NOT NULL
ORDER BY created_at DESC 
LIMIT 100;

-- ==========================================
-- Check for problematic patterns
-- ==========================================

-- 1. Check how many incomplete reports exist (affects index size)
SELECT 
  COUNT(*) as total_incomplete_reports,
  COUNT(*) FILTER (WHERE created_at > NOW() - INTERVAL '1 day') as last_24h,
  COUNT(*) FILTER (WHERE created_at > NOW() - INTERVAL '7 days') as last_7d,
  COUNT(DISTINCT organization_id) as distinct_orgs,
  COUNT(DISTINCT user_id) as distinct_users
FROM reports.reports
WHERE completed_at IS NULL;

-- 2. Check params JSONB structure and size
SELECT 
  pg_size_pretty(SUM(pg_column_size(params))) as total_params_size,
  AVG(pg_column_size(params)) as avg_params_size,
  MAX(pg_column_size(params)) as max_params_size,
  COUNT(DISTINCT params) as distinct_param_combinations
FROM reports.reports
WHERE completed_at IS NULL
  AND created_at > NOW() - INTERVAL '7 days';

-- 3. Check data distribution (important for index selectivity)
SELECT 
  organization_id,
  COUNT(*) as report_count,
  COUNT(DISTINCT user_id) as user_count,
  COUNT(DISTINCT report_type) as report_types
FROM reports.reports
WHERE completed_at IS NULL
  AND created_at > NOW() - INTERVAL '7 days'
GROUP BY organization_id
ORDER BY report_count DESC
LIMIT 20;

-- ==========================================
-- WHAT TO LOOK FOR IN EXPLAIN OUTPUT
-- ==========================================

/*
🔍 KEY THINGS TO IDENTIFY:

1. **Seq Scan** - BAD
   - "Seq Scan on reports.reports"
   - Means scanning entire table (millions of rows?)
   - This is why it takes 12 seconds

2. **Index Scan** - GOOD
   - "Index Scan using some_index_name on reports.reports"
   - Fast lookup

3. **Bitmap Heap Scan** - OKAY
   - Can be okay for moderate result sets
   - Check "Buffers" line for I/O

4. **Filter conditions** - CHECK THESE
   - Lines starting with "Filter:"
   - These are conditions NOT using an index
   - Example: "Filter: (params = ...)" means params isn't indexed

5. **Planning time vs Execution time**
   - Planning time: < 1ms usually
   - Execution time: Should be < 100ms (currently 12000ms!)

6. **Buffers**
   - "Buffers: shared hit=X read=Y"
   - High "read" numbers = disk I/O (slow)
   - Want most to be "hit" (in cache)

7. **Rows Removed by Filter**
   - High number = inefficient filtering
   - Means scanning many rows unnecessarily

-- ==========================================
-- EXAMPLE OUTPUT INTERPRETATION
-- ==========================================

Bad plan (what you probably have now):
┌─────────────────────────────────────────────────────────────────┐
│ Limit (cost=... rows=10)                                         │
│   -> Sort (cost=... rows=1000)                                   │
│        -> Seq Scan on reports (cost=... rows=1000)              │ ← BAD!
│             Filter: (completed_at IS NULL AND ...)               │
│             Rows Removed by Filter: 2000000                      │ ← BAD!
│             Buffers: shared read=50000                           │ ← BAD!
└─────────────────────────────────────────────────────────────────┘

Good plan (what we want after index):
┌─────────────────────────────────────────────────────────────────┐
│ Limit (cost=... rows=10)                                         │
│   -> Index Scan using idx_reports_dedup_lookup on reports       │ ← GOOD!
│        Index Cond: (organization_id = X AND user_id = Y ...)    │
│        Filter: (params = $5)                                     │
│        Rows Removed by Filter: 0                                 │ ← GOOD!
│        Buffers: shared hit=15                                    │ ← GOOD!
└─────────────────────────────────────────────────────────────────┘

*/

-- ==========================================
-- NEXT STEPS AFTER EXPLAIN
-- ==========================================

/*
Once you run EXPLAIN and paste the output:

1. I'll identify the exact bottleneck
2. We'll design the optimal index
3. We'll estimate index creation time
4. We'll create the index (CONCURRENTLY)
5. We'll verify the improvement

Paste the EXPLAIN output here and I'll analyze it!
*/
