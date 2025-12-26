# Partial Index Strategy - Platform DBRE Deep Dive

## Executive Summary

**Problem:** Read-heavy workloads accumulate indexes reactively. Teams add indexes per slow query without analyzing whether they're indexing the right subset. Result: massive indexes scanning thousands of irrelevant rows, storage bloat, cache pollution, and degraded write performance.

**Core Insight:** Most queries filter on predictable, skewed distributions (status='active', deleted_at IS NULL, type='premium'). Full indexes waste 95%+ of their space on rows never queried. Partial indexes target the hot path, reducing index size by 10-100x while improving both read and write performance.

**Your Mandate:** As Staff/Principal DBRE, you must systematically identify filter selectivity, right-size indexes to match query patterns, and establish engineering practices that prevent index bloat.

---

## CRITICAL FINDINGS FROM YOUR PRODUCTION DATA

### Immediate Red Flags (Action Required)

**1. BLOATED: `subscriptions_scorecards_uq_idx` - 5.9GB (92% of table)**
- Only 94 scans but reading 127 rows per scan on average
- This is likely a unique constraint index on a large composite key
- **Action:** Investigate if this can be a hash index or if columns can be reduced

**2. SUSPICIOUS: `idx_product_company_url_product_id` - 5.6GB (63% of table)**
- 467K scans, but reading 240 rows per scan (low selectivity)
- **Critical Issue:** This composite index isn't selective enough
- **Root Cause Analysis Needed:** Are you querying with company_url alone without product_id?

**3. DISASTER: `product_pkey` - 2.7GB, reading 38,948 rows per scan**
- Your PRIMARY KEY is scanning ~39K rows per lookup!
- This should NEVER happen - PKs should return 1 row
- **URGENT:** Something is fundamentally wrong - are you doing range scans on PK?

**4. CATASTROPHIC: `idx_scorecard_scores_score_desc` - 2.3GB, 624K rows per scan**
- 1.5M scans returning 624K rows each time
- This index is essentially useless for filtering
- **Action:** This needs to be a partial index IMMEDIATELY

**5. UNUSED INDEXES (Free 2.4GB by dropping these):**
- `scorecards_url_key` - 667 MB, 0 scans
- `scorecards_name_key` - 551 MB, 0 scans  
- `scorecard_ransomware_scores_pkey` - 474 MB, 0 scans
- `idx_mv_follower_count_domain` - 450 MB, 0 scans
- `scorecards_custom_legacy_id` - 292 MB, 0 scans

**Total Quick Win: 2.4GB storage + reduced write amplification**

### Scanning Pattern Analysis

**Extremely High Rows Per Scan (Partial Index Candidates):**
```
product_product_name_lower_index: 43M rows/scan (872MB wasted)
product_product_name_index: 2.8M rows/scan (872MB wasted)
audit_status_index: 31M rows/scan (368MB wasted)
```

These are scanning entire tables through indexes - classic partial index opportunities.

---

## Part 1: Deep Analysis Framework

### 1.1 Index Bloat Assessment

**Calculate index efficiency ratio:**
```sql
WITH index_stats AS (
  SELECT
    schemaname,
    relname as tablename,
    indexrelname as indexname,
    pg_size_pretty(pg_relation_size(indexrelid)) as index_size,
    pg_relation_size(indexrelid) as index_bytes,
    idx_scan,
    idx_tup_read,
    idx_tup_fetch
  FROM pg_stat_user_indexes
),
table_stats AS (
  SELECT
    schemaname,
    relname as tablename,
    n_live_tup,
    pg_size_pretty(pg_relation_size(relid)) as table_size,
    pg_relation_size(relid) as table_bytes
  FROM pg_stat_user_tables
)
SELECT
  i.schemaname,
  i.tablename,
  i.indexname,
  i.index_size,
  t.table_size,
  ROUND(100.0 * i.index_bytes / NULLIF(t.table_bytes, 0), 2) as pct_of_table,
  i.idx_scan as scans,
  CASE 
    WHEN i.idx_scan = 0 THEN 'UNUSED'
    WHEN i.index_bytes > t.table_bytes THEN 'BLOATED'
    WHEN i.index_bytes > t.table_bytes * 0.5 THEN 'SUSPICIOUS'
    ELSE 'OK'
  END as status,
  ROUND(i.idx_tup_read::numeric / NULLIF(i.idx_scan, 0), 2) as avg_rows_read_per_scan
FROM index_stats i
JOIN table_stats t USING (schemaname, tablename)
WHERE i.schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY i.index_bytes DESC
LIMIT 50;
```

