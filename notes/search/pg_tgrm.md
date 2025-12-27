# PostgreSQL LIKE Query Optimization with pg_trgm - Platform DBRE Guide

## Executive Summary

**Problem:** Wildcard LIKE queries (`%pattern%`) cause sequential scans that degrade as data grows  
**Solution:** pg_trgm extension with GIN/GiST trigram indexes  
**Performance Gain:** Seconds to milliseconds on multi-million row tables  
**Trade-off:** 2-4x larger indexes, slower writes, higher maintenance cost  
**When to Use:** Unanchored wildcard searches on read-heavy workloads

---

## Problem Statement

### The Silent Performance Killer

**Typical Scenario:**
```sql
-- Looks innocent in development
SELECT * FROM users WHERE email LIKE '%gmail.com%';

-- Development: 100 rows, 5ms
-- Staging: 10K rows, 50ms  
-- Production: 5M rows, 8 seconds
```

**Why It Hurts:**
- No alerts fire (query is "correct")
- Shows up in slow query logs weeks later
- CPU spikes during peak hours
- Support teams complain about slowness
- Default solution: "Add more servers"

**Root Cause:** B-tree indexes cannot help with leading wildcard patterns

---

## How PostgreSQL Executes LIKE Queries

### B-tree Index Limitations

```
B-tree Index Structure (Ordered):
--------------------------------
aaron@gmail.com
alice@yahoo.com
bob@hotmail.com
charlie@gmail.com
david@outlook.com
...
```

**Prefix Search (Works):**
```sql
WHERE email LIKE 'alice%'
                  ↓
         Can use B-tree index
         Finds start: 'alice'
         Scans until: 'alicf'
         ✓ Fast
```

**Suffix/Contains Search (Fails):**
```sql
WHERE email LIKE '%gmail.com%'
                  ↓
         Cannot determine start point
         Must scan entire table
         ✗ Sequential scan on millions of rows
```

### Execution Flow Comparison

```
Query: SELECT * FROM users WHERE email LIKE '%gmail%'

┌────────────────────────────────────────────────┐
│          Without Trigram Index                 │
└────────────────────────────────────────────────┘
                    ↓
         Sequential Scan on users
                    ↓
    ┌───────────────────────────────────┐
    │ For EACH row (5M rows):           │
    │   1. Read row from disk           │
    │   2. Check email contains 'gmail' │
    │   3. Add to result if match       │
    └───────────────────────────────────┘
                    ↓
         Result (after scanning 5M rows)
         Time: 8 seconds
         Buffers: 45000 shared blocks


┌────────────────────────────────────────────────┐
│           With Trigram Index                   │
└────────────────────────────────────────────────┘
                    ↓
    Bitmap Index Scan using idx_email_trgm
                    ↓
    ┌───────────────────────────────────┐
    │ 1. Break 'gmail' into trigrams:   │
    │    ' gm', 'gma', 'mai', 'ail'     │
    │ 2. Look up trigrams in index      │
    │ 3. Get bitmap of matching rows    │
    │ 4. Fetch only matching rows       │
    └───────────────────────────────────┘
                    ↓
         Result (scanned ~5000 rows)
         Time: 15 milliseconds
         Buffers: 120 shared blocks
```

---

## pg_trgm Fundamentals

### How Trigrams Work

**Concept:** Break text into overlapping 3-character fragments

**Example:**
```
String: "postgres"

Trigrams generated:
'  p'  (space-space-p)
' po'  (space-p-o)
'pos'
'ost'
'stg'
'tgr'
'gre'
'res'
'es '  (e-s-space)
```

**Similarity Calculation:**
```sql
SELECT similarity('postgres', 'postgre');
-- Returns: 0.777778 (7 common trigrams / 9 total)

SELECT 'postgres' % 'postgre';  -- % is similarity operator
-- Returns: true (similarity > threshold)
```

### Index Types: GIN vs GiST

