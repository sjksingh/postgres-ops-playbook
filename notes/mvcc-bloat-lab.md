# PostgreSQL MVCC Bloat & Space Reuse Lab
## Understanding Dead Tuples, Bloat, and Space Reclamation

**Based on Frank Pachot's "Postgres dead tuple space reused without vacuum"**

---

## Introduction: What You'll Learn

This lab demonstrates PostgreSQL's Multi-Version Concurrency Control (MVCC) internals:
- How UPDATE/DELETE creates dead tuples (bloat)
- How PostgreSQL reuses space **without VACUUM**
- The difference between heap table and B-Tree index cleanup
- Why reads can modify database state
- When VACUUM is actually needed

**Key Insight:** PostgreSQL has surprising built-in mechanisms to reclaim space before VACUUM runs, but they work differently for tables vs indexes.

---

## Part 1: Environment Setup

```sql
-- Check PostgreSQL version
SELECT version();

-- Enable PageInspect extension (to see internal page structure)
CREATE EXTENSION IF NOT EXISTS pageinspect;

-- Drop existing table if present
DROP TABLE IF EXISTS demo CASCADE;
```

---

## Part 2: Create Demo Table with Auto-Vacuum Disabled

```sql
-- Create table WITHOUT auto-vacuum to control when cleanup happens
CREATE TABLE demo (
    id BIGINT,
    value TEXT
) WITH (
    autovacuum_enabled = off  -- Critical: we control VACUUM manually
);

-- Create a covering B-Tree index (includes value column)
CREATE UNIQUE INDEX demo_pkey ON demo (id) INCLUDE (value);

-- Insert 16 large rows (500 bytes each)
-- Large rows = few per page = easier to visualize
INSERT INTO demo
SELECT 
    generate_series(0, 15),
    lpad('x', 500, 'x');  -- 500 character string of 'x'

-- Verify insertion
SELECT COUNT(*) FROM demo;
```

**Expected Result:**
```
count
-------
    16
```

**Why large rows?** With 500-byte rows, only ~15 rows fit in an 8KB page, making page-level changes easy to observe.

---

## Part 3: Initial State - Examine Page Structure

### 3.1 Examine Heap Table (First Page)

```sql
-- View all tuples in block 0 of the heap table
SELECT 
    t_ctid,           -- Tuple ID (block, offset)
    lp,               -- Line pointer number
    lp_len,           -- Length of tuple
    lp_flags,         -- Status: 1=normal, 2=redirect, 3=dead
    t_xmin,           -- Transaction that created this tuple
    t_xmax,           -- Transaction that deleted/updated (0=still visible)
    substr(t_data, 1, 30) -- First 30 bytes of data
FROM heap_page_items(get_raw_page('demo', 0))
ORDER BY lp;
```

**Expected Output (15 rows in block 0):**
```
 t_ctid | lp | lp_len | lp_flags | t_xmin | t_xmax |           substr
--------+----+--------+----------+--------+--------+---------------------------
 (0,1)  |  1 |    536 |        1 |   XXXX |      0 | \x000000...787878787878
 (0,2)  |  2 |    536 |        1 |   XXXX |      0 | \x010000...787878787878
 ...
 (0,15) | 15 |    536 |        1 |   XXXX |      0 | \x0e0000...787878787878
```

**Key observations:**
- `lp_flags = 1` means "normal" (live tuple)
- `t_xmax = 0` means no transaction has deleted/updated this tuple
- Each tuple is 536 bytes (28 byte header + 508 byte data)

### 3.2 Examine B-Tree Index (First Leaf Page)

```sql
-- View index entries in leaf block 1
SELECT 
    substr(data, 1, 30) as data_preview,
    itemoffset,
    htid,              -- Heap tuple ID this points to
    itemlen,           -- Index entry length
    dead               -- Is this a dead entry?
FROM bt_page_items(get_raw_page('demo_pkey', 1))
ORDER BY data;
```

**Expected Output (14 index entries in block 1):**
```
     data_preview          | itemoffset |  htid  | itemlen | dead
---------------------------+------------+--------+---------+------
 00 00 00 00 00 00 00 00   |          2 | (0,1)  |     520 | f
 01 00 00 00 00 00 00 00   |          3 | (0,2)  |     520 | f
 ...
 0d 00 00 00 00 00 00 00   |          1 |        |      16 | 
```

**Key observations:**
- Each index entry points to a heap tuple via `htid`
- Covering index includes the value, making entries large (520 bytes)
- `dead = f` means all entries are live

### 3.3 Check Initial Sizes

```sql
-- Table and index sizes
SELECT 
    relname,
    pg_table_size(oid) as bytes,
    pg_size_pretty(pg_table_size(oid)) as size
FROM pg_class 
WHERE relname LIKE 'demo%'
ORDER BY relname;
```