**Red flags:**
- Index larger than table (>100% ratio)
- Index >50% of table size with low selectivity queries
- avg_rows_read_per_scan >10% of n_live_tup
- High scan count but reading most of the table each time

### 1.2 Filter Selectivity Analysis

**Identify high-selectivity filters (candidates for partial indexes):**
```sql
-- Analyze column value distributions
SELECT
  schemaname,
  tablename,
  attname as column_name,
  n_distinct,
  most_common_vals,
  most_common_freqs,
  correlation,
  -- Calculate selectivity of most common value
  (most_common_freqs[1] * 100)::numeric(5,2) as top_value_pct
FROM pg_stats
WHERE schemaname = 'public'
  AND tablename IN ('orders', 'tasks', 'notifications')  -- your hot tables
  AND n_distinct > 0
ORDER BY top_value_pct DESC NULLS LAST;
```

**Extract actual query filters from logs:**
```sql
-- Parse query patterns from pg_stat_statements
SELECT
  query,
  calls,
  mean_exec_time,
  stddev_exec_time,
  rows as avg_rows_returned,
  -- Extract WHERE clause patterns (simplified regex)
  regexp_matches(query, 'WHERE\s+([a-z_]+)\s*=\s*''([^'']+)''', 'gi') as filter_pattern
FROM pg_stat_statements
WHERE query LIKE '%WHERE%'
  AND calls > 1000  -- Frequent queries only
ORDER BY calls DESC
LIMIT 100;
```

**Calculate filter effectiveness:**
```sql
-- For a specific table, analyze which filters reduce result sets most
WITH query_analysis AS (
  SELECT
    query,
    calls,
    rows as avg_rows,
    mean_exec_time
  FROM pg_stat_statements
  WHERE query LIKE '%FROM your_table%'
    AND query LIKE '%WHERE%'
)
SELECT
  CASE
    WHEN query LIKE '%status = ''active''%' THEN 'status=active'
    WHEN query LIKE '%deleted_at IS NULL%' THEN 'deleted_at IS NULL'
    WHEN query LIKE '%is_processed = false%' THEN 'is_processed=false'
    ELSE 'other'
  END as filter_type,
  COUNT(*) as query_count,
  ROUND(AVG(avg_rows)) as avg_result_size,
  ROUND(AVG(mean_exec_time), 2) as avg_time_ms
FROM query_analysis
GROUP BY filter_type
ORDER BY query_count DESC;
```

### 1.3 Read vs Write Trade-off Analysis

**Measure write amplification from indexes:**
```sql
SELECT
  schemaname,
  tablename,
  pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as total_size,
  pg_size_pretty(pg_relation_size(schemaname||'.'||tablename)) as table_size,
  pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename) - 
                 pg_relation_size(schemaname||'.'||tablename)) as index_total_size,
  COUNT(*) as num_indexes,
  n_tup_ins + n_tup_upd + n_tup_del as write_ops,
  seq_scan + idx_scan as read_ops,
  ROUND((n_tup_ins + n_tup_upd + n_tup_del)::numeric / 
        NULLIF(seq_scan + idx_scan, 0), 3) as write_read_ratio
FROM pg_stat_user_tables
JOIN pg_stat_user_indexes USING (schemaname, tablename)
WHERE schemaname = 'public'
GROUP BY schemaname, tablename, n_tup_ins, n_tup_upd, n_tup_del, seq_scan, idx_scan
HAVING COUNT(*) > 3  -- Tables with many indexes
ORDER BY write_read_ratio DESC;
```

