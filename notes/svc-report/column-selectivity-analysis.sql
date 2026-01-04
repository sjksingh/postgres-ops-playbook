-- ==========================================
-- COLUMN SELECTIVITY ANALYSIS
-- Determine optimal index column order
-- ==========================================

-- 1️⃣ Check column statistics and cardinality
SELECT 
  attname as column_name,
  n_distinct,
  null_frac,
  avg_width,
  correlation
FROM pg_stats
WHERE schemaname = 'reports'
  AND tablename = 'reports'
  AND attname IN (
    'organization_id', 
    'user_id', 
    'report_type', 
    'title', 
    'format', 
    'completed_at',
    'created_at',
    'params'
  )
ORDER BY 
  CASE attname
    WHEN 'organization_id' THEN 1
    WHEN 'user_id' THEN 2
    WHEN 'report_type' THEN 3
    WHEN 'title' THEN 4
    WHEN 'format' THEN 5
    WHEN 'completed_at' THEN 6
    WHEN 'created_at' THEN 7
    WHEN 'params' THEN 8
  END;

-- 2️⃣ Check actual distinct counts and NULL percentage
SELECT 
  'organization_id' as column_name,
  COUNT(DISTINCT organization_id) as distinct_values,
  COUNT(*) as total_rows,
  COUNT(*) FILTER (WHERE organization_id IS NULL) as null_count,
  ROUND(100.0 * COUNT(DISTINCT organization_id) / NULLIF(COUNT(*), 0), 2) as selectivity_pct
FROM reports.reports
UNION ALL
SELECT 
  'user_id',
  COUNT(DISTINCT user_id),
  COUNT(*),
  COUNT(*) FILTER (WHERE user_id IS NULL),
  ROUND(100.0 * COUNT(DISTINCT user_id) / NULLIF(COUNT(*), 0), 2)
FROM reports.reports
UNION ALL
SELECT 
  'report_type',
  COUNT(DISTINCT report_type),
  COUNT(*),
  COUNT(*) FILTER (WHERE report_type IS NULL),
  ROUND(100.0 * COUNT(DISTINCT report_type) / NULLIF(COUNT(*), 0), 2)
FROM reports.reports
UNION ALL
SELECT 
  'title',
  COUNT(DISTINCT title),
  COUNT(*),
  COUNT(*) FILTER (WHERE title IS NULL),
  ROUND(100.0 * COUNT(DISTINCT title) / NULLIF(COUNT(*), 0), 2)
FROM reports.reports
UNION ALL
SELECT 
  'format',
  COUNT(DISTINCT format),
  COUNT(*),
  COUNT(*) FILTER (WHERE format IS NULL),
  ROUND(100.0 * COUNT(DISTINCT format) / NULLIF(COUNT(*), 0), 2)
FROM reports.reports
UNION ALL
SELECT 
  'completed_at (NULL)',
  1,
  COUNT(*),
  COUNT(*) FILTER (WHERE completed_at IS NULL),
  ROUND(100.0 * COUNT(*) FILTER (WHERE completed_at IS NULL) / NULLIF(COUNT(*), 0), 2)
FROM reports.reports;

-- 3️⃣ Check data distribution for incomplete reports specifically
-- (Since the query filters on completed_at IS NULL)
SELECT 
  'Total reports' as metric,
  COUNT(*) as count,
  pg_size_pretty(pg_total_relation_size('reports.reports')) as size
FROM reports.reports
UNION ALL
SELECT 
  'Incomplete reports (completed_at IS NULL)',
  COUNT(*),
  NULL
FROM reports.reports
WHERE completed_at IS NULL
UNION ALL
SELECT 
  'Incomplete in last 24h',
  COUNT(*),
  NULL
FROM reports.reports
WHERE completed_at IS NULL
  AND created_at > NOW() - INTERVAL '1 day'
UNION ALL
SELECT 
  'Incomplete in last 7d',
  COUNT(*),
  NULL
FROM reports.reports
WHERE completed_at IS NULL
  AND created_at > NOW() - INTERVAL '7 days';

-- 4️⃣ Check most common values for key columns
-- This helps understand data distribution
SELECT 
  format,
  COUNT(*) as count,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) as pct
FROM reports.reports
WHERE completed_at IS NULL
GROUP BY format
ORDER BY count DESC;

SELECT 
  report_type,
  COUNT(*) as count,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) as pct
FROM reports.reports
WHERE completed_at IS NULL
GROUP BY report_type
ORDER BY count DESC
LIMIT 20;

-- 5️⃣ Check combination selectivity (key for dedup query)
-- How many rows match typical filter combinations?
SELECT 
  organization_id,
  user_id,
  report_type,
  title,
  format,
  COUNT(*) as duplicate_count
FROM reports.reports
WHERE completed_at IS NULL
  AND created_at > NOW() - INTERVAL '7 days'
GROUP BY organization_id, user_id, report_type, title, format
HAVING COUNT(*) > 1
ORDER BY duplicate_count DESC
LIMIT 20;

-- 6️⃣ Estimate rows per organization (important for index selectivity)
SELECT 
  COUNT(*) FILTER (WHERE incomplete_count = 0) as orgs_with_0_incomplete,
  COUNT(*) FILTER (WHERE incomplete_count BETWEEN 1 AND 10) as orgs_1_to_10,
  COUNT(*) FILTER (WHERE incomplete_count BETWEEN 11 AND 100) as orgs_11_to_100,
  COUNT(*) FILTER (WHERE incomplete_count > 100) as orgs_over_100,
  ROUND(AVG(incomplete_count), 2) as avg_incomplete_per_org,
  MAX(incomplete_count) as max_incomplete_per_org
FROM (
  SELECT 
    organization_id,
    COUNT(*) as incomplete_count
  FROM reports.reports
  WHERE completed_at IS NULL
  GROUP BY organization_id
) org_counts;

-- ==========================================
-- INDEX RECOMMENDATION LOGIC
-- ==========================================

/*
🎯 INDEX COLUMN ORDER PRINCIPLES:

1. **Equality columns first** (most selective to least)
   - Start with columns that filter to fewest rows
   - n_distinct closer to total rows = more selective

2. **Range/Sort columns last**
   - created_at DESC for ORDER BY

3. **Partial index WHERE clause**
   - completed_at IS NULL (filter out completed reports)

EXPECTED SELECTIVITY ORDER (guess before seeing stats):
1. organization_id - Moderate (100s-1000s distinct?)
2. user_id - High (10,000s distinct?)
3. report_type - Low (10-50 types?)
4. title - Medium (100s distinct?)
5. format - Very Low (3-5 formats: pdf, csv, xlsx?)
6. created_at - Range filter (use for ORDER BY)

📊 AFTER RUNNING pg_stats:

The stats will show us:
- n_distinct: Higher = more selective = should be earlier
- null_frac: High nulls = less useful
- correlation: How well sorted data is

Example interpretation:
- If organization_id has 500 distinct values in 1M rows → ~2000 rows/org
- If user_id has 50,000 distinct values → ~20 rows/user
- user_id is more selective, should come BEFORE organization_id

💡 LIKELY OPTIMAL INDEX:

CREATE INDEX CONCURRENTLY idx_reports_dedup_lookup 
ON reports.reports (
  user_id,              -- Most selective (if many users)
  organization_id,      -- Or swap with user_id based on stats
  report_type,
  title,
  format,
  created_at DESC       -- For ORDER BY
)
WHERE completed_at IS NULL;

Alternative if params comparison is slow:
- Add computed column: params_hash
- Include in index for fast lookup
*/