| Feature | GIN (Generalized Inverted Index) | GiST (Generalized Search Tree) |
|---------|----------------------------------|--------------------------------|
| **Query Speed** | Faster lookups | Slower lookups |
| **Index Size** | Larger (2-4x B-tree) | Smaller (1-2x B-tree) |
| **Build Time** | Slower initial build | Faster build |
| **Write Performance** | Slower inserts/updates | Faster writes |
| **Maintenance** | Higher WAL generation | Lower WAL |
| **Best For** | Read-heavy workloads | Write-heavy workloads |

**Rule of Thumb:** Use GIN unless you have write-heavy workload or disk constraints

---

## Diagnostic Analysis: Can Your Database Benefit?

### Step 1: Identify Problematic LIKE Queries

**Find slow LIKE queries in pg_stat_statements:**
```sql
-- Enable pg_stat_statements if not already enabled
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

-- Find expensive LIKE queries
SELECT 
    substring(query, 1, 100) AS query_snippet,
    calls,
    mean_exec_time,
    total_exec_time,
    (total_exec_time / 1000 / 60) AS total_minutes,
    stddev_exec_time,
    min_exec_time,
    max_exec_time,
    shared_blks_hit + shared_blks_read AS total_buffers
FROM pg_stat_statements
WHERE query ~* 'LIKE.*%.*%'  -- Contains LIKE with wildcards
  AND calls > 10
ORDER BY mean_exec_time DESC
LIMIT 20;
```

**Analyze execution plans:**
```sql
-- Check if queries are doing sequential scans
SELECT 
    substring(query, 1, 100) AS query_snippet,
    calls,
    mean_exec_time
FROM pg_stat_statements
WHERE query ~* 'LIKE.*%.*%'
  AND query ~* 'Seq Scan'  -- Indicates no index usage
ORDER BY calls * mean_exec_time DESC
LIMIT 10;
```

### Step 2: Identify Candidate Tables

**Find tables with LIKE queries and no trigram indexes:**
```sql
WITH like_queries AS (
    SELECT 
        substring(query FROM 'FROM\s+(\w+)') AS table_name,
        COUNT(*) AS query_count,
        SUM(calls) AS total_calls,
        AVG(mean_exec_time) AS avg_exec_time
    FROM pg_stat_statements
    WHERE query ~* 'LIKE.*%.*%'
    GROUP BY substring(query FROM 'FROM\s+(\w+)')
),
existing_trgm_indexes AS (
    SELECT 
        schemaname,
        tablename,
        indexname
    FROM pg_indexes
    WHERE indexdef ~* 'gin_trgm_ops|gist_trgm_ops'
)
SELECT 
    lq.table_name,
    lq.query_count,
    lq.total_calls,
    ROUND(lq.avg_exec_time::numeric, 2) AS avg_exec_time_ms,
    CASE WHEN eti.tablename IS NULL 
         THEN 'No trigram index' 
         ELSE 'Has trigram index' 
    END AS index_status,
    pg_size_pretty(pg_total_relation_size(lq.table_name::regclass)) AS table_size
FROM like_queries lq
LEFT JOIN existing_trgm_indexes eti ON lq.table_name = eti.tablename
ORDER BY lq.total_calls * lq.avg_exec_time DESC;
```

### Step 3: Analyze Query Patterns

**Identify wildcard pattern types:**
```sql
SELECT 
    CASE 
        WHEN query ~* 'LIKE\s+''%[^%]+%''' THEN 'Contains (%pattern%)'
        WHEN query ~* 'LIKE\s+''%[^%]+''' THEN 'Suffix (%pattern)'
        WHEN query ~* 'LIKE\s+''[^%]+%''' THEN 'Prefix (pattern%)'
        WHEN query ~* 'ILIKE' THEN 'Case-insensitive'
        ELSE 'Other'
    END AS pattern_type,
    COUNT(*) AS query_count,
    SUM(calls) AS total_calls,
    AVG(mean_exec_time) AS avg_exec_time_ms,
    SUM(total_exec_time) AS total_time_minutes
FROM pg_stat_statements
WHERE query ~* 'LIKE|ILIKE'
GROUP BY pattern_type
ORDER BY total_calls DESC;
```

