# PostgreSQL Partition Attach/Detach RUNBOOK

## Table of Contents
- [Objective](#objective)
- [What Does This Feature Do?](#what-does-this-feature-do)
- [Prerequisites](#prerequisites)
- [Standard Operations](#standard-operations)
- [Verification Commands](#verification-commands)
- [Important Notes & Gotchas](#important-notes--gotchas)
- [Regular Engineering Task Workflow](#regular-engineering-task-workflow)
- [Questions Before Starting](#questions-before-starting)
- [Emergency Rollback](#emergency-rollback)
- [Contact & Escalation](#contact--escalation)

---

## Objective

This runbook covers PostgreSQL's partition attach/detach feature, which allows you to move partitions between tables **without copying data**. This is a metadata-only operation that enables instant archival, reorganization, and maintenance of partitioned tables.

---

## What Does This Feature Do?

### Core Capability

- **Detach**: Removes a partition from a partitioned table (becomes standalone table)
- **Attach**: Adds an existing table as a partition to a partitioned table
- **Zero-copy**: No data movement - only metadata changes
- **Instant**: Operations complete in milliseconds regardless of partition size
- **Reversible**: Partitions can be moved back and forth between tables

### Common Use Cases

1. **Data Archival**: Move old partitions to archive tables
2. **Storage Tiering**: Move cold data to cheaper/compressed storage
3. **Index Optimization**: Drop heavy indexes on old data
4. **Data Enrichment**: Add columns to historical data offline
5. **Regional Splitting**: Separate data by geography
6. **Maintenance**: Isolate partitions for repairs/cleanup

---

## Prerequisites

### Check Your Environment

```sql
-- Verify PostgreSQL version (18+ recommended for best features)
SELECT version();

-- List all partitioned tables
SELECT 
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as size
FROM pg_tables 
WHERE tablename LIKE '%_part%'
ORDER BY tablename;

-- View partition structure
\d+ your_partitioned_table
```

### Critical Constraint

**DEFAULT PARTITIONS BLOCK CONCURRENT DETACH**

```sql
-- Check for default partition
SELECT tablename FROM pg_tables 
WHERE tablename LIKE '%_default';

-- If exists and empty, remove it first
SELECT COUNT(*) FROM your_table_default;

ALTER TABLE your_partitioned_table 
DETACH PARTITION your_table_default;
```

---

## Standard Operations

### Operation 1: Archive Old Partition

**Scenario**: Move 1995 data from main table to archive

```sql
-- Step 1: Create archive table (one-time setup)
CREATE TABLE uk_price_paid_archive (
    LIKE uk_price_paid_pg_part INCLUDING ALL
) PARTITION BY RANGE (date);

-- Step 2: Remove default partition if exists
ALTER TABLE uk_price_paid_pg_part 
DETACH PARTITION uk_price_paid_pg_part_default;

-- Step 3: Detach partition (use CONCURRENTLY for production)
ALTER TABLE uk_price_paid_pg_part 
DETACH PARTITION uk_price_paid_pg_part_p19950101 CONCURRENTLY;

-- Step 4: Attach to archive
ALTER TABLE uk_price_paid_archive 
ATTACH PARTITION uk_price_paid_pg_part_p19950101 
FOR VALUES FROM ('1995-01-01') TO ('1996-01-01');

-- Step 5: Verify
SELECT COUNT(*) FROM uk_price_paid_archive;

SELECT COUNT(*) FROM uk_price_paid_pg_part 
WHERE date >= '1995-01-01' AND date < '1996-01-01'; -- Should be 0
```

**Result**: 797,088 rows moved instantly (147 MB stayed in same location)

---

### Operation 2: Optimize Indexes on Old Data

**Scenario**: Drop unnecessary indexes from archived partitions

```sql
-- Step 1: Detach partition
ALTER TABLE uk_price_paid_pg_part 
DETACH PARTITION uk_price_paid_pg_part_p19950101;

-- Step 2: Check current indexes
\d uk_price_paid_pg_part_p19950101

-- Step 3: Drop heavy indexes not needed for old data
DROP INDEX IF EXISTS uk_price_paid_pg_part_p19950101_type_price_idx;
DROP INDEX IF EXISTS uk_price_paid_pg_part_p1995010_town_district_postcode1_type_idx;
DROP INDEX IF EXISTS uk_price_paid_pg_part_p199501_postcode1_town_district_type__idx;

-- Step 4: Check space savings
SELECT pg_size_pretty(pg_total_relation_size('uk_price_paid_pg_part_p19950101'));
-- Before: 147 MB → After: 141 MB (6 MB saved)

-- Step 5: Reattach
ALTER TABLE uk_price_paid_archive 
ATTACH PARTITION uk_price_paid_pg_part_p19950101 
FOR VALUES FROM ('1995-01-01') TO ('1996-01-01');
```

**Space Savings**: 6 MB per partition (scales with more partitions)

---

### Operation 3: Add Computed Column to Historical Data

**Scenario**: Enrich old data without impacting production table

```sql
-- Step 1: Detach partition
ALTER TABLE uk_price_paid_pg_part 
DETACH PARTITION uk_price_paid_pg_part_p19960101;

-- Step 2: Add new column
ALTER TABLE uk_price_paid_pg_part_p19960101 
ADD COLUMN price_2024_adjusted integer;

-- Step 3: Populate (runs on standalone table, no production impact)
UPDATE uk_price_paid_pg_part_p19960101 
SET price_2024_adjusted = price * 2; -- 965,338 rows updated

-- Step 4: Verify
SELECT AVG(price), AVG(price_2024_adjusted) 
FROM uk_price_paid_pg_part_p19960101;

-- Step 5: IMPORTANT - Cannot reattach to original table (schema mismatch)
-- Option A: Keep as standalone enriched table
-- Option B: Add column to main table first, then reattach
```

**Schema Compatibility Rule**: Partition must match parent table schema to attach

---

### Operation 4: Regional Data Split

**Scenario**: Separate London data for specialized analysis

```sql
-- Step 1: Create regional table
CREATE TABLE uk_price_paid_london (
    LIKE uk_price_paid_pg_part INCLUDING ALL
) PARTITION BY RANGE (date);

-- Step 2: Detach source partition
ALTER TABLE uk_price_paid_pg_part 
DETACH PARTITION uk_price_paid_pg_part_p20200101;

-- Step 3: Check regional distribution
SELECT COUNT(*) 
FROM uk_price_paid_pg_part_p20200101 
WHERE town ILIKE '%london%';
-- Found: 59,639 London transactions out of ~896k total

-- Step 4: Split data
CREATE TABLE uk_price_paid_london_p20200101 AS
SELECT * FROM uk_price_paid_pg_part_p20200101
WHERE town ILIKE '%london%';

CREATE TABLE uk_price_paid_rest_p20200101 AS
SELECT * FROM uk_price_paid_pg_part_p20200101
WHERE town NOT ILIKE '%london%';

-- Step 5: Attach to respective tables
ALTER TABLE uk_price_paid_london 
ATTACH PARTITION uk_price_paid_london_p20200101 
FOR VALUES FROM ('2020-01-01') TO ('2021-01-01');

-- Original partition can be dropped or attached to "rest" table
DROP TABLE uk_price_paid_pg_part_p20200101;
```

---

## Verification Commands

### Confirm Physical Table Identity

```sql
-- Same OID = same physical file (no copy occurred)
SELECT
    'partition_name'::regclass::oid as table_oid,
    pg_relation_filepath('partition_name') as file_path;

-- Run before and after attach/detach - OID should be identical
```

**Example Output**:
```
 table_oid |  file_path
-----------+--------------
     16936 | base/5/16936
```

### Check Partition Relationships

```sql
SELECT 
    nmsp_parent.nspname AS parent_schema,
    parent.relname AS parent,
    child.relname AS child
FROM pg_inherits
JOIN pg_class parent ON pg_inherits.inhparent = parent.oid
JOIN pg_class child ON pg_inherits.inhrelid = child.oid
JOIN pg_namespace nmsp_parent ON parent.relnamespace = nmsp_parent.oid
WHERE parent.relname = 'your_partitioned_table'
ORDER BY child.relname;
```

### Query Across Multiple Tables

```sql
-- Union queries work seamlessly
SELECT COUNT(*), AVG(price), EXTRACT(YEAR FROM date) as year
FROM (
    SELECT * FROM uk_price_paid_pg_part
    UNION ALL
    SELECT * FROM uk_price_paid_archive
) combined
GROUP BY year
ORDER BY year;
```

### Check Partition Sizes

```sql
SELECT 
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as size
FROM pg_tables 
WHERE tablename LIKE 'uk_price_paid_pg_part_p%'
ORDER BY tablename;
```

---

## Important Notes & Gotchas

### ⚠️ CONCURRENTLY Restrictions

- **Cannot use CONCURRENTLY if default partition exists**
- **Solution**: Detach default partition first
- **Without CONCURRENTLY**: Brief table lock during detach

```sql
-- Error you'll see:
ERROR:  cannot detach partitions concurrently when a default partition exists

-- Fix:
ALTER TABLE parent_table DETACH PARTITION parent_table_default;
```

### ⚠️ Schema Compatibility

- Partition must have **exact same columns** as parent to attach
- **Check constraints** are preserved when detached
- **Indexes** remain but are independent after detach
- **NOT NULL constraints** are inherited

### ⚠️ Production Safety

```sql
-- Always use CONCURRENTLY in production
ALTER TABLE parent_table 
DETACH PARTITION partition_name CONCURRENTLY;

-- If interrupted, finalize later
ALTER TABLE parent_table 
DETACH PARTITION partition_name FINALIZE;
```

### ⚠️ Rollback Plan

Operations are reversible - keep detach/attach commands handy:

```sql
-- If something goes wrong, reverse immediately
ALTER TABLE archive_table DETACH PARTITION partition_name;

ALTER TABLE original_table 
ATTACH PARTITION partition_name 
FOR VALUES FROM ('start_date') TO ('end_date');
```

### ⚠️ Check Constraints Are Preserved

```sql
-- After detach, partition keeps its range constraint
\d partition_name

-- Example output:
Check constraints:
    "partition_name_date_check" CHECK (date >= '1995-01-01' AND date < '1996-01-01')
```

---

## Regular Engineering Task Workflow

**When**: Monthly archival of data older than 5 years

**Duration**: ~5-10 minutes per partition

### Step-by-Step Process

```sql
-- 1. Identify partitions to archive
SELECT tablename 
FROM pg_tables 
WHERE tablename LIKE 'uk_price_paid_pg_part_p%'
  AND tablename < 'uk_price_paid_pg_part_p' || 
      TO_CHAR(CURRENT_DATE - INTERVAL '5 years', 'YYYYMMDD')
ORDER BY tablename;

-- 2. Remove default partition (if exists)
ALTER TABLE uk_price_paid_pg_part 
DETACH PARTITION uk_price_paid_pg_part_default;

-- 3. Detach and archive (repeat for each partition)
ALTER TABLE uk_price_paid_pg_part 
DETACH PARTITION uk_price_paid_pg_part_pYYYYMMDD CONCURRENTLY;

ALTER TABLE uk_price_paid_archive 
ATTACH PARTITION uk_price_paid_pg_part_pYYYYMMDD 
FOR VALUES FROM ('YYYY-MM-DD') TO ('YYYY-MM-DD');

-- 4. Optional: Optimize archived partition
-- Drop unnecessary indexes
DROP INDEX IF EXISTS partition_name_heavy_index;

-- Move to compressed storage
ALTER TABLE partition_name SET TABLESPACE cold_storage;

-- 5. Reattach default if needed
ALTER TABLE uk_price_paid_pg_part 
ATTACH PARTITION uk_price_paid_pg_part_default DEFAULT;

-- 6. Verify row counts match before/after
SELECT 
    'Main Table' as location,
    COUNT(*) as rows
FROM uk_price_paid_pg_part
UNION ALL
SELECT 
    'Archive',
    COUNT(*)
FROM uk_price_paid_archive;
```

### Automation Script Template

```bash
#!/bin/bash
# Archive partitions older than 5 years

CUTOFF_DATE=$(date -d "5 years ago" +%Y%m%d)
PARTITIONS=$(psql -t -c "SELECT tablename FROM pg_tables 
                         WHERE tablename LIKE 'uk_price_paid_pg_part_p%' 
                         AND tablename < 'uk_price_paid_pg_part_p${CUTOFF_DATE}'")

for partition in $PARTITIONS; do
    echo "Archiving $partition..."
    
    # Extract date range from partition name
    YEAR=${partition:25:4}
    START_DATE="${YEAR}-01-01"
    END_DATE="$((YEAR+1))-01-01"
    
    # Detach and archive
    psql -c "ALTER TABLE uk_price_paid_pg_part 
             DETACH PARTITION ${partition} CONCURRENTLY;"
    
    psql -c "ALTER TABLE uk_price_paid_archive 
             ATTACH PARTITION ${partition} 
             FOR VALUES FROM ('${START_DATE}') TO ('${END_DATE}');"
    
    echo "✓ Archived $partition"
done
```

---

## Questions Before Starting

### Pre-Flight Checklist

- [ ] **Does the table have a default partition?** → Must detach first
- [ ] **Is this production?** → Use CONCURRENTLY
- [ ] **Do schemas match?** → Check column definitions match exactly
- [ ] **What's the partition key?** → Need exact range values for ATTACH
- [ ] **Is rollback plan ready?** → Keep reverse commands handy
- [ ] **Are there foreign keys?** → May complicate detach operations
- [ ] **Is monitoring in place?** → Watch for query plan changes
- [ ] **Have you tested in non-prod?** → Always test first
- [ ] **Is there a maintenance window?** → Non-concurrent detach needs brief lock
- [ ] **Are backups current?** → Safety first

### Key Information to Gather

```sql
-- Get partition range
SELECT 
    pt.relname AS partition_name,
    pg_get_expr(c.relpartbound, c.oid) AS partition_bounds
FROM pg_class c
JOIN pg_inherits i ON c.oid = i.inhrelid
JOIN pg_class pt ON pt.oid = i.inhparent
WHERE pt.relname = 'your_partitioned_table'
ORDER BY c.relname;

-- Check for dependencies
SELECT 
    conname,
    contype,
    pg_get_constraintdef(oid)
FROM pg_constraint
WHERE conrelid = 'partition_name'::regclass;
```

---

## Emergency Rollback

### Quick Rollback Procedure

If an operation causes issues:

```sql
-- Immediate rollback example
BEGIN;

-- Detach from problematic location
ALTER TABLE new_location DETACH PARTITION partition_name;

-- Reattach to original location
ALTER TABLE original_location 
ATTACH PARTITION partition_name 
FOR VALUES FROM ('start_date') TO ('end_date');

-- Verify data is accessible
SELECT COUNT(*) FROM original_location WHERE date >= 'start_date' AND date < 'end_date';

COMMIT;
```

### Recovery Scenarios

**Scenario 1: Detach completed but attach failed**

```sql
-- Partition is standalone, just reattach to original
ALTER TABLE original_table 
ATTACH PARTITION partition_name 
FOR VALUES FROM ('start') TO ('end');
```

**Scenario 2: Schema mismatch on attach**

```sql
-- Drop added columns or add to parent first
ALTER TABLE partition_name DROP COLUMN new_column;

-- Or add to parent
ALTER TABLE parent_table ADD COLUMN new_column type;
```

**Scenario 3: Production queries failing**

```sql
-- Emergency reattach to main table
ALTER TABLE archive_table DETACH PARTITION partition_name;
ALTER TABLE main_table ATTACH PARTITION partition_name FOR VALUES ...;

-- Investigate issue offline later
```

---

## Contact & Escalation

### Support Channels

- **DBA Team**: dba-team@company.com
- **Slack Channel**: #database-ops
- **On-Call**: Page "Database-Oncall" in PagerDuty
- **Escalation**: Staff DBREs on-call rotation

### Related Documentation

- [Partition Strategy Guide](link-to-docs)
- [Storage Tier Policy](link-to-docs)
- [PostgreSQL 18 Release Notes](https://www.postgresql.org/docs/18/release-18.html)

### Monitoring & Alerts

- **Grafana Dashboard**: [Partition Operations](link-to-dashboard)
- **Alert Rules**: `partition_detach_duration`, `partition_size_anomaly`
- **Logs**: Check `/var/log/postgresql/` for operation timing

---

## Appendix

### Common Error Messages

| Error | Cause | Solution |
|-------|-------|----------|
| `cannot detach partitions concurrently when a default partition exists` | Default partition exists | Detach default partition first |
| `partition constraint is violated by some row` | Data doesn't match range | Fix data or use correct range values |
| `relation "partition_name" does not exist` | Typo in partition name | Check exact name with `\dt` |
| `cannot attach table with incompatible columns` | Schema mismatch | Align schemas before attach |

### Performance Metrics

From testing on `uk_price_paid_pg_part`:

- **Detach time**: < 100ms (metadata only)
- **Attach time**: < 100ms (metadata only)
- **Index drop savings**: ~6 MB per partition (varies)
- **Partitions archived**: 797,088 rows in 147 MB = instant

### Quick Reference Commands

```sql
-- List all partitions of a table
\d+ partitioned_table_name

-- Get partition file location
SELECT pg_relation_filepath('partition_name');

-- Check partition size
SELECT pg_size_pretty(pg_total_relation_size('partition_name'));

-- View partition constraints
SELECT pg_get_expr(relpartbound, oid) FROM pg_class WHERE relname = 'partition_name';
```

---

**Document Version**: 1.0  
**Last Updated**: December 2025  
**PostgreSQL Version**: 18  
**Review Frequency**: Quarterly  
**Next Review Date**: March 2026  
**Document Owner**: Database Engineering Team

---

## Changelog

| Date | Version | Changes | Author |
|------|---------|---------|--------|
| 2025-12-18 | 1.0 | Initial release | Platform DBRE Team |

---

**End of Runbook**
