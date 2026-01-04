-- ==========================================
-- TEST THE ACTUAL SLOW QUERY PATTERN
-- This is the exact query from pg_stat_statements
-- ==========================================

-- 1️⃣ Run EXPLAIN on the CURRENT slow query (BEFORE index)
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, COSTS)
SELECT 
  id, report_type, params, created_at, created_by, 
  title, format, started_at, completed_at, result 
FROM reports.reports 
WHERE report_type = 'managed-vendor-findings-csv'
  AND title = 'Managed Vendor findings CSV'
  AND format = 'csv'
  AND user_id = 'bd62dda8-99a8-51b3-8cd0-a320dc626bf6'::uuid
  AND params = '{"id": "53fede82-a65a-4126-ae9c-9a99b832168d", "title": "Likelihood Assessment optomi.com findings", "onComplete": {"share": {"with": [{"organizationId": "14e3c91b-a64c-5ba1-be38-ecd7034546dd"}]}}}'::jsonb
  AND organization_id = '4a7e860d-0d6c-5534-8882-a1df3861b431'::uuid
  AND EXTRACT(EPOCH FROM current_timestamp - created_at)/60 < 1440  -- 24 hours in minutes
  AND completed_at IS NULL 
ORDER BY created_at DESC 
LIMIT 10;

-- ==========================================
-- WHAT TO LOOK FOR IN OUTPUT:
-- ==========================================

/*
❌ BAD SIGNS (current state):
- "Seq Scan on reports.reports" 
- "Rows Removed by Filter: 320000" (scanning all incomplete reports)
- "Buffers: shared read=50000" (lots of disk I/O)
- "Execution Time: 10000-15000 ms"

The problem is likely:
1. No index covers this query pattern
2. EXTRACT() makes created_at filter non-SARGable
3. JSONB params comparison is expensive
4. Sequential scan through 320K incomplete reports
*/

-- ==========================================
-- 2️⃣ CREATE THE INDEX NOW! (Critical Fix)
-- ==========================================

-- Current problem from EXPLAIN:
-- ❌ Uses reports_organization_id_index (org only)
-- ❌ Scans 151,472 rows per worker = 454K total rows
-- ❌ All other filters applied AFTER index scan
-- ❌ Result: 150ms now, 12+ seconds in production

-- This index will change:
-- ✅ Index Cond will include: user_id, org_id, report_type, format
-- ✅ Rows scanned: ~1-5 (not 151,472!)
-- ✅ Result: 5-20ms consistently

CREATE INDEX CONCURRENTLY idx_reports_dedup_active_v1
ON reports.reports (
  user_id,           -- Filters to ~104 incomplete reports/user
  organization_id,   -- Further narrows to ~3-6 reports
  report_type,       -- Usually gets to 0-1 reports
  format,            -- Confirms exact match
  created_at DESC    -- For ORDER BY (bonus)
)
WHERE completed_at IS NULL;  -- Partial index: 320K rows not 11.7M!

-- Monitor progress:
SELECT 
  phase,
  round(100.0 * blocks_done / nullif(blocks_total, 0), 1) AS "% complete",
  tuples_done,
  tuples_total
FROM pg_stat_progress_create_index;

-- ==========================================
-- 3️⃣ Test AFTER index creation (should be MUCH faster)
-- ==========================================

-- Same query - should now use the index
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, COSTS)
SELECT 
  id, report_type, params, created_at, created_by, 
  title, format, started_at, completed_at, result 
FROM reports.reports 
WHERE report_type = 'managed-vendor-findings-csv'
  AND title = 'Managed Vendor findings CSV'
  AND format = 'csv'
  AND user_id = 'bd62dda8-99a8-51b3-8cd0-a320dc626bf6'::uuid
  AND params = '{"id": "53fede82-a65a-4126-ae9c-9a99b832168d", "title": "Likelihood Assessment optomi.com findings", "onComplete": {"share": {"with": [{"organizationId": "14e3c91b-a64c-5ba1-be38-ecd7034546dd"}]}}}'::jsonb
  AND organization_id = '4a7e860d-0d6c-5534-8882-a1df3861b431'::uuid
  AND EXTRACT(EPOCH FROM current_timestamp - created_at)/60 < 1440
  AND completed_at IS NULL 
ORDER BY created_at DESC 
LIMIT 10;

