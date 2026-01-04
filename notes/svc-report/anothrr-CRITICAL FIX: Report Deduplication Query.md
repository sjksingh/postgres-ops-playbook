-- ==========================================
-- CRITICAL FIX: Report Deduplication Query
-- Current: 12 seconds avg, causing connection exhaustion
-- Target: < 100ms
-- ==========================================

-- 1️⃣ ANALYZE THE CURRENT QUERY PLAN
-- Run this to see why it's slow:
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT id, report_type, params, created_at, created_by, title, format, 
       started_at, completed_at, result 
FROM reports.reports 
WHERE report_type = 'some_type'
  AND title = 'some_title'
  AND format = 'pdf'
  AND user_id = 12345
  AND params = '{"key": "value"}'::jsonb
  AND organization_id = 100
  AND EXTRACT(EPOCH FROM current_timestamp - created_at)/60 < 1440  -- 24 hours
  AND completed_at IS NULL 
ORDER BY created_at DESC 
LIMIT 10;

-- ==========================================
-- 2️⃣ RECOMMENDED INDEX STRATEGY
-- ==========================================

-- Option A: Multi-column index for deduplication lookup
-- This covers all equality conditions in optimal order
CREATE INDEX CONCURRENTLY idx_reports_dedup_lookup ON reports.reports (
  organization_id,      -- Most selective first
  user_id,
  report_type,
  title,
  format,
  created_at DESC       -- For ORDER BY
) 
WHERE completed_at IS NULL;  -- Partial index - only incomplete reports

-- Option B: Add GIN index for JSONB params if needed
-- Only if params comparison is causing issues
CREATE INDEX CONCURRENTLY idx_reports_params_gin 
ON reports.reports USING gin (params jsonb_path_ops)
WHERE completed_at IS NULL;

-- Option C: Composite index with time range
-- Alternative if you need time filtering in index
CREATE INDEX CONCURRENTLY idx_reports_dedup_with_time ON reports.reports (
  organization_id,
  user_id,
  report_type,
  created_at DESC
) 
WHERE completed_at IS NULL 
  AND created_at > NOW() - INTERVAL '7 days';  -- Adjust based on your dedup window

-- ==========================================
-- 3️⃣ QUERY REWRITE OPTIONS
-- ==========================================

-- OPTION 1: Move time calculation out of WHERE clause (make it SARGable)
-- BEFORE (bad - 12 seconds):
-- WHERE EXTRACT(EPOCH FROM current_timestamp - created_at)/60 < $7

-- AFTER (good - index-friendly):
WHERE created_at > current_timestamp - INTERVAL '1 day'  -- or ($7 || ' minutes')::interval

-- OPTION 2: Revised query with better structure
SELECT id, report_type, params, created_at, created_by, title, format, 
       started_at, completed_at, result 
FROM reports.reports 
WHERE organization_id = $6          -- Most selective
  AND user_id = $4
  AND report_type = $1
  AND title = $2
  AND format = $3
  AND completed_at IS NULL
  AND created_at > current_timestamp - ($7 || ' minutes')::interval  -- SARGable!
  AND params = $5                    -- JSONB comparison last (most expensive)
ORDER BY created_at DESC 
LIMIT $10;

-- OPTION 3: Use hash for JSONB comparison (avoid full equality check)
-- Add computed column for faster dedup checks
ALTER TABLE reports.reports 
ADD COLUMN params_hash TEXT GENERATED ALWAYS AS (md5(params::text)) STORED;

CREATE INDEX CONCURRENTLY idx_reports_params_hash 
ON reports.reports (organization_id, user_id, params_hash, created_at DESC)
WHERE completed_at IS NULL;

-- Then query becomes:
SELECT id, report_type, params, created_at, created_by, title, format, 
       started_at, completed_at, result 
FROM reports.reports 
WHERE organization_id = $6
  AND user_id = $4
  AND params_hash = md5($5::text)   -- Fast hash comparison
  AND report_type = $1              -- Add other filters for safety
  AND title = $2
  AND format = $3
  AND completed_at IS NULL
  AND created_at > current_timestamp - ($7 || ' minutes')::interval
  AND params = $5                    -- Final verification (rare false positive)
ORDER BY created_at DESC 
LIMIT $10;

-- ==========================================
-- 4️⃣ MONITORING QUERIES
-- ==========================================

-- Check if indexes are being used after creation
SELECT 
  schemaname,
  tablename,
  indexname,
  idx_scan,
  idx_tup_read,
  idx_tup_fetch,
  pg_size_pretty(pg_relation_size(indexrelid)) as index_size