**If write_read_ratio > 0.1:** You're write-heavy, aggressive partial indexing saves substantial overhead  
**If write_read_ratio < 0.01:** You're read-dominant, partial indexes provide cache/scan benefits

---

## Part 2: Partial Index Design Patterns

### 2.1 Pattern: Boolean/Status Flags

**Before (full index):**
```sql
CREATE INDEX idx_tasks_status ON tasks(status);
-- Index size: 840 MB for 10M rows
-- Typical query scans 200K rows to find 50K active tasks
```

**After (partial index):**
```sql
-- Only index the status value you actually query
CREATE INDEX idx_tasks_active ON tasks(status, created_at DESC) 
WHERE status = 'active';

CREATE INDEX idx_tasks_pending ON tasks(status, priority, created_at DESC)
WHERE status = 'pending';

-- Total index size: 45 MB (18.7x reduction)
-- Query scans only active tasks directly
```

**When to use:**
- Boolean columns (is_deleted, is_active, is_verified)
- Low-cardinality enums with skewed distribution
- Soft-delete patterns (deleted_at IS NULL)
- Status flags where 1-2 values dominate queries

### 2.2 Pattern: Time-Based Hot Data

**Before:**
```sql
CREATE INDEX idx_orders_created ON orders(created_at);
-- Indexes all 50M historical orders
-- Queries only last 90 days (2M rows)
```

**After:**
```sql
-- Index only recent, actively queried data
CREATE INDEX idx_orders_recent ON orders(created_at DESC, user_id, status)
WHERE created_at > '2024-01-01';  -- Updated quarterly

-- For historical analysis, separate index or sequential scan is acceptable
CREATE INDEX idx_orders_historical ON orders(created_at DESC)
WHERE created_at <= '2024-01-01';
```

**Maintenance strategy:**
```sql
-- Quarterly: rotate the date boundary
BEGIN;
DROP INDEX CONCURRENTLY idx_orders_recent;
CREATE INDEX CONCURRENTLY idx_orders_recent ON orders(created_at DESC, user_id, status)
WHERE created_at > '2024-04-01';
COMMIT;
```

### 2.3 Pattern: Composite Filters

**Before (multiple full indexes):**
```sql
CREATE INDEX idx_events_status ON events(status);
CREATE INDEX idx_events_type ON events(type);
CREATE INDEX idx_events_user ON events(user_id);
-- Total: 2.4 GB across 3 indexes
```

**After (targeted composite partial):**
```sql
-- Match your actual query pattern
-- SELECT * FROM events WHERE status = 'active' AND type = 'purchase' AND user_id = ?
CREATE INDEX idx_events_active_purchases ON events(user_id, created_at DESC)
WHERE status = 'active' AND type = 'purchase';

CREATE INDEX idx_events_active_clicks ON events(user_id, created_at DESC)
WHERE status = 'active' AND type = 'click';

-- Total: 180 MB (13.3x reduction)
```

**Column order matters:**
1. Equality filters (status = 'active') → WHERE clause
2. High-cardinality equality (user_id = ?) → First column
3. Range filters (created_at > ?) → Last column
4. Include covering columns if needed

### 2.4 Pattern: Null Exclusion

**Before:**
```sql
CREATE INDEX idx_users_deleted ON users(deleted_at);
-- Indexes 10M NULL values (active users) + 100K deleted
```

**After:**
```sql
-- Most queries filter deleted_at IS NULL
CREATE INDEX idx_users_active ON users(email, created_at)
WHERE deleted_at IS NULL;

-- Rare admin queries for deleted users
CREATE INDEX idx_users_deleted ON users(deleted_at, email)
WHERE deleted_at IS NOT NULL;
```

---

## Part 3: Migration Methodology

### 3.1 Safe Migration Process