**Expected Output:**
```
  relname  | bytes  | size
-----------+--------+------
 demo      |  49152 | 48 kB
 demo_pkey |  32768 | 32 kB
```

---

## Part 4: UPDATE - Create a Dead Tuple

```sql
-- Update one row (id=2), changing value to uppercase
UPDATE demo 
SET value = upper(value) 
WHERE id = 2;

-- Check how many rows affected
-- Expected: UPDATE 1
```

**What just happened:**
1. Old tuple at (0,3) was marked as deleted (t_xmax set)
2. New tuple was created at (1,2) with new data
3. Index now has TWO entries for id=2

### 4.1 Examine Heap After UPDATE

```sql
SELECT 
    t_ctid,
    lp,
    lp_flags,
    t_xmin,
    t_xmax,
    substr(t_data, 1, 30)
FROM heap_page_items(get_raw_page('demo', 0))
ORDER BY lp;
```

**Look for changes:**
```
 t_ctid | lp | lp_flags | t_xmin | t_xmax |           substr
--------+----+----------+--------+--------+---------------------------
 (0,1)  |  1 |        1 |   3231 |      0 | \x0000...787878 (still 'x')
 (0,2)  |  2 |        1 |   3231 |      0 | \x0100...787878
 (1,2)  |  3 |        1 |   3231 |   3232 | \x0200...787878 ← OLD VERSION
 (0,4)  |  4 |        1 |   3231 |      0 | \x0300...787878
 ...
```

**Critical observation:**
- Line pointer 3 (id=2) has `t_xmax = 3232` (deleted by transaction 3232)
- `t_ctid = (1,2)` points to new version in block 1

### 4.2 Check New Version in Block 1

```sql
SELECT 
    t_ctid,
    lp,
    lp_flags,
    t_xmin,
    t_xmax,
    substr(t_data, 1, 42)
FROM heap_page_items(get_raw_page('demo', 1))
ORDER BY lp;
```

**Expected Output:**
```
 t_ctid | lp | lp_len | lp_flags | t_xmin | t_xmax |           substr
--------+----+--------+----------+--------+--------+---------------------------
 (1,1)  |  1 |    536 |        1 |   3231 |      0 | \x0f00...787878 (id=15)
 (1,2)  |  2 |    536 |        1 |   3232 |      0 | \x0200...585858 ← NEW (X→X)
```

**Notice:** New version has uppercase X's (hex 58 instead of 78)!

### 4.3 Examine Index After UPDATE

```sql
SELECT 
    substr(data, 1, 42) as data_preview,
    itemoffset,
    htid,
    dead
FROM bt_page_items(get_raw_page('demo_pkey', 1))
ORDER BY data;
```

**Expected Output:**
```
         data_preview          | itemoffset |  htid  | dead
-------------------------------+------------+--------+------
 00 00 00 00 ... 78 78         |          2 | (0,1)  | f
 01 00 00 00 ... 78 78         |          3 | (0,2)  | f
 02 00 00 00 ... 58 58         |          5 | (1,2)  | f    ← NEW entry
 02 00 00 00 ... 78 78         |          4 | (0,3)  | f    ← OLD entry
 03 00 00 00 ... 78 78         |          6 | (0,4)  | f
 ...
```

**Critical Bloat Issue:**
- Index now has **TWO entries for id=2**
- One points to dead tuple (0,3)
- One points to live tuple (1,2)
- This is **space amplification** and **read amplification**

### 4.4 Verify Sizes Haven't Changed

```sql
SELECT 
    relname,
    pg_size_pretty(pg_table_size(oid)) as size
FROM pg_class 
WHERE relname LIKE 'demo%'
ORDER BY relname;
```

**Expected:**
```
  relname  | size
-----------+------
 demo      | 48 kB  -- No change (block already allocated)
 demo_pkey | 32 kB  -- No change
```

---

## Part 5: SELECT (Seq Scan) - First Cleanup Magic

```sql
-- Simple SELECT to read all rows
SELECT 
    ctid,
    id,
    xmin,
    xmax,
    substr(value, 1, 30),
    length(value)
FROM demo
ORDER BY id;
```

**Expected Output:**
```
  ctid  | id | xmin | xmax |           substr           | length
--------+----+------+------+----------------------------+--------
 (0,1)  |  0 | 3231 |    0 | xxxxxxxxxxxxxx...          |    500
 (0,2)  |  1 | 3231 |    0 | xxxxxxxxxxxxxx...          |    500
 (1,2)  |  2 | 3232 |    0 | XXXXXXXXXXXXXX...          |    500  ← NEW
 (0,4)  |  3 | 3231 |    0 | xxxxxxxxxxxxxx...          |    500
 ...
```

**Now check heap page again:**

