-- ==========================================
-- DATA DISTRIBUTION ANALYSIS
-- Understand real-world query patterns
-- ==========================================

-- 1️⃣ Find users with MOST incomplete reports
-- This shows us the "power users" who hit the slow query most
SELECT 
  user_id,
  organization_id,
  COUNT(*) as incomplete_reports,
  COUNT(DISTINCT report_type) as distinct_types,
  COUNT(DISTINCT format) as distinct_formats,
  MIN(created_at) as oldest_incomplete,
  MAX(created_at) as newest_incomplete
FROM reports.reports
WHERE completed_at IS NULL
GROUP BY user_id, organization_id
ORDER BY incomplete_reports DESC
LIMIT 20;

-- 2️⃣ Orgs with MOST incomplete reports
-- Shows which orgs have the most dedup queries running
SELECT 
  organization_id,
  COUNT(*) as incomplete_reports,
  COUNT(DISTINCT user_id) as distinct_users,
  COUNT(DISTINCT report_type) as distinct_types,
  ROUND(COUNT(*)::numeric / NULLIF(COUNT(DISTINCT user_id), 0), 2) as avg_reports_per_user
FROM reports.reports
WHERE completed_at IS NULL
GROUP BY organization_id
ORDER BY incomplete_reports DESC
LIMIT 20;

-- 3️⃣ CRITICAL: Simulate the dedup query pattern
-- This shows how many rows each index strategy would scan
WITH test_cases AS (
  -- Get 10 real dedup query examples from incomplete reports
  SELECT DISTINCT ON (user_id, organization_id, report_type, title, format)
    user_id,
    organization_id,
    report_type,
    title,
    format,
    created_at
  FROM reports.reports
  WHERE completed_at IS NULL
    AND created_at > NOW() - INTERVAL '7 days'
  LIMIT 10
)
SELECT 
  tc.user_id,
  tc.organization_id,
  tc.report_type,
  
  -- Current index: reports_organization_id_index
  (SELECT COUNT(*) 
   FROM reports.reports 
   WHERE organization_id = tc.organization_id 
     AND completed_at IS NULL) as rows_scanned_current_index,
  
  -- Proposed index: user_id + organization_id + report_type + format
  (SELECT COUNT(*) 
   FROM reports.reports 
   WHERE user_id = tc.user_id 
     AND organization_id = tc.organization_id 
     AND report_type = tc.report_type 
     AND format = tc.format
     AND completed_at IS NULL) as rows_scanned_new_index,
  
  -- Improvement ratio
  ROUND(
    (SELECT COUNT(*) FROM reports.reports WHERE organization_id = tc.organization_id AND completed_at IS NULL)::numeric /
    NULLIF((SELECT COUNT(*) FROM reports.reports WHERE user_id = tc.user_id AND organization_id = tc.organization_id AND report_type = tc.report_type AND format = tc.format AND completed_at IS NULL), 0)
  , 0) as improvement_ratio
  
FROM test_cases tc
ORDER BY rows_scanned_current_index DESC;

-- 4️⃣ Check the specific user/org from EXPLAIN output
-- This user had 151,472 rows filtered - let's see their pattern
SELECT 
  'User bd62dda8... in org 4a7e860d...' as description,
  COUNT(*) as total_incomplete_reports,
  COUNT(DISTINCT report_type) as distinct_types,
  COUNT(DISTINCT title) as distinct_titles,
  COUNT(DISTINCT format) as distinct_formats,
  MIN(created_at) as oldest,
  MAX(created_at) as newest
FROM reports.reports
WHERE user_id = 'bd62dda8-99a8-51b3-8cd0-a320dc626bf6'::uuid
  AND organization_id = '4a7e860d-0d6c-5534-8882-a1df3861b431'::uuid
  AND completed_at IS NULL;

-- 5️⃣ Show the "worst case" scenario
-- Find the user+org combination that would scan the MOST rows
SELECT 
  organization_id,
  COUNT(*) as incomplete_in_org,
  MAX(user_report_count) as max_reports_single_user,
  COUNT(DISTINCT user_id) as users_in_org