**Phase 1: Baseline Measurement**
```sql
-- Capture current performance
CREATE TABLE index_migration_baseline AS
SELECT
  now() as measured_at,
  schemaname,
  tablename,
  indexname,
  pg_relation_size(indexrelid) as index_size,
  idx_scan,
  idx_tup_read,
  idx_tup_fetch
FROM pg_stat_user_indexes
WHERE schemaname = 'public';

-- Document top 20 queries
\copy (SELECT query, calls, mean_exec_time, rows FROM pg_stat_statements WHERE calls > 100 ORDER BY calls DESC LIMIT 20) TO '/tmp/baseline_queries.csv' CSV HEADER;
```

**Phase 2: Create Partial Index (Non-Blocking)**
```sql
-- CONCURRENTLY to avoid locking
CREATE INDEX CONCURRENTLY idx_tasks_active_new ON tasks(status, priority, created_at DESC)
WHERE status = 'active';

-- Verify index was created successfully
SELECT 
  indexname, 
  indexdef,
  pg_size_pretty(pg_relation_size(indexname::regclass)) as size
FROM pg_indexes 
WHERE tablename = 'tasks' 
  AND indexname = 'idx_tasks_active_new';
```

**Phase 3: Validate Performance**
```sql
-- Test queries use new index
EXPLAIN (ANALYZE, BUFFERS) 
SELECT * FROM tasks 
WHERE status = 'active' 
ORDER BY created_at DESC 
LIMIT 100;

-- Should show "Index Scan using idx_tasks_active_new"
-- Compare buffers hit vs baseline
```

**Phase 4: Monitor for 24-48 Hours**
```sql
-- Check new index usage
SELECT 
  indexname,
  idx_scan as scans,
  idx_tup_read as tuples_read,
  idx_tup_fetch as tuples_fetched,
  pg_size_pretty(pg_relation_size(indexrelid)) as size
FROM pg_stat_user_indexes
WHERE indexname IN ('idx_tasks_status', 'idx_tasks_active_new')
ORDER BY indexname;

-- If new index scans > 0 and performance good, proceed
```

**Phase 5: Drop Old Index**
```sql
-- CONCURRENTLY to avoid locks
DROP INDEX CONCURRENTLY idx_tasks_status;

-- Verify space reclaimed
SELECT pg_size_pretty(pg_total_relation_size('tasks'));
```

### 3.2 Rollback Plan

```sql
-- If performance degrades, immediately recreate old index
CREATE INDEX CONCURRENTLY idx_tasks_status ON tasks(status);

-- Keep partial index around for investigation
-- Document what went wrong before cleanup
```

---

## Part 4: Ongoing Optimization Framework

### 4.1 Monthly Index Audit Checklist

**Run this query monthly:**
```sql
WITH index_efficiency AS (
  SELECT
    schemaname,
    tablename,
    indexname,
    pg_size_pretty(pg_relation_size(indexrelid)) as size,
    idx_scan,
    idx_tup_read,
    idx_tup_fetch,
    ROUND(idx_tup_read::numeric / NULLIF(idx_scan, 0), 2) as selectivity_ratio
  FROM pg_stat_user_indexes
  WHERE schemaname = 'public'
)
SELECT
  *,
  CASE
    WHEN idx_scan = 0 THEN 'REMOVE - Unused'
    WHEN selectivity_ratio > 10000 THEN 'OPTIMIZE - Poor selectivity'
    WHEN pg_relation_size(indexrelid) > 1073741824 THEN 'REVIEW - Large (>1GB)'
    ELSE 'OK'
  END as recommendation
FROM index_efficiency
WHERE schemaname = 'public'
ORDER BY pg_relation_size(indexrelid) DESC;
```

### 4.2 Query Pattern Analysis

**Quarterly deep dive:**
```sql
-- Export all query patterns for analysis
\copy (
  SELECT 
    query,
    calls,
    total_exec_time,
    mean_exec_time,
    stddev_exec_time,
    rows,
    100.0 * shared_blks_hit / NULLIF(shared_blks_hit + shared_blks_read, 0) AS cache_hit_ratio
  FROM pg_stat_statements
  WHERE calls > 50
  ORDER BY total_exec_time DESC
  LIMIT 500
) TO '/tmp/query_patterns_2025_q1.csv' CSV HEADER;
```