FROM pg_stat_user_indexes
WHERE schemaname = 'reports'
  AND tablename = 'reports'
ORDER BY idx_scan DESC;

-- Monitor query performance after fix
SELECT 
  userid::regrole,
  calls,
  (total_time / calls)::numeric(10,2) as avg_ms,
  (max_time)::numeric(10,2) as max_ms,
  LEFT(query, 100) as query_preview
FROM pg_stat_statements
WHERE query LIKE '%reports.reports%'
  AND query LIKE '%completed_at IS NULL%'
ORDER BY avg_ms DESC;

-- ==========================================
-- 5️⃣ APPLICATION-LEVEL FIXES
-- ==========================================

/*
## In Your Node.js Application (Slonik):

### A. Add Query Timeout
```javascript
const pool = createPool('postgres://...', {
  maximumPoolSize: 10,
  statementTimeout: 5000,  // 5 seconds - fail fast on slow queries
  idleTimeout: 60000,
  connectionTimeout: 3000
});
```

### B. Add Retry Logic with Backoff
```javascript
async function findExistingReport(params) {
  const maxRetries = 3;
  for (let i = 0; i < maxRetries; i++) {
    try {
      return await pool.query(sql.type(reportSchema)`
        SELECT ... FROM reports.reports 
        WHERE organization_id = ${params.orgId}
          AND user_id = ${params.userId}
          AND created_at > NOW() - INTERVAL '24 hours'
          AND completed_at IS NULL
        LIMIT 10
      `);
    } catch (err) {
      if (err.code === '57014') {  // query_canceled / timeout
        if (i === maxRetries - 1) throw err;
        await sleep(Math.pow(2, i) * 1000);  // exponential backoff
      } else {
        throw err;
      }
    }
  }
}
```

### C. Consider Alternative Dedup Strategy
```javascript
// Instead of expensive DB query for every report creation:
// 1. Use Redis/cache for recent dedup checks
// 2. Add unique constraint and handle conflicts
// 3. Use database-level locking (FOR UPDATE SKIP LOCKED)

// Example: Optimistic approach
ALTER TABLE reports.reports 
ADD CONSTRAINT unique_active_report 
UNIQUE (organization_id, user_id, report_type, title, params_hash)
WHERE completed_at IS NULL;

// Then in code:
try {
  await pool.query(sql.unsafe`
    INSERT INTO reports.reports (organization_id, user_id, ...)
    VALUES (${orgId}, ${userId}, ...)
  `);
} catch (err) {
  if (err.code === '23505') {  // unique_violation
    // Report already exists, fetch it
    return await pool.query(sql.type(reportSchema)`
      SELECT ... FROM reports.reports 
      WHERE organization_id = ${orgId}
        AND user_id = ${userId}
        AND completed_at IS NULL
      LIMIT 1
    `);
  }
  throw err;
}
```

### D. Add Circuit Breaker
```javascript
const CircuitBreaker = require('opossum');

const reportQueryBreaker = new CircuitBreaker(findExistingReport, {
  timeout: 5000,           // 5s timeout
  errorThresholdPercentage: 50,
  resetTimeout: 30000      // Try again after 30s
});

reportQueryBreaker.on('open', () => {
  logger.error('Circuit breaker opened - report queries failing');
  // Alert your team
});
```
*/

-- ==========================================
-- 6️⃣ IMMEDIATE ACTION PLAN
-- ==========================================

/*
Priority Order (Do in this sequence):

1. ✅ CREATE INDEX (30 minutes):
   - Run the idx_reports_dedup_lookup index creation (CONCURRENTLY)
   - Monitor: SELECT * FROM pg_stat_progress_create_index;
   
2. ✅ REWRITE QUERY (2 hours):
   - Fix the time calculation to be SARGable
   - Test with EXPLAIN ANALYZE
   - Deploy to staging, verify < 100ms
   
3. ✅ ADD STATEMENT TIMEOUT (15 minutes):
   - Update Slonik pool config: statementTimeout: 5000
   - Deploy immediately as safety net
   
4. ✅ MONITOR (ongoing):
   - Watch pg_stat_statements for query time improvement
   - Alert if avg query time > 1 second
   - Alert if connections > 80% of max_connections
   
5. ✅ LONG-TERM FIX (1 week):
   - Consider params_hash approach
   - Implement unique constraint strategy
   - Add Redis caching layer for dedup checks

Expected Results:
- Query time: 12s → < 100ms (120x improvement)
- Connection spikes: Eliminated
- Database load: 6.9 hours/day → < 3 minutes/day
*/