```sql
SELECT 
    t_ctid,
    lp,
    lp_flags,
    lp_len,
    t_xmin,
    t_xmax
FROM heap_page_items(get_raw_page('demo', 0))
ORDER BY lp;
```

**🎉 SURPRISE! The page changed:**
```
 t_ctid | lp | lp_flags | lp_len | t_xmin | t_xmax
--------+----+----------+--------+--------+--------
 (0,1)  |  1 |        1 |    536 |   3231 |      0
 (0,2)  |  2 |        1 |    536 |   3231 |      0
        |  3 |        3 |      0 |        |        ← DEAD STUB!
 (0,4)  |  4 |        1 |    536 |   3231 |      0
 ...
```

**Critical Teaching Point:**
- `lp_flags = 3` means "dead" (redirect stub)
- `lp_len = 0` means **no data stored** (536 bytes reclaimed!)
- **A SELECT cleaned up the heap table WITHOUT VACUUM!**

---

## Part 6: SELECT (Index Scan) - Index Cleanup Magic

```sql
-- Query using index
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM demo WHERE id = 2;
```

**Expected Plan:**
```
Index Only Scan using demo_pkey on demo
  Index Cond: (id = 2)
  Heap Fetches: 2           ← Had to check both versions!
  Buffers: local hit=4      ← 2 index + 2 heap
```

**Why 2 heap fetches?**
- Index has 2 entries for id=2
- Must check heap to determine which is visible
- This is **read amplification**

**Run the same query again:**

```sql
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM demo WHERE id = 2;
```

**Expected Plan (improved):**
```
Index Only Scan using demo_pkey on demo
  Index Cond: (id = 2)
  Heap Fetches: 1           ← Only 1 now!
  Buffers: local hit=3      ← 1 fewer buffer
```

**Check the index again:**

```sql
SELECT 
    substr(data, 1, 30),
    itemoffset,
    htid,
    dead
FROM bt_page_items(get_raw_page('demo_pkey', 1))
ORDER BY data;
```

**🎉 SURPRISE! Dead flag changed:**
```
     data_preview          | itemoffset |  htid  | dead
---------------------------+------------+--------+------
 02 00 00 00 ... 58 58     |          5 | (1,2)  | f    ← LIVE
 02 00 00 00 ... 78 78     |          4 | (0,3)  | t    ← MARKED DEAD!
```

**Critical Teaching Point:**
- The first index scan **marked the entry as dead**
- Second scan skips the dead entry
- **Reads can modify state to reduce future read amplification!**
- But dead entry **still takes space** (520 bytes)

---

## Part 7: INSERT - Space Reuse in Heap

### 7.1 Insert Large Rows (Won't Fit)

```sql
-- Try to insert rows with same large size (500 bytes)
INSERT INTO demo
SELECT 
    generate_series(16, 1000),
    lpad('y', 500, 'y');

-- Check: 985 rows inserted
```

**Check block 0:**

```sql
SELECT 
    t_ctid,
    lp,
    lp_flags,
    lp_len
FROM heap_page_items(get_raw_page('demo', 0))
ORDER BY lp;
```

**Result:**
```
 t_ctid | lp | lp_flags | lp_len
--------+----+----------+--------
 (0,1)  |  1 |        1 |    536
 (0,2)  |  2 |        1 |    536
        |  3 |        3 |      0  ← Still dead, NOT reused
 (0,4)  |  4 |        1 |    536
 ...
```

**Why not reused?** The dead stub has 0 bytes free space, but new rows need 536 bytes!

### 7.2 Insert Smaller Rows (Will Fit)

```sql
-- Insert rows with smaller size (30 bytes)
INSERT INTO demo
SELECT 
    generate_series(3001, 4000),
    lpad('y', 30, 'y');  -- Much smaller!

-- Check: 1000 rows inserted
```

**Check block 0 again:**

```sql
SELECT 
    t_ctid,
    lp,
    lp_flags,
    lp_len,
    substr(t_data, 1, 30)
FROM heap_page_items(get_raw_page('demo', 0))
ORDER BY lp;
```

**🎉 SPACE REUSED!**
```
 t_ctid | lp | lp_flags | lp_len |           substr
--------+----+----------+--------+---------------------------
 (0,1)  |  1 |        1 |    536 | \x0000...787878
 (0,2)  |  2 |        1 |    536 | \x0100...787878
        |  3 |        3 |      0 | 
 (0,4)  |  4 |        1 |    536 | \x0300...787878
 ...
 (0,16) | 16 |        1 |     68 | \xe40b...797979 ← NEW ROW (id=3000)
 (0,17) | 17 |        1 |     68 | \xe50b...797979 ← NEW ROW (id=3001)
 (0,18) | 18 |        1 |     68 | \xe60b...797979
 ...
```

