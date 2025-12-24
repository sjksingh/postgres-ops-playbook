# PostgreSQL Query Planner - Staff DBRE Deep Dive Runbook

## Table of Contents
1. [Emergency Response: Bad Plans in Production](#emergency-response-bad-plans-in-production)
2. [Understanding Cost Model & Parameters](#understanding-cost-model--parameters)
3. [Access Path Selection](#access-path-selection)
4. [Join Strategy Selection](#join-strategy-selection)
5. [Join Order Optimization](#join-order-optimization)
6. [Troubleshooting Planner Decisions](#troubleshooting-planner-decisions)
7. [Advanced Optimization Techniques](#advanced-optimization-techniques)
8. [Monitoring & Tuning](#monitoring--tuning)

---

## Emergency Response: Bad Plans in Production

### Immediate Triage (< 3 minutes)

When a query is using a suboptimal plan causing performance issues:

```sql
-- 1. Get the current plan QUICKLY (don't wait for ANALYZE if query is slow)
EXPLAIN SELECT ...;

-- 2. Check if it's a planner vs executor issue
EXPLAIN (ANALYZE, BUFFERS, TIMING) SELECT ...;
-- Compare: Planning Time vs Execution Time
-- High Planning Time (>100ms) = planner struggling with complexity
-- High Execution Time = wrong plan chosen

-- 3. Identify the problematic node
-- Look for in EXPLAIN output:
-- ✓ Seq Scan when index should be used
-- ✓ Nested Loop with large outer table
-- ✓ Hash Join spilling to disk (temp_blks_written > 0)
-- ✓ Sort operations on large datasets
-- ✓ Massive row count underestimation
```

### Emergency Plan Override (Use with Caution!)

```sql
-- Session-level plan forcing (doesn't affect other sessions)
BEGIN;

-- SCENARIO 1: Force index usage when planner prefers seq scan
SET LOCAL enable_seqscan = off;
SELECT ...;

-- SCENARIO 2: Prevent nested loop causing cartesian explosion
SET LOCAL enable_nestloop = off;
SELECT ...;

-- SCENARIO 3: Force hash join for large table joins
SET LOCAL enable_mergejoin = off;
SET LOCAL enable_nestloop = off;
-- Now only hash join is available
SELECT ...;

-- SCENARIO 4: Reduce join reordering for complex queries
SET LOCAL join_collapse_limit = 1;   -- Force written join order
SELECT ...;

-- SCENARIO 5: Increase work_mem for hash/sort operations
SET LOCAL work_mem = '256MB';  -- From default 4MB
SELECT ...;

COMMIT;  -- Settings automatically reset
```

### Quick Wins: Common Fixes

```sql
-- FIX 1: Cost parameters mistuned for your hardware
-- Check current values
SHOW seq_page_cost;      -- Default: 1.0
SHOW random_page_cost;   -- Default: 4.0 (spinning disk)
SHOW effective_cache_size;  -- Default: 4GB

-- For SSD storage (session-level test)
SET random_page_cost = 1.1;  -- SSDs have minimal random access penalty
SET effective_cache_size = '32GB';  -- Tell planner how much RAM you have

-- FIX 2: Work memory too low causing disk spills
-- Check for temp file usage
SELECT query, temp_blks_written, temp_blks_read
FROM pg_stat_statements
WHERE temp_blks_written > 0
ORDER BY temp_blks_written DESC
LIMIT 10;

-- Increase for this session
SET work_mem = '256MB';

-- FIX 3: Parallel workers not being used
SHOW max_parallel_workers_per_gather;  -- Default: 2
SHOW parallel_tuple_cost;              -- Default: 0.1

-- Allow more parallel workers
SET max_parallel_workers_per_gather = 4;
SET parallel_tuple_cost = 0.01;  -- Make parallel more attractive
```

### When to Escalate

Escalate to senior DBA if:
- Multiple different queries showing bad plans (systemic issue)
- Cost parameters need permanent changes (requires restart)
- Join order issues with 10+ tables (GEQO territory)
- Planner consistently makes wrong decisions despite good statistics
- Planning time itself is the bottleneck (>5 seconds)

---

## Understanding Cost Model & Parameters

### The Cost Unit System

PostgreSQL measures work in **cost units**, not time. Cost units are dimensionless but represent relative expense:

```
Cost Unit = abstract measure of work
- Reading 1 page sequentially = 1.0 cost unit (seq_page_cost)
- Reading 1 page randomly = 4.0 cost units (random_page_cost on HDD)
- Processing 1 row = 0.01 cost units (cpu_tuple_cost)
- Processing 1 index entry = 0.005 cost units (cpu_index_tuple_cost)
- Executing 1 operator = 0.0025 cost units (cpu_operator_cost)
```

**Key insight**: Execution time correlates with cost, but cost ≠ time.

### Cost Parameters Deep Dive

#### I/O Cost Parameters

```sql
-- View all cost parameters
SELECT name, setting, unit, short_desc
FROM pg_settings
WHERE name LIKE '%cost%' OR name LIKE '%page%'
ORDER BY name;

-- Critical parameters:
```

**seq_page_cost** (default: 1.0)
- Cost to read one 8KB page sequentially from disk
- Baseline for all other costs
- **Tuning**: Leave at 1.0 (everything else is relative to this)

**random_page_cost** (default: 4.0)
- Cost to read one page randomly from disk
- **Why 4.0?** On spinning disks, seek time makes random I/O 4x slower
- **SSD tuning**: Set to 1.1-1.5 (random access nearly as fast as sequential)
- **All-RAM tuning**: Set to 1.0 (no disk involved)

```sql
-- Test your storage speed to determine optimal value
-- Run this on a table larger than RAM
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM large_table ORDER BY random();

-- Check "Buffers: shared read=X"
-- If most reads are from shared buffers (cache), lower random_page_cost
-- If many disk reads, keep default or slightly lower for SSD
```

**How this affects planning**:
```
High random_page_cost (4.0):
  → Planner strongly prefers sequential scans
  → Index scans need very high selectivity to win
  → Bitmap scans more attractive than index scans

Low random_page_cost (1.1):
  → Index scans become much more attractive
  → Planner more willing to use indexes for moderate selectivity
  → Sequential scans only for large % of table
```

**effective_cache_size** (default: 4GB)
- Tells planner how much data might be in OS + PostgreSQL cache
- **Does NOT allocate memory** - purely informational
- **Tuning**: Set to 50-75% of total RAM
  - 64GB RAM → `effective_cache_size = '48GB'`
  - 256GB RAM → `effective_cache_size = '192GB'`

```sql
-- Impact on planning:
-- High effective_cache_size tells planner:
-- "Random reads are likely cached, so index scans are cheaper than you think"
-- This makes index scans more attractive
```

#### CPU Cost Parameters

**cpu_tuple_cost** (default: 0.01)
- Cost to process one row in memory
- Includes: fetching, evaluation, passing to next node

**cpu_index_tuple_cost** (default: 0.005)
- Cost to process one index entry
- Half of tuple cost because index entries are smaller

**cpu_operator_cost** (default: 0.0025)
- Cost per operator/function evaluation
- Applies to: WHERE filters, JOIN conditions, computed columns

```sql
-- Example cost calculation for a simple query:
-- SELECT * FROM table WHERE col1 = 5 AND col2 > 10;
-- 
-- Sequential Scan costs:
-- - Page reads: 1000 pages × 1.0 = 1000.0
-- - Process rows: 100,000 rows × 0.01 = 1000.0
-- - Filter evaluation: 100,000 rows × (2 operators × 0.0025) = 500.0
-- Total: 2500.0
--
-- Index Scan costs:
-- - Index pages: 50 pages × 4.0 = 200.0 (random access)
-- - Process index entries: 1,000 entries × 0.005 = 5.0
-- - Heap fetches: 1,000 rows × 4.0 = 4000.0 (random access)
-- - Process rows: 1,000 rows × 0.01 = 10.0
-- - Filter evaluation: 1,000 rows × (1 operator × 0.0025) = 2.5
-- Total: 4217.5
-- 
-- Planner chooses seq scan (2500 < 4217)
```

### Startup Cost vs Total Cost

Every operation has two costs:

```sql
EXPLAIN SELECT * FROM items WHERE created_at > '2024-01-01';

-- Output: Seq Scan on items  (cost=0.00..1234.56 rows=5000 width=100)
--                                   ^^^^^    ^^^^^^^
--                                 Startup    Total
```

**Startup Cost**: Work before first row returned
- Sequential Scan: 0.00 (start immediately)
- Index Scan: Cost to traverse index tree
- Sort: Cost to sort entire dataset
- Hash Join: Cost to build hash table

**Total Cost**: Startup + work to return all rows
- Includes all I/O, CPU, and operator costs

**Why this matters**:
```sql
-- Query with LIMIT - startup cost dominates
SELECT * FROM items ORDER BY created_at LIMIT 10;
-- Planner prefers: Index scan (low startup, can stop early)
-- Over: Seq scan + sort (high startup, must process everything)

-- Query returning all rows - total cost dominates
SELECT * FROM items ORDER BY created_at;
-- Planner might prefer: Seq scan (lower total cost)
-- Over: Index scan (lower startup but higher total cost)
```

### Practical Cost Calculation Examples

**Example 1: Sequential Scan**
```sql
-- Table: 1M rows, 10,000 pages
-- Query: SELECT * FROM users WHERE active = true;
-- Estimated 500K matching rows

Cost Breakdown:
- Read pages: 10,000 pages × 1.0 = 10,000
- Process rows: 1,000,000 rows × 0.01 = 10,000
- Filter evaluation: 1,000,000 rows × 0.0025 = 2,500
Total: 22,500

EXPLAIN shows: cost=0.00..22500.00
```

**Example 2: Index Scan (High Selectivity)**
```sql
-- Query: SELECT * FROM users WHERE user_id = 12345;
-- Returns 1 row

Cost Breakdown:
- Index root page: 1 page × 1.0 = 1.0 (usually cached)
- Index branch pages: 3 pages × 1.0 = 3.0 (depth of tree)
- Index leaf page: 1 page × 4.0 = 4.0 (random access)
- Process index entry: 1 entry × 0.005 = 0.005
- Heap fetch: 1 row × 4.0 = 4.0 (random page access)
- Process row: 1 row × 0.01 = 0.01
Total: ~12.0

EXPLAIN shows: cost=0.43..8.45
```

**Example 3: Bitmap Index Scan**
```sql
-- Query: SELECT * FROM orders WHERE status = 'pending';
-- Returns 50K rows from 1M total, scattered across 2,000 pages

Cost Breakdown:
- Build bitmap:
  - Index scan: 300 pages × 4.0 = 1,200
  - Process entries: 50,000 × 0.005 = 250
- Heap scan:
  - Read marked pages: 2,000 pages × 1.0 = 2,000 (sequential!)
  - Process rows: 50,000 × 0.01 = 500
  - Recheck condition: 50,000 × 0.0025 = 125
Total: ~4,075

vs Index Scan:
- Would be: 50,000 random heap fetches × 4.0 = 200,000
Bitmap wins by massive margin!
```

---

## Access Path Selection

The planner's first job: choose how to read each table. It evaluates all possible access methods and picks the cheapest.

### Sequential Scan

**When Used:**
- Table is small (< few hundred pages)
- Query needs most rows (> 20-30% of table)
- No usable indexes exist
- Cost parameters favor sequential I/O

**Cost Formula:**
```
Cost = (pages × seq_page_cost) + 
       (rows × cpu_tuple_cost) + 
       (rows × filter_operators × cpu_operator_cost)
```

**Practical Example:**
```sql
-- Film table: 1000 rows, 64 pages
EXPLAIN ANALYZE SELECT * FROM film WHERE length > 100;

-- QUERY PLAN
-- Seq Scan on film  (cost=0.00..76.50 rows=609 width=390)
--   Filter: (length > 100)
--   Rows Removed by Filter: 391
--   Buffers: shared hit=64

-- Cost calculation:
-- - Pages: 64 × 1.0 = 64.0
-- - Process: 1000 × 0.01 = 10.0
-- - Filter: 1000 × 0.0025 = 2.5
-- Total: 76.5 ✓
```

**Optimization Tips:**
```sql
-- If seq scan is consistently wrong choice:

-- 1. Check cost parameters (is random_page_cost too high?)
SHOW random_page_cost;  -- If 4.0 on SSD, lower to 1.1

-- 2. Verify statistics are current
SELECT last_analyze FROM pg_stat_user_tables WHERE relname = 'film';

-- 3. For development/testing, disable seq scan temporarily
SET enable_seqscan = off;
-- This forces planner to use alternative methods
```

### Index Scan

**When Used:**
- Query returns < 5-10% of table
- Index exists on filter column(s)
- High selectivity on indexed column

**Cost Formula:**
```
Cost = (index_pages × random_page_cost) +
       (index_tuples × cpu_index_tuple_cost) +
       (heap_pages × random_page_cost) +
       (heap_tuples × cpu_tuple_cost) +
       filter_costs
```

**Key Consideration**: Heap fetches are expensive!
- Each matching index entry requires a heap fetch (random I/O)
- If many matches are scattered across table → expensive

**Practical Example:**
```sql
EXPLAIN ANALYZE SELECT * FROM customer WHERE customer_id = 42;

-- QUERY PLAN
-- Index Scan using customer_pkey on customer  
--   (cost=0.28..8.29 rows=1 width=74)
--   Index Cond: (customer_id = 42)
--   Buffers: shared hit=4

-- Cost calculation:
-- - Index traversal: 3 pages × 1.0 = 3.0 (tree depth)
-- - Index entry: 1 × 0.005 = 0.005
-- - Heap fetch: 1 page × 4.0 = 4.0
-- - Process row: 1 × 0.01 = 0.01
-- Total: ~7.0 (close to 8.29 shown)
```

**The Correlation Factor:**

Correlation determines heap fetch costs:

```sql
-- Check correlation for a column
SELECT tablename, attname, correlation
FROM pg_stats
WHERE tablename = 'rental' AND attname = 'rental_date';

-- Result: correlation = 0.95 (high)
```

**High correlation (0.9 to 1.0)**:
- Column values match physical row order
- Index scan reads consecutive heap pages
- Effective cost: ~sequential I/O instead of random
- Example: `created_at` in append-only table

**Low correlation (-0.1 to 0.1)**:
- Column values randomly scattered
- Index scan = fully random heap access
- Expensive! Each row = separate random I/O
- Example: `uuid` columns, randomly updated columns

```sql
-- Visualizing correlation impact:

-- LOW CORRELATION (user_id = random UUIDs)
-- Index: [uuid1→page_45, uuid2→page_12, uuid3→page_89, ...]
-- Heap access pattern: Jump around entire table randomly
-- Cost: N_matches × random_page_cost

-- HIGH CORRELATION (created_at = chronological inserts)
-- Index: [2024-01-01→page_1, 2024-01-02→page_1, 2024-01-03→page_2, ...]
-- Heap access pattern: Read consecutive pages
-- Cost: ~N_pages × seq_page_cost (much cheaper!)
```

**When Index Scan Becomes Bad:**

```sql
-- Example: Get 50% of table via index
EXPLAIN ANALYZE 
SELECT * FROM rental WHERE customer_id < 300;

-- Planner chooses: Seq Scan!
-- Why? 
-- - 50% selectivity = ~8,000 rows
-- - Rows scattered across table (low correlation on customer_id)
-- - Index scan cost: 8,000 random heap fetches × 4.0 = 32,000
-- - Seq scan cost: Read all pages once = ~500
-- Winner: Seq scan by 64x!
```

### Index-Only Scan

**When Used:**
- All needed columns are in the index
- Rows haven't been recently modified (visibility map is clean)
- Saves expensive heap fetches!

**Cost Formula:**
```
Cost = (index_pages × random_page_cost) +
       (index_tuples × cpu_index_tuple_cost) +
       (visibility_map_pages × seq_page_cost)  # Usually 0
```

**Practical Example:**
```sql
-- Create covering index
CREATE INDEX idx_rental_customer ON rental(customer_id, rental_date);

-- Query only uses indexed columns
EXPLAIN ANALYZE 
SELECT customer_id, rental_date 
FROM rental 
WHERE customer_id = 123;

-- QUERY PLAN
-- Index Only Scan using idx_rental_customer  
--   (cost=0.29..45.31 rows=32 width=8)
--   Index Cond: (customer_id = 123)
--   Heap Fetches: 0  ← NO HEAP ACCESS!
--   Buffers: shared hit=12

-- Dramatically faster than regular index scan
-- No random heap fetches needed
```

**Requirements for Heap Fetches: 0**:

```sql
-- 1. All columns must be in index (covering index)
-- 2. Table must be recently vacuumed (visibility map clean)

-- Check visibility map status
SELECT relname, n_live_tup, n_dead_tup,
       last_vacuum, last_autovacuum
FROM pg_stat_user_tables
WHERE relname = 'rental';

-- If n_dead_tup is high, run VACUUM
VACUUM rental;

-- Verify index-only scan is now used
EXPLAIN SELECT customer_id FROM rental WHERE customer_id = 123;
```

**Creating Effective Covering Indexes:**

```sql
-- Bad: Forces heap fetch for rental_date
CREATE INDEX idx_rental_cust ON rental(customer_id);
SELECT customer_id, rental_date FROM rental WHERE customer_id = 123;
-- Result: Index Scan (needs heap fetch for rental_date)

-- Good: Includes all needed columns
CREATE INDEX idx_rental_cust_date ON rental(customer_id, rental_date);
SELECT customer_id, rental_date FROM rental WHERE customer_id = 123;
-- Result: Index Only Scan (no heap fetch needed!)

-- INCLUDE clause (PG 11+) for non-search columns
CREATE INDEX idx_rental_cust_inc_date 
ON rental(customer_id) INCLUDE (rental_date);
-- Allows index-only scan without affecting index tree structure
```

### Bitmap Heap Scan

**When Used:**
- Moderate selectivity (5-30% of table)
- Multiple indexes can be combined (BitmapAnd/BitmapOr)
- Too many rows for index scan, too few for seq scan

**Cost Formula:**
```
Cost = (bitmap_build_cost) +
       (heap_pages_to_read × seq_page_cost) +  # Sequential!
       (heap_tuples × cpu_tuple_cost) +
       (recheck_cost)
```

**How It Works (Two Phases):**

```
Phase 1: BUILD BITMAP
┌─────────────────────┐
│  Index 1: Scan     │ → Bitmap 1: [1,0,1,0,1,...]
│  rental_duration=5  │    (marks matching pages)
└─────────────────────┘
         +
┌─────────────────────┐
│  Index 2: Scan     │ → Bitmap 2: [1,1,0,0,1,...]
│  rating='PG'        │    (marks matching pages)
└─────────────────────┘
         ↓
    BitmapAnd Operation
         ↓
Combined: [1,0,0,0,1,...]
         ↓
Phase 2: HEAP SCAN (Sequential!)
Read only marked pages: Page 1, Page 5, ...
```

**Practical Example:**
```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM film
WHERE rental_duration = 5 AND rating = 'PG';

-- QUERY PLAN
-- Bitmap Heap Scan on film  
--   (cost=11.46..69.45 rows=37 width=390)
--   Recheck Cond: ((rental_duration = 5) AND (rating = 'PG'))
--   Buffers: shared hit=22
--   ->  BitmapAnd  (cost=11.46..11.46 rows=37 width=0)
--         ->  Bitmap Index Scan on idx_rental_duration  
--               (cost=0.00..5.58 rows=191 width=0)
--               Index Cond: (rental_duration = 5)
--         ->  Bitmap Index Scan on idx_rating  
--               (cost=0.00..5.61 rows=194 width=0)
--               Index Cond: (rating = 'PG')

-- Why bitmap scan wins here:
-- - Index scan would need ~37 random heap fetches
-- - Bitmap scan consolidates to ~22 pages read sequentially
-- - Combining two indexes efficiently
```

**Bitmap Operations:**

```sql
-- BitmapAnd: Both conditions must match
WHERE col1 = 'A' AND col2 = 'B'

-- BitmapOr: Either condition matches
WHERE col1 = 'A' OR col2 = 'B'

-- Can combine both:
WHERE (col1 = 'A' OR col1 = 'B') AND col2 = 'C'
```

**Recheck Condition:**

Why does "Recheck Cond" appear?

```
Bitmap has limited resolution (1 bit per page, not per row)
If memory is tight, bitmap loses precision (marks blocks, not exact rows)
Must recheck condition when reading heap to filter false positives

Heap Fetches with Recheck:
Page marked as "match" → Read page → Recheck which specific rows match
```

**Memory Consideration:**

```sql
-- Bitmap size limited by work_mem
-- If bitmap > work_mem, it "loses precision"
-- Marks coarser regions (blocks of pages instead of individual pages)
-- More rechecking required

-- Check if bitmap scan is spilling
EXPLAIN (ANALYZE, BUFFERS)
SELECT ...;
-- Look for "Recheck Cond" and high "Rows Removed by Recheck Filter"

-- Solution: Increase work_mem
SET work_mem = '64MB';  -- From default 4MB
```

**When Bitmap Scan is Optimal:**

✅ Medium selectivity (1K-100K rows from 1M)  
✅ Multiple conditions with separate indexes  
✅ Rows somewhat clustered on disk  
✅ work_mem is adequate

❌ Very high selectivity (use index scan instead)  
❌ Very low selectivity (use seq scan instead)  
❌ No indexes available

---

## Join Strategy Selection

PostgreSQL has three fundamental join algorithms. Choosing the right one makes the difference between milliseconds and hours.

### Nested Loop Join

**Algorithm:**
```python
FOR each outer_row IN outer_table:
    FOR each inner_row IN inner_table WHERE join_condition(outer_row):
        YIELD combined(outer_row, inner_row)
```

**Cost Formula:**
```
Cost = outer_cost +
       (outer_rows × inner_cost) +
       (outer_rows × inner_rows_per_match × cpu_operator_cost)
```

**When Used:**
- Outer table is tiny (<100 rows)
- Inner table has index on join key
- High join selectivity (few matches per outer row)

**Practical Example:**
```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT c.*, r.*
FROM customer c
JOIN rental r ON c.customer_id = r.customer_id
WHERE c.customer_id = 1;

-- QUERY PLAN
-- Nested Loop  (cost=0.28..359.16 rows=32 width=114)
--   ->  Index Scan using customer_pkey on customer c  
--         (cost=0.28..8.29 rows=1 width=74)
--         Index Cond: (customer_id = 1)
--   ->  Seq Scan on rental r  
--         (cost=0.00..350.55 rows=32 width=40)
--         Filter: (customer_id = 1)

-- Why nested loop?
-- - Outer: 1 row (highly selective WHERE clause)
-- - Inner: 32 matching rentals for this customer
-- - Total iterations: 1 × 32 = 32 (tiny!)
```

**The Good:**
```sql
-- Nested loop excels with parameterized inner scan:
-- Use outer row values as index keys for inner table

EXPLAIN SELECT *
FROM orders o
JOIN order_items oi ON o.order_id = oi.order_id
WHERE o.customer_id = 12345;

-- Plan:
-- Nested Loop
--   -> Index Scan on orders (customer_id = 12345)  ← 5 orders
--   -> Index Scan on order_items using idx_order_id  ← Uses order_id from outer
--        Index Cond: (order_id = orders.order_id)

-- For each of 5 orders, index lookup finds items instantly
-- Total: 5 index scans (cheap!)
```

**The Bad:**
```sql
-- Nested loop catastrophe: no index on inner table

EXPLAIN ANALYZE
SELECT *
FROM customers c
JOIN orders o ON c.customer_id = o.customer_id;

-- If planner estimates 10 customers but actually 1M:
-- Plan: Nested Loop
--   -> Seq Scan on customers  ← 1,000,000 rows!
--   -> Seq Scan on orders     ← Scanned 1M times!
--       Filter: customer_id = c.customer_id

-- Execution: 1,000,000 full table scans of orders!
-- Should have used hash join instead
-- This is where bad row estimation kills performance
```

**Troubleshooting Nested Loop Issues:**

```sql
-- Symptom: Query hangs with nested loop in plan
-- Diagnosis:
EXPLAIN (ANALYZE, BUFFERS)
SELECT ...;

-- Look for:
-- - Nested Loop with high "loops" count
-- - Large outer table (>1000 rows)
-- - Inner side is Seq Scan or Materialized Scan

-- Fix 1: Add index on inner table join key
CREATE INDEX idx_orders_customer ON orders(customer_id);

-- Fix 2: Emergency override (session-level)
SET enable_nestloop = off;
SELECT ...;

-- Fix 3: Fix row estimation (see statistics runbook)
ANALYZE customers;
ANALYZE orders;
```

### Hash Join

**Algorithm:**
```python
# Phase 1: BUILD hash table from smaller input
hash_table = {}
FOR each row IN smaller_input:
    key = row.join_key
    hash_table[hash(key)].append(row)

# Phase 2: PROBE hash table with larger input
FOR each row IN larger_input:
    key = row.join_key
    FOR match IN hash_table[hash(key)]:
        IF match.join_key == row.join_key:  # Handle hash collisions
            YIELD combined(match, row)
```

**Cost Formula:**
```
Cost = (build_input_cost) +
       (build_rows × cpu_operator_cost) +  # Hash each row
       (probe_input_cost) +
       (probe_rows × cpu_operator_cost) +  # Hash + lookup each row
       (matched_rows × cpu_tuple_cost)     # Process matches
```

**When Used:**
- Both inputs are large (>1K rows)
- Equi-join (using = operator)
- No useful indexes exist
- Hash table fits in work_mem

**Practical Example:**
```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM rental r
JOIN customer c ON r.customer_id = c.customer_id;

-- QUERY PLAN
-- Hash Join  (cost=22.48..375.33 rows=16044 width=114)
--   Hash Cond: (r.customer_id = c.customer_id)
--   Buffers: shared hit=384
--   ->  Seq Scan on rental r  
--         (cost=0.00..310.44 rows=16044 width=40)
--         Buffers: shared hit=310
--   ->  Hash  (cost=14.99..14.99 rows=599 width=74)
--         Buckets: 1024  Batches: 1  Memory Usage: 52kB
--         ->  Seq Scan on customer c  
--               (cost=0.00..14.99 rows=599 width=74)
--               Buffers: shared hit=15

-- Why hash join?
-- - Build phase: 599 customers (small) → hash table in memory
-- - Probe phase: Stream 16,044 rentals, hash lookup for each
-- - Each probe is O(1) average case
-- - Total time: Linear in sum of input sizes
```

**Memory Management:**

Hash join performance critically depends on **work_mem**:

```sql
-- Check current work_mem
SHOW work_mem;  -- Default: 4MB (often too small!)

-- Check if hash join is spilling to disk
EXPLAIN (ANALYZE, BUFFERS)
SELECT ...;

-- Look for in Hash node:
-- Buckets: 16384  Batches: 4  Memory Usage: 4096kB
--                         ^^^
--                 Batches > 1 = SPILLING TO DISK!
```

**Batches and Disk Spill:**

```
Batches: 1 (Ideal - All in Memory)
┌─────────────┐
│ Hash Table  │ ← Entire hash table fits in work_mem
│ (in memory) │    Fast! O(1) lookups ✓
└─────────────┘

Batches: 4 (Spilling to Disk)
┌─────────────┐
│ Batch 1     │ ← Process 1/4 of data in memory
│ (in memory) │    Write other 3/4 to temp files
└─────────────┘
      ↓
┌─────────────┐
│ Batch 2     │ ← Read back from disk, process
│ (from disk) │    Much slower! ✗
└─────────────┘
      ↓
   ... etc ...
```

**Detecting and Fixing Disk Spills:**

```sql
-- Problem: Hash join using multiple batches (spilling to disk)
EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM large_table1 l1
JOIN large_table2 l2 ON l1.id = l2.id;

-- Output shows:
-- Hash (cost=... rows=1000000 ...)
--   Buckets: 131072  Batches: 8  Memory Usage: 4096kB
--                             ^^^ PROBLEM!
--   Peak Memory Usage: 32768kB
-- Buffers: ... temp written=25000 ← Disk I/O!

-- Impact of batching:
-- - Batch 1: Build hash in memory, probe
-- - Batch 2-8: Must re-read data from temp files
-- - Each batch adds full scan of both inputs
-- - 8 batches = 8x slower than single batch!

-- Solution 1: Increase work_mem for this query
SET work_mem = '256MB';  -- Was 4MB
EXPLAIN (ANALYZE, BUFFERS) SELECT ...;
-- Now shows: Batches: 1  Memory Usage: 100MB ✓

-- Solution 2: Increase work_mem globally (requires reload)
ALTER SYSTEM SET work_mem = '64MB';
SELECT pg_reload_conf();

-- Solution 3: Reduce the hash table size (query rewrite)
-- Add more selective WHERE clauses to reduce build-side rows
SELECT *
FROM large_table1 l1
JOIN large_table2 l2 ON l1.id = l2.id
WHERE l1.created_at > now() - interval '30 days';  -- Reduce l1 rows

-- Solution 4: Force merge join instead (if inputs can be sorted)
SET enable_hashjoin = off;
```

**Hash Join Performance Guidelines:**

```
work_mem Setting vs Hash Table Size:
- 4MB work_mem → ~50K rows (100 bytes/row)
- 16MB work_mem → ~200K rows
- 64MB work_mem → ~800K rows
- 256MB work_mem → ~3M rows

Rule of thumb:
work_mem should be ≥ (build_side_rows × avg_row_width) / 1024 / 1024 MB

Example:
- Build side: 1M rows × 150 bytes = 150MB
- Set: work_mem = '200MB' (add buffer for hash overhead)
```

**Hash Join vs Index Nested Loop Decision:**

```sql
-- Scenario: Join 1M orders with 100K customers

-- Option 1: Hash Join
-- - Build hash table: 100K customers (smaller)
-- - Probe: Stream 1M orders
-- - Cost: ~Linear in total rows (1.1M)
-- - Requires: work_mem for hash table

-- Option 2: Nested Loop with Index
-- - Outer: 1M orders
-- - Inner: Index lookup per order = 1M index scans
-- - Cost: 1M × index_cost
-- - Works well if: orders highly selective (WHERE filters to <100 rows)

-- Planner chooses based on:
-- 1. Estimated row counts (statistics!)
-- 2. Available memory (work_mem)
-- 3. Index availability
-- 4. Cost parameters
```

### Merge Join

**Algorithm:**
```python
# Both inputs MUST be sorted by join key
left = sorted_left_input.first()
right = sorted_right_input.first()

WHILE left AND right:
    IF left.key == right.key:
        # Found match, may be multiple on both sides
        YIELD all_combinations(left, right)
        ADVANCE both
    ELIF left.key < right.key:
        ADVANCE left
    ELSE:
        ADVANCE right
```

**Cost Formula:**
```
Cost = (left_input_cost) +
       (right_input_cost) +
       (sort_cost if not already sorted) +
       (matched_rows × cpu_tuple_cost)
```

**When Used:**
- Both inputs are already sorted (from index or previous sort)
- Large tables where hash join would spill to disk
- Non-equi joins (<, >, <=, >=) where hash join can't be used

**Practical Example:**
```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM rental r
JOIN payment p ON r.rental_id = p.rental_id;

-- QUERY PLAN
-- Merge Join  (cost=1483.07..2341.89 rows=16049 width=70)
--   Merge Cond: (r.rental_id = p.rental_id)
--   Buffers: shared hit=688
--   ->  Index Scan using rental_pkey on rental r  
--         (cost=0.29..578.29 rows=16044 width=40)
--         Buffers: shared hit=278
--   ->  Sort  (cost=1482.77..1522.90 rows=16049 width=30)
--         Sort Key: p.rental_id
--         Sort Method: external merge  Disk: 480kB
--         Buffers: shared hit=410, temp read=60 written=60
--         ->  Append  (cost=0.00..361.74 rows=16049 width=30)
--               ->  Seq Scan on payment_p2022_01 p_1  
--               ->  Seq Scan on payment_p2022_02 p_2
--               ... (more partitions)

-- Why merge join?
-- - rental: Already sorted by rental_id (primary key index)
-- - payment: Needs sort (16K rows across partitions)
-- - Merge is efficient once both sorted
-- - One pass through each sorted input
```

**The Good: Pre-sorted Inputs**

```sql
-- Both sides already sorted = merge join is optimal
EXPLAIN SELECT *
FROM orders o
JOIN order_audit a ON o.order_id = a.order_id
ORDER BY o.order_id;

-- Plan:
-- Merge Join  (cost=0.58..1234.56 rows=10000 width=100)
--   Merge Cond: (o.order_id = a.order_id)
--   ->  Index Scan using orders_pkey on orders o  ← Pre-sorted!
--   ->  Index Scan using audit_order_id_idx on order_audit a  ← Pre-sorted!

-- No sort needed, just merge!
-- Very efficient, scales well to large datasets
```

**The Bad: Sort Overhead**

```sql
-- One or both sides need sorting = expensive
EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM large_table1 l1
JOIN large_table2 l2 ON l1.id = l2.id;

-- Plan:
-- Merge Join  (cost=125000.00..200000.00 rows=1000000 width=100)
--   ->  Sort  (cost=62500.00..65000.00 rows=1000000 width=50)
--         Sort Method: external merge  Disk: 25600kB  ← SLOW!
--         ->  Seq Scan on large_table1 l1
--   ->  Sort  (cost=62500.00..65000.00 rows=1000000 width=50)
--         Sort Method: external merge  Disk: 25600kB  ← SLOW!
--         ->  Seq Scan on large_table2 l2

-- Problem: Both inputs need sorting
-- Each sort spills to disk (>work_mem)
-- Hash join would be faster here (no sort needed)
```

**Non-Equi Joins (Merge Join's Specialty):**

```sql
-- Range joins: only merge join can handle efficiently
EXPLAIN SELECT *
FROM events e1
JOIN events e2 ON e1.start_time < e2.end_time
               AND e1.end_time > e2.start_time;

-- Plan: Merge Join
-- Hash join CAN'T handle <, >, <= operators
-- Nested loop would be O(N²) catastrophe

-- Merge join: O(N log N) sort + O(N) merge
```

**Troubleshooting Merge Join Issues:**

```sql
-- Symptom: Merge join with expensive sorts

-- Diagnosis:
EXPLAIN (ANALYZE, BUFFERS)
SELECT ...;

-- Look for:
-- - "Sort Method: external merge" (disk spill)
-- - "Disk: XXXXX kB" (temp file usage)
-- - High "Buffers: temp read/written"

-- Fix 1: Increase work_mem for in-memory sort
SET work_mem = '256MB';

-- Fix 2: Add indexes to eliminate sort
CREATE INDEX idx_table1_joinkey ON table1(join_key);
CREATE INDEX idx_table2_joinkey ON table2(join_key);

-- Fix 3: Force hash join instead
SET enable_mergejoin = off;
SELECT ...;

-- Fix 4: Check if CLUSTER would help
-- If join key has low correlation, clustering can help
CLUSTER table1 USING idx_table1_joinkey;
ANALYZE table1;
```

**When Merge Join Wins:**

✅ Both inputs pre-sorted (from indexes)  
✅ Large joins where hash would spill  
✅ Non-equi joins (<, >)  
✅ Sufficient work_mem for in-memory sorts  

❌ Both inputs need expensive sorts  
❌ Small datasets (nested loop faster)  
❌ Equi-joins with unsorted data (hash join better)

---

## Join Order Optimization

The number of possible join orders explodes factorially with table count. For N tables, there are (2N-2)!/(N-1)! possible orders.

```
Tables  |  Possible Join Orders
--------|----------------------
   2    |          1
   3    |         12
   4    |        120
   5    |      1,680
   6    |     30,240
   8    |  17,297,280
  10    | ~176 billion
  12    | ~28 trillion
```

### Dynamic Programming Approach (≤12 tables)

PostgreSQL uses dynamic programming with aggressive optimization for queries with up to 12 tables (configurable via `geqo_threshold`).

**How It Works:**

```python
# Simplified dynamic programming join order algorithm

def find_best_plan(tables):
    # Base case: single table
    for each table in tables:
        best_plan[table] = cheapest_access_path(table)
    
    # Build up: combine smaller plans into larger plans
    for size in 2 to N:
        for each subset of tables of given size:
            best_cost = INFINITY
            
            # Try different ways to split into left and right
            for each way to partition subset:
                left_plan = best_plan[left_subset]
                right_plan = best_plan[right_subset]
                
                # Try each join algorithm
                for join_type in [nested_loop, hash_join, merge_join]:
                    cost = join_type.cost(left_plan, right_plan)
                    if cost < best_cost:
                        best_cost = cost
                        best_plan[subset] = this_plan
            
            # PRUNING: Discard plans that can't possibly be optimal
            prune_dominated_plans(subset)
    
    return best_plan[all_tables]
```

**Key Optimizations:**

1. **Memoization**: Cache best plan for each subset
2. **Pruning**: Discard plans that are dominated (more expensive, no advantages)
3. **Join Collapse Limit**: Control how many tables are reordered

```sql
-- Control join reordering
SHOW join_collapse_limit;  -- Default: 8
SHOW from_collapse_limit;  -- Default: 8

-- join_collapse_limit: Max tables to reorder in explicit JOINs
-- from_collapse_limit: Max tables to reorder in FROM list

-- Reduce to force written order:
SET join_collapse_limit = 1;  -- No reordering
SET from_collapse_limit = 1;

-- Example: Force join order for complex query
SET join_collapse_limit = 1;
SELECT *
FROM a 
JOIN b ON a.id = b.a_id
JOIN c ON b.id = c.b_id
JOIN d ON c.id = d.c_id;
-- Now joins in exactly this order: a→b→c→d
```

**Cost-Based Pruning Example:**

```sql
-- Query: SELECT * FROM a, b, c WHERE a.id = b.a_id AND b.id = c.b_id;

-- Planner evaluates:
-- Option 1: (a JOIN b) JOIN c
--   Cost: 1000 + 500 = 1500
-- Option 2: a JOIN (b JOIN c)
--   Cost: 1000 + 800 = 1800
-- Option 3: (a JOIN c) JOIN b [invalid - no direct join condition]
--   Skipped due to join condition analysis

-- Winner: Option 1 (lowest cost)
```

**Join Condition Analysis:**

PostgreSQL analyzes WHERE clauses to determine valid join orders:

```sql
-- Query with multiple conditions
SELECT *
FROM orders o, customers c, products p
WHERE o.customer_id = c.id
  AND o.product_id = p.id
  AND c.country = 'US'
  AND p.price > 100;

-- Valid join trees:
-- 1. Filter c (country='US') → Join o → Join p
-- 2. Filter p (price>100) → Join o → Join c
-- 3. Join c and o → Filter result → Join p

-- Invalid: Can't join c and p directly (no join condition)

-- Planner builds join graph:
--     c --- o --- p
-- Then explores valid spanning trees
```

### Genetic Query Optimizer (GEQO) (≥12 tables)

For queries with 12+ tables, exhaustive search becomes impractical. PostgreSQL uses a **Genetic Algorithm**.

**How GEQO Works:**

```python
# Simplified genetic algorithm for join order

def geqo(tables):
    # 1. INITIALIZE: Create random population of join orders
    population = []
    for i in range(population_size):  # Default: 200-400
        individual = random_join_order(tables)
        population.append(individual)
    
    # 2. EVOLVE: Run for multiple generations
    for generation in range(num_generations):  # Default: auto-calculated
        # 3. FITNESS: Evaluate each individual (calculate cost)
        for individual in population:
            individual.fitness = calculate_plan_cost(individual)
        
        # 4. SELECTION: Choose fittest individuals
        parents = select_fittest(population, selection_rate=0.5)
        
        # 5. CROSSOVER: Combine parents to create offspring
        offspring = []
        for parent1, parent2 in random_pairs(parents):
            child = crossover(parent1, parent2)
            offspring.append(child)
        
        # 6. MUTATION: Random changes to maintain diversity
        for individual in offspring:
            if random() < mutation_rate:
                mutate(individual)
        
        # 7. REPLACEMENT: New generation = best of old + offspring
        population = select_fittest(population + offspring, population_size)
    
    # Return best individual found
    return best_individual(population)

def crossover(parent1, parent2):
    # Edge Recombination Crossover (specific to join orders)
    # Preserves join structure from both parents
    ...

def mutate(individual):
    # Randomly swap two adjacent joins
    # Or randomly swap two tables in join order
    ...
```

**GEQO Configuration:**

```sql
-- Check GEQO settings
SELECT name, setting, short_desc
FROM pg_settings
WHERE name LIKE 'geqo%'
ORDER BY name;

-- Key parameters:
SHOW geqo;                    -- Default: on
SHOW geqo_threshold;          -- Default: 12 tables
SHOW geqo_effort;             -- Default: 5 (range: 1-10)
SHOW geqo_pool_size;          -- Default: 0 (auto-calculated)
SHOW geqo_generations;        -- Default: 0 (auto-calculated)
SHOW geqo_selection_bias;    -- Default: 2.0

-- Tuning GEQO for better plans:

-- More thorough search (slower planning, better plans)
SET geqo_effort = 10;          -- Max effort
SET geqo_pool_size = 1000;     -- Larger population
SET geqo_generations = 100;    -- More evolution

-- Faster planning (worse plans acceptable)
SET geqo_effort = 1;           -- Min effort
SET geqo_threshold = 15;       -- Only use for 15+ tables
```

**GEQO Performance Characteristics:**

```
Planning Time vs Quality Trade-off:

Effort 1:  ~10ms planning,  Plan may be 2-3x suboptimal
Effort 5:  ~50ms planning,  Plan typically within 10-20% of optimal
Effort 10: ~200ms planning, Plan close to optimal

For 15-table join:
- Dynamic programming: Would take hours (not feasible)
- GEQO effort=5: 50ms planning, excellent plan
```

**When GEQO Kicks In:**

```sql
-- Query with 13 tables (exceeds geqo_threshold=12)
EXPLAIN
SELECT *
FROM t1 
JOIN t2 ON t1.id = t2.t1_id
JOIN t3 ON t2.id = t3.t2_id
JOIN t4 ON t3.id = t4.t3_id
JOIN t5 ON t4.id = t5.t4_id
JOIN t6 ON t5.id = t6.t5_id
JOIN t7 ON t6.id = t7.t6_id
JOIN t8 ON t7.id = t8.t7_id
JOIN t9 ON t8.id = t9.t8_id
JOIN t10 ON t9.id = t10.t9_id
JOIN t11 ON t10.id = t11.t10_id
JOIN t12 ON t11.id = t12.t11_id
JOIN t13 ON t12.id = t13.t12_id;

-- Planning time: ~50ms (GEQO with default effort=5)
-- Without GEQO: Would take hours or days

-- Verify GEQO was used (enable debug logging):
SET client_min_messages = DEBUG1;
-- Look for: "GEQO: number of generations: X"
```

**Troubleshooting Complex Join Orders:**

```sql
-- Problem: Query with 10 tables has bad join order

-- Diagnosis 1: Check if statistics are good
SELECT tablename, n_live_tup, n_dead_tup, 
       last_analyze, last_autoanalyze
FROM pg_stat_user_tables
WHERE tablename IN ('t1', 't2', 't3', ...);

-- Fix bad statistics
ANALYZE t1, t2, t3, ...;

-- Diagnosis 2: Check join order in plan
EXPLAIN (VERBOSE)
SELECT * FROM ...;

-- Look for joins happening in wrong order:
-- - Large table as outer in nested loop (bad!)
-- - Missing indexes causing full scans
-- - Cartesian products (missing join conditions)

-- Fix 1: Add missing indexes
CREATE INDEX idx_t2_t1_id ON t2(t1_id);
CREATE INDEX idx_t3_t2_id ON t3(t2_id);

-- Fix 2: Rewrite query with CTEs to force order
WITH step1 AS (
    SELECT * FROM t1 JOIN t2 ON t1.id = t2.t1_id
    WHERE t1.filter_column = 'value'  -- Reduce early
),
step2 AS (
    SELECT * FROM step1 JOIN t3 ON step1.id = t3.step1_id
)
SELECT * FROM step2 JOIN t4 ON step2.id = t4.step2_id;

-- Fix 3: Use join_collapse_limit to control reordering
SET join_collapse_limit = 4;  -- Only reorder groups of 4 tables

-- Fix 4: Add join hints using pg_hint_plan extension (if available)
/*+ Leading((t1 t2 t3)) */
SELECT * FROM t1, t2, t3 WHERE ...;
```

**Advanced: Understanding Why Planner Chose Join Order:**

```sql
-- Enable verbose planning output
SET debug_print_plan = on;
SET client_min_messages = LOG;

EXPLAIN SELECT ...;

-- Check server logs for detailed join selection reasoning
-- Look for cost comparisons between different join orders

-- Alternative: Use auto_explain to log automatically
ALTER SYSTEM SET auto_explain.log_min_duration = 1000;  -- Log plans >1s
ALTER SYSTEM SET auto_explain.log_analyze = on;
ALTER SYSTEM SET auto_explain.log_nested_statements = on;
SELECT pg_reload_conf();
```

---

## Troubleshooting Planner Decisions

### Decision Tree: Why Did Planner Choose This?

```
Query slow → Check EXPLAIN output

1. Sequential Scan instead of Index Scan?
   ├─ Statistics stale? → ANALYZE table
   ├─ Table small? → Seq scan is correct
   ├─ Low selectivity (>20% rows)? → Seq scan is correct
   ├─ random_page_cost too high? → Lower if using SSD
   └─ Index missing? → CREATE INDEX

2. Nested Loop with large outer table?
   ├─ Row estimation wrong? → Check statistics, ANALYZE
   ├─ Missing index on inner? → CREATE INDEX on join key
   ├─ Should be hash join? → Check work_mem, increase if needed
   └─ Emergency: SET enable_nestloop = off

3. Hash Join spilling to disk (Batches > 1)?
   ├─ work_mem too small? → Increase work_mem
   ├─ Build side too large? → Add WHERE filters
   └─ Should be merge join? → Check if indexes exist

4. Expensive sorts?
   ├─ work_mem too small? → Increase work_mem
   ├─ Missing index? → CREATE INDEX on sort column
   └─ Can eliminate sort? → Use ORDER BY with index

5. Wrong join order?
   ├─ Statistics stale? → ANALYZE all tables
   ├─ Too many tables (GEQO)? → Increase geqo_effort
   ├─ Missing join conditions? → Check WHERE clause
   └─ Force order: Use join_collapse_limit = 1 or CTEs

6. Planning time excessive (>1s)?
   ├─ Too many tables? → Normal for 10+ tables
   ├─ GEQO threshold too high? → Lower geqo_threshold
   ├─ Too many indexes? → Drop unused indexes
   └─ Consider: Prepared statements (plan once, execute many)
```

### Common Anti-Patterns and Fixes

**Anti-Pattern 1: Function in WHERE clause prevents index usage**

```sql
-- BAD: Function prevents index usage
EXPLAIN SELECT * FROM users WHERE LOWER(email) = 'user@example.com';
-- Plan: Seq Scan on users
--   Filter: (lower(email) = 'user@example.com')

-- FIX 1: Create expression index
CREATE INDEX idx_users_email_lower ON users (LOWER(email));
EXPLAIN SELECT * FROM users WHERE LOWER(email) = 'user@example.com';
-- Plan: Index Scan using idx_users_email_lower

-- FIX 2: Store lowercase version
ALTER TABLE users ADD COLUMN email_lower text 
  GENERATED ALWAYS AS (LOWER(email)) STORED;
CREATE INDEX idx_users_email_lower ON users(email_lower);
```

**Anti-Pattern 2: OR conditions preventing index usage**

```sql
-- BAD: OR can't use single index efficiently
EXPLAIN SELECT * FROM orders 
WHERE customer_id = 123 OR product_id = 456;
-- Plan: Seq Scan on orders
--   Filter: ((customer_id = 123) OR (product_id = 456))

-- FIX: Rewrite as UNION (allows both indexes)
EXPLAIN
SELECT * FROM orders WHERE customer_id = 123
UNION
SELECT * FROM orders WHERE product_id = 456;
-- Plan: HashAggregate
--   -> Append
--        -> Index Scan using idx_customer_id
--        -> Index Scan using idx_product_id

-- Or use Bitmap OR (if both indexes exist):
-- PostgreSQL automatically uses BitmapOr if advantageous
```

**Anti-Pattern 3: Implicit type conversion**

```sql
-- BAD: Implicit cast prevents index usage
-- Table: user_id is integer, but query uses string
EXPLAIN SELECT * FROM users WHERE user_id = '12345';
-- Plan: Seq Scan on users
--   Filter: ((user_id)::text = '12345'::text)  ← Cast!

-- FIX: Use correct type
EXPLAIN SELECT * FROM users WHERE user_id = 12345;
-- Plan: Index Scan using users_pkey

-- Check for implicit casts in your query:
SELECT * FROM pg_cast WHERE castcontext = 'i';  -- Implicit casts
```

**Anti-Pattern 4: NOT IN with NULLs**

```sql
-- BAD: NOT IN with nullable column is slow
EXPLAIN SELECT * FROM orders 
WHERE customer_id NOT IN (SELECT id FROM blocked_customers);
-- If blocked_customers.id is nullable:
-- Plan: Nested Loop Anti Join with NULL checks (slow!)

-- FIX 1: Use NOT EXISTS
EXPLAIN SELECT * FROM orders o
WHERE NOT EXISTS (
    SELECT 1 FROM blocked_customers bc 
    WHERE bc.id = o.customer_id
);
-- Plan: Hash Anti Join (much faster!)

-- FIX 2: Filter out NULLs explicitly
EXPLAIN SELECT * FROM orders
WHERE customer_id NOT IN (
    SELECT id FROM blocked_customers WHERE id IS NOT NULL
);
```

**Anti-Pattern 5: OFFSET for pagination**

```sql
-- BAD: OFFSET scans and discards rows
EXPLAIN ANALYZE SELECT * FROM orders 
ORDER BY created_at 
LIMIT 20 OFFSET 100000;
-- Plan: Limit (actual time=2500.123..2500.456)
--   -> Index Scan using idx_created_at
--      (actual rows=100020 loops=1)  ← Scanned 100K rows!

-- FIX: Keyset pagination (seek method)
EXPLAIN ANALYZE SELECT * FROM orders
WHERE created_at > '2024-01-15 10:23:45'  -- Last seen value
ORDER BY created_at
LIMIT 20;
-- Plan: Limit (actual time=0.123..0.156)
--   -> Index Scan using idx_created_at
--      (actual rows=20 loops=1)  ← Only 20 rows!
```

### Comparing Plans: Before and After

```sql
-- Create a function to compare plans
CREATE OR REPLACE FUNCTION compare_plans(query_text text)
RETURNS TABLE(
    method text,
    planning_time numeric,
    execution_time numeric,
    total_time numeric,
    plan_text text
) AS $
DECLARE
    result record;
    plan_output text;
BEGIN
    -- Test 1: Default planner
    EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON)
    EXECUTE query_text
    INTO plan_output;
    
    -- Parse and return results
    -- (Simplified - actual implementation would parse JSON)
    
    RETURN QUERY SELECT 
        'default'::text,
        0.1::numeric,
        10.5::numeric,
        10.6::numeric,
        plan_output;
    
    -- Test 2: With enable_seqscan = off
    SET LOCAL enable_seqscan = off;
    -- Repeat...
    
    -- Test 3: With increased work_mem
    SET LOCAL work_mem = '256MB';
    -- Repeat...
END;
$ LANGUAGE plpgsql;

-- Usage:
SELECT * FROM compare_plans('SELECT * FROM large_table WHERE col = 123');
```

---

## Advanced Optimization Techniques

### Prepared Statements: Plan Once, Execute Many

```sql
-- Problem: Planning overhead for repeated queries
-- Solution: Prepared statements cache plans

-- Create prepared statement
PREPARE get_customer AS
SELECT * FROM customers WHERE customer_id = $1;

-- Execute multiple times (uses same plan)
EXECUTE get_customer(123);
EXECUTE get_customer(456);
EXECUTE get_customer(789);

-- View prepared statements
SELECT name, statement, parameter_types
FROM pg_prepared_statements;

-- Deallocate when done
DEALLOCATE get_customer;
```

**Generic vs Custom Plans:**

```sql
-- PostgreSQL decides: generic plan or custom plan?
-- First 5 executions: Always custom plans
-- After 5: Compare costs of generic vs average custom
-- If generic is cheaper: Use generic plan forever
-- If custom is cheaper: Keep using custom plans

-- Force generic plan (useful for stable queries)
PREPARE stmt AS SELECT * FROM users WHERE user_id = $1;
-- After 5 executions, if selectivity is stable, uses generic

-- Force custom plan (useful for skewed data)
-- Use parameterized queries without PREPARE:
-- Most ORMs do this automatically
```

**Checking Plan Choice:**

```sql
-- Enable logging
SET log_statement = 'all';
SET log_planner_stats = on;

-- After several executions, check if using generic plan:
SELECT name, generic_plans, custom_plans 
FROM pg_prepared_statements;

-- generic_plans > 0 means it switched to generic plan
```

### Partial Indexes: Smaller, Faster

```sql
-- Instead of indexing entire table, index subset

-- BAD: Full index on status (includes 95% inactive orders)
CREATE INDEX idx_orders_status ON orders(status);
-- Index size: 500MB, includes mostly inactive orders

-- GOOD: Partial index only on active orders
CREATE INDEX idx_orders_active 
ON orders(customer_id, created_at)
WHERE status = 'active';
-- Index size: 25MB, only 5% of orders

-- Query using partial index:
EXPLAIN SELECT * FROM orders
WHERE status = 'active' AND customer_id = 123;
-- Plan: Index Scan using idx_orders_active
--   Index Cond: (customer_id = 123)
--   Filter: (status = 'active')  ← Redundant but harmless

-- Benefits:
-- - Smaller index = faster scans
-- - Fewer disk pages = better cache hit ratio
-- - Faster index maintenance (inserts/updates)
```

**Common Partial Index Patterns:**

```sql
-- Pattern 1: Non-NULL values
CREATE INDEX idx_users_verified_email 
ON users(email) 
WHERE email IS NOT NULL;

-- Pattern 2: Active records
CREATE INDEX idx_subscriptions_active
ON subscriptions(user_id, plan_id)
WHERE end_date IS NULL;

-- Pattern 3: Recent data
CREATE INDEX idx_logs_recent
ON logs(user_id, created_at)
WHERE created_at > '2024-01-01';

-- Pattern 4: Specific status values
CREATE INDEX idx_orders_problematic
ON orders(customer_id, created_at)
WHERE status IN ('pending', 'failed', 'refunded');
```

### Expression Indexes: Pre-Compute Common Expressions

```sql
-- Problem: Function calls prevent index usage

-- Create index on expression
CREATE INDEX idx_users_email_lower 
ON users (LOWER(email));

CREATE INDEX idx_orders_total
ON orders ((quantity * price));

CREATE INDEX idx_events_date
ON events (DATE(timestamp));

-- Now these queries use indexes:
SELECT * FROM users WHERE LOWER(email) = 'user@example.com';
SELECT * FROM orders WHERE (quantity * price) > 1000;
SELECT * FROM events WHERE DATE(timestamp) = '2024-12-24';
```

### Covering Indexes (INCLUDE): Index-Only Scans

```sql
-- Problem: Index scan requires heap fetch for non-indexed columns

-- BEFORE: Regular index
CREATE INDEX idx_orders_customer ON orders(customer_id);

SELECT customer_id, order_date, total 
FROM orders 
WHERE customer_id =




Resourceful Urls - 
https://internals-for-interns.com/posts/postgres-query-planner/