/*
✅ GOOD SIGNS (after index):
- "Index Scan using idx_reports_dedup_active_v1 on reports.reports"
- "Index Cond: (user_id = ... AND organization_id = ...)"
- "Rows Removed by Filter: 0" or very small number
- "Buffers: shared hit=10" (data in cache, minimal I/O)
- "Execution Time: 10-100 ms" (100-1000x faster!)

Even with the non-SARGable EXTRACT() and expensive JSONB comparison,
the index should narrow down to ~1-5 rows before those filters run.
*/

-- ==========================================
-- 4️⃣ OPTIONAL: Test with REWRITTEN query (even faster)
-- ==========================================

-- This version has a SARGable time filter (index-friendly)
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, COSTS)
SELECT 
  id, report_type, params, created_at, created_by, 
  title, format, started_at, completed_at, result 
FROM reports.reports 
WHERE user_id = 'bd62dda8-99a8-51b3-8cd0-a320dc626bf6'::uuid
  AND organization_id = '4a7e860d-0d6c-5534-8882-a1df3861b431'::uuid
  AND report_type = 'managed-vendor-findings-csv'
  AND format = 'csv'
  AND completed_at IS NULL
  AND created_at > current_timestamp - INTERVAL '1440 minutes'  -- SARGable!
  AND title = 'Managed Vendor findings CSV'
  AND params = '{"id": "53fede82-a65a-4126-ae9c-9a99b832168d", "title": "Likelihood Assessment optomi.com findings", "onComplete": {"share": {"with": [{"organizationId": "14e3c91b-a64c-5ba1-be38-ecd7034546dd"}]}}}'::jsonb
ORDER BY created_at DESC 
LIMIT 10;

/*
This rewritten version:
- Uses index more efficiently (created_at in Index Cond, not Filter)
- Should be even faster than the original with index
- This is what the dev team should deploy
*/

-- ==========================================
-- 5️⃣ COMPARISON TEST - All 3 scenarios
-- ==========================================

-- Run each and compare execution times:

-- A. Without any time filter (fastest - pure index lookup)
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, report_type, params, created_at, created_by, title, format, started_at, completed_at, result 
FROM reports.reports 
WHERE user_id = 'bd62dda8-99a8-51b3-8cd0-a320dc626bf6'::uuid
  AND organization_id = '4a7e860d-0d6c-5534-8882-a1df3861b431'::uuid
  AND report_type = 'managed-vendor-findings-csv'
  AND format = 'csv'
  AND completed_at IS NULL
ORDER BY created_at DESC 
LIMIT 10;

-- B. With non-SARGable time filter (current app query)
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, report_type, params, created_at, created_by, title, format, started_at, completed_at, result 
FROM reports.reports 
WHERE user_id = 'bd62dda8-99a8-51b3-8cd0-a320dc626bf6'::uuid
  AND organization_id = '4a7e860d-0d6c-5534-8882-a1df3861b431'::uuid
  AND report_type = 'managed-vendor-findings-csv'
  AND format = 'csv'
  AND completed_at IS NULL
  AND EXTRACT(EPOCH FROM current_timestamp - created_at)/60 < 1440
ORDER BY created_at DESC 
LIMIT 10;

-- C. With SARGable time filter (recommended fix)
EXPLAIN (ANALYZE, BUFFERS)
SELECT id, report_type, params, created_at, created_by, title, format, started_at, completed_at, result 
FROM reports.reports 
WHERE user_id = 'bd62dda8-99a8-51b3-8cd0-a320dc626bf6'::uuid
  AND organization_id = '4a7e860d-0d6c-5534-8882-a1df3861b431'::uuid
  AND report_type = 'managed-vendor-findings-csv'
  AND format = 'csv'
  AND completed_at IS NULL
  AND created_at > current_timestamp - INTERVAL '1440 minutes'
ORDER BY created_at DESC 
LIMIT 10;

-- Expected results:
-- A: ~10ms (pure index scan)
-- B: ~50ms (index scan + filter)
-- C: ~10ms (index scan with time in Index Cond)

-- ==========================================
-- 6️⃣ TEST WITH DIFFERENT USER (more realistic)
-- ==========================================

-- The user_id above might be a power user with many reports
-- Test with a typical user to see average case performance

-- Find a user with fewer reports:
SELECT 
  user_id,
  organization_id,
  COUNT(*) as incomplete_count
FROM reports.reports
WHERE completed_at IS NULL
GROUP BY user_id, organization_id
HAVING COUNT(*) BETWEEN 1 AND 10
LIMIT 5;

-- Then test with one of those user_id/org_id combinations