**Analyze patterns offline:**
- Group queries by WHERE clause structure
- Identify common filter combinations
- Calculate % of queries that would benefit from partial indexes
- Prioritize by (frequency × execution_time × current_index_size)

### 4.3 Storage and Cache Impact Tracking

```sql
-- Track storage savings over time
CREATE TABLE index_optimization_log (
  log_date date PRIMARY KEY,
  total_index_size_gb numeric,
  total_table_size_gb numeric,
  index_table_ratio numeric,
  top_20_queries_p95_ms numeric,
  cache_hit_ratio numeric
);

-- Insert weekly
INSERT INTO index_optimization_log VALUES (
  CURRENT_DATE,
  (SELECT SUM(pg_relation_size(indexrelid))/1073741824.0 FROM pg_stat_user_indexes WHERE schemaname='public'),
  (SELECT SUM(pg_relation_size(schemaname||'.'||tablename))/1073741824.0 FROM pg_stat_user_tables WHERE schemaname='public'),
  (SELECT SUM(pg_relation_size(indexrelid))::numeric/SUM(pg_relation_size(schemaname||'.'||tablename)) FROM pg_stat_user_indexes JOIN pg_stat_user_tables USING(schemaname,tablename) WHERE schemaname='public'),
  (SELECT percentile_cont(0.95) WITHIN GROUP (ORDER BY mean_exec_time) FROM pg_stat_statements WHERE calls > 100),
  (SELECT 100.0 * sum(blks_hit) / (sum(blks_hit) + sum(blks_read)) FROM pg_stat_database)
);
```

---

## Part 5: Staff/Principal Responsibilities

### 5.1 Establish Team Standards

**Document in team runbook:**
```markdown
# Index Creation Standards

## Before Creating Any Index:

1. **Query Analysis Required**
   - Document the slow query pattern
   - Run EXPLAIN ANALYZE to confirm index would help
   - Check if existing index can be modified instead

2. **Selectivity Check**
   - If filter returns <20% of rows, consider partial index
   - Calculate: `SELECT count(*) FILTER (WHERE your_condition) * 100.0 / count(*) FROM table;`

3. **Filter Pattern Match**
   - Does your WHERE clause match a consistent pattern?
   - Can you guarantee filter values in production?
   - Example: status='active' (good), status=ANY(dynamic_array) (bad for partial)

4. **Column Order Validation**
   - Equality columns first, range columns last
   - High cardinality before low cardinality
   - Test with EXPLAIN (ANALYZE, BUFFERS)

5. **Approval Requirements**
   - Index >100MB: Staff DBRE review
   - Partial index: Document filter rationale
   - New table index: Compare with similar tables first
```

### 5.2 Metrics to Track and Report

**Monthly reports to engineering leadership:**

```sql
-- Index efficiency dashboard
SELECT
  'Total Index Storage' as metric,
  pg_size_pretty(SUM(pg_relation_size(indexrelid))) as value,
  'Target: <50% of table storage' as target
FROM pg_stat_user_indexes
WHERE schemaname = 'public'
UNION ALL
SELECT
  'Unused Indexes',
  COUNT(*)::text,
  'Target: 0'
FROM pg_stat_user_indexes
WHERE idx_scan = 0 
  AND schemaname = 'public'
UNION ALL
SELECT
  'Average Query Selectivity',
  ROUND(AVG(rows))::text || ' rows',
  'Target: <1000 for indexed queries'
FROM pg_stat_statements
WHERE query LIKE '%WHERE%'
  AND calls > 100;
```

**Quarterly business impact:**
- Storage cost reduction from index optimization
- Query p95 latency improvements
- Write throughput improvements (TPS)
- Cache hit ratio improvements

### 5.3 Cross-Functional Collaboration

**With Application Teams:**
- Review ORM query patterns (N+1, unnecessary joins)
- Identify hardcoded filter values suitable for partial indexes
- Propose API changes that enable better indexing (consistent filters)

**With Data Engineering:**
- Partial indexes for ETL temp tables (status='processing')
- Historical data archival strategies (time-based partials)
- OLAP vs OLTP index separation

