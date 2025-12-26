# Platform DBRE Runbook: ORDER BY + LIMIT Performance
## PostgreSQL 13, 15, 16 | Read-Heavy Workloads with Aggregations

---

## Executive Summary

ORDER BY + LIMIT queries become exponentially expensive under production load despite appearing trivial. This runbook addresses the full spectrum of performance issues in read-heavy systems (70%+ reads) with complex aggregation patterns, providing staff-level investigation protocols and remediation strategies.

**Critical Understanding**: LIMIT does not reduce sort cost—it only limits output after sorting completes.

---

## Problem Space

### When ORDER BY + LIMIT Degrades

| Scenario | Why It Fails | Production Impact |
|----------|--------------|-------------------|
| **No matching index** | Full table scan → in-memory sort → discard 99.9% | Query time: O(n log n) regardless of LIMIT |
| **Index exists but unused** | Random I/O to heap for non-indexed columns | Worse than sequential scan on large tables |
| **Deep OFFSET pagination** | Re-sorts entire dataset + skips N rows | Linear degradation with page depth |
| **Aggregation + ORDER BY** | Materializes aggregation before sorting | Memory pressure, temp file writes |
| **GROUP BY + ORDER BY** | Groups entire dataset before sorting | Cannot use index for ordering |

### Read-Heavy Workload Specifics

Your workload profile (70% reads, heavy aggregation) amplifies these issues:
- Aggregations prevent index-only scans
- GROUP BY forces materialization before ORDER BY
- Concurrent reads compete for shared buffers
- Connection pooling saturates under slow queries

---

## Diagnostic Protocol

### Stage 1: Identify Problem Queries

```sql
-- Find queries with high sort cost (PostgreSQL 13-16)
SELECT 
    query,
    calls,
    total_exec_time,
    mean_exec_time,
    rows,
    100.0 * shared_blks_hit / NULLIF(shared_blks_hit + shared_blks_read, 0) AS cache_hit_ratio
FROM pg_stat_statements
WHERE query LIKE '%ORDER BY%'
  AND query LIKE '%LIMIT%'
ORDER BY total_exec_time DESC
LIMIT 20;
```

```sql
-- Detect excessive sorting operations
SELECT 
    schemaname,
    relname,
    seq_scan,
    seq_tup_read,
    idx_scan,
    seq_tup_read / NULLIF(seq_scan, 0) AS avg_seq_tup_per_scan
FROM pg_stat_user_tables
WHERE seq_scan > 0
ORDER BY seq_tup_read DESC
LIMIT 20;
```

### Stage 2: Explain Analysis

```sql
-- Critical: Always use EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, WAM) 
SELECT product_name, price, created_at
FROM products
ORDER BY created_at DESC
LIMIT 20;
```

**Red Flags in Execution Plan**:
- `Sort Method: external merge` → Spilling to disk
- `Buffers: temp read=X written=Y` → Memory exhaustion
- `Rows Removed by Filter: 999980` → No index utilization
- `Heap Fetches: 1000000` → Index not covering
- `Sort Space Used: XMB` → work_mem insufficient

### Stage 3: Index Coverage Analysis

```sql
-- Check index usage patterns
SELECT 
    schemaname,
    tablename,
    indexname,
    idx_scan,
    idx_tup_read,
    idx_tup_fetch,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pg_stat_user_indexes
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY idx_scan ASC
LIMIT 20;
```

---

## Remediation Strategies

### Strategy 1: Index-Only Scans (Highest Impact)

**Problem**: Database reads index for ordering, then fetches heap for other columns.

**Solution**: INCLUDE clause (PostgreSQL 11+)

```sql
-- Before: Index on sort column only
CREATE INDEX idx_products_created_at ON products (created_at DESC);
-- Result: Still requires heap fetches for product_name, price

-- After: Covering index with INCLUDE
CREATE INDEX idx_products_created_at_covering 
ON products (created_at DESC) 
INCLUDE (product_name, price, category_id);
-- Result: Index-only scan, 10-100x faster
```