**Expected Results:**
```
 pattern_type           | query_count | total_calls | avg_exec_time_ms | total_time_minutes 
------------------------+-------------+-------------+------------------+--------------------
 Contains (%pattern%)   |          45 |       89234 |           324.50 |            482.15
 Case-insensitive       |          23 |       45678 |           198.25 |            150.89
 Prefix (pattern%)      |          12 |       12345 |             2.45 |              0.50
```

**Action:** Focus on "Contains" and "Case-insensitive" patterns

### Step 4: Identify Specific Columns

**Find columns frequently used in LIKE queries:**
```sql
SELECT 
    substring(query FROM 'WHERE\s+(\w+)\s+[I]?LIKE') AS column_name,
    COUNT(*) AS query_count,
    SUM(calls) AS total_calls,
    AVG(mean_exec_time) AS avg_exec_time_ms,
    MAX(max_exec_time) AS max_exec_time_ms
FROM pg_stat_statements
WHERE query ~* 'WHERE\s+\w+\s+[I]?LIKE.*%.*%'
GROUP BY column_name
HAVING COUNT(*) > 5
ORDER BY SUM(calls) * AVG(mean_exec_time) DESC
LIMIT 20;
```

**Expected Output:**
```
 column_name | query_count | total_calls | avg_exec_time_ms | max_exec_time_ms
-------------+-------------+-------------+------------------+------------------
 email       |          23 |       45678 |           324.50 |          8234.12
 full_name   |          15 |       23456 |           256.30 |          5678.45
 address     |          12 |       12345 |           189.20 |          3456.78
 description |           8 |        8901 |           145.60 |          2345.67
```

### Step 5: Estimate Index Size

**Calculate expected trigram index size:**
```sql
SELECT 
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS table_size,
    pg_size_pretty(pg_indexes_size(schemaname||'.'||tablename)) AS current_indexes_size,
    -- Estimate trigram index: 3-4x the text column size
    pg_size_pretty(
        (SELECT SUM(pg_column_size(email)) FROM users) * 4
    ) AS estimated_trgm_index_size
FROM pg_tables
WHERE tablename = 'users';
```

### Step 6: Benchmark Current Performance

**Establish baseline before creating index:**
```sql
-- Clear caches for accurate measurement
SELECT pg_prewarm('users');

-- Benchmark query
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, COSTS)
SELECT * FROM users WHERE email LIKE '%gmail%';

-- Record baseline metrics:
-- Planning Time: X ms
-- Execution Time: Y ms
-- Shared Buffers Hit: Z blocks
-- Shared Buffers Read: W blocks
```

### Step 7: Decision Matrix

**Should you add a trigram index?**

| Criteria | Threshold | Your Value | Decision |
|----------|-----------|------------|----------|
| Query calls/day | > 1000 | _____ | ✓ / ✗ |
| Avg exec time | > 100ms | _____ ms | ✓ / ✗ |
| Table size | > 100K rows | _____ rows | ✓ / ✗ |
| Pattern type | Contains/Suffix | _____ | ✓ / ✗ |
| Read/Write ratio | > 10:1 | _____ | ✓ / ✗ |
| Available disk | Index size * 1.5 | _____ GB free | ✓ / ✗ |
| Write throughput | < 1000/sec | _____ writes/sec | ✓ / ✗ |

**Decision Rule:**
- **5+ ✓ marks:** Strong candidate for trigram index
- **3-4 ✓ marks:** Consider based on pain points
- **< 3 ✓ marks:** Probably not worth the overhead

---

## Implementation Guide

### Step 1: Enable Extension

```sql
-- One-time per database
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- Verify installation
SELECT * FROM pg_available_extensions WHERE name = 'pg_trgm';
```

### Step 2: Create Trigram Index

**Basic GIN index:**
```sql
CREATE INDEX CONCURRENTLY idx_users_email_trgm
ON users
USING gin (email gin_trgm_ops);
```

**Case-insensitive index:**
```sql
CREATE INDEX CONCURRENTLY idx_users_email_lower_trgm
ON users
USING gin (LOWER(email) gin_trgm_ops);
```