**Critical Teaching Point:**
- **Heap tables CAN reuse dead tuple space without VACUUM!**
- Requires: New row must fit in available free space
- Dead stub (lp=3) remains as metadata (pointer placeholder)

---

## Part 8: DELETE Large Range - Preparing for Index Cleanup

```sql
-- Delete a large range affecting entire index page
DELETE FROM demo WHERE id <= 13;

-- Check: 14 rows deleted
```

### 8.1 Check Heap Table

```sql
SELECT 
    t_ctid,
    lp,
    lp_flags,
    t_xmin,
    t_xmax
FROM heap_page_items(get_raw_page('demo', 0))
ORDER BY lp;
```

**Expected:**
```
 t_ctid | lp | lp_flags | t_xmin | t_xmax
--------+----+----------+--------+--------
 (0,1)  |  1 |        1 |   3231 |   3237  ← DELETED (xmax set)
 (0,2)  |  2 |        1 |   3231 |   3237  ← DELETED
        |  3 |        3 |        |         ← Already dead
 (0,4)  |  4 |        1 |   3231 |   3237  ← DELETED
 ...
 (0,14) | 14 |        1 |   3231 |   3237  ← DELETED
 (0,15) | 15 |        1 |   3231 |      0  ← STILL ALIVE (id=14)
 (0,16) | 16 |        1 |   3236 |      0  ← STILL ALIVE
 ...
```

### 8.2 Query the Deleted Range

```sql
-- Seq Scan will trigger cleanup
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM demo WHERE id <= 13;
```

**Expected:**
```
Seq Scan on demo
  Filter: (id <= 13)
  Rows Removed by Filter: 1987
  Buffers: local hit=21
  
Actual rows: 0  ← All deleted!
```

**Check heap again:**

```sql
SELECT 
    t_ctid,
    lp,
    lp_flags,
    lp_len
FROM heap_page_items(get_raw_page('demo', 0))
ORDER BY lp;
```

**🎉 ALL CLEANED!**
```
 t_ctid | lp | lp_flags | lp_len
--------+----+----------+--------
        |  1 |        3 |      0  ← DEAD STUB (was id=0)
        |  2 |        3 |      0  ← DEAD STUB (was id=1)
        |  3 |        3 |      0  ← DEAD STUB
        |  4 |        3 |      0  ← DEAD STUB (was id=3)
 ...
        | 14 |        3 |      0  ← DEAD STUB (was id=13)
 (0,15) | 15 |        1 |    536  ← ALIVE (id=14)
 (0,16) | 16 |        1 |     68  ← ALIVE (id=3000)
 ...
```

**Critical Teaching Point:**
- **Heap pages clean up automatically during scans**
- Dead tuples → Dead stubs (space reclaimed, metadata remains)
- **But index is still bloated!**

---

## Part 9: The Index Problem - Why VACUUM is Needed

### 9.1 Check Index Status

```sql
SELECT 
    substr(data, 1, 30),
    itemoffset,
    htid,
    dead
FROM bt_page_items(get_raw_page('demo_pkey', 1))
ORDER BY data;
```

**Expected:**
```
     data_preview          | itemoffset |  htid  | dead
---------------------------+------------+--------+------
 00 00 00 00 ...           |          2 | (0,1)  | f     ← Still there!
 01 00 00 00 ...           |          3 | (0,2)  | f     ← Still there!
 02 00 00 00 ... (new)     |          5 | (1,2)  | f
 02 00 00 00 ... (old)     |          4 | (0,3)  | t
 03 00 00 00 ...           |          6 | (0,4)  | f     ← Still there!
 ...
 0d 00 00 00 ...           |         15 | (0,13) | f     ← Still there!
```

**Critical Problem:**
- **Index still has entries for ALL deleted rows (id=0-13)**
- Each entry is 520 bytes
- Total bloat: 14 entries × 520 bytes = 7,280 bytes wasted!
- Dead flag might be set, but **space not reclaimed**

### 9.2 Check Sizes

```sql
SELECT 
    relname,
    pg_size_pretty(pg_table_size(oid)) as size
FROM pg_class 
WHERE relname LIKE 'demo%';
```

**Expected:**
```
  relname  | size
-----------+-------
 demo      | 200 kB  ← Grew (new rows)
 demo_pkey | 168 kB  ← Still bloated!
```

---

## Part 10: VACUUM - True Cleanup

```sql
-- Run VACUUM to reclaim index space
VACUUM demo;
```

### 10.1 Check Heap After VACUUM

```sql
SELECT 
    t_ctid,
    lp,
    lp_flags,
    lp_len
FROM heap_page_items(get_raw_page('demo', 0))
ORDER BY lp;
```

