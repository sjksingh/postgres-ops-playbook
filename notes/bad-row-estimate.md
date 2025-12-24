# PostgreSQL Bad Row Estimation - Staff DBRE Runbook

## Table of Contents
1. [Emergency Response](#emergency-response)
2. [Detection & Diagnosis](#detection--diagnosis)
3. [Root Cause Analysis](#root-cause-analysis)
4. [Resolution Patterns](#resolution-patterns)
5. [Prevention & Monitoring](#prevention--monitoring)
6. [Version-Specific Notes](#version-specific-notes)

---

## Emergency Response

### Immediate Triage (< 5 minutes)

When a query is degraded or timing out in production:

```sql
-- 1. Capture the query plan (if query completes in reasonable time)
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, SETTINGS)
SELECT * FROM items WHERE organization_id = 102;

-- 2. Check if it's a planning vs execution issue
SELECT query, 
       mean_plan_time, 
       mean_exec_time,
       calls
FROM pg_stat_statements 
WHERE query LIKE '%your_table%'
ORDER BY mean_exec_time DESC 
LIMIT 10;

-- 3. Check statistics freshness
SELECT schemaname, tablename, last_analyze, last_autoanalyze,
       n_live_tup, n_dead_tup,
       ROUND(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_pct
FROM pg_stat_user_tables
WHERE tablename = 'your_table'
ORDER BY last_analyze NULLIF;
```

### Emergency Mitigation Options

**Option 1: Force immediate ANALYZE (lowest risk)**
```sql
-- Quick analyze (samples less data, faster)
ANALYZE your_table;

-- Full analyze (thorough but slower)
ANALYZE VERBOSE your_table;
```

**Option 2: Planner hints (temporary workaround)**
```sql
-- Session-level override (doesn't affect other connections)
SET LOCAL enable_nestloop = off;
SET LOCAL enable_seqscan = off;
SET LOCAL random_page_cost = 1.1;

-- Run your query
SELECT ...;

-- These settings auto-reset at transaction end
```

**Option 3: Kill runaway queries**
```sql
-- Find long-running queries
SELECT pid, now() - pg_stat_activity.query_start AS duration, 
       query, state
FROM pg_stat_activity
WHERE state != 'idle'
  AND now() - pg_stat_activity.query_start > interval '5 minutes'
ORDER BY duration DESC;

-- Terminate specific query
SELECT pg_terminate_backend(pid);

-- Cancel query (gentler, tries to let it clean up)
SELECT pg_cancel_backend(pid);
```

**Option 4: Circuit breaker (prevent future occurrences)**
```sql
-- Set statement timeout for problematic endpoint
ALTER ROLE app_user SET statement_timeout = '30s';

-- Or at database level
ALTER DATABASE your_db SET statement_timeout = '30s';
```

### Escalation Criteria

Escalate immediately if:
- Multiple queries are affected (systemic issue)
- ANALYZE doesn't help within 2 attempts
- Table size > 1TB (ANALYZE may take hours)
- Production traffic is impacted > 15 minutes
- Requires schema changes (extended statistics, indexes)

---

## Detection & Diagnosis

### Proactive Monitoring Queries

**1. Detect queries with bad estimation across the system**
```sql
-- Requires pg_stat_statements extension
SELECT 
    query,
    calls,
    mean_exec_time,
    max_exec_time,
    stddev_exec_time,
    -- High stddev suggests inconsistent plans
    CASE 
        WHEN stddev_exec_time > mean_exec_time THEN '🔴 HIGH VARIANCE'
        WHEN stddev_exec_time > mean_exec_time * 0.5 THEN '🟡 MODERATE'
        ELSE '🟢 STABLE'
    END AS stability
FROM pg_stat_statements
WHERE calls > 100
  AND mean_exec_time > 100  -- ms
ORDER BY stddev_exec_time DESC
LIMIT 20;
```

**2. Identify tables with stale statistics**
```sql
-- Tables not analyzed in last 24 hours with significant writes
SELECT 
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size,
    n_live_tup,
    n_dead_tup,
    n_mod_since_analyze,
    last_analyze,
    last_autoanalyze,
    CASE 
        WHEN last_analyze IS NULL AND last_autoanalyze IS NULL THEN '🔴 NEVER ANALYZED'
        WHEN GREATEST(last_analyze, last_autoanalyze) < now() - interval '24 hours' 
             AND n_mod_since_analyze > n_live_tup * 0.1 THEN '🔴 STALE + HEAVY WRITES'
        WHEN n_mod_since_analyze > n_live_tup * 0.2 THEN '🟡 NEEDS ANALYZE'
        ELSE '🟢 OK'
    END AS status
FROM pg_stat_user_tables
WHERE n_live_tup > 10000
ORDER BY n_mod_since_analyze DESC;
```

**3. Check for correlation issues (multi-tenant patterns)**
```sql
-- Find potential correlation between columns
-- Run this on tables with tenant/user/org patterns
SELECT 
    tablename,
    attname,
    n_distinct,
    correlation,
    null_frac
FROM pg_stats
WHERE tablename = 'items'
  AND attname IN ('organization_id', 'user_id', 'tenant_id')
ORDER BY tablename, attname;

-- High correlation (close to 1.0 or -1.0) with another filtered column = problem
```

**4. Detect function-wrapped columns**
```sql
-- Query to find common anti-patterns in slow queries
-- This is manual inspection, no automated query available
-- Look for: COALESCE, CAST, DATE_TRUNC, LOWER, UPPER in WHERE clauses

-- Check if indexes exist on expressions
SELECT 
    schemaname,
    tablename,
    indexname,
    indexdef
FROM pg_indexes
WHERE indexdef LIKE '%COALESCE%'
   OR indexdef LIKE '%LOWER%'
   OR indexdef LIKE '%DATE_TRUNC%';
```

**5. Identify outliers in data distribution**
```sql
-- Check min/max ranges for time-series columns
SELECT 
    tablename,
    attname,
    (SELECT min(created_at) FROM items) AS min_val,
    (SELECT max(created_at) FROM items) AS max_val,
    (SELECT max(created_at) FROM items) - (SELECT min(created_at) FROM items) AS range_span
FROM pg_stats
WHERE tablename = 'items'
  AND attname = 'created_at';

-- If range_span is suspiciously large (e.g., 74 years when data is < 5 years old)
-- You have outliers

-- Find actual outliers
SELECT created_at, count(*)
FROM items
WHERE created_at > now() + interval '1 year'
   OR created_at < now() - interval '10 years'
GROUP BY created_at
ORDER BY created_at;
```

**6. Verify n_distinct accuracy**
```sql
-- Compare estimated vs actual distinct values
WITH actual AS (
    SELECT COUNT(DISTINCT organization_id) AS actual_distinct
    FROM items
),
estimated AS (
    SELECT 
        CASE 
            WHEN n_distinct > 0 THEN n_distinct
            ELSE ABS(n_distinct) * (SELECT n_live_tup FROM pg_stat_user_tables WHERE tablename = 'items')
        END AS estimated_distinct
    FROM pg_stats
    WHERE tablename = 'items' 
      AND attname = 'organization_id'
)
SELECT 
    actual_distinct,
    ROUND(estimated_distinct) AS estimated_distinct,
    ROUND(100.0 * estimated_distinct / NULLIF(actual_distinct, 0), 2) AS accuracy_pct,
    CASE 
        WHEN ABS(estimated_distinct - actual_distinct) / NULLIF(actual_distinct, 0) > 0.5 THEN '🔴 NEEDS FIX'
        WHEN ABS(estimated_distinct - actual_distinct) / NULLIF(actual_distinct, 0) > 0.2 THEN '🟡 MONITOR'
        ELSE '🟢 OK'
    END AS status
FROM actual, estimated;
```

### Quick Estimation Quality Check

When you have a suspect query with EXPLAIN ANALYZE output:

```
Estimation Quality = Actual Rows / Estimated Rows

🟢 0.5 - 2.0    = Good (within 2x)
🟡 0.1 - 0.5    = Concerning (5-10x off)
🟡 2.0 - 10.0   = Concerning (5-10x off)
🔴 < 0.1        = Critical (>10x underestimate)
🔴 > 10.0       = Critical (>10x overestimate)
```

**Why it matters:**
- **Underestimate by 1000x**: Planner chooses nested loop instead of hash join → 1000x slower
- **Overestimate by 1000x**: Planner allocates huge hash tables → OOM or spill to disk

---

## Root Cause Analysis

### Case 1: Data Skew (Outliers)

**Symptoms:**
- Histogram-based queries (date ranges, numeric ranges) have terrible estimation
- Recent ANALYZE didn't help
- Min/max values span much wider range than actual data

**Diagnosis:**
```sql
-- 1. Check histogram bounds
SELECT 
    tablename,
    attname,
    array_length(histogram_bounds, 1) AS num_buckets,
    histogram_bounds[1] AS min_bound,
    histogram_bounds[array_length(histogram_bounds, 1)] AS max_bound
FROM pg_stats
WHERE tablename = 'items' 
  AND attname = 'created_at';

-- 2. Find outliers
SELECT created_at, COUNT(*)
FROM items
WHERE created_at < '2020-01-01' 
   OR created_at > '2030-01-01'
GROUP BY created_at
ORDER BY created_at;

-- 3. Check data concentration
SELECT 
    date_trunc('month', created_at) AS month,
    COUNT(*) AS row_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_total
FROM items
GROUP BY 1
ORDER BY 1 DESC
LIMIT 20;
```

**Root Cause:**
- Single outlier record (e.g., year 2099) stretches the final histogram bucket
- Final bucket now spans 74 years but contains 1% of data
- Planner assumes uniform distribution within bucket
- Query for Dec 2025 falls in this bucket → massive underestimate

**Resolution:**

```sql
-- Option 1: Clean outliers (preferred)
DELETE FROM items WHERE created_at > '2030-01-01';
DELETE FROM items WHERE created_at < '2020-01-01';
ANALYZE items;

-- Option 2: Increase statistics target
ALTER TABLE items ALTER COLUMN created_at SET STATISTICS 1000;
ANALYZE items;

-- Verify new bucket count
SELECT 
    attname,
    array_length(histogram_bounds, 1) AS buckets
FROM pg_stats
WHERE tablename = 'items' AND attname = 'created_at';

-- Option 3: Add check constraint (prevent future outliers)
ALTER TABLE items 
ADD CONSTRAINT items_created_at_range 
CHECK (created_at >= '2020-01-01' AND created_at <= '2035-12-31');
```

**Tradeoffs:**
- STATISTICS 1000 means ANALYZE samples more rows (slower)
- Each 10x increase in stats target ≈ 3x longer ANALYZE time
- More granular buckets = more accurate estimates for date ranges
- Default 100 buckets is usually fine; increase only for skewed data

---

### Case 2: Correlated Columns (Independence Assumption)

**Symptoms:**
- Multi-column WHERE clauses have terrible estimation
- Single column filters estimate correctly
- Columns have hierarchical/FK relationship (user → organization, order → customer)

**Diagnosis:**
```sql
-- 1. Test individual vs combined filters
EXPLAIN ANALYZE SELECT * FROM items WHERE organization_id = 1;
-- Note: rows=3650 (assume this is accurate)

EXPLAIN ANALYZE SELECT * FROM items WHERE user_id = '2b56d251...';
-- Note: rows=3650 (assume this is accurate)

EXPLAIN ANALYZE 
SELECT * FROM items 
WHERE organization_id = 1 
  AND user_id = '2b56d251...';
-- Note: rows=21 (WRONG! Should be ~3650)

-- 2. Check for extended statistics
SELECT * FROM pg_stats_ext 
WHERE tablename = 'items';

-- 3. Calculate expected vs actual
-- If planner estimates 21 rows:
-- P(org=1) * P(user=X) = (3650/total) * (3650/total) ≈ 21
-- This confirms independence assumption is wrong
```

**Root Cause:**
- Postgres assumes columns are independent: P(A AND B) = P(A) × P(B)
- In reality, user_id **implies** organization_id (perfect correlation)
- Planner "double filters" the probability
- Estimation: 3650/total × 3650/total = 21 rows (way too low)

**Resolution:**

```sql
-- Option 1: Remove redundant filter (best if possible)
SELECT * FROM items 
WHERE user_id = '2b56d251...';
-- organization_id is implicit, no need to filter it

-- Option 2: Create extended statistics (if you must filter both)
CREATE STATISTICS items_user_org_deps (dependencies) 
ON user_id, organization_id 
FROM items;

ANALYZE items;

-- Verify it's created and used
SELECT stxname, stxkeys, stxkind, stxddependencies
FROM pg_statistic_ext
WHERE stxrelid = 'items'::regclass;

-- Test the query again
EXPLAIN ANALYZE 
SELECT * FROM items 
WHERE organization_id = 1 
  AND user_id = '2b56d251...';
-- Should now estimate ~3650 rows correctly
```

**When to use each type of extended statistics:**

```sql
-- DEPENDENCIES: For correlated columns (user → org, state → country)
CREATE STATISTICS stat_name (dependencies) ON col1, col2 FROM table;

-- NDISTINCT: For multi-column cardinality (combinations of values)
CREATE STATISTICS stat_name (ndistinct) ON col1, col2 FROM table;

-- MCV: For multi-column most common value lists
CREATE STATISTICS stat_name (mcv) ON col1, col2 FROM table;

-- ALL: Use all types
CREATE STATISTICS stat_name (dependencies, ndistinct, mcv) ON col1, col2 FROM table;
```

**Tradeoffs:**
- Extended statistics increase ANALYZE time (10-30% overhead)
- Each statistic object uses disk space (~few MB per object)
- Planning time increases slightly (few microseconds)
- Only affects queries that filter on BOTH columns

---

### Case 3: Function Blind Spot

**Symptoms:**
- Query uses COALESCE, CAST, LOWER, DATE_TRUNC, etc. in WHERE clause
- Estimation is suspiciously round number (33.3%, 0.5%, 1%)
- ANALYZE doesn't help at all

**Diagnosis:**
```sql
-- 1. Identify the problem query
EXPLAIN ANALYZE
SELECT * FROM items
WHERE COALESCE(updated_at, created_at) > '2026-02-01';

-- Estimated rows will be ~33.3% of table (hard-coded default)

-- 2. Verify total rows
SELECT COUNT(*) FROM items;  -- e.g., 7,649,448

-- 3. Calculate: 7,649,448 / 3 = 2,549,816 (matches estimate)
-- This proves the planner used default selectivity

-- 4. Check actual selectivity
SELECT COUNT(*)
FROM items
WHERE COALESCE(updated_at, created_at) > '2026-02-01';
-- Result: 0 rows (estimation was completely wrong)
```

**Hard-coded selectivity defaults:**

```
Operator          Default Selectivity    Explanation
===============   ===================    ================================
=                 0.005 (0.5%)          Equality on unknown expression
<>, !=            0.995 (99.5%)         Not-equal on unknown expression
<, <=, >, >=      0.333 (33.3%)         Range on unknown expression (1/3)
LIKE 'foo%'       0.005 (0.5%)          Prefix match
LIKE '%foo%'      0.010 (1.0%)          Substring match
~, ~*             0.010 (1.0%)          Regex match
IS NULL           0.005 (0.5%)          Usually low null fraction assumed
IS NOT NULL       0.995 (99.5%)         Opposite of IS NULL
```

**Root Cause:**
- Statistics are stored per column, not per expression
- Function wrapping (COALESCE, LOWER, etc.) hides the column from planner
- Planner can't access histogram, MCV list, or null fraction
- Falls back to hard-coded guesses based on operator type

**Resolution:**

```sql
-- Option 1: Rewrite query to expose columns (best for one-off queries)
SELECT * FROM items
WHERE updated_at > '2026-02-01'
   OR (updated_at IS NULL AND created_at > '2026-02-01');

-- Now planner can use actual statistics
EXPLAIN ANALYZE ...;
-- Estimation should be accurate

-- Option 2: Create expression statistics (PG 14+, for repeated queries)
CREATE STATISTICS items_updated_or_created (statistics_kind)
ON (COALESCE(updated_at, created_at)) FROM items;

ANALYZE items;

-- Option 3: Create expression index (enables statistics + faster queries)
CREATE INDEX idx_items_updated_or_created 
ON items ((COALESCE(updated_at, created_at)));

ANALYZE items;

-- Expression indexes automatically collect statistics on the expression
```

**Tradeoffs:**
- Query rewrite: More verbose SQL, no schema changes, immediate fix
- Expression statistics: Requires PG 14+, increases ANALYZE overhead
- Expression index: Uses disk space, maintains index on writes, but speeds up queries

**Multi-tenant caveat:**
If different tenants have vastly different data distributions, even expression statistics won't help because statistics are table-level, not per-tenant. Consider:
- Partition by tenant
- Query rewrite to expose columns
- Application-level query routing

---

### Case 4: Partition Pruning Failures

**Symptoms:**
- Partitioned table scans all partitions when it should scan one
- Query filters on partition key but planner doesn't prune
- Estimation includes rows from partitions that shouldn't be scanned

**Diagnosis:**
```sql
-- 1. Check if partition pruning is enabled
SHOW enable_partition_pruning;  -- Should be 'on'

-- 2. Run EXPLAIN on partitioned table
EXPLAIN (ANALYZE, VERBOSE)
SELECT * FROM orders
WHERE order_date = '2024-12-01';

-- Look for "Partitions removed" or "Partitions scanned" in output
-- If it scans all partitions → pruning failed

-- 3. Check partition constraints
SELECT 
    parent.relname AS parent_table,
    child.relname AS partition_name,
    pg_get_expr(child.relpartbound, child.oid) AS partition_bound
FROM pg_inherits
JOIN pg_class parent ON pg_inherits.inhparent = parent.oid
JOIN pg_class child ON pg_inherits.inhrelid = child.oid
WHERE parent.relname = 'orders'
ORDER BY child.relname;
```

**Root Cause:**
- Query uses function on partition key: `WHERE DATE_TRUNC('day', order_date) = '2024-12-01'`
- Partition key doesn't match query predicate exactly
- Planner can't prove which partitions to exclude
- Statistics are per-partition, but planner scans all → wrong row counts

**Resolution:**

```sql
-- Option 1: Rewrite query to match partition key exactly
-- Bad:
WHERE DATE_TRUNC('day', order_date) = '2024-12-01'

-- Good:
WHERE order_date >= '2024-12-01' 
  AND order_date < '2024-12-02'

-- Option 2: Ensure partition constraints are explicit
-- If using RANGE partitioning, constraints are automatic
-- If using LIST or custom, verify constraints exist:
SELECT conname, contype, pg_get_constraintdef(oid)
FROM pg_constraint
WHERE conrelid = 'orders_2024_12'::regclass;

-- Option 3: Enable runtime pruning (PG 11+)
SET enable_partition_pruning = on;

-- Option 4: Use partition-wise joins for large join queries
SET enable_partitionwise_join = on;
SET enable_partitionwise_aggregate = on;
```

**Partition statistics gotchas:**
```sql
-- Statistics exist at BOTH partition and parent level
-- Parent table statistics are aggregate (usually less useful)

-- Run ANALYZE on individual partitions for best estimates
ANALYZE orders_2024_12;
ANALYZE orders_2024_11;
-- etc.

-- Or analyze parent (slower but covers all)
ANALYZE orders;
```

---

### Case 5: N-Distinct Underestimation

**Symptoms:**
- GROUP BY queries have terrible estimation
- Hash aggregates spill to disk unexpectedly
- Planner thinks column has 1000 distinct values but actually has 1,000,000

**Diagnosis:**
```sql
-- 1. Compare estimated vs actual distinct values
SELECT 
    n_distinct,
    (SELECT COUNT(DISTINCT user_id) FROM items) AS actual_distinct
FROM pg_stats
WHERE tablename = 'items' AND attname = 'user_id';

-- 2. Check if n_distinct is negative (percentage-based)
-- n_distinct < 0 means: |n_distinct| * total_rows = estimated distinct
-- n_distinct > 0 means: absolute count

-- 3. If n_distinct is way off, check sampling
SELECT 
    tablename,
    attname,
    n_distinct,
    null_frac,
    n_dead_tup,
    n_live_tup,
    last_analyze
FROM pg_stats
JOIN pg_stat_user_tables USING (tablename)
WHERE tablename = 'items' AND attname = 'user_id';
```

**Root Cause:**
- ANALYZE samples rows (default: 30,000 × statistics_target / 100)
- If distinct values are rare or grow over time, sample misses them
- Planner underestimates distinct count
- Hash aggregates allocate too little memory → spill to disk

**Resolution:**

```sql
-- Option 1: Increase statistics target for the column
ALTER TABLE items ALTER COLUMN user_id SET STATISTICS 1000;
ANALYZE items;

-- Verify improvement
SELECT n_distinct FROM pg_stats 
WHERE tablename = 'items' AND attname = 'user_id';

-- Option 2: Manual n_distinct override (use with caution!)
-- Only if you KNOW the actual distinct count and it's stable
ALTER TABLE items ALTER COLUMN user_id SET (n_distinct = 1000000);
ANALYZE items;

-- Option 3: Create extended n_distinct statistics for multi-column cardinality
CREATE STATISTICS items_user_org_ndist (ndistinct) 
ON user_id, organization_id 
FROM items;
ANALYZE items;

-- This helps queries like:
-- SELECT user_id, organization_id, COUNT(*) FROM items GROUP BY 1, 2;
```

**When n_distinct matters most:**
- GROUP BY queries (hash aggregate sizing)
- DISTINCT queries
- Semi-joins (IN, EXISTS subqueries)
- Hash joins (hash table sizing)

---

### Case 6: Join Order Explosions

**Symptoms:**
- Query with 5+ table joins hangs in planning phase
- EXPLAIN takes 30+ seconds to return
- Query plan changes dramatically with minor query changes

**Diagnosis:**
```sql
-- 1. Check planning time vs execution time
EXPLAIN (ANALYZE, BUFFERS)
SELECT ... FROM t1 JOIN t2 JOIN t3 JOIN t4 JOIN t5 ...;

-- If "Planning Time" is excessive (>1000ms for 5 tables), you have a problem

-- 2. Check join collapse limits
SHOW join_collapse_limit;      -- Default: 8
SHOW from_collapse_limit;      -- Default: 8
SHOW geqo_threshold;           -- Default: 12

-- 3. Count number of joins in query
-- If query has 8+ joins and limits are default, planner evaluates ALL join orders
-- Join orders = factorial(n) → 8 tables = 40,320 possible orders
```

**Root Cause:**
- Postgres planner tries to find optimal join order
- For N tables, there are N! possible join orders
- Bad row estimation causes planner to explore wrong paths
- With many tables, bad estimates multiply exponentially

**Resolution:**

```sql
-- Option 1: Fix underlying row estimation (best long-term fix)
-- Use techniques from Cases 1-5 above

-- Option 2: Reduce join collapse limits (faster planning, potentially worse plans)
SET join_collapse_limit = 6;
SET from_collapse_limit = 6;

-- This limits planner to reordering only 6 tables at a time
-- Larger join sets use left-to-right order as written

-- Option 3: Enable GEQO for large joins (genetic algorithm)
SET geqo = on;
SET geqo_threshold = 8;
SET geqo_effort = 5;       -- 1-10, higher = more thorough
SET geqo_generations = 0;  -- 0 = auto

-- GEQO uses randomized search instead of exhaustive search
-- Faster planning, but plans may be suboptimal

-- Option 4: Rewrite query with explicit join order hints
-- Use CTEs or subqueries to force join order:
WITH small_set AS (
    SELECT * FROM large_table WHERE filter = 'X'  -- Reduce early
)
SELECT ... FROM small_set JOIN other_table ...;

-- Option 5: Use pg_hint_plan extension (if installed)
/*+ Leading((t1 t2 t3)) */
SELECT ... FROM t1 JOIN t2 JOIN t3 ...;
```

**Join strategy selection based on row counts:**
```
Nested Loop:     Best when one side is tiny (<100 rows)
                 Cost: O(rows_a * rows_b)
                 
Hash Join:       Best for medium-large joins (1K-10M rows)
                 Cost: O(rows_a + rows_b)
                 Requires memory for hash table
                 
Merge Join:      Best when both sides are pre-sorted
                 Cost: O(rows_a + rows_b)
                 Requires sorted input (index or sort step)
```

**Bad estimation impact on joins:**
```
Underestimate outer by 1000x:
  ✗ Chooses nested loop (1000x slower than hash join)
  
Overestimate inner by 1000x:
  ✗ Allocates giant hash table (OOM or spill to disk)
  
Underestimate both sides:
  ✗ Chooses nested loop when merge join is better
  ✗ Skips parallel workers (thinks dataset is tiny)
```

---

## Resolution Patterns

### Decision Tree: Which Fix to Apply?

```
1. Run EXPLAIN ANALYZE on the problematic query
   ├─ Estimation within 2x of actual? → Consider acceptable, monitor
   └─ Estimation >2x off? → Continue to step 2

2. Check last ANALYZE timestamp
   ├─ Last analyzed >24h ago AND table has heavy writes?
   │  └─ Run ANALYZE, go back to step 1
   └─ Recently analyzed? → Continue to step 3

3. Identify the operation with worst estimation
   ├─ Sequential scan with terrible estimation?
   │  └─ Check for function in WHERE clause → Case 3
   ├─ Hash join building huge hash table?
   │  └─ Check for correlated filters → Case 2
   ├─ Index scan returning way more rows than expected?
   │  └─ Check for outliers in data → Case 1
   ├─ Nested loop running 1M+ iterations?
   │  └─ Check for underestimated join input → Cases 2, 5
   └─ Planning time > 1s?
      └─ Check join count → Case 6

4. Apply appropriate fix from cases above

5. Verify fix worked
   ├─ Run EXPLAIN ANALYZE again
   ├─ Check estimation accuracy
   └─ Monitor production metrics

6. If fix didn't work, escalate for deeper investigation
```

### Quick Reference: Fix Selection Matrix

| Symptom | Likely Cause | Quick Fix | Proper Fix |
|---------|-------------|-----------|------------|
| Date range estimation way off | Outliers (Case 1) | Clean bad data | Increase STATISTICS + constraint |
| Multi-column filter estimation way off | Correlation (Case 2) | Remove redundant filter | Extended statistics (dependencies) |
| COALESCE/function in WHERE terrible estimate | Function blind spot (Case 3) | Rewrite query | Expression index/stats |
| Partitioned table scans all partitions | Pruning failure (Case 4) | Rewrite predicate | Fix partition key usage |
| GROUP BY creates huge hash table | N-distinct wrong (Case 5) | Increase work_mem | Increase STATISTICS |
| Planning takes forever | Join explosion (Case 6) | Lower join_collapse_limit | Fix row estimates + CTEs |
| Random variance between runs | Stale stats | Run ANALYZE | Tune autovacuum |

### Statistics Target Guidelines

```sql
-- Default: 100 (sufficient for most cases)
-- Use higher values for:

-- 1. Columns with outliers or extreme skew
ALTER TABLE items ALTER COLUMN created_at SET STATISTICS 1000;

-- 2. Columns with very high cardinality (>100K distinct values)
ALTER TABLE items ALTER COLUMN user_id SET STATISTICS 500;

-- 3. Columns used in frequent range queries
ALTER TABLE items ALTER COLUMN price SET STATISTICS 300;

-- 4. Foreign key columns in multi-tenant schemas
ALTER TABLE items ALTER COLUMN organization_id SET STATISTICS 1000;

-- Keep default for:
-- - Boolean columns
-- - Enum columns with few values
-- - Columns rarely used in WHERE clauses
```

**Cost of increasing STATISTICS:**

| Target | Sample Size | ANALYZE Time | Use Case |
|--------|-------------|--------------|----------|
| 10 | 3,000 rows | Fastest | Testing only |
| 100 (default) | 30,000 rows | ~1s per GB | Most tables |
| 500 | 150,000 rows | ~3s per GB | High cardinality |
| 1000 | 300,000 rows | ~5s per GB | Extreme skew |
| 10000 | 3,000,000 rows | ~30s per GB | Rare, special cases |

---

## Prevention & Monitoring

### Proactive Statistics Maintenance

**1. Tune autovacuum for your workload**

```sql
-- Check current autovacuum settings
SELECT name, setting, unit, context 
FROM pg_settings 
WHERE name LIKE '%autovacuum%' 
   OR name LIKE '%vacuum%'
ORDER BY name;

-- Global tuning (postgresql.conf or ALTER SYSTEM)
ALTER SYSTEM SET autovacuum_analyze_scale_factor = 0.05;  -- Default: 0.1
ALTER SYSTEM SET autovacuum_analyze_threshold = 50;       -- Default: 50
ALTER SYSTEM SET autovacuum_max_workers = 4;              -- Default: 3
SELECT pg_reload_conf();

-- Per-table tuning for high-churn tables
ALTER TABLE orders SET (
    autovacuum_analyze_scale_factor = 0.01,  -- Analyze after 1% change
    autovacuum_analyze_threshold = 1000       -- Or 1000 row changes
);

-- Per-table tuning for append-only tables
ALTER TABLE logs SET (
    autovacuum_analyze_scale_factor = 0.0,   -- Don't scale
    autovacuum_analyze_threshold = 100000    -- Analyze every 100K inserts
);

-- Disable autovacuum for static tables (use with caution!)
ALTER TABLE static_reference_data SET (
    autovacuum_enabled = false
);
-- Must manually ANALYZE after any changes
```

**2. Manual ANALYZE schedule for critical tables**

```sql
-- Create a function to analyze critical tables
CREATE OR REPLACE FUNCTION analyze_critical_tables()
RETURNS void AS $
BEGIN
    -- High-traffic tables
    ANALYZE VERBOSE items;
    ANALYZE VERBOSE orders;
    ANALYZE VERBOSE users;
    
    -- Partitioned tables (analyze parent + recent partitions)
    ANALYZE VERBOSE orders;  -- Parent
    ANALYZE VERBOSE orders_2024_12;
    ANALYZE VERBOSE orders_2024_11;
    
    RAISE NOTICE 'Critical tables analyzed at %', now();
END;
$ LANGUAGE plpgsql;

-- Schedule via cron (pg_cron extension)
-- Run every 4 hours during business hours
SELECT cron.schedule(
    'analyze-critical-tables',
    '0 8,12,16,20 * * *',
    'SELECT analyze_critical_tables();'
);
```

**3. Statistics validation after bulk operations**

```sql
-- Always run ANALYZE after:
-- - Bulk INSERT (>10% of table size)
-- - Bulk UPDATE (>10% of table size)
-- - Bulk DELETE (>10% of table size)
-- - TRUNCATE + reload
-- - Major schema migrations
-- - Partition creation/attachment

-- Example post-migration script:
BEGIN;
    -- Migration operations here
    INSERT INTO items SELECT * FROM items_staging;
    
    -- Refresh statistics immediately
    ANALYZE items;
COMMIT;
```

### Monitoring Dashboard Queries

**Query 1: Statistics health overview**

```sql
CREATE VIEW stats_health_dashboard AS
SELECT 
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size,
    n_live_tup,
    n_dead_tup,
    n_mod_since_analyze,
    last_analyze,
    last_autoanalyze,
    ROUND(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 1) AS dead_pct,
    ROUND(100.0 * n_mod_since_analyze / NULLIF(n_live_tup, 0), 1) AS mod_pct,
    CASE 
        WHEN last_analyze IS NULL AND last_autoanalyze IS NULL THEN 'NEVER'
        WHEN COALESCE(last_analyze, last_autoanalyze) < now() - interval '7 days' THEN 'STALE'
        WHEN n_mod_since_analyze > n_live_tup * 0.2 THEN 'NEEDS_ANALYZE'
        WHEN n_dead_tup > n_live_tup * 0.1 THEN 'NEEDS_VACUUM'
        ELSE 'OK'
    END AS status
FROM pg_stat_user_tables
WHERE n_live_tup > 1000
ORDER BY n_mod_since_analyze DESC;

-- Query the view
SELECT * FROM stats_health_dashboard 
WHERE status != 'OK'
ORDER BY size DESC;
```

**Query 2: Estimation accuracy tracker**

```sql
-- Requires auto_explain extension in production
-- ALTER SYSTEM SET auto_explain.log_min_duration = 1000;  -- Log plans for queries >1s
-- ALTER SYSTEM SET auto_explain.log_analyze = on;
-- ALTER SYSTEM SET auto_explain.log_buffers = on;

-- Parse logs to extract estimation vs actual rows
-- This is a conceptual query; actual implementation depends on your log aggregation
CREATE VIEW query_estimation_accuracy AS
SELECT 
    query_id,
    LEFT(query, 100) AS query_preview,
    calls,
    mean_exec_time,
    -- These fields available if you parse EXPLAIN output from logs
    -- estimated_rows,
    -- actual_rows,
    -- ROUND(actual_rows::numeric / NULLIF(estimated_rows, 0), 2) AS estimation_ratio,
    CASE 
        -- WHEN estimation_ratio BETWEEN 0.5 AND 2.0 THEN 'GOOD'
        -- WHEN estimation_ratio BETWEEN 0.1 AND 10.0 THEN 'POOR'
        -- ELSE 'CRITICAL'
    END AS estimation_quality
FROM pg_stat_statements
WHERE calls > 100
ORDER BY mean_exec_time DESC
LIMIT 50;
```

**Query 3: Autovacuum activity monitor**

```sql
SELECT 
    schemaname,
    tablename,
    pid,
    age(clock_timestamp(), xact_start) AS duration,
    CASE 
        WHEN query LIKE '%autovacuum%' THEN 'VACUUM'
        WHEN query LIKE '%ANALYZE%' THEN 'ANALYZE'
        ELSE 'OTHER'
    END AS operation,
    wait_event_type,
    wait_event
FROM pg_stat_activity
WHERE query LIKE '%autovacuum%' 
   OR query LIKE '%ANALYZE%'
ORDER BY duration DESC;
```

### Alerting Thresholds

```yaml
# Example alert rules (adapt to your monitoring system)

alerts:
  - name: stale_statistics
    condition: last_analyze > 24h AND n_mod_since_analyze > 100000
    severity: warning
    action: Run manual ANALYZE
    
  - name: critical_estimation_miss
    condition: estimated_rows / actual_rows > 10 OR estimated_rows / actual_rows < 0.1
    severity: critical
    action: Investigate query plan, check statistics
    
  - name: autovacuum_stuck
    condition: autovacuum_duration > 2h
    severity: warning
    action: Check for blocking locks, consider canceling
    
  - name: query_planning_time_high
    condition: planning_time > 5000ms
    severity: warning
    action: Check join_collapse_limit, number of joins
    
  - name: never_analyzed_table
    condition: last_analyze IS NULL AND table_size > 1GB
    severity: critical
    action: Run immediate ANALYZE
```

---

## Version-Specific Notes

### PostgreSQL 12

**Key Features:**
- Basic extended statistics (dependencies, n_distinct, MCV)
- Limited partition pruning capabilities
- No expression statistics

**Limitations:**
- Cannot create statistics on expressions
- Partition-wise join performance limited
- ANALYZE on partitioned tables is less efficient

**Workarounds:**
```sql
-- Must use query rewrites for function-wrapped columns
-- Cannot use expression statistics

-- For partitions, must analyze each partition individually
DO $
DECLARE
    partition_name text;
BEGIN
    FOR partition_name IN 
        SELECT tablename FROM pg_tables 
        WHERE tablename LIKE 'orders_2024%'
    LOOP
        EXECUTE 'ANALYZE ' || partition_name;
    END LOOP;
END $;
```

### PostgreSQL 13

**Key Features:**
- Improved parallel query planning
- Better partition pruning
- Enhanced VACUUM and ANALYZE performance

**New Capabilities:**
```sql
-- Parallel ANALYZE for large tables
ALTER TABLE large_table SET (parallel_workers = 4);
ANALYZE large_table;  -- Now runs in parallel

-- Incremental sort optimization (helps with estimation on sorted data)
SET enable_incremental_sort = on;
```

### PostgreSQL 14

**Key Features:**
- **Expression statistics** (game changer!)
- Better multi-column statistics
- Improved parallel workers cost model

**New Capabilities:**
```sql
-- Create statistics on expressions
CREATE STATISTICS items_expr_stats (statistics_kind)
ON (COALESCE(updated_at, created_at)),
   (LOWER(email))
FROM items;

-- More accurate parallel worker decisions
-- Planner better estimates when to use parallel workers
```

### PostgreSQL 15

**Key Features:**
- MERGE command (affects estimation on UPSERT workloads)
- Better handling of partitioned tables
- Improved statistics for sorted data

**Changes:**
```sql
-- More accurate estimation for sorted data
-- Better use of correlation statistics

-- Check correlation values
SELECT tablename, attname, correlation
FROM pg_stats
WHERE tablename = 'time_series_data'
  AND ABS(correlation) > 0.9;  -- High correlation = sorted data
```

### PostgreSQL 16

**Key Features:**
- Parallel vacuuming improvements
- Better incremental sort costing
- Enhanced logical replication statistics

**Improvements:**
```sql
-- Parallel VACUUM/ANALYZE is more efficient
-- Better estimation for incremental sort operations
-- Logical replication now tracks statistics better
```

### PostgreSQL 17 (Preview)

**Expected Features:**
- Further improvements to parallel query estimation
- Enhanced partition pruning
- Better handling of very large tables (>1TB)

---

## Advanced Troubleshooting

### Scenario: Estimation is correct but plan is still wrong

**Symptoms:**
- EXPLAIN shows accurate row counts
- But planner still chooses suboptimal plan (e.g., nested loop when hash join is faster)

**Diagnosis:**
```sql
-- Check planner cost parameters
SHOW seq_page_cost;       -- Default: 1.0
SHOW random_page_cost;    -- Default: 4.0
SHOW cpu_tuple_cost;      -- Default: 0.01
SHOW cpu_operator_cost;   -- Default: 0.0025
SHOW effective_cache_size; -- Default: 4GB

-- These defaults assume spinning disks
-- If you have SSDs or lots of RAM, they're wrong!
```

**Resolution:**
```sql
-- For SSD storage
ALTER SYSTEM SET random_page_cost = 1.1;  -- Down from 4.0
ALTER SYSTEM SET effective_cache_size = '32GB';  -- Match your RAM

-- For all-in-memory workloads
ALTER SYSTEM SET random_page_cost = 1.0;
ALTER SYSTEM SET seq_page_cost = 1.0;

SELECT pg_reload_conf();

-- Test query again
EXPLAIN (ANALYZE, BUFFERS) SELECT ...;
```

### Scenario: Estimation fluctuates wildly between runs

**Symptoms:**
- Same query, different plans on different days
- No obvious data changes

**Diagnosis:**
```sql
-- Check if autovacuum is actually running
SELECT schemaname, tablename, 
       n_tup_ins, n_tup_upd, n_tup_del,
       n_live_tup, n_dead_tup,
       last_vacuum, last_autovacuum,
       last_analyze, last_autoanalyze
FROM pg_stat_user_tables
WHERE tablename = 'your_table';

-- Check for autovacuum cancellations
SELECT query, state, wait_event_type, wait_event,
       age(clock_timestamp(), xact_start) AS duration
FROM pg_stat_activity
WHERE query LIKE '%autovacuum%';

-- Check for blocking locks
SELECT 
    blocked.pid AS blocked_pid,
    blocked.query AS blocked_query,
    blocking.pid AS blocking_pid,
    blocking.query AS blocking_query,
    age(clock_timestamp(), blocked.xact_start) AS blocked_duration
FROM pg_stat_activity blocked
JOIN pg_locks blocked_locks ON blocked.pid = blocked_locks.pid
JOIN pg_locks blocking_locks ON 
    blocked_locks.locktype = blocking_locks.locktype
    AND blocked_locks.relation = blocking_locks.relation
    AND blocked_locks.pid != blocking_locks.pid
JOIN pg_stat_activity blocking ON blocking_locks.pid = blocking.pid
WHERE NOT blocked_locks.granted;
```

**Resolution:**
```sql
-- 1. Ensure autovacuum can complete
-- Lower autovacuum_naptime for more frequent runs
ALTER SYSTEM SET autovacuum_naptime = '30s';  -- Default: 1min

-- Increase autovacuum_work_mem for faster completion
ALTER SYSTEM SET autovacuum_work_mem = '1GB';  -- Default: -1 (use maintenance_work_mem)

-- 2. Kill long-running transactions that block autovacuum
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE state = 'idle in transaction'
  AND xact_start < now() - interval '1 hour';

-- 3. Consider using pg_cron for scheduled ANALYZE during off-peak
SELECT cron.schedule(
    'late-night-analyze',
    '0 2 * * *',  -- 2 AM daily
    'ANALYZE;'
);
```

### Scenario: Multi-tenant table with vastly different data distributions

**Symptoms:**
- Tenant A has 1M rows, Tenant B has 100 rows
- Queries for Tenant A are fast, Tenant B are slow (or vice versa)
- Statistics represent "average" distribution, helping no one

**Diagnosis:**
```sql
-- Check tenant distribution
SELECT 
    tenant_id,
    COUNT(*) AS row_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct_of_total
FROM items
GROUP BY tenant_id
ORDER BY row_count DESC
LIMIT 20;

-- Check if statistics match any specific tenant
SELECT 
    tablename,
    attname,
    n_distinct,
    most_common_vals,
    most_common_freqs
FROM pg_stats
WHERE tablename = 'items'
  AND attname = 'tenant_id';
```

**Resolution:**

```sql
-- Option 1: Partition by tenant (best for large tenants)
CREATE TABLE items_partitioned (
    id UUID,
    tenant_id INT,
    ...
) PARTITION BY LIST (tenant_id);

CREATE TABLE items_tenant_1 PARTITION OF items_partitioned
    FOR VALUES IN (1);
    
CREATE TABLE items_tenant_2 PARTITION OF items_partitioned
    FOR VALUES IN (2);

-- Now each partition has accurate statistics
ANALYZE items_tenant_1;
ANALYZE items_tenant_2;

-- Option 2: Use schema-per-tenant (extreme isolation)
CREATE SCHEMA tenant_1;
CREATE TABLE tenant_1.items (...);

CREATE SCHEMA tenant_2;
CREATE TABLE tenant_2.items (...);

-- Each tenant's statistics are independent
-- No cross-tenant pollution

-- Option 3: Application-level query optimization
-- Detect large vs small tenants in app layer
-- Route to different query strategies

-- For large tenant (1M+ rows):
SELECT * FROM items 
WHERE tenant_id = 1 
  AND created_at > '2024-01-01';

-- For small tenant (<1K rows):
SELECT * FROM items 
WHERE tenant_id = 999;  -- Don't even filter by date, fetch all rows

-- Option 4: Per-tenant extended statistics (PG 14+)
-- Only helps if you filter on tenant + another correlated column
CREATE STATISTICS items_tenant_user_stats (dependencies)
ON tenant_id, user_id
FROM items;
```

### Scenario: Table too large to ANALYZE in reasonable time

**Symptoms:**
- Table is 5TB+
- ANALYZE takes 12+ hours
- Cannot block production for that long

**Diagnosis:**
```sql
-- Check current statistics target
SELECT attname, attstattarget
FROM pg_attribute
WHERE attrelid = 'huge_table'::regclass
  AND attname NOT IN ('tableoid', 'cmax', 'xmax', 'cmin', 'xmin', 'ctid');

-- Estimate ANALYZE time based on sample size
-- Sample size = 300 * statistics_target rows per column
-- At statistics_target = 1000:
-- Sample size = 300,000 rows × number_of_columns
-- On a 5TB table, this could mean scanning 100GB+
```

**Resolution:**

```sql
-- Option 1: Lower statistics target temporarily
ALTER TABLE huge_table ALTER COLUMN col1 SET STATISTICS 100;  -- Down from 1000
ALTER TABLE huge_table ALTER COLUMN col2 SET STATISTICS 100;
ANALYZE huge_table;

-- Gradually increase after confirming it helps
ALTER TABLE huge_table ALTER COLUMN col1 SET STATISTICS 300;
ANALYZE huge_table;

-- Option 2: Analyze only specific columns
ANALYZE huge_table (col1, col2, col3);  -- Only analyze these columns

-- Option 3: Use parallel analyze (PG 13+)
ALTER TABLE huge_table SET (parallel_workers = 8);
ANALYZE huge_table;  -- Now runs in parallel

-- Option 4: Partition the table
-- Convert to partitioned table (requires migration)
-- Each partition can be analyzed independently and quickly

-- Option 5: Scheduled rolling ANALYZE
-- Analyze different columns on different days
DO $
DECLARE
    day_of_week INT := EXTRACT(DOW FROM now());
BEGIN
    CASE day_of_week
        WHEN 0 THEN ANALYZE huge_table (col1, col2);
        WHEN 1 THEN ANALYZE huge_table (col3, col4);
        WHEN 2 THEN ANALYZE huge_table (col5, col6);
        -- etc.
    END CASE;
END $;
```

---

## Appendix: Quick Reference

### EXPLAIN Options Cheat Sheet

```sql
-- Basic plan (no execution)
EXPLAIN SELECT ...;

-- With execution timing
EXPLAIN ANALYZE SELECT ...;

-- With buffer usage (I/O stats)
EXPLAIN (ANALYZE, BUFFERS) SELECT ...;

-- With all details (use this for deep debugging)
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, SETTINGS, WAL) SELECT ...;

-- JSON format (for tooling)
EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) SELECT ...;
```

### Statistics Catalog Quick Reference

```sql
-- View table statistics
SELECT * FROM pg_stats WHERE tablename = 'your_table';

-- View extended statistics
SELECT * FROM pg_stats_ext WHERE tablename = 'your_table';

-- View table-level autovacuum stats
SELECT * FROM pg_stat_user_tables WHERE tablename = 'your_table';

-- View query performance stats
SELECT * FROM pg_stat_statements ORDER BY mean_exec_time DESC LIMIT 20;

-- View current statistics targets
SELECT 
    attname,
    attstattarget,
    CASE 
        WHEN attstattarget = -1 THEN 'default (100)'
        ELSE attstattarget::text
    END AS effective_target
FROM pg_attribute
WHERE attrelid = 'your_table'::regclass
  AND attnum > 0
ORDER BY attnum;
```

### Common Planner Hints (Session-Level)

```sql
-- Force specific join strategy
SET enable_nestloop = off;        -- Disable nested loop
SET enable_hashjoin = off;        -- Disable hash join
SET enable_mergejoin = off;       -- Disable merge join

-- Force specific scan strategy  
SET enable_seqscan = off;         -- Disable sequential scan
SET enable_indexscan = off;       -- Disable index scan
SET enable_bitmapscan = off;      -- Disable bitmap scan

-- Parallel query tuning
SET max_parallel_workers_per_gather = 4;
SET parallel_tuple_cost = 0.01;
SET parallel_setup_cost = 100;

-- Join order control
SET join_collapse_limit = 1;      -- Force written join order
SET from_collapse_limit = 1;      -- No reordering

-- Reset all to defaults
RESET ALL;
```

### Useful Monitoring Views

```sql
-- Create helper views for common diagnostics

-- View 1: Tables needing attention
CREATE OR REPLACE VIEW tables_need_maintenance AS
SELECT 
    schemaname || '.' || tablename AS table_name,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size,
    n_live_tup,
    n_dead_tup,
    ROUND(100.0 * n_dead_tup / NULLIF(n_live_tup, 0), 1) AS dead_pct,
    n_mod_since_analyze,
    last_analyze,
    last_autoanalyze,
    CASE 
        WHEN last_analyze IS NULL THEN 'NEVER_ANALYZED'
        WHEN n_mod_since_analyze > n_live_tup * 0.2 THEN 'NEED_ANALYZE'
        WHEN n_dead_tup > n_live_tup * 0.1 THEN 'NEED_VACUUM'
        ELSE 'OK'
    END AS action_needed
FROM pg_stat_user_tables
WHERE n_live_tup > 1000
  AND schemaname NOT IN ('pg_catalog', 'information_schema');

-- View 2: Slow queries with bad plans
CREATE OR REPLACE VIEW slow_queries_bad_plans AS
SELECT 
    queryid,
    LEFT(query, 120) AS query_preview,
    calls,
    ROUND(mean_exec_time::numeric, 2) AS mean_ms,
    ROUND(stddev_exec_time::numeric, 2) AS stddev_ms,
    ROUND(100.0 * stddev_exec_time / NULLIF(mean_exec_time, 0), 1) AS variance_pct,
    rows,
    shared_blks_hit + shared_blks_read AS total_blocks,
    CASE 
        WHEN stddev_exec_time > mean_exec_time THEN 'UNSTABLE'
        WHEN mean_exec_time > 1000 THEN 'SLOW'
        ELSE 'OK'
    END AS status
FROM pg_stat_statements
WHERE calls > 10
  AND mean_exec_time > 100
ORDER BY stddev_exec_time DESC;

-- View 3: Current blocking locks
CREATE OR REPLACE VIEW current_blocking_locks AS
SELECT 
    blocked.pid AS blocked_pid,
    blocked_activity.usename AS blocked_user,
    blocked_activity.query AS blocked_query,
    blocking.pid AS blocking_pid,
    blocking_activity.usename AS blocking_user,
    blocking_activity.query AS blocking_query,
    blocked_locks.mode AS blocked_mode,
    blocking_locks.mode AS blocking_mode,
    age(clock_timestamp(), blocked_activity.xact_start) AS blocked_duration
FROM pg_catalog.pg_locks blocked_locks
JOIN pg_catalog.pg_stat_activity blocked_activity ON blocked_locks.pid = blocked_activity.pid
JOIN pg_catalog.pg_locks blocking_locks ON 
    blocking_locks.locktype = blocked_locks.locktype
    AND blocking_locks.database IS NOT DISTINCT FROM blocked_locks.database
    AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation
    AND blocking_locks.page IS NOT DISTINCT FROM blocked_locks.page
    AND blocking_locks.tuple IS NOT DISTINCT FROM blocked_locks.tuple
    AND blocking_locks.virtualxid IS NOT DISTINCT FROM blocked_locks.virtualxid
    AND blocking_locks.transactionid IS NOT DISTINCT FROM blocked_locks.transactionid
    AND blocking_locks.classid IS NOT DISTINCT FROM blocked_locks.classid
    AND blocking_locks.objid IS NOT DISTINCT FROM blocked_locks.objid
    AND blocking_locks.objsubid IS NOT DISTINCT FROM blocked_locks.objsubid
    AND blocking_locks.pid != blocked_locks.pid
JOIN pg_catalog.pg_stat_activity blocking_activity ON blocking_locks.pid = blocking_activity.pid
WHERE NOT blocked_locks.granted;
```

---

## Runbook Maintenance

### Change Log Template

```
Date: YYYY-MM-DD
Engineer: [Your Name]
Change: [Description]
Tables Affected: [List]
Before Stats: [EXPLAIN output]
After Stats: [EXPLAIN output]
Result: [Success/Failure]
Rollback Required: [Yes/No]
```

### Post-Incident Review Checklist

After resolving a bad estimation incident:

- [ ] Document the root cause
- [ ] Update this runbook if new pattern discovered
- [ ] Add monitoring/alerting to detect similar issues
- [ ] Review other tables for same pattern
- [ ] Schedule proactive ANALYZE if needed
- [ ] Update application query patterns if needed
- [ ] Communicate findings to team
- [ ] Schedule follow-up to verify fix holds

### Quarterly Statistics Audit

Run this checklist every quarter:

```sql
-- 1. Identify tables never analyzed
SELECT tablename 
FROM pg_stat_user_tables 
WHERE last_analyze IS NULL 
  AND last_autoanalyze IS NULL
  AND n_live_tup > 1000;

-- 2. Check for tables with stale extended statistics
SELECT stxname, stxrelid::regclass, 
       (SELECT last_analyze FROM pg_stat_user_tables 
        WHERE relid = stxrelid) AS last_analyzed
FROM pg_statistic_ext
WHERE (SELECT last_analyze FROM pg_stat_user_tables WHERE relid = stxrelid) 
      < now() - interval '30 days';

-- 3. Review statistics targets for large tables
SELECT tablename,
       pg_size_pretty(pg_total_relation_size(tablename::regclass)) AS size,
       attname,
       attstattarget
FROM pg_attribute
JOIN pg_stat_user_tables ON attrelid = relid
WHERE attnum > 0
  AND pg_total_relation_size(relid) > 10*1024*1024*1024  -- >10GB
  AND attstattarget = -1  -- Using default
ORDER BY pg_total_relation_size(relid) DESC;

-- 4. Check for correlation opportunities
-- Manual review: look for foreign key relationships
-- Check if extended statistics exist for correlated columns
```

---

## Emergency Contact & Escalation

### When to Escalate

Escalate to senior DBA / database team lead if:
- Issue persists after applying all resolution patterns
- Requires breaking changes (schema migrations, partitioning)
- Impacts multiple critical services
- Data corruption suspected
- Requires extended production outage

### Pre-Escalation Checklist

Before escalating, gather:
- [ ] Complete EXPLAIN ANALYZE output (before and after fixes attempted)
- [ ] pg_stat_statements data for the query
- [ ] Table statistics: `SELECT * FROM pg_stats WHERE tablename = '...'`
- [ ] Recent ANALYZE history
- [ ] Timeline of issue (when started, query volume, impact)
- [ ] All fixes attempted and their results
- [ ] Current production impact metrics

---

## Additional Resources

### Official Documentation
- [PostgreSQL Planner Statistics](https://www.postgresql.org/docs/current/planner-stats.html)
- [Extended Statistics](https://www.postgresql.org/docs/current/planner-stats.html#PLANNER-STATS-EXTENDED)
- [ANALYZE Command](https://www.postgresql.org/docs/current/sql-analyze.html)
- [pg_stats View](https://www.postgresql.org/docs/current/view-pg-stats.html)
- [Original] (https://dev.to/michal_cyncynatus_3a792c2/when-analyze-isnt-enough-debugging-bad-row-estimation-in-postgresql-47n6)

### Visualization Tools
- [Dalibo Plan Viewer](https://explain.dalibo.com/)
- [explain.depesz.com](https://explain.depesz.com/)
- [PEV2 (Postgres Explain Visualizer)](https://dalibo.github.io/pev2/)

### Extensions
- `pg_stat_statements`: Query performance tracking
- `auto_explain`: Automatic EXPLAIN logging
- `pg_hint_plan`: Query hints for plan control
- `pg_cron`: Scheduling for maintenance tasks

---