**For PostgreSQL 13-16 with aggregations**:
```sql
-- Partial index for filtered aggregations
CREATE INDEX idx_products_active_created 
ON products (created_at DESC) 
INCLUDE (price, quantity)
WHERE status = 'active' AND deleted_at IS NULL;
```

**When to Use**:
- Queries consistently request same columns
- Index size acceptable (monitor bloat)
- Read:write ratio > 10:1

### Strategy 2: Composite Indexes for Filtered Sorts

**Critical Ordering**: Filter columns → Sort columns → INCLUDE columns

```sql
-- Anti-pattern
CREATE INDEX idx_bad ON products (created_at DESC, category_id);

-- Correct pattern
CREATE INDEX idx_products_category_created 
ON products (category_id, created_at DESC)
INCLUDE (product_name, price);
```

**For multi-column sorts**:
```sql
-- Query: WHERE status = 'active' ORDER BY priority DESC, created_at DESC
CREATE INDEX idx_products_status_priority_created
ON products (status, priority DESC, created_at DESC)
INCLUDE (title, user_id);
```

**PostgreSQL 13-16 Behavior**:
- Uses index if WHERE columns are leftmost
- Can skip sort if ORDER BY matches index order exactly
- NULLS FIRST/LAST must match index definition

### Strategy 3: Aggregation Optimization

**Problem**: `GROUP BY` + `ORDER BY` forces full aggregation before sorting.

```sql
-- Slow: Aggregates all groups, then sorts
SELECT category_id, COUNT(*), MAX(price)
FROM products
GROUP BY category_id
ORDER BY MAX(price) DESC
LIMIT 10;
```

**Solution A: Partial Aggregation Index**
```sql
-- PostgreSQL 13+: Expression index on aggregate
CREATE INDEX idx_products_category_price 
ON products (category_id, price DESC);

-- Query planner may use for GROUP BY optimization
```

**Solution B: Materialized Views** (for complex aggregations)
```sql
CREATE MATERIALIZED VIEW mv_category_stats AS
SELECT 
    category_id,
    COUNT(*) as product_count,
    MAX(price) as max_price,
    AVG(price) as avg_price,
    MAX(updated_at) as last_updated
FROM products
GROUP BY category_id;

CREATE INDEX idx_mv_category_stats_price 
ON mv_category_stats (max_price DESC);

-- Refresh strategy (PostgreSQL 13-16)
REFRESH MATERIALIZED VIEW CONCURRENTLY mv_category_stats;
-- Requires unique index for CONCURRENTLY
```

**Solution C: Incremental View Maintenance** (PostgreSQL 16+)
```sql
-- Available in pg_ivm extension or native in future versions
-- Automatically updates materialized view on base table changes
```

### Strategy 4: Keyset (Cursor) Pagination

**Problem**: OFFSET becomes O(n) as page depth increases.

```sql
-- Anti-pattern: Deep OFFSET
SELECT * FROM products
ORDER BY created_at DESC, id DESC
LIMIT 20 OFFSET 100000;
-- Sorts 100,020 rows, returns 20
```

**Solution**: Seek method using WHERE clauses
```sql
-- Initial page
SELECT id, created_at, product_name
FROM products
ORDER BY created_at DESC, id DESC
LIMIT 20;
-- Returns: last row has created_at='2024-01-15 10:30:00', id=42

-- Next page
SELECT id, created_at, product_name
FROM products
WHERE (created_at, id) < ('2024-01-15 10:30:00', 42)
ORDER BY created_at DESC, id DESC
LIMIT 20;
```

**Critical**: Requires composite index on pagination columns:
```sql
CREATE INDEX idx_products_created_id 
ON products (created_at DESC, id DESC)
INCLUDE (product_name, price);
```

**Advantages**:
- Constant time per page (O(log n))
- Resilient to concurrent inserts
- Predictable performance at any depth

**Disadvantages**:
- Cannot jump to arbitrary page numbers
- Requires exposing pagination cursor to client

### Strategy 5: Window Functions for Ranked Results

**Problem**: Subqueries with ORDER BY + LIMIT per group.