**Result:**
```
 t_ctid | lp | lp_flags | lp_len
--------+----+----------+--------
        |  1 |        0 |      0  ← UNUSED (not just dead!)
        |  2 |        0 |      0  ← UNUSED
        |  3 |        0 |      0  ← UNUSED
 ...
        | 14 |        0 |      0  ← UNUSED
 (0,15) | 15 |        1 |    536  ← ALIVE
 (0,16) | 16 |        1 |     68  ← ALIVE
 ...
```

**Key Change:**
- `lp_flags = 0` means "unused" (vs 3 = "dead")
- Line pointers remain but can be reused
- Space is marked as available in free space map

### 10.2 Check Index After VACUUM

```sql
SELECT 
    substr(data, 1, 30),
    itemoffset,
    htid,
    dead
FROM bt_page_items(get_raw_page('demo_pkey', 1))
ORDER BY data;
```

**🎉 ENTIRE PAGE RECLAIMED!**
```
NOTICE:  page is deleted
NOTICE:  page from block is deleted

(0 rows)
```

**What happened:**
- **ALL entries in this leaf page were dead**
- VACUUM removed entire page from index
- Page is now on free list for reuse
- **Space amplification eliminated!**

### 10.3 Check Sizes After VACUUM

```sql
SELECT 
    relname,
    pg_size_pretty(pg_table_size(oid)) as size
FROM pg_class 
WHERE relname LIKE 'demo%';
```

**Expected:**
```
  relname  | size
-----------+-------
 demo      | 208 kB  ← Slightly larger (FSM overhead)
 demo_pkey | 168 kB  ← No change yet (see Part 11)
```

**Why no size reduction?**
- Deleted pages marked as reusable, not removed from file
- File size stays same until VACUUM FULL or REINDEX

---

## Part 11: INSERT After VACUUM - Efficient Space Reuse

```sql
-- Insert rows in the deleted range
INSERT INTO demo
SELECT 
    generate_series(5000, 5013),
    lpad('x', 500, 'x');

-- Check: 14 rows inserted
```

### 11.1 Check Sizes

```sql
SELECT 
    relname,
    pg_size_pretty(pg_table_size(oid)) as size
FROM pg_class 
WHERE relname LIKE 'demo%';
```

**Result:**
```
  relname  | size
-----------+-------
 demo      | 208 kB  ← No change! (reused block 0)
 demo_pkey | 176 kB  ← Grew by 1 block (8KB)
```

**Why index grew:**
- New entries created in index
- But couldn't reuse deleted block 1 (PostgreSQL quirk)
- Would be fixed by REINDEX

---

## Part 12: REINDEX - Final Cleanup

```sql
-- Rebuild index without blocking reads/writes
REINDEX INDEX CONCURRENTLY demo_pkey;
```

**Check sizes:**

```sql
SELECT 
    relname,
    pg_size_pretty(pg_table_size(oid)) as size
FROM pg_class 
WHERE relname LIKE 'demo%';
```

**Result:**
```
  relname  | size
-----------+-------
 demo      | 208 kB
 demo_pkey | 168 kB  ← Back to optimal size!
```

**REINDEX completely rebuilt the index:**
- Removed all bloat
- Optimal page packing
- No wasted space

---

## Part 13: Summary Table - Cleanup Mechanisms

| Operation | Heap Table | B-Tree Index | Space Reclaimed | When It Happens |
|-----------|------------|--------------|-----------------|-----------------|
| **SELECT (Seq Scan)** | ✅ Converts dead tuples to stubs | ❌ No change | Partial (data only) | During scan |
| **SELECT (Index Scan)** | ❌ No change | ⚠️ Marks entries dead | None | During index traversal |
| **INSERT** | ✅ Reuses dead stubs if size fits | ❌ No reuse | Partial | When finding free space |
| **DELETE (then scan)** | ✅ Converts to dead stubs | ❌ No change | Partial (data only) | During scan |
| **VACUUM** | ✅ Marks unused, updates FSM | ✅ Removes entries, may delete pages | Full (metadata remains) | Manual or auto-vacuum |
| **REINDEX** | N/A | ✅ Completely rebuilds | Full | Manual |
| **VACUUM FULL** | ✅ Rebuilds table | ✅ Rebuilds all indexes | Full (file shrinks) | Manual (locks table) |

---

## Part 14: Key Takeaways

### 1. **Heap Tables Self-Clean (Mostly)**
- Seq Scans convert dead tuples → dead stubs (data freed)
- INSERTs can reuse dead stub space
- **But:** Line pointers remain until VACUUM

### 2. **Indexes Don't Self-Clean**
- Index Scans mark entries as dead (reduces read amplification)
- **But:** Dead entries keep taking space
- **Only VACUUM removes index bloat**

### 3. **MVCC Creates Two Types of Bloat**
- **Space Amplification:** Dead data taking disk space
- **Read Amplification:** Scanning dead tuples during queries