**Multi-column search index:**
```sql
CREATE INDEX CONCURRENTLY idx_users_search_trgm
ON users
USING gin (
    (name || ' ' || email || ' ' || phone) gin_trgm_ops
);
```

**GiST index (for write-heavy workloads):**
```sql
CREATE INDEX CONCURRENTLY idx_users_email_gist_trgm
ON users
USING gist (email gist_trgm_ops);
```

**Index with WHERE clause (partial index):**
```sql
-- Only index active users
CREATE INDEX CONCURRENTLY idx_active_users_email_trgm
ON users
USING gin (email gin_trgm_ops)
WHERE status = 'active';
```

### Step 3: Verify Index Usage

```sql
-- Test query with EXPLAIN
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT * FROM users WHERE email LIKE '%gmail%';

-- Look for:
-- - "Bitmap Index Scan using idx_users_email_trgm"
-- - Dramatically reduced buffer reads
-- - Faster execution time
```

**Before Index:**
```
Seq Scan on users  (cost=0.00..125000.00 rows=5000 width=200) 
                   (actual time=0.050..8234.567 rows=5000 loops=1)
  Filter: (email ~~ '%gmail%'::text)
  Rows Removed by Filter: 4995000
Planning Time: 0.123 ms
Execution Time: 8234.890 ms
Buffers: shared hit=45000
```

**After Index:**
```
Bitmap Heap Scan on users  (cost=48.50..2845.67 rows=5000 width=200)
                           (actual time=2.345..14.567 rows=5000 loops=1)
  Recheck Cond: (email ~~ '%gmail%'::text)
  Heap Blocks: exact=1234
  ->  Bitmap Index Scan on idx_users_email_trgm  (cost=0.00..47.25 rows=5000)
        Index Cond: (email ~~ '%gmail%'::text)
Planning Time: 0.234 ms
Execution Time: 14.890 ms
Buffers: shared hit=1250
```

**Performance Improvement: 553x faster (8234ms → 15ms)**

---

## Common Use Cases and Solutions

### 1. Email Search in Admin Panels

**Problem:**
```sql
SELECT * FROM users WHERE email LIKE '%@gmail.com%';
-- Sequential scan on 5M users
```

**Solution:**
```sql
CREATE INDEX CONCURRENTLY idx_users_email_trgm
ON users USING gin (email gin_trgm_ops);

-- Query now uses index
SELECT * FROM users WHERE email LIKE '%@gmail.com%';
```

**Result:** 8s → 15ms

### 2. Case-Insensitive Search

**Problem:**
```sql
SELECT * FROM users WHERE email ILIKE '%GMAIL%';
-- ILIKE forces case conversion, prevents index usage
```

**Solution:**
```sql
-- Create index on LOWER()
CREATE INDEX CONCURRENTLY idx_users_email_lower_trgm
ON users USING gin (LOWER(email) gin_trgm_ops);

-- Rewrite query to use LOWER()
SELECT * FROM users WHERE LOWER(email) LIKE '%gmail%';
```

**Important:** Query must match index expression exactly

### 3. Customer Name Search (CRM)

**Problem:**
```sql
SELECT id, full_name FROM customers 
WHERE full_name LIKE '%alex%';
-- Works at 50K rows, slow at 500K, fails at millions
```

**Solution:**
```sql
CREATE INDEX CONCURRENTLY idx_customers_name_trgm
ON customers USING gin (full_name gin_trgm_ops);
```

**Result:** Consistent performance regardless of table size

### 4. Multi-Field Search (Support Dashboards)

**Problem:**
```sql
SELECT * FROM users 
WHERE name LIKE '%john%' 
   OR email LIKE '%john%' 
   OR phone LIKE '%john%';
-- Three separate scans or sequential scan
```

**Solution:**
```sql
-- Concatenated column index
CREATE INDEX CONCURRENTLY idx_users_search_trgm
ON users USING gin (
    (name || ' ' || email || ' ' || phone) gin_trgm_ops
);

-- Single query
SELECT * FROM users 
WHERE (name || ' ' || email || ' ' || phone) LIKE '%john%';
```