```sql
-- Anti-pattern: Correlated subquery
SELECT * FROM products p1
WHERE id IN (
    SELECT id FROM products p2
    WHERE p2.category_id = p1.category_id
    ORDER BY created_at DESC
    LIMIT 5
);
-- O(n²) complexity
```

**Solution**: LATERAL join with window functions (PostgreSQL 13-16)
```sql
SELECT DISTINCT ON (category_id, rn) *
FROM (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY category_id ORDER BY created_at DESC) as rn
    FROM products
) sub
WHERE rn <= 5;

-- Or with LATERAL (often faster)
SELECT p.*
FROM (SELECT DISTINCT category_id FROM products) c
CROSS JOIN LATERAL (
    SELECT * FROM products
    WHERE category_id = c.category_id
    ORDER BY created_at DESC
    LIMIT 5
) p;
```

**Index for LATERAL**:
```sql
CREATE INDEX idx_products_category_created_lateral
ON products (category_id, created_at DESC)
INCLUDE (product_name, price);
```

---

## Advanced Techniques

### Work_mem Tuning for Sorts

```sql
-- Session-level for analytical queries
SET work_mem = '256MB';

-- Check if sorts are spilling to disk
EXPLAIN (ANALYZE, BUFFERS) 
SELECT ... ORDER BY ... LIMIT ...;
-- Look for: "Sort Method: external merge"
```

**Guidelines**:
- Default: 4MB (too low for production)
- Read-heavy workload: 64-256MB per connection
- Max: `(Total RAM * 0.5) / max_connections`
- Monitor: `log_temp_files = 0` to catch disk spills

### Parallel Query for Large Sorts (PostgreSQL 13+)

```sql
-- Enable parallel execution
SET max_parallel_workers_per_gather = 4;
SET parallel_setup_cost = 100;
SET parallel_tuple_cost = 0.01;

-- Force parallel sort (for testing)
SET force_parallel_mode = on;
```

**Effective when**:
- Table > 8MB (configurable via `min_parallel_table_scan_size`)
- Sort cost > `parallel_setup_cost`
- Available workers in pool

**Not effective for**:
- Queries with LIMIT < 1000 (overhead exceeds benefit)
- Hot tables with high write contention

### Partition Pruning for Time-Series Data

```sql
-- Range partitioning by created_at
CREATE TABLE products (
    id BIGSERIAL,
    created_at TIMESTAMPTZ NOT NULL,
    ...
) PARTITION BY RANGE (created_at);

CREATE TABLE products_2024_q1 PARTITION OF products
FOR VALUES FROM ('2024-01-01') TO ('2024-04-01');

-- Index per partition
CREATE INDEX idx_products_2024_q1_created 
ON products_2024_q1 (created_at DESC)
INCLUDE (product_name, price);

-- Query with partition pruning
SELECT * FROM products
WHERE created_at >= '2024-03-01'
ORDER BY created_at DESC
LIMIT 20;
-- Only scans products_2024_q1 partition
```

**Benefits**:
- Smaller index per partition
- Faster VACUUM/ANALYZE
- Automatic partition pruning with WHERE clauses

### BRIN Indexes for Sequential Data

```sql
-- For timestamp columns with high correlation
CREATE INDEX idx_products_created_brin 
ON products USING BRIN (created_at) 
WITH (pages_per_range = 32);

-- 100x smaller than B-tree, effective for:
-- - ORDER BY on naturally ordered data
-- - Large tables with sequential inserts
-- - Low cardinality filtering
```

**PostgreSQL 16 Enhancement**: BRIN indexes support MIN/MAX optimization for ORDER BY.

---

## Monitoring & Alerting

### Key Metrics

```sql
-- Sort operations per second
SELECT 
    (sum(calls) / EXTRACT(EPOCH FROM (now() - stats_reset))) as sorts_per_sec,
    sum(total_exec_time) / sum(calls) as avg_sort_time_ms
FROM pg_stat_statements
WHERE query LIKE '%ORDER BY%';
```