### 4. **Cleanup Hierarchy**
```
Automatic (during queries):
├── Heap: Dead tuple → Dead stub (536 bytes → 0 bytes)
└── Index: Live entry → Dead-marked entry (520 bytes → 520 bytes)

VACUUM:
├── Heap: Dead stub → Unused (ready for any size)
└── Index: Dead entry → Removed (520 bytes → 0 bytes)

REINDEX:
└── Index: Complete rebuild (optimal packing)

VACUUM FULL:
├── Heap: Complete rebuild with FILLFACTOR
└── All Indexes: Complete rebuild
```

### 5. **Why Auto-VACUUM Must Be Aggressive**
- Heap self-cleans data but not metadata
- Indexes don't self-clean at all
- Without VACUUM: Indexes grow indefinitely
- Read performance degrades (scanning dead entries)

### 6. **Production Recommendations**

**DO:**
- ✅ Let auto-vacuum run frequently
- ✅ Tune `autovacuum_vacuum_scale_factor` lower for high-update tables
- ✅ Use FILLFACTOR < 100 for frequently updated tables
- ✅ Monitor index bloat with pg_stat_user_indexes
- ✅ REINDEX CONCURRENTLY for severely bloated indexes

**DON'T:**
- ❌ Disable auto-vacuum (unless you know why)
- ❌ Use VACUUM FULL in production (blocks all access)
- ❌ Ignore pg_stat_user_tables.n_dead_tup
- ❌ Wait for bloat to become severe

---

## Part 15: Real Lab Results & Critical Observations

### 🎉 Actual Results from 10M Row Lab

Based on your execution with ~2,000 rows across the demo table:

---

### Observation 1: The Automatic Heap Cleanup Magic ✨

**After UPDATE (Part 4):**
```sql
-- Line pointer 3 before SELECT:
(1,2)  |  3 |        1 |    810 |    812 | ... ← Dead tuple with DATA

-- After running SELECT (Part 5):
       |  3 |        3 |      0 |        | ... ← Dead STUB, 536 bytes freed!
```

**Critical Teaching Point:**
- **A simple SELECT cleaned up 536 bytes WITHOUT VACUUM!**
- Heap pages self-clean during scans
- Dead tuple → Dead stub (keeps line pointer, frees data)
- This is PostgreSQL's "early cleanup" optimization

---

### Observation 2: Index Scan Reduced Read Amplification

**First Index Scan (Part 6):**
```
Heap Fetches: 1
Buffers: shared hit=3
```

**Your Result:** Only 1 heap fetch instead of expected 2!

**Why this happened:**
- The earlier SELECT (Part 5) already cleaned the heap
- Dead tuple (0,3) was converted to dead stub
- Index scan didn't need to check it
- **But index entry still marked as dead after scan**

**Index entry status:**
```
02 00 00 00 ... (old) |  4 | (0,3)  | t  ← Marked DEAD
```

---

### Observation 3: Space Reuse Without VACUUM (Part 7)

**After inserting 1000 small rows (30 bytes):**
```
Block 0 gained NEW rows:
 (0,16) | 16 |        1 |     63 | id=3025 (small row)
 (0,17) | 17 |        1 |     63 | id=3026
 ...
 (0,23) | 23 |        1 |     63 | id=3032

Dead stub (lp=3) still present:
        |  3 |        3 |      0 | ← Still a stub
```

**Critical Insight:**
- Small rows (63 bytes) fit in free space of block 0
- PostgreSQL reused available space WITHOUT VACUUM
- **But dead stub remains as metadata placeholder**
- Space efficiency: 536 bytes freed, 8×63=504 bytes reused

---

### Observation 4: DELETE + Seq Scan Mass Cleanup (Part 8)

**Before DELETE scan:**
```
14 rows with t_xmax=815 (deleted but data still there)
```

**After Seq Scan on deleted range:**
```
All 14 rows cleaned:
        |  1 |        3 |      0  ← Dead stub (was id=0, 536 bytes freed)
        |  2 |        3 |      0  ← Dead stub (was id=1, 536 bytes freed)
        ...
        | 14 |        3 |      0  ← Dead stub (was id=13, 536 bytes freed)

Total space reclaimed: 14 × 536 = 7,504 bytes
```

**Critical Teaching Point:**
- **Seq Scan cleaned ALL 14 dead tuples in one pass**
- Each tuple: 536 bytes → 0 bytes
- Heap table self-cleanup is VERY effective
- But index still has all 14 entries (bloated)

---

### Observation 5: Index Still Bloated Despite Heap Cleanup