**Result:** One index scan instead of three, much faster

### 5. Product Search (E-commerce)

**Problem:**
```sql
SELECT id, name, price FROM products 
WHERE name LIKE '%wireless%';
-- Sluggish UI, poor UX
```

**Solution:**
```sql
CREATE INDEX CONCURRENTLY idx_products_name_trgm
ON products USING gin (name gin_trgm_ops);
```

**Result:** Instant search, happy users

### 6. Fuzzy Matching for Typos

**Problem:** Users type "wirless hedphones" instead of "wireless headphones"

**Solution:**
```sql
-- Using similarity operator (%)
SELECT 
    name, 
    similarity(name, 'wirless hedphones') AS score
FROM products
WHERE name % 'wirless hedphones'  -- % is similarity operator
ORDER BY score DESC
LIMIT 10;

-- Or using similarity threshold
SET pg_trgm.similarity_threshold = 0.3;

SELECT name FROM products 
WHERE name % 'wirless hedphones';
```

**Result:** Forgiving search that finds "wireless headphones"

### 7. Address Search (Logistics)

**Problem:**
```sql
SELECT * FROM shipments 
WHERE destination_address LIKE '%jakarta%';
-- Large dataset, frequent searches
```

**Solution:**
```sql
CREATE INDEX CONCURRENTLY idx_shipments_address_trgm
ON shipments USING gin (destination_address gin_trgm_ops);
```

**Result:** One of biggest single wins from pg_trgm

### 8. Log Search Without External Tools

**Problem:**
```sql
SELECT * FROM application_logs 
WHERE message LIKE '%connection timeout%'
  AND created_at > now() - interval '1 day';
```

**Solution:**
```sql
CREATE INDEX CONCURRENTLY idx_logs_message_trgm
ON application_logs USING gin (message gin_trgm_ops);

-- Composite index for time + search
CREATE INDEX CONCURRENTLY idx_logs_time_message_trgm
ON application_logs (created_at, message gin_trgm_ops);
```

**Result:** Effective for recent log searches, avoids ELK stack for simple cases

### 9. When NOT to Use Trigram Indexes

**Prefix searches (B-tree works perfectly):**
```sql
-- B-tree index is optimal
SELECT * FROM users WHERE username LIKE 'alex%';

-- Don't create trigram index for this
CREATE INDEX idx_users_username_btree ON users(username);
```

**Exact matches:**
```sql
-- B-tree index is optimal
SELECT * FROM users WHERE email = 'alex@example.com';
```

**Very short strings (< 3 characters):**
```sql
-- Trigrams don't help much
SELECT * FROM codes WHERE code LIKE '%AB%';
```

**Write-heavy tables:**
- If inserts/updates > 1000/sec, trigram overhead may hurt
- Consider GiST instead of GIN, or skip trigrams entirely

---

## Trade-offs and Considerations

### Index Size Overhead

**Typical Size Increase:**
```sql
-- Check current table and index sizes
SELECT 
    schemaname,
    tablename,
    pg_size_pretty(pg_table_size(schemaname||'.'||tablename)) AS table_size,
    pg_size_pretty(pg_indexes_size(schemaname||'.'||tablename)) AS indexes_size,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS total_size
FROM pg_tables
WHERE tablename = 'users';
```

**Expected Results:**
```
 tablename | table_size | indexes_size | total_size
-----------+------------+--------------+------------
 users     | 1200 MB    | 450 MB       | 1650 MB    (Before trigram index)
 users     | 1200 MB    | 1850 MB      | 3050 MB    (After trigram index)
```

**Trigram index added ~1400 MB (3x the B-tree indexes)**

### Write Performance Impact

**Measure write performance:**
```sql
-- Benchmark INSERT performance
EXPLAIN (ANALYZE, BUFFERS)
INSERT INTO users (name, email, created_at)
VALUES ('Test User', 'test@example.com', now());

-- Before trigram index:
-- Execution Time: 0.5 ms

-- After trigram index:
-- Execution Time: 1.2 ms (2.4x slower)
```