```sql
-- Index bloat detection
SELECT 
    schemaname, tablename, indexname,
    pg_size_pretty(pg_relation_size(indexrelid)) as index_size,
    round(100 * pg_relation_size(indexrelid) / 
          NULLIF(pg_relation_size(relid), 0), 2) as index_ratio
FROM pg_stat_user_indexes
JOIN pg_class ON pg_class.oid = indexrelid
ORDER BY pg_relation_size(indexrelid) DESC;
```

### Alerting Thresholds

- **Sort temp file writes** > 100MB/sec → Insufficient work_mem
- **Mean query time** > 500ms for ORDER BY + LIMIT → Missing index
- **Cache hit ratio** < 95% on sorted queries → Index bloat or memory pressure
- **Sequential scans** > index scans on large tables → Index not used

---

## PostgreSQL Version-Specific Considerations

### PostgreSQL 13
- Parallel hashing for GROUP BY
- Incremental sort optimization
- B-tree deduplication (reduces index bloat)

### PostgreSQL 15
- UNIQUE NULLS NOT DISTINCT (affects index usage)
- MERGE command (for materialized view updates)
- Improved cost estimation for ORDER BY

### PostgreSQL 16
- Parallel execution for window functions (major win for aggregations)
- Incremental sort improvements
- Right/inner incremental sort optimization

---

## Critical Advanced Topics (Beyond Original Article)

### 1. **FOR UPDATE SKIP LOCKED with ORDER BY**

**Problem**: Queue processing with ORDER BY + LIMIT + FOR UPDATE SKIP LOCKED has unique performance characteristics.

```sql
-- Anti-pattern: Can cause index-only scan to become heap scan
SELECT id FROM jobs 
WHERE status = 'pending'
ORDER BY created_at 
LIMIT 100 
FOR UPDATE SKIP LOCKED;
```

**Why It's Slow**:
- `FOR UPDATE` requires writing xmin/xmax to tuple headers
- Converts Index-Only Scan → Index Scan (heap fetches)
- With many locked rows, degrades toward sequential scan performance

**Query Plan Impact**:
```sql
-- Without FOR UPDATE (fast - Index Only Scan)
EXPLAIN ANALYZE 
SELECT id FROM jobs WHERE status = 'pending' ORDER BY id LIMIT 100;
-- Index Only Scan, Heap Fetches: 91

-- With FOR UPDATE SKIP LOCKED (slower - Index Scan)
EXPLAIN ANALYZE 
SELECT id FROM jobs WHERE status = 'pending' ORDER BY id LIMIT 100 
FOR UPDATE SKIP LOCKED;
-- Index Scan (cannot use Index Only), must access heap
```

**Optimization Strategies**:

**A. Batch Locking** (reduce lock overhead)
```sql
-- Instead of LIMIT 1, lock batches
SELECT id FROM jobs
WHERE status = 'pending'
ORDER BY created_at
LIMIT 250  -- Process in batches
FOR UPDATE SKIP LOCKED;
```

**B. Eliminate ORDER BY When Not Strictly Needed**
```sql
-- If FIFO is "mostly ordered" not "strictly ordered"
SELECT id FROM jobs
WHERE status = 'pending'
-- Remove ORDER BY - let insertion order dominate
LIMIT 250
FOR UPDATE SKIP LOCKED;
```

**C. Use UPDATE...RETURNING Pattern**
```sql
-- Combine lock + update in single statement
WITH cte AS (
    SELECT id FROM jobs
    WHERE status = 'pending'
    ORDER BY created_at
    LIMIT 100
    FOR UPDATE SKIP LOCKED
)
UPDATE jobs
SET status = 'processing', started_at = NOW()
FROM cte
WHERE jobs.id = cte.id
RETURNING jobs.*;
```

**D. Index Strategy for SKIP LOCKED**
```sql
-- Composite index: filter → sort → covering
CREATE INDEX idx_jobs_status_created 
ON jobs (status, created_at)
INCLUDE (payload, worker_id)
WHERE status IN ('pending', 'processing');
-- Partial index reduces bloat from completed jobs
```

**PostgreSQL 13-16 Behavior**:
- Many locked rows → scanning overhead increases linearly
- ORDER BY with SKIP LOCKED scales poorly beyond ~100 concurrent workers
- Consider partitioning by worker pool or removing strict ordering