**Index status after heap cleanup:**
```
All 14 deleted entries STILL in index:
 00 00 00 00 ... |  2 | (0,1)  | f  ← id=0, 520 bytes
 01 00 00 00 ... |  3 | (0,2)  | f  ← id=1, 520 bytes
 ...
 0c 00 00 00 ... | 15 | (0,13) | f  ← id=12, 520 bytes

Total index bloat: 14 × 520 = 7,280 bytes
```

**Why this is a problem:**
- Index scans must skip these entries
- Read amplification continues
- **Only VACUUM can remove them**

**Your sizes at this point:**
```
demo      | 632 kB  ← Heap grew (new inserts)
demo_pkey | 688 kB  ← Index bloated with dead entries
```

---

### Observation 6: VACUUM's Dramatic Index Cleanup (Part 10)

**After VACUUM:**
```sql
SELECT ... FROM bt_page_items(get_raw_page('demo_pkey', 1));

NOTICE:  page is deleted
NOTICE:  page from block is deleted

(0 rows)  ← ENTIRE PAGE REMOVED!
```

**What VACUUM did:**
1. **Heap:** Dead stubs (lp_flags=3) → Unused (lp_flags=0)
2. **Index:** Removed ALL 14 dead entries
3. **Index Page:** Entire leaf page deleted and marked for reuse

**Sizes after VACUUM:**
```
demo      | 640 kB  ← Slightly larger (FSM metadata)
demo_pkey | 688 kB  ← Stays same (page marked reusable, not truncated)
```

**Key insight:** VACUUM doesn't shrink files, it marks space as reusable.

---

### Observation 7: Post-VACUUM Insert Efficiency (Part 11)

**Inserted 14 large rows (500 bytes each):**
```
demo      | 640 kB  ← No change! Reused block 0
demo_pkey | 696 kB  ← Grew 8KB (1 new block)
```

**What this proves:**
- Heap efficiently reused freed space
- Index grew because new values (id=5000-5013) went to new range
- Index couldn't reuse deleted page 1 (PostgreSQL quirk with deleted pages)

---

### Observation 8: REINDEX Final Optimization (Part 12)

**After REINDEX CONCURRENTLY:**
```
demo      | 640 kB  ← No change
demo_pkey | 688 kB  ← Back to optimal!
```

**What REINDEX did:**
- Completely rebuilt index from scratch
- Optimal page packing
- Removed deleted page 1 from file structure
- **But took 13ms (very fast for small dataset)**

---

### 📊 Complete Cleanup Timeline - Your Lab

| Step | Operation | Heap Size | Index Size | Heap State | Index State |
|------|-----------|-----------|------------|------------|-------------|
| **Init** | INSERT 16 rows | 48 kB | 32 kB | All live | All live |
| **Step 1** | UPDATE id=2 | 48 kB | 32 kB | 1 dead tuple | 2 entries for id=2 |
| **Step 2** | SELECT (scan) | 48 kB | 32 kB | **Dead stub** | 1 entry marked dead |
| **Step 3** | INSERT 985 large | ~632 kB | ~688 kB | Dead stub remains | Bloat grows |
| **Step 4** | INSERT 1000 small | ~632 kB | ~688 kB | **Space reused!** | More bloat |
| **Step 5** | DELETE 14 rows | ~632 kB | ~688 kB | Marked deleted | Still bloated |
| **Step 6** | SELECT (scan) | ~632 kB | ~688 kB | **14 dead stubs** | Still bloated |
| **Step 7** | VACUUM | 640 kB | 688 kB | **14 unused** | **Page deleted** |
| **Step 8** | INSERT 14 rows | 640 kB | 696 kB | Reused block 0 | New block added |
| **Step 9** | REINDEX | 640 kB | **688 kB** | No change | **Optimal** |

---

### 🎯 Key Metrics Summary

#### Space Reclamation Efficiency

**Heap Table (Self-Cleaning):**
```
Dead tuples cleaned: 15 total (1 from UPDATE + 14 from DELETE)
Space reclaimed: 15 × 536 = 8,040 bytes
Method: Automatic during Seq Scans
When: Immediately during queries
Efficiency: ★★★★★ (Excellent)
```

**B-Tree Index (Needs VACUUM):**
```
Dead entries: 14 (ids 0-13)
Space bloated: 14 × 520 = 7,280 bytes
Cleanup method: VACUUM only
When: Manual or auto-vacuum trigger
Efficiency: ★★☆☆☆ (Poor without VACUUM)
```

#### Read Amplification Reduction

**Before cleanup:**
- Index has 2 entries for id=2
- Must check both heap locations
- Extra buffer reads

**After index scan:**
- Dead entry marked (dead=t)
- Future scans skip it
- Read amplification reduced

**After VACUUM:**
- Dead entry removed completely
- Only 1 entry for id=2
- Optimal read performance

---

### 💡 Critical Insights from Your Lab