**Mitigation strategies:**
- Use `CREATE INDEX CONCURRENTLY` to avoid blocking
- Schedule index maintenance during low-traffic periods
- Consider GiST instead of GIN for write-heavy workloads
- Use partial indexes (WHERE clause) to reduce index size

### WAL Generation

**Monitor WAL volume:**
```sql
SELECT 
    pg_size_pretty(
        pg_wal_lsn_diff(pg_current_wal_lsn(), '0/0')
    ) AS wal_since_start;

-- Check WAL growth rate
SELECT 
    slot_name,
    pg_size_pretty(
        pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)
    ) AS wal_retained
FROM pg_replication_slots;
```

**GIN indexes generate more WAL than B-tree**
- Impacts replication lag
- Increases archive storage needs
- Consider this for high-write tables

### Maintenance Requirements

**Regular maintenance:**
```sql
-- Analyze table after major changes
ANALYZE users;

-- Reindex if performance degrades (rare)
REINDEX INDEX CONCURRENTLY idx_users_email_trgm;

-- Vacuum to reclaim space
VACUUM ANALYZE users;
```

**Monitoring index bloat:**
```sql
SELECT 
    schemaname,
    tablename,
    indexname,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    idx_scan AS index_scans,
    idx_tup_read AS tuples_read,
    idx_tup_fetch AS tuples_fetched
FROM pg_stat_user_indexes
WHERE indexname LIKE '%_trgm'
ORDER BY pg_relation_size(indexrelid) DESC;
```

---

## Monitoring and Maintenance

### Performance Monitoring Queries

**Track index usage:**
```sql
SELECT 
    schemaname,
    tablename,
    indexname,
    idx_scan AS times_used,
    idx_tup_read AS rows_read,
    idx_tup_fetch AS rows_fetched,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pg_stat_user_indexes
WHERE indexname LIKE '%_trgm'
ORDER BY idx_scan DESC;
```

**Identify unused indexes:**
```sql
SELECT 
    schemaname,
    tablename,
    indexname,
    idx_scan,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
    idx_tup_read,
    idx_tup_fetch
FROM pg_stat_user_indexes
WHERE indexname LIKE '%_trgm'
  AND idx_scan < 10  -- Used less than 10 times
  AND pg_relation_size(indexrelid) > 10485760  -- Larger than 10MB
ORDER BY pg_relation_size(indexrelid) DESC;
```

**Query performance tracking:**
```sql
-- Compare query performance before/after index
SELECT 
    substring(query, 1, 100) AS query_snippet,
    calls,
    mean_exec_time,
    min_exec_time,
    max_exec_time,
    stddev_exec_time
FROM pg_stat_statements
WHERE query ~* 'email.*LIKE.*gmail'
ORDER BY calls DESC;
```

### Health Checks

**Index validity:**
```sql
SELECT 
    schemaname,
    tablename,
    indexname,
    indexdef
FROM pg_indexes
WHERE indexname LIKE '%_trgm'
  AND indexdef IS NOT NULL;
```

**Bloat detection:**
```sql
-- Estimate index bloat
SELECT 
    schemaname,
    tablename,
    indexname,
    pg_size_pretty(pg_relation_size(indexrelid)) AS actual_size,
    pg_size_pretty(
        (pg_relation_size(indexrelid)::numeric / 
         NULLIF(idx_tup_read, 0)) * idx_scan
    ) AS estimated_optimal_size
FROM pg_stat_user_indexes
WHERE indexname LIKE '%_trgm';
```

---

## Troubleshooting Guide

### Issue 1: Index Not Being Used

**Symptoms:**
```sql
EXPLAIN SELECT * FROM users WHERE email LIKE '%gmail%';
-- Still shows "Seq Scan"
```