**With SRE/Platform:**
- Capacity planning: storage growth projections
- Alert thresholds for index bloat
- Runbook updates for index-related incidents

---

## Part 6: Advanced Techniques

### 6.1 Expression Indexes with Partial Clauses

```sql
-- Optimize case-insensitive lookups on active users only
CREATE INDEX idx_users_email_lower_active ON users(LOWER(email))
WHERE deleted_at IS NULL;

-- Optimize JSONB queries on recent events
CREATE INDEX idx_events_metadata_recent ON events((metadata->>'campaign_id'))
WHERE created_at > '2024-01-01' AND status = 'active';
```

### 6.2 Covering Indexes with Partial Clauses

```sql
-- Eliminate table lookups for hot queries
CREATE INDEX idx_orders_active_covering ON orders(
  user_id, 
  created_at DESC, 
  total_amount,
  status
) WHERE status IN ('pending', 'processing');

-- Query uses Index Only Scan (no table access)
EXPLAIN (ANALYZE, BUFFERS)
SELECT user_id, created_at, total_amount
FROM orders
WHERE status = 'pending' AND user_id = 12345
ORDER BY created_at DESC
LIMIT 20;
```

### 6.3 Partial Index Refresh Strategies

```sql
-- For time-based partials that need periodic updates
-- Create automation script:

CREATE OR REPLACE FUNCTION refresh_recent_index()
RETURNS void AS $$
DECLARE
  cutoff_date date := CURRENT_DATE - interval '90 days';
BEGIN
  -- Recreate index with new date boundary
  DROP INDEX CONCURRENTLY IF EXISTS idx_events_recent;
  EXECUTE format('
    CREATE INDEX CONCURRENTLY idx_events_recent 
    ON events(created_at DESC, user_id, type)
    WHERE created_at > %L
  ', cutoff_date);
END;
$$ LANGUAGE plpgsql;

-- Schedule via pg_cron or external scheduler
-- SELECT cron.schedule('refresh-recent-index', '0 2 1 * *', 'SELECT refresh_recent_index()');
```

---

## Part 7: Decision Framework

### Should You Use a Partial Index?

**✅ YES if:**
- Filter reduces result set by >80% consistently
- Filter uses hardcoded values (status='active', deleted_at IS NULL)
- Table is large (>1M rows) and growing
- Write:read ratio suggests write optimization matters
- Query pattern appears in top 20 by frequency or time

**❌ NO if:**
- Filter values are dynamic (status = ANY($1))
- Query patterns vary significantly across users/features
- Table is small (<100K rows) - full index overhead is minimal
- Ad-hoc analytical queries need full table access
- You can't guarantee filter stability in production

**🤔 MAYBE - Test Both:**
- Filter reduces by 50-80%
- Multiple partial indexes might be needed
- Write load is extreme (>10K writes/sec)
- Composite index with partial might work better

---

## Success Metrics

**After 90 days of systematic partial index optimization:**

- [ ] Index:table storage ratio reduced by >30%
- [ ] Top 20 query p95 latency improved by >20%
- [ ] Write throughput improved by >10% (if write-heavy)
- [ ] Cache hit ratio improved by >5%
- [ ] Zero production incidents from index changes
- [ ] Team adoption: 80% of new indexes follow standards
- [ ] Documentation: Complete runbook and standards published

---

## Conclusion: Strategic Thinking

As Staff/Principal DBRE, partial indexes are not just a technical optimization—they're a forcing function for discipline:

1. **Understand your queries** before indexing
2. **Measure selectivity** instead of guessing
3. **Match indexes to reality** not theoretical access patterns
4. **Track impact** with metrics that matter to the business
5. **Teach the team** to think in filters, not just columns

The goal isn't to convert every index to partial. It's to **stop accumulating dead weight** and **index what you actually query**.

Your next action: Run the bloat assessment query above, identify your top 3 oversized indexes, analyze their query patterns, and propose partial index migrations with full performance validation. Document the methodology for your team.

**What's the biggest index in your production cluster, and what percentage of it is actually queried daily?**