**Real-World Metrics**:
- 60 concurrent workers: minimal overhead
- 70+ concurrent workers: exponential degradation
- 80+ concurrent workers: 30+ minute delays observed

**When SKIP LOCKED + ORDER BY Is Acceptable**:
- Low concurrency (< 10 workers)
- Small batch sizes (LIMIT < 100)
- ORDER BY is business-critical (strict FIFO required)

### 2. **UNION ALL Merge Sort Optimization**

**Problem**: JOIN + ORDER BY + LIMIT with filtered data often scans unnecessarily.

```sql
-- Anti-pattern: Filters 800,000 rows to find 10 rows
SELECT tbl.* 
FROM tbl 
JOIN tbl_gid ON tbl.gid = tbl_gid.gid
WHERE tbl_gid.gid IN (9, 10)
ORDER BY tbl.crt_time 
LIMIT 10;
-- Problem: Sorts entire join result before LIMIT
```

**Solution**: UNION ALL with per-partition ORDER BY (Merge Append)
```sql
-- Optimized: Each subquery uses index, merged without re-sorting
SELECT * FROM (
    SELECT * FROM tbl WHERE gid = 9 ORDER BY crt_time LIMIT 10
) UNION ALL (
    SELECT * FROM tbl WHERE gid = 10 ORDER BY crt_time LIMIT 10
)
ORDER BY crt_time LIMIT 10;
-- PostgreSQL uses Merge Append (no sort needed)
```

**Execution Plan Difference**:
```sql
-- Bad plan (100ms)
-> Sort (rows=20000) -> Nested Loop Join

-- Good plan (<1ms)
-> Limit
  -> Merge Append
    -> Index Scan on tbl WHERE gid=9 (already sorted)
    -> Index Scan on tbl WHERE gid=10 (already sorted)
```

**Requirements for Merge Append**:
1. Each UNION ALL branch has same ORDER BY
2. Indexes exist for ORDER BY in each branch
3. No WHERE clause spanning multiple branches

**Index Strategy**:
```sql
CREATE INDEX idx_tbl_gid_crt_time 
ON tbl (gid, crt_time)
INCLUDE (other_columns);
-- Allows index-only scan per partition
```

**Performance Gain**: 100-1000x for queries with:
- High cardinality GROUP BY before ORDER BY
- Data naturally partitioned (tenant_id, category_id)
- Need "top N per group" pattern

**PostgreSQL 13+ Improvement**: Better Merge Append cost estimation