**Diagnosis:**
```sql
-- Check if index exists
SELECT * FROM pg_indexes WHERE indexname = 'idx_users_email_trgm';

-- Check if pg_trgm is enabled
SELECT * FROM pg_extension WHERE extname = 'pg_trgm';

-- Force index usage to test
SET enable_seqscan = off;
EXPLAIN SELECT * FROM users WHERE email LIKE '%gmail%';
SET enable_seqscan = on;
```

**Solutions:**
1. Run `ANALYZE users;` to update statistics
2. Check if query matches index expression exactly
3. Verify pattern has wildcards (`%`)
4. Ensure sufficient `random_page_cost` setting

### Issue 2: Slow Index Creation

**Symptoms:**
```sql
CREATE INDEX CONCURRENTLY idx_users_email_trgm...
-- Runs for hours on large table
```

**Solutions:**
```sql
-- Increase maintenance_work_mem for faster build
SET maintenance_work_mem = '2GB';

-- Create index during low-traffic period
-- Monitor progress:
SELECT 
    pid,
    now() - pg_stat_activity.query_start AS duration,
    query,
    state
FROM pg_stat_activity
WHERE query ~* 'CREATE INDEX';

-- Check locks:
SELECT * FROM pg_locks WHERE granted = false;
```

### Issue 3: Write Performance Degradation

**Symptoms:**
- INSERT/UPDATE becomes noticeably slower
- Increased WAL generation
- Replication lag increases

**Diagnosis:**
```sql
-- Measure INSERT performance
EXPLAIN (ANALYZE, BUFFERS) 
INSERT INTO users (name, email) 
VALUES ('Test', 'test@example.com');

-- Check index size
SELECT pg_size_pretty(pg_relation_size('idx_users_email_trgm'));
```

**Solutions:**
1. Consider GiST instead of GIN for better write performance
2. Use partial index with WHERE clause
3. Batch inserts instead of individual INSERTs
4. Schedule REINDEX during maintenance windows

### Issue 4: Query Still Slow with Index

**Symptoms:**
- Index is used but query is still slow
- Bitmap Heap Scan takes long time

**Diagnosis:**
```sql
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT * FROM users WHERE email LIKE '%a%';
-- Returns too many rows (1M+ matches)
```

**Solutions:**
1. Pattern is too generic (single character)
2. Add additional filters:
```sql
SELECT * FROM users 
WHERE email LIKE '%a%' 
  AND created_at > '2024-01-01'
  AND status = 'active';
```
3. Implement pagination:
```sql
SELECT * FROM users 
WHERE email LIKE '%gmail%'
ORDER BY id
LIMIT 100 OFFSET 0;
```

---

## Production Best Practices

### 1. Always Use CONCURRENTLY

```sql
-- Good: Non-blocking index creation
CREATE INDEX CONCURRENTLY idx_users_email_trgm
ON users USING gin (email gin_trgm_ops);

-- Bad: Locks table during creation
CREATE INDEX idx_users_email_trgm
ON users USING gin (email gin_trgm_ops);
```

**Why:** `CONCURRENTLY` allows reads/writes during index creation

### 2. Test in Non-Production First

```bash
# Create production-like dataset in staging
pg_dump --data-only --table=users production_db | \
    psql staging_db

# Test index creation time
\timing on
CREATE INDEX CONCURRENTLY idx_users_email_trgm
ON users USING gin (email gin_trgm_ops);

# Benchmark queries before/after
EXPLAIN (ANALYZE) SELECT * FROM users WHERE email LIKE '%gmail%';
```

### 3. Monitor Index Usage After Deployment

```sql
-- Set up monitoring query (run daily)
SELECT 
    current_date AS check_date,
    indexname,
    idx_scan AS scans_today,
    idx_tup_read AS tuples_read,
    idx_tup_fetch AS tuples_fetched,
    pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE indexname = 'idx_users_email_trgm';
```

### 4. Set Appropriate Similarity Threshold

```sql
-- Default threshold: 0.3
SHOW pg_trgm.similarity_threshold;

-- Adjust per session or globally
SET pg_trgm.similarity_threshold = 0.4;  -- Stricter matching

-- Or in postgresql.conf:
-- pg_trgm.similarity_threshold = 0.4
```

### 5. Use Composite