FROM (
  SELECT 
    organization_id,
    user_id,
    COUNT(*) as user_report_count
  FROM reports.reports
  WHERE completed_at IS NULL
  GROUP BY organization_id, user_id
) user_counts
GROUP BY organization_id
ORDER BY incomplete_in_org DESC
LIMIT 10;

-- 6️⃣ Timeline analysis - when were reports created?
-- Shows if there was a burst at 16:15 (connection spike time)
SELECT 
  DATE_TRUNC('hour', created_at) as hour,
  COUNT(*) as reports_created,
  COUNT(DISTINCT user_id) as distinct_users,
  COUNT(DISTINCT organization_id) as distinct_orgs
FROM reports.reports
WHERE created_at >= '2026-01-04 16:00:00'
  AND created_at < '2026-01-04 18:00:00'
  AND completed_at IS NULL
GROUP BY DATE_TRUNC('hour', created_at)
ORDER BY hour;

-- More granular - by 5 minute windows
SELECT 
  DATE_TRUNC('minute', created_at) - 
    (EXTRACT(MINUTE FROM created_at)::int % 5 || ' minutes')::interval as time_window,
  COUNT(*) as reports_created,
  COUNT(DISTINCT user_id) as distinct_users,
  COUNT(DISTINCT organization_id) as distinct_orgs
FROM reports.reports
WHERE created_at >= '2026-01-04 16:00:00'
  AND created_at < '2026-01-04 17:00:00'
  AND completed_at IS NULL
GROUP BY time_window
ORDER BY time_window;

-- ==========================================
-- PROOF: Connect to pg_stat_statements
-- ==========================================

-- 7️⃣ Show which user_ids appear most in slow queries
-- Cross-reference with the top report creators
SELECT 
  userid::regrole as db_user,
  calls,
  (total_time / calls)::numeric(10,2) as avg_ms,
  (max_time)::numeric(10,2) as max_ms,
  LEFT(query, 150) as query_preview
FROM pg_stat_statements
WHERE query LIKE '%reports.reports%'
  AND query LIKE '%completed_at IS NULL%'
  AND (total_time / calls) > 1000  -- avg > 1 second
ORDER BY calls * (total_time / calls) DESC  -- Total impact
LIMIT 10;

-- ==========================================
-- EXPECTED FINDINGS & PROOF
-- ==========================================

/*
🎯 WHAT WE'RE LOOKING FOR:

1. **Power Users Pattern** (Query #1):
   - If a few users have 1000+ incomplete reports each
   - These users' dedup queries scan TONS of rows
   - New index filters to their specific reports immediately
   
2. **Large Org Pattern** (Query #2):
   - If some orgs have 100K+ incomplete reports
   - Current index (org_id only) scans ALL of them
   - New index narrows by user_id first (~100 rows)
   
3. **Index Improvement** (Query #3 - CRITICAL):
   - Current index scans: 10,000-150,000 rows
   - New index scans: 1-10 rows
   - Improvement: 1000-10000x reduction!
   
4. **16:15 Burst Correlation** (Query #6):
   - Did 50+ reports get created at 16:15?
   - All running dedup queries simultaneously?
   - Each query taking 10-15 seconds = connection exhaustion

📊 HYPOTHESIS:

At 16:15, a batch job or scheduled task triggered:
- 50-100 report creation requests
- Each runs the dedup query to check for duplicates
- Each query scans 50K-150K rows (current index)
- 50 queries × 10 seconds = 500 seconds of DB time
- Across multiple pods = 50-100 concurrent connections
- Result: Connection spike to 95, "unable to connect" errors

With new index:
- 50-100 report creation requests
- Each dedup query scans 1-5 rows (new index)
- 50 queries × 0.02 seconds = 1 second of DB time
- No connection spike, system handles it easily

💰 BUSINESS CASE:

Current cost: 6.9 hours of DB time per day
New index cost: < 3 minutes of DB time per day
Reduction: 99.95%

Connection spikes eliminated
User experience improved
DB costs reduced
*/