**Limitation**: Must manually rewrite query (optimizer won't do this automatically)

### 3. **OR Conditions Break Index Usage**

**Problem**: OR predicates with ORDER BY prevent index usage.

```sql
-- Extremely slow (516ms for 100 rows)
SELECT * FROM entities
WHERE effective_on > '2024-06-11' 
   OR (effective_on = '2024-06-11' AND id > 1459)
ORDER BY effective_on, id
LIMIT 100;
-- Query plan: Index Scan, Rows Removed by Filter: 797,708
```

**Why It Fails**:
- Index scan on `effective_on` walks millions of rows
- OR forces filter to check second condition on every row
- Cannot use index for range + equality simultaneously

**Solution A**: Rewrite as UNION
```sql
SELECT * FROM (
    SELECT * FROM entities
    WHERE effective_on > '2024-06-11'
    ORDER BY effective_on, id
    LIMIT 100
) UNION ALL (
    SELECT * FROM entities
    WHERE effective_on = '2024-06-11' AND id > 1459
    ORDER BY effective_on, id
    LIMIT 100
)
ORDER BY effective_on, id
LIMIT 100;
-- 2.6ms (200x faster)
```

**Solution B**: Row Constructor Comparison (PostgreSQL-specific)
```sql
-- Elegant and fast
SELECT * FROM entities
WHERE (effective_on, id) > ('2024-06-11', 1459)
ORDER BY effective_on, id
LIMIT 100;
-- Lexicographical comparison, single index scan
```

**Index Required**:
```sql
CREATE INDEX idx_entities_effective_id 
ON entities (effective_on, id);
```

**Row Constructor Advantages**:
- Single index scan path
- Handles tie-breaking naturally
- Perfect for keyset pagination
- PostgreSQL and MySQL support (syntax differs)

**Caution**: Row constructors don't work across JOINs in same way

### 4. **Query Planner Confusion with LIMIT**

**Classic Trap**: Adding LIMIT can make query slower.

```sql
-- Fast (48ms, returns all 1020 rows)
SELECT * FROM table
WHERE field2 = value
ORDER BY field3 DESC;
-- Uses index on field2

-- Slow (5572ms, returns 1 row)
SELECT * FROM table
WHERE field2 = value
ORDER BY field3 DESC
LIMIT 1;
-- Switches to index on field3, filters 797,708 rows
```

**Why This Happens**:
- Planner assumes: "With LIMIT 1, finding first match in ORDER BY index is fast"
- Reality: First matching row in field3 index requires scanning millions
- Cost model underestimates filter selectivity

**Solution**: Add tie-breaker to ORDER BY
```sql
-- Forces better plan choice
SELECT * FROM table
WHERE field2 = value
ORDER BY field3 DESC, field1  -- Added field1
LIMIT 1;
-- 3.9ms (using correct index)
```

**Alternative**: Explicit index hints (PostgreSQL doesn't support, but can disable)
```sql
SET enable_indexscan = off;  -- Force Seq Scan
SET enable_bitmapscan = on;  -- Allow Bitmap Scan
```

**Long-term Fix**: Update statistics
```sql
ALTER TABLE table ALTER COLUMN field2 SET STATISTICS 1000;
ALTER TABLE table ALTER COLUMN field3 SET STATISTICS 1000;
ANALYZE table;
```

**PostgreSQL 15+ Improvement**: Better cost estimation for filtered index scans

### 5. **Connection Pool Saturation**
Slow ORDER BY queries hold connections longer, starving the pool:
```sql
-- Monitor connection wait times
SELECT COUNT(*) as waiting_connections,
       wait_event_type, wait_event
FROM pg_stat_activity
WHERE state = 'active'
GROUP BY wait_event_type, wait_event;
```

**Solution**: Statement timeout + connection timeout
```sql
ALTER DATABASE mydb SET statement_timeout = '30s';
ALTER DATABASE mydb SET idle_in_transaction_session_timeout = '60s';
```

### 2. **Lock Contention from Sorting**
Large sorts acquire temporary AccessShareLock, blocking DDL:
```sql
-- Detect blocked queries
SELECT blocked_locks.pid AS blocked_pid,
       blocking_locks.pid AS blocking_pid,
       blocked_activity.query AS blocked_statement
FROM pg_locks blocked_locks
JOIN pg_stat_activity blocked_activity ON blocked_activity.pid = blocked_locks.pid
JOIN pg_locks blocking_locks ON blocking_locks.locktype = blocked_locks.locktype
WHERE NOT blocked_locks.granted;
```

### 3. **Autovacuum Impact**
Index bloat degrades ORDER BY performance:
```sql
-- Force aggressive autovacuum on hot tables
ALTER TABLE products SET (
    autovacuum_vacuum_scale_factor = 0.01,
    autovacuum_analyze_scale_factor = 0.005
);
```

### 4. **Query Result Caching**
Application-level caching for sorted results:
- Redis sorted sets for leaderboards
- HTTP cache headers for paginated APIs
- Precalculated "top N" tables

### 5. **Read Replicas Strategy**
Offload ORDER BY queries to read replicas:
- Route analytical queries to dedicated replica
- Use streaming replication lag monitoring
- Implement stale-read tolerance in application

### 6. **Statistics Collection**
```sql
-- Increase statistics target for sort columns
ALTER TABLE products ALTER COLUMN created_at SET STATISTICS 1000;
ANALYZE products;
```

### 7. **Prepared Statements**
```sql
-- Prepared statements enable plan caching
PREPARE get_recent_products (int) AS
SELECT * FROM products
ORDER BY created_at DESC
LIMIT $1;

EXECUTE get_recent_products(20);
```

### 8. **PostgreSQL 15 Sort Performance Improvements**

PostgreSQL 15 introduced multiple sort optimizations that directly benefit ORDER BY + LIMIT:

**A. Single-Column Sort Optimization**
- Stores only Datum (not full tuple) for single-column sorts
- 26% faster for `ORDER BY single_column`
- Benefits: Merge Semi/Anti Joins, EXISTS/NOT EXISTS queries

**B. Sort Specialization for Common Types**
- Specialized comparison functions for int, bigint, text, timestamp
- 4-6% improvement for in-memory sorts
- Reduces constant factors in comparison operations

**C. K-Way Merge for Large Sorts**
- Improved merge algorithm when sort exceeds work_mem
- Up to 43% faster for large sorts with small work_mem
- Better tape merging efficiency

**D. Generation Memory Context**
- Reduces memory overhead during sort operations
- NOT used for bounded sorts (ORDER BY + LIMIT)
- Benefits unbounded sorts significantly

**Implications for Your Workload**:
```sql
-- Single column sorts (PG15+ optimization)
SELECT product_id FROM products
ORDER BY created_at DESC
LIMIT 1000;
-- 26% faster in PG15+

-- Multi-column sorts (less improvement)
SELECT * FROM products
ORDER BY category_id, created_at DESC
LIMIT 1000;
-- 4-6% improvement from sort specialization
```

**Version-Specific Recommendation**:
- PostgreSQL 13-14: Focus on index optimization
- PostgreSQL 15+: Still need indexes, but sort performance ceiling is higher
- PostgreSQL 16+: Parallel window functions + incremental sort improvements

---

## Decision Matrix

| Scenario | Recommended Solution | Implementation Effort | Performance Gain |
|----------|---------------------|----------------------|------------------|
| Simple ORDER BY + LIMIT | Covering index with INCLUDE | Low | 10-100x |
| Filtered ORDER BY | Composite index (filter, sort, INCLUDE) | Low | 50-500x |
| Deep pagination | Keyset pagination | Medium | 100-1000x |
| GROUP BY + ORDER BY | Materialized view | Medium-High | 10-100x |
| Real-time aggregations | Partial indexes + incremental updates | High | 5-50x |
| Multi-tenant with ORDER BY | Composite index with tenant_id first | Low | 20-200x |

---

## Emergency Response Checklist

When ORDER BY queries cause production incident:

1. ☐ **Identify**: Run pg_stat_statements query to find culprit
2. ☐ **Isolate**: Set statement_timeout to prevent cascading failure
3. ☐ **Mitigate**: Add covering index with CREATE INDEX CONCURRENTLY
4. ☐ **Monitor**: Watch index build progress via pg_stat_progress_create_index
5. ☐ **Verify**: Run EXPLAIN on affected query to confirm index usage
6. ☐ **Document**: Add index rationale to schema documentation

---

## Long-Term Optimization Roadmap

**Phase 1: Discovery (Week 1-2)**
- Enable pg_stat_statements
- Log slow queries > 100ms
- Identify top 20 slow ORDER BY patterns

**Phase 2: Quick Wins (Week 3-4)**
- Add covering indexes for most frequent patterns
- Implement keyset pagination for deep paginated endpoints
- Tune work_mem for analytical queries

**Phase 3: Structural Changes (Month 2)**
- Migrate to materialized views for complex aggregations
- Implement partition pruning for time-series tables
- Deploy read replicas for ORDER BY-heavy workloads

**Phase 4: Application Layer (Month 3+)**
- Redis caching for frequently sorted datasets
- Precompute "top N" for dashboards
- GraphQL DataLoader for batched sorted queries

---

## Conclusion

ORDER BY + LIMIT performance is not about the SQL syntax—it's about giving PostgreSQL the right data structures to answer the question efficiently. In read-heavy workloads with aggregations, the cumulative effect of slow sorts can degrade entire system performance.

The difference between P50 = 5ms and P50 = 500ms is usually one well-designed index. The difference between P99 = 100ms and P99 = 30s is understanding when to materialize, when to paginate differently, and when to cache.

*** Predicting which patterns will fail at scale before they reach production.