#### 1. **Heap Self-Cleaning is Real**
```
Evidence: lp_flags changed 1→3 after SELECT
Space freed: 536 bytes per dead tuple
Sustainability: Works continuously without intervention
```

#### 2. **Index Bloat is Persistent**
```
Evidence: 688 kB index size even after heap cleanup
Space wasted: 7,280 bytes (14 dead entries)
Solution: Only VACUUM can fix
```

#### 3. **VACUUM is Critical for Indexes**
```
Your proof: Index page completely deleted after VACUUM
Notice: "page is deleted" message
Impact: Enables future space reuse
```

#### 4. **Space Reuse is Selective**
```
Large rows (500 bytes): Couldn't reuse dead stub (0 bytes free)
Small rows (63 bytes): Successfully reused free space
Key factor: Free space must fit new row
```

#### 5. **File Sizes Don't Shrink**
```
After VACUUM: 688 kB (same as before)
Why: Pages marked reusable, not removed from file
Solution: VACUUM FULL or pg_repack (with downtime)
```

---

### 🚀 Production Implications from Your Results

#### Auto-VACUUM Tuning Recommendations

```sql
-- For high-update tables like your demo:
ALTER TABLE demo SET (
    autovacuum_vacuum_scale_factor = 0.05,  -- Trigger at 5% dead tuples
    autovacuum_vacuum_threshold = 50,       -- Minimum 50 dead tuples
    autovacuum_vacuum_cost_delay = 10       -- Don't throttle too much
);
```

**Why:** Your lab showed 14 dead tuples created 7KB+ bloat. At scale, this becomes severe quickly.

#### Monitoring Query

```sql
-- Check if your tables need VACUUM
SELECT 
    schemaname || '.' || relname as table_name,
    n_live_tup,
    n_dead_tup,
    round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 1) as pct_dead,
    pg_size_pretty(pg_total_relation_size(relid)) as total_size,
    last_vacuum,
    last_autovacuum
FROM pg_stat_user_tables
WHERE n_dead_tup > 100
ORDER BY n_dead_tup DESC;
```

#### Index Bloat Detection

```sql
-- Estimate index bloat
SELECT 
    schemaname,
    tablename,
    indexname,
    pg_size_pretty(pg_relation_size(indexrelid)) as index_size,
    idx_scan,
    CASE 
        WHEN idx_scan = 0 THEN 'UNUSED - Consider DROP'
        WHEN idx_tup_read::float / NULLIF(idx_tup_fetch, 0) > 2 
        THEN 'HIGH READ AMPLIFICATION - Consider REINDEX'
        ELSE 'OK'
    END as status
FROM pg_stat_user_indexes
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY pg_relation_size(indexrelid) DESC;
```

---

### 📚 Final Teaching Summary

Your lab perfectly demonstrated Frank Pachot's key lessons:

1. **PostgreSQL has surprising self-cleaning mechanisms**
   - ✅ Proven: Dead tuples → Dead stubs during SELECTs
   - ✅ Proven: Small rows reuse freed space

2. **But these mechanisms are incomplete**
   - ✅ Proven: Indexes don't self-clean
   - ✅ Proven: Line pointers remain until VACUUM

3. **VACUUM is essential, not optional**
   - ✅ Proven: Index page deletion after VACUUM
   - ✅ Proven: Space marked reusable (not shrunk)

4. **Auto-VACUUM must be tuned aggressively**
   - ✅ Your evidence: 14 rows = 7KB bloat immediately
   - ✅ Scale this to millions of updates = GBs of bloat

5. **Monitoring is critical**
   - ✅ Track n_dead_tup regularly
   - ✅ Watch for idx_tup_read amplification
   - ✅ REINDEX when bloat exceeds 30-40%

---

## Part 16: Monitoring Queries

### 16.1 Check Dead Tuples

```sql
SELECT 
    schemaname,
    relname,
    n_live_tup,
    n_dead_tup,
    n_dead_tup::float / NULLIF(n_live_tup, 0) as dead_ratio,
    last_vacuum,
    last_autovacuum
FROM pg_stat_user_tables
WHERE relname = 'demo';
```

### 15.2 Check Index Bloat (Estimate)

```sql
SELECT 
    relname,
    pg_size_pretty(pg_relation_size(indexrelid)) as size,
    idx_scan,
    idx_tup_read,
    idx_tup_fetch,
    idx_tup_read::float / NULLIF(idx_tup_fetch, 0) as read_amplification
FROM pg_stat_user_indexes
WHERE relname = 'demo';
```

### 15.3 Find Tables Needing VACUUM

```sql
SELECT 
    schemaname || '.' || relname as table,
    n_dead_tup,
    n_live_tup,
    round(100.0 * n_dead_tup / NULLIF(n_live_tup, 0), 1) as pct_dea
