# Production Postgres Index Optimization Runbook
## Platform DBRE Edition - RDS/Aurora PostgreSQL 13-17

**Owner:** Staff DBRE  
**Last Updated:** 2025-12-16  
**Environments:** RDS PostgreSQL 13-17, Aurora PostgreSQL  
**Automation:** Bash, psql, AWS CLI  
**Alerting:** Slack, PagerDuty  

---

## Table of Contents
1. [Quick Reference](#quick-reference)
2. [Emergency Response](#emergency-response)
3. [Daily/Weekly Operations](#daily-weekly-operations)
4. [Index Health Monitoring](#index-health-monitoring)
5. [Safe Optimization Procedures](#safe-optimization-procedures)
6. [Automation Scripts](#automation-scripts)
7. [Rollback Procedures](#rollback-procedures)
8. [Capacity Planning](#capacity-planning)

---

## Quick Reference

### When to Use This Runbook

| Symptom | Root Cause | Section to Use |
|---------|-----------|----------------|
| Storage alert fired | Index bloat | §4.1 Bloat Detection |
| P95 latency spike | Missing partial index | §5.2 Partial Index Creation |
| High write latency | Too many indexes | §5.5 Index Retirement |
| Query timeout | Full table scan | §4.2 Missing Index Detection |
| Storage cost spike | Unused indexes | §5.5 Index Retirement |
| Replication lag | Write amplification | §5.4 Index Consolidation |

### Critical Safety Rules

```bash
# ✅ ALWAYS use CONCURRENTLY for production
CREATE INDEX CONCURRENTLY ...
DROP INDEX CONCURRENTLY ...
REINDEX INDEX CONCURRENTLY ...

# ❌ NEVER drop constraints
# Check first: SELECT contype FROM pg_constraint WHERE conname = 'index_name';
# If contype IN ('p','u','f') -> DO NOT DROP

# ✅ ALWAYS test in staging first (when available)
# Exception: Hot fixes during incidents with Staff DBRE approval (you)

# ✅ ALWAYS capture baseline before changes
# See §4.3 Baseline Capture
```

### Emergency Contacts
- **Staff DBRE (You):** Primary on-call
- **Slack:** `#database-ops` (alerts) `#incidents` (active)
- **PagerDuty:** Database escalation policy
- **Runbook Updates:** This document in `docs/runbooks/postgres-index-optimization.md`

---

## Emergency Response

### 2.1 Index-Related Incident Response

**Incident: Storage Full / Approaching Limit**

```bash
#!/bin/bash
# incident-storage-full.sh
# Run this immediately when storage alert fires

DB_HOST="prod-db.cluster-xxx.us-east-1.rds.amazonaws.com"
DB_NAME="production"
DB_USER="dbre_admin"

echo "=== INCIDENT: Storage Critical ==="
echo "Time: $(date)"
echo "Database: $DB_NAME"

# 1. Immediate assessment
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
SELECT 
  pg_size_pretty(pg_database_size('$DB_NAME')) as current_size,
  pg_size_pretty(pg_database_size('$DB_NAME') * 1.2) as projected_24h,
  'RDS Max varies by instance' as limit_note;
"

# 2. Find biggest unused indexes (safe to drop immediately)
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
SELECT 
  schemaname || '.' || indexrelname as full_index_name,
  pg_size_pretty(pg_relation_size(indexrelid)) as size,
  idx_scan as scans,
  'DROP INDEX CONCURRENTLY ' || schemaname || '.' || indexrelname || ';' as drop_command
FROM pg_stat_user_indexes
WHERE idx_scan = 0 
  AND schemaname = 'users'
  AND pg_relation_size(indexrelid) > 100000000  -- >100MB
  AND indexrelname NOT LIKE '%_pkey'  -- Never drop PKs
  AND indexrelname NOT LIKE '%_key'   -- Likely unique constraints
ORDER BY pg_relation_size(indexrelid) DESC
LIMIT 10;
" | tee /tmp/emergency-drop-candidates.txt

echo ""
echo "=== DECISION POINT ==="
echo "Review drop candidates above. Verify they're NOT constraints:"

# 3. Verify these aren't backing constraints
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
SELECT 
  i.indexrelname,
  c.contype,
  CASE c.contype
    WHEN 'p' THEN '❌ PRIMARY KEY - DO NOT DROP'
    WHEN 'u' THEN '❌ UNIQUE - DO NOT DROP'
    WHEN 'f' THEN '❌ FOREIGN KEY - DO NOT DROP'
    ELSE '✅ Safe to drop if unused'
  END as safety
FROM pg_stat_user_indexes i
LEFT JOIN pg_constraint c ON c.conname = i.indexrelname
WHERE i.idx_scan = 0 
  AND i.schemaname = 'users'
  AND pg_relation_size(i.indexrelid) > 100000000;
"

echo ""
echo "To drop safe indexes, copy commands from /tmp/emergency-drop-candidates.txt"
echo "Run each DROP INDEX CONCURRENTLY command manually"
echo "Monitor: watch -n 5 'psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c \"SELECT pg_size_pretty(pg_database_size(\'$DB_NAME\'))\"'"
```

**Run immediately:**
```bash
chmod +x incident-storage-full.sh
./incident-storage-full.sh
```

**Post-incident:**
- Update `#incidents` Slack with space freed
- Schedule §4 health check within 24h
- Document in incident postmortem

---

**Incident: Query Timeouts / P95 Spike**

```bash
#!/bin/bash
# incident-query-timeout.sh

DB_HOST="prod-db.cluster-xxx.us-east-1.rds.amazonaws.com"
DB_NAME="production"
DB_USER="dbre_admin"

echo "=== INCIDENT: Query Performance Degradation ==="

# 1. Find currently slow queries
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
SELECT 
  pid,
  now() - query_start as duration,
  state,
  substring(query, 1, 100) as query_snippet
FROM pg_stat_activity
WHERE state = 'active'
  AND now() - query_start > interval '5 seconds'
ORDER BY query_start;
"

# 2. Find queries with highest total time (last 30 days)
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
SELECT 
  substring(query, 1, 150) as query,
  calls,
  round(total_exec_time::numeric, 2) as total_time_sec,
  round(mean_exec_time::numeric, 2) as avg_ms,
  round((total_exec_time / sum(total_exec_time) OVER ()) * 100, 2) as pct_total_time
FROM pg_stat_statements
WHERE calls > 100
ORDER BY total_exec_time DESC
LIMIT 20;
" | tee /tmp/slow-queries.txt

echo ""
echo "Review /tmp/slow-queries.txt for patterns"
echo "Look for:"
echo "  - Queries with high calls + moderate avg_ms (death by 1000 cuts)"
echo "  - Queries filtering on status/deleted_at (partial index candidates)"
echo "  - Queries with avg_ms > 50ms (immediate optimization target)"
```

**Analysis workflow:**
1. Run script above
2. For each top query, get EXPLAIN plan:
```bash
# Extract actual query from pg_stat_statements
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
SELECT query FROM pg_stat_statements 
WHERE query LIKE '%your_table%' 
LIMIT 1;
" | tee /tmp/full-query.sql

# Get execution plan
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
EXPLAIN (ANALYZE, BUFFERS) 
<paste query from /tmp/full-query.sql>;
"
```
3. Look for "Seq Scan" on large tables → missing index
4. Look for "Index Scan" reading >10K rows → partial index opportunity
5. Proceed to §5 for optimization

---

### 2.2 Incident Postmortem Template

```markdown
# Incident: [Index-Related Performance Issue]

**Date:** YYYY-MM-DD
**Duration:** Xh Ym
**Severity:** P1/P2/P3
**DBRE:** Your Name

## Impact
- P95 latency: Xms → Yms
- Error rate: X%
- Affected queries: [list]

## Root Cause
- Missing index on [table].[column]
- Index bloat on [index_name] (size: XGB)
- Too many indexes on [table] (N indexes, M unused)

## Resolution
- Created partial index: [SQL]
- Dropped unused indexes: [list]
- Storage freed: XGB
- P95 latency: Yms → Zms

## Prevention
- [ ] Add monitoring for [specific metric]
- [ ] Update §8 capacity planning
- [ ] Schedule weekly index health check
```

---

## Daily/Weekly Operations

### 3.1 Daily Health Check (5 minutes)

```bash
#!/bin/bash
# daily-index-health.sh
# Run: 0 8 * * * /path/to/daily-index-health.sh

DB_HOST="prod-db.cluster-xxx.us-east-1.rds.amazonaws.com"
DB_NAME="production"
DB_USER="dbre_admin"
SLACK_WEBHOOK="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"

echo "=== Daily Index Health Check - $(date) ===" > /tmp/daily-health.txt

# Storage trending
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
SELECT 
  pg_size_pretty(pg_database_size('$DB_NAME')) as total_db_size,
  pg_size_pretty(
    (SELECT sum(pg_relation_size(indexrelid)) 
     FROM pg_stat_user_indexes 
     WHERE schemaname = 'users')
  ) as total_index_size;
" >> /tmp/daily-health.txt

# New large indexes (created yesterday)
NEW_INDEXES=$(psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -c "
SELECT count(*) 
FROM pg_stat_user_indexes 
WHERE schemaname = 'users'
  AND pg_relation_size(indexrelid) > 100000000
  AND idx_scan = 0;
")

if [ "$NEW_INDEXES" -gt 0 ]; then
  echo "⚠️  Warning: $NEW_INDEXES large unused indexes detected" >> /tmp/daily-health.txt
  
  psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
  SELECT 
    schemaname || '.' || indexrelname as index_name,
    pg_size_pretty(pg_relation_size(indexrelid)) as size,
    idx_scan as scans
  FROM pg_stat_user_indexes
  WHERE schemaname = 'users'
    AND pg_relation_size(indexrelid) > 100000000
    AND idx_scan = 0;
  " >> /tmp/daily-health.txt
fi

# Send to Slack
cat /tmp/daily-health.txt
curl -X POST -H 'Content-type: application/json' \
  --data "{\"text\":\"$(cat /tmp/daily-health.txt | sed 's/"/\\"/g')\"}" \
  $SLACK_WEBHOOK
```

**Setup:**
```bash
chmod +x daily-index-health.sh
# Add to cron:
crontab -e
# Add: 0 8 * * * /path/to/daily-index-health.sh
```

---

### 3.2 Weekly Deep Dive (30 minutes)

```bash
#!/bin/bash
# weekly-index-audit.sh
# Run: 0 9 * * MON /path/to/weekly-index-audit.sh

DB_HOST="prod-db.cluster-xxx.us-east-1.rds.amazonaws.com"
DB_NAME="production"
DB_USER="dbre_admin"
REPORT_DIR="/var/log/postgres-audits"

mkdir -p $REPORT_DIR
REPORT_FILE="$REPORT_DIR/index-audit-$(date +%Y%m%d).txt"

echo "=== Weekly Index Audit - $(date) ===" > $REPORT_FILE

# 1. Storage breakdown
echo -e "\n## Storage Breakdown\n" >> $REPORT_FILE
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
SELECT 
  schemaname,
  tablename,
  pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) as total_size,
  pg_size_pretty(pg_relation_size(schemaname||'.'||tablename)) as table_size,
  pg_size_pretty(
    pg_total_relation_size(schemaname||'.'||tablename) - 
    pg_relation_size(schemaname||'.'||tablename)
  ) as index_size,
  (SELECT count(*) FROM pg_indexes WHERE schemaname = t.schemaname AND tablename = t.tablename) as num_indexes
FROM pg_stat_user_tables t
WHERE schemaname = 'users'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC
LIMIT 20;
" >> $REPORT_FILE

# 2. Unused indexes (candidates for removal)
echo -e "\n## Unused Indexes (0 scans in 30 days)\n" >> $REPORT_FILE
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
SELECT 
  schemaname || '.' || indexrelname as index_name,
  schemaname || '.' || tablename as table_name,
  pg_size_pretty(pg_relation_size(indexrelid)) as size,
  idx_scan as scans,
  'DROP INDEX CONCURRENTLY ' || schemaname || '.' || indexrelname || ';' as drop_cmd
FROM pg_stat_user_indexes
WHERE schemaname = 'users'
  AND idx_scan = 0
  AND pg_relation_size(indexrelid) > 10000000  -- >10MB
ORDER BY pg_relation_size(indexrelid) DESC;
" >> $REPORT_FILE

# 3. Low selectivity indexes (scanning too many rows)
echo -e "\n## Low Selectivity Indexes (avg >1000 rows per scan)\n" >> $REPORT_FILE
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
SELECT 
  schemaname || '.' || indexrelname as index_name,
  pg_size_pretty(pg_relation_size(indexrelid)) as size,
  idx_scan as scans,
  round(idx_tup_read::numeric / NULLIF(idx_scan, 0), 0) as avg_rows_per_scan,
  'Partial index candidate' as recommendation
FROM pg_stat_user_indexes
WHERE schemaname = 'users'
  AND idx_scan > 0
  AND idx_tup_read::numeric / NULLIF(idx_scan, 0) > 1000
ORDER BY pg_relation_size(indexrelid) DESC
LIMIT 20;
" >> $REPORT_FILE

# 4. Top queries by total time
echo -e "\n## Top 20 Queries by Total Execution Time\n" >> $REPORT_FILE
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
SELECT 
  substring(query, 1, 200) as query,
  calls,
  round(total_exec_time::numeric / 1000, 2) as total_time_sec,
  round(mean_exec_time::numeric, 2) as avg_ms,
  round(rows::numeric / NULLIF(calls, 0), 0) as avg_rows
FROM pg_stat_statements
WHERE calls > 100
ORDER BY total_exec_time DESC
LIMIT 20;
" >> $REPORT_FILE

echo "Report saved to: $REPORT_FILE"
cat $REPORT_FILE

# Email report (optional, replace with your email command)
# mail -s "Weekly Postgres Index Audit" your-email@company.com < $REPORT_FILE
```

---

## Index Health Monitoring

### 4.1 Index Bloat Detection

```bash
#!/bin/bash
# check-index-bloat.sh
# Detects B-tree bloat using pgstattuple (requires extension)

DB_HOST="prod-db.cluster-xxx.us-east-1.rds.amazonaws.com"
DB_NAME="production"
DB_USER="dbre_admin"

# Enable pgstattuple if not already
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
CREATE EXTENSION IF NOT EXISTS pgstattuple;
"

# Check bloat on largest indexes
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
SELECT 
  schemaname || '.' || indexrelname as index_name,
  pg_size_pretty(pg_relation_size(indexrelid)) as size,
  idx_scan as scans,
  (pgstatindex(schemaname || '.' || indexrelname)).avg_leaf_density as leaf_density,
  CASE 
    WHEN (pgstatindex(schemaname || '.' || indexrelname)).avg_leaf_density < 50 
      THEN '❌ REINDEX NEEDED'
    WHEN (pgstatindex(schemaname || '.' || indexrelname)).avg_leaf_density < 70 
      THEN '⚠️  Monitor'
    ELSE '✅ Healthy'
  END as status
FROM pg_stat_user_indexes
WHERE schemaname = 'users'
  AND pg_relation_size(indexrelid) > 100000000  -- >100MB
ORDER BY pg_relation_size(indexrelid) DESC
LIMIT 10;
"
```

**Interpretation:**
- `leaf_density < 50%`: Immediate REINDEX CONCURRENTLY needed
- `leaf_density 50-70%`: Schedule REINDEX in next maintenance window
- `leaf_density > 70%`: Healthy

**When to REINDEX:**
- After bulk DELETE/UPDATE operations
- Monthly for high-churn tables (scorecard_scores, audit logs)
- When storage alerts trigger without clear cause

---

### 4.2 Missing Index Detection

```bash
#!/bin/bash
# detect-missing-indexes.sh
# Finds sequential scans on large tables

DB_HOST="prod-db.cluster-xxx.us-east-1.rds.amazonaws.com"
DB_NAME="production"
DB_USER="dbre_admin"

psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
SELECT 
  schemaname || '.' || relname as table_name,
  seq_scan as sequential_scans,
  seq_tup_read as rows_read_seqscan,
  idx_scan as index_scans,
  n_live_tup as live_rows,
  pg_size_pretty(pg_relation_size(schemaname||'.'||relname)) as size,
  CASE 
    WHEN seq_scan > idx_scan AND n_live_tup > 10000 
      THEN '❌ Likely missing index'
    WHEN seq_scan > idx_scan * 0.5 AND n_live_tup > 100000
      THEN '⚠️  Review query patterns'
    ELSE '✅ OK'
  END as recommendation
FROM pg_stat_user_tables
WHERE schemaname = 'users'
ORDER BY seq_scan DESC
LIMIT 20;
"
```

**Action items:**
1. For tables flagged with "Likely missing index"
2. Run §4.3 to identify specific queries
3. Use §5.2 to create appropriate index

---

### 4.3 Baseline Capture (Before Any Changes)

```bash
#!/bin/bash
# capture-baseline.sh
# ALWAYS run before making index changes

DB_HOST="prod-db.cluster-xxx.us-east-1.rds.amazonaws.com"
DB_NAME="production"
DB_USER="dbre_admin"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BASELINE_DIR="/var/log/postgres-baselines"

mkdir -p $BASELINE_DIR

echo "Capturing baseline at $TIMESTAMP"

# 1. Current index state
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
COPY (
  SELECT 
    now() as captured_at,
    schemaname,
    tablename,
    indexrelname,
    pg_relation_size(indexrelid) as size_bytes,
    idx_scan,
    idx_tup_read,
    idx_tup_fetch
  FROM pg_stat_user_indexes
  WHERE schemaname = 'users'
) TO STDOUT CSV HEADER
" > $BASELINE_DIR/index_state_$TIMESTAMP.csv

# 2. Query performance snapshot
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
COPY (
  SELECT 
    now() as captured_at,
    substring(query, 1, 500) as query,
    calls,
    total_exec_time,
    mean_exec_time,
    stddev_exec_time,
    rows
  FROM pg_stat_statements
  WHERE calls > 100
  ORDER BY total_exec_time DESC
  LIMIT 100
) TO STDOUT CSV HEADER
" > $BASELINE_DIR/query_perf_$TIMESTAMP.csv

echo "Baseline captured:"
echo "  - $BASELINE_DIR/index_state_$TIMESTAMP.csv"
echo "  - $BASELINE_DIR/query_perf_$TIMESTAMP.csv"
echo ""
echo "After changes, compare with:"
echo "  diff <(sort $BASELINE_DIR/index_state_$TIMESTAMP.csv) <(sort current_state.csv)"
```

**MANDATORY before:**
- Creating new indexes
- Dropping indexes
- REINDEX operations
- Changing autovacuum settings

---

## Safe Optimization Procedures

### 5.1 REINDEX CONCURRENTLY (for bloat)

```bash
#!/bin/bash
# reindex-safe.sh INDEX_NAME
# Example: ./reindex-safe.sh users.idx_scorecard_scores_score_desc

DB_HOST="prod-db.cluster-xxx.us-east-1.rds.amazonaws.com"
DB_NAME="production"
DB_USER="dbre_admin"
INDEX_NAME=$1

if [ -z "$INDEX_NAME" ]; then
  echo "Usage: ./reindex-safe.sh SCHEMA.INDEX_NAME"
  exit 1
fi

echo "=== Safe REINDEX Procedure ==="
echo "Index: $INDEX_NAME"
echo "Started: $(date)"

# 1. Check current size
BEFORE_SIZE=$(psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -c "
  SELECT pg_size_pretty(pg_relation_size('$INDEX_NAME'));
")
echo "Size before: $BEFORE_SIZE"

# 2. Check bloat
LEAF_DENSITY=$(psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -c "
  CREATE EXTENSION IF NOT EXISTS pgstattuple;
  SELECT (pgstatindex('$INDEX_NAME')).avg_leaf_density;
")
echo "Leaf density: $LEAF_DENSITY%"

if (( $(echo "$LEAF_DENSITY > 70" | bc -l) )); then
  echo "⚠️  Warning: Index appears healthy (>70% density). Reindex may not help."
  read -p "Continue anyway? (yes/no): " CONFIRM
  if [ "$CONFIRM" != "yes" ]; then
    echo "Aborted."
    exit 0
  fi
fi

# 3. Estimate duration (rough: 1GB = 5-10min on RDS)
SIZE_GB=$(psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -c "
  SELECT round(pg_relation_size('$INDEX_NAME')::numeric / 1073741824, 2);
")
EST_MINUTES=$(echo "$SIZE_GB * 7" | bc)
echo "Estimated duration: $EST_MINUTES minutes"

# 4. Check maintenance window
read -p "Is this a good time? (yes/no): " TIMING
if [ "$TIMING" != "yes" ]; then
  echo "Aborted. Schedule for maintenance window."
  exit 0
fi

# 5. Execute REINDEX CONCURRENTLY
echo "Starting REINDEX CONCURRENTLY..."
START_TIME=$(date +%s)

psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
  REINDEX INDEX CONCURRENTLY $INDEX_NAME;
" 

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# 6. Verify results
AFTER_SIZE=$(psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -c "
  SELECT pg_size_pretty(pg_relation_size('$INDEX_NAME'));
")

echo ""
echo "=== REINDEX Complete ==="
echo "Duration: $DURATION seconds"
echo "Size before: $BEFORE_SIZE"
echo "Size after: $AFTER_SIZE"
echo "Completed: $(date)"

# Log to audit trail
echo "$(date)|REINDEX|$INDEX_NAME|$BEFORE_SIZE|$AFTER_SIZE|${DURATION}s" >> /var/log/postgres-audits/reindex-log.txt
```

**When to use:**
- Monthly for high-churn tables (scorecard_scores, audit)
- After large bulk operations (DELETE >10% of rows)
- When bloat detection shows <60% leaf density
- P95 latency trending upward despite no query changes

---

### 5.2 Create Partial Index (your primary optimization tool)

```bash
#!/bin/bash
# create-partial-index.sh
# Interactive helper for creating optimized partial indexes

DB_HOST="prod-db.cluster-xxx.us-east-1.rds.amazonaws.com"
DB_NAME="production"
DB_USER="dbre_admin"

echo "=== Partial Index Creation Wizard ==="

# 1. Identify target table and query pattern
read -p "Table name (schema.table): " TABLE_NAME
read -p "Common WHERE clause (e.g., deleted_at IS NULL): " WHERE_CLAUSE
read -p "Key columns (e.g., customer_id, created_at): " KEY_COLUMNS
read -p "Include columns (optional, for covering): " INCLUDE_COLS

# Generate index name
TABLE_SHORT=$(echo $TABLE_NAME | sed 's/.*\.//')
INDEX_NAME="idx_${TABLE_SHORT}_partial_$(date +%s)"

# 2. Check selectivity
echo ""
echo "Checking filter selectivity..."
TOTAL_ROWS=$(psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -c "
  SELECT count(*) FROM $TABLE_NAME;
")
FILTERED_ROWS=$(psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -c "
  SELECT count(*) FROM $TABLE_NAME WHERE $WHERE_CLAUSE;
")
SELECTIVITY=$(echo "scale=2; $FILTERED_ROWS * 100 / $TOTAL_ROWS" | bc)

echo "Total rows: $TOTAL_ROWS"
echo "Filtered rows: $FILTERED_ROWS"
echo "Selectivity: $SELECTIVITY%"

if (( $(echo "$SELECTIVITY > 80" | bc -l) )); then
  echo "⚠️  Warning: Filter only excludes $((100 - SELECTIVITY))% of rows."
  echo "Partial index may not provide significant benefit."
  read -p "Continue anyway? (yes/no): " CONFIRM
  if [ "$CONFIRM" != "yes" ]; then
    exit 0
  fi
fi

# 3. Build CREATE INDEX statement
if [ -z "$INCLUDE_COLS" ]; then
  INDEX_SQL="CREATE INDEX CONCURRENTLY $INDEX_NAME ON $TABLE_NAME($KEY_COLUMNS) WHERE $WHERE_CLAUSE;"
else
  INDEX_SQL="CREATE INDEX CONCURRENTLY $INDEX_NAME ON $TABLE_NAME($KEY_COLUMNS) INCLUDE ($INCLUDE_COLS) WHERE $WHERE_CLAUSE;"
fi

echo ""
echo "Generated SQL:"
echo "$INDEX_SQL"
echo ""

# 4. Estimate size
FULL_INDEX_SIZE=$(psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -c "
  SELECT pg_size_pretty(pg_relation_size(indexrelid)) 
  FROM pg_stat_user_indexes 
  WHERE schemaname || '.' || tablename = '$TABLE_NAME' 
  ORDER BY pg_relation_size(indexrelid) DESC 
  LIMIT 1;
")
echo "Existing index size (largest): $FULL_INDEX_SIZE"
echo "Estimated partial index size: ~$(echo "$SELECTIVITY / 100 * $FULL_INDEX_SIZE" | bc)% of that"

# 5. Capture baseline
read -p "Capture baseline before creating? (yes/no): " DO_BASELINE
if [ "$DO_BASELINE" == "yes" ]; then
  ./capture-baseline.sh
fi

# 6. Execute
read -p "Create index now? (yes/no): " DO_CREATE
if [ "$DO_CREATE" == "yes" ]; then
  echo "Creating index..."
  START_TIME=$(date +%s)
  
  psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "$INDEX_SQL"
  
  END_TIME=$(date +%s)
  DURATION=$((END_TIME - START_TIME))
  
  FINAL_SIZE=$(psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -c "
    SELECT pg_size_pretty(pg_relation_size('$INDEX_NAME'));
  ")
  
  echo ""
  echo "✅ Index created successfully"
  echo "Name: $INDEX_NAME"
  echo "Size: $FINAL_SIZE"
  echo "Duration: ${DURATION}s"
  
  # Log
  echo "$(date)|CREATE_PARTIAL|$INDEX_NAME|$TABLE_NAME|$FINAL_SIZE|${DURATION}s|$WHERE_CLAUSE" >> /var/log/postgres-audits/index-changes.txt
  
  echo ""
  echo "Next steps:"
  echo "1. Monitor for 24-48 hours"
  echo "2. Check index usage: SELECT idx_scan FROM pg_stat_user_indexes WHERE indexrelname='$INDEX_NAME';"
  echo "3. Compare with baseline"
  echo "4. If successful, consider dropping old full index"
else
  echo "Index creation cancelled. SQL saved to /tmp/partial-index.sql"
  echo "$INDEX_SQL" > /tmp/partial-index.sql
fi
```

**Real-world examples from your production data:**

```sql
-- Example 1: scorecard_tags (1.7M calls, 5.3M seconds total)
-- Current: Full index on (scorecard_id, tag_id) - 664 MB
-- Optimize: Partial index excluding soft-deletes
CREATE INDEX CONCURRENTLY idx_scorecard_tags_active_lookup
ON users.scorecard_tags(scorecard_id, tag_id)
WHERE deleted_at IS NULL;
-- Expected: 400 MB (40% reduction), 30-40% faster queries

-- Example 2: scorecard_scores (85M inserts @ 66ms each)
-- Current: idx_scorecard_scores_score_desc - 2.3 GB, reading 624K rows/scan
-- Optimize: Partial index for high-score queries only
CREATE INDEX CONCURRENTLY idx_scorecard_scores_top_scores
ON users.scorecard_scores(score DESC, company_id, created_at)
WHERE score >= 70 AND created_at > '2024-01-01';
-- Expected: 200 MB (90% reduction), 20-30% faster inserts
```

---

### 5.3 Covering Index Creation (INCLUDE columns)

```bash
#!/bin/bash
# create-covering-index.sh
# Reduces heap lookups by including non-key columns

DB_HOST="prod-db.cluster-xxx.us-east-1.rds.amazonaws.com"
DB_NAME="production"
DB_USER="dbre_admin"

read -p "Table name: " TABLE_NAME
read -p "Key columns (for WHERE/ORDER BY): " KEY_COLS
read -p "INCLUDE columns (for SELECT list): " INCLUDE_COLS

INDEX_NAME="idx_${TABLE_NAME}_covering_$(date +%s)"

# Check query pattern
echo "This covering index will eliminate heap lookups for queries like:"
echo "SELECT $KEY_COLS, $INCLUDE_COLS FROM $TABLE_NAME WHERE [conditions on $KEY_COLS]"
echo ""

read -p "Continue? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  exit 0
fi

# Create covering index
INDEX_SQL="CREATE INDEX CONCURRENTLY $INDEX_NAME ON $TABLE_NAME($KEY_COLS) INCLUDE ($INCLUDE_COLS);"

echo "Executing: $INDEX_SQL"
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "$INDEX_SQL"

# Verify with EXPLAIN
echo ""
echo "Test query to verify Index Only Scan:"
echo "EXPLAIN (ANALYZE, BUFFERS) SELECT $KEY_COLS, $INCLUDE_COLS FROM $TABLE_NAME LIMIT 10;"
```

**When to use covering indexes:**
- Queries that SELECT specific columns repeatedly
- High idx_tup_read but low idx_tup_fetch (many index reads, few table fetches)
- Want to eliminate "Heap Fetches" from EXPLAIN output

---

### 5.4 Tune Autovacuum for High-Churn Tables

```bash
#!/bin/bash
# tune-autovacuum.sh TABLE_NAME
# Aggressive autovacuum settings for write-heavy tables

DB_HOST="prod-db.cluster-xxx.us-east-1.rds.amazonaws.com"
DB_NAME="production"
DB_USER="dbre_admin"
TABLE_NAME=$1

if [ -z "$TABLE_NAME" ]; then
  echo "Usage: ./tune-autovacuum.sh SCHEMA.TABLE"
  exit 1
fi

# Check current dead tuple ratio
echo "Current dead tuple statistics:"
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
SELECT 
  schemaname || '.' || relname as table_name,
  n_live_tup as live_rows,
  n_dead_tup as dead_rows,
  round(100.0 * n_dead_tup / NULLIF(n_live_tup, 0), 2) as dead_pct,
  last_autovacuum,
  last_vacuum
FROM pg_stat_user_tables
WHERE schemaname || '.' || relname = '$TABLE_NAME';
"

echo ""
read -p "Apply aggressive autovacuum settings? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  exit 0
fi

# Apply tuned settings
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
ALTER TABLE $TABLE_NAME SET (
  autovacuum_vacuum_scale_factor = 0.02,    -- Vacuum at 2% dead tuples
  autovacuum_vacuum_threshold = 5000,        -- Or 5000 dead tuples minimum
  autovacuum_analyze_scale_factor = 0.01,    -- Analyze at 1% changes
  autovacuum_analyze_threshold = 2000,       -- Or 2000 changes minimum
  autovacuum_vacuum_cost_limit = 2000        -- Higher I/O budget
);
"

echo "✅ Autovacuum tuned for $TABLE_NAME"
echo "Monitor: SELECT last_autovacuum FROM pg_stat_user_tables WHERE relname='$(echo $TABLE_NAME | cut -d. -f2)';"

# Log change
echo "$(date)|TUNE_AUTOVACUUM|$TABLE_NAME|scale_factor=0.02|threshold=5000" >> /var/log/postgres-audits/autovacuum-changes.txt
```

**Apply to these tables from your data:**
- `scorecard_scores` (85M inserts, high churn)
- `audit` tables (write-heavy, rarely updated)
- Any table with `n_dead_tup > 10%` of `n_live_tup`

---

### 5.5 Safe Index Retirement

```bash
#!/bin/bash
# retire-index.sh INDEX_NAME
# Safe multi-step process to drop unused indexes

DB_HOST="prod-db.cluster-xxx.us-east-1.rds.amazonaws.com"
DB_NAME="production"
DB_USER="dbre_admin"
INDEX_NAME=$1

if [ -z "$INDEX_NAME" ]; then
  echo "Usage: ./retire-index.sh SCHEMA.INDEX_NAME"
  exit 1
fi

echo "=== Index Retirement Safety Check ==="

# 1. Verify it's not a constraint
CONSTRAINT_CHECK=$(psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -c "
SELECT 
  CASE c.contype
    WHEN 'p' THEN 'PRIMARY_KEY'
    WHEN 'u' THEN 'UNIQUE'
    WHEN 'f' THEN 'FOREIGN_KEY'
    ELSE 'NONE'
  END
FROM pg_constraint c
WHERE c.conname = '$(echo $INDEX_NAME | cut -d. -f2)';
")

if [[ "$CONSTRAINT_CHECK" =~ (PRIMARY_KEY|UNIQUE|FOREIGN_KEY) ]]; then
  echo "❌ ABORT: $INDEX_NAME backs a $CONSTRAINT_CHECK constraint"
  echo "Cannot drop constraint-backing indexes."
  exit 1
fi

# 2. Check usage stats
echo "Usage statistics (last 30 days):"
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
SELECT 
  schemaname || '.' || indexrelname as index_name,
  schemaname || '.' || tablename as table_name,
  pg_size_pretty(pg_relation_size(indexrelid)) as size,
  idx_scan as scans,
  idx_tup_read as tuples_read,
  idx_tup_fetch as tuples_fetched
FROM pg_stat_user_indexes
WHERE schemaname || '.' || indexrelname = '$INDEX_NAME';
"

# 3. Find queries that might use it
echo ""
echo "Checking pg_stat_statements for queries on this table..."
TABLE_NAME=$(psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -c "
SELECT schemaname || '.' || tablename 
FROM pg_stat_user_indexes 
WHERE schemaname || '.' || indexrelname = '$INDEX_NAME';
")

psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
SELECT 
  substring(query, 1, 200) as query,
  calls,
  mean_exec_time
FROM pg_stat_statements
WHERE query LIKE '%$(echo $TABLE_NAME | cut -d. -f2)%'
ORDER BY calls DESC
LIMIT 5;
"

echo ""
read -p "Proceed with dropping $INDEX_NAME? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  echo "Aborted."
  exit 0
fi

# 4. Capture baseline (for rollback)
INDEX_DEF=$(psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -c "
SELECT indexdef FROM pg_indexes 
WHERE schemaname || '.' || indexname = '$INDEX_NAME';
")
echo "$INDEX_DEF" > /tmp/index-backup-$(echo $INDEX_NAME | sed 's/\./_/g').sql
echo "Index definition saved to /tmp/index-backup-*.sql for rollback"

# 5. Drop index
echo "Dropping index..."
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
DROP INDEX CONCURRENTLY $INDEX_NAME;
"

if [ $? -eq 0 ]; then
  echo "✅ Index dropped successfully"
  
  # Log the change
  SIZE=$(psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -c "
    SELECT pg_size_pretty(sum(pg_relation_size(indexrelid))) 
    FROM pg_stat_user_indexes 
    WHERE schemaname || '.' || tablename = '$TABLE_NAME';
  ")
  
  echo "$(date)|DROP_INDEX|$INDEX_NAME|$TABLE_NAME|freed_space" >> /var/log/postgres-audits/index-changes.txt
  
  echo ""
  echo "Monitor for 24-48 hours:"
  echo "1. Watch for query performance regressions"
  echo "2. Check application logs for errors"
  echo "3. If problems occur, restore with:"
  echo "   psql -h $DB_HOST -U $DB_USER -d $DB_NAME -f /tmp/index-backup-*.sql"
else
  echo "❌ DROP failed. Check error above."
fi
```

**Safe candidates from your production data:**
```bash
# These are safe (verified NOT constraints, 0 scans):
./retire-index.sh users.idx_mv_follower_count_domain      # 450 MB
./retire-index.sh users.scorecards_custom_legacy_id       # 292 MB
# Total: 742 MB immediate savings
```

---

### 5.6 Fillfactor Optimization for Insert-Heavy Tables

```bash
#!/bin/bash
# optimize-fillfactor.sh TABLE_NAME
# Reduces page splits on monotonically increasing indexes

DB_HOST="prod-db.cluster-xxx.us-east-1.rds.amazonaws.com"
DB_NAME="production"
DB_USER="dbre_admin"
TABLE_NAME=$1

if [ -z "$TABLE_NAME" ]; then
  echo "Usage: ./optimize-fillfactor.sh SCHEMA.TABLE"
  exit 1
fi

echo "=== Fillfactor Optimization for $TABLE_NAME ==="

# Find indexes on timestamp/serial columns (append-heavy patterns)
echo "Indexes on sequential columns:"
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
SELECT 
  i.indexrelname as index_name,
  a.attname as column_name,
  pg_size_pretty(pg_relation_size(i.indexrelid)) as size,
  i.idx_scan as scans
FROM pg_stat_user_indexes i
JOIN pg_index x ON x.indexrelid = i.indexrelid
JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(x.indkey)
WHERE i.schemaname || '.' || i.tablename = '$TABLE_NAME'
  AND (a.attname LIKE '%_at' OR a.attname LIKE '%_id' OR a.attname = 'id')
ORDER BY pg_relation_size(i.indexrelid) DESC;
"

read -p "Enter index name to optimize: " INDEX_NAME
read -p "Fillfactor (90 for high-write, 70 for extreme): " FILLFACTOR

if [ -z "$FILLFACTOR" ]; then
  FILLFACTOR=90
fi

echo "Setting fillfactor=$FILLFACTOR for $INDEX_NAME"
echo "This requires REINDEX to take effect."

# Set fillfactor
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
ALTER INDEX $INDEX_NAME SET (fillfactor = $FILLFACTOR);
"

# Reindex to apply
read -p "REINDEX now? (yes/no): " DO_REINDEX
if [ "$DO_REINDEX" == "yes" ]; then
  echo "Reindexing..."
  psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
  REINDEX INDEX CONCURRENTLY $INDEX_NAME;
  "
  echo "✅ Fillfactor applied"
fi

# Log
echo "$(date)|FILLFACTOR|$INDEX_NAME|$FILLFACTOR" >> /var/log/postgres-audits/index-changes.txt
```

**Apply to these from your data:**
- Any index on `created_at`, `updated_at`, `id` columns
- High-insert tables: `scorecard_scores`, `audit`, `events`

---

### 5.7 BRIN Index for Time-Series Data

```bash
#!/bin/bash
# create-brin-index.sh
# For massive append-only tables (logs, events, audit)

DB_HOST="prod-db.cluster-xxx.us-east-1.rds.amazonaws.com"
DB_NAME="production"
DB_USER="dbre_admin"

read -p "Table name (e.g., users.audit_log): " TABLE_NAME
read -p "Timestamp column (e.g., created_at): " TIME_COL

INDEX_NAME="idx_$(echo $TABLE_NAME | cut -d. -f2)_${TIME_COL}_brin"

# Check table size
TABLE_SIZE=$(psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -c "
SELECT pg_size_pretty(pg_relation_size('$TABLE_NAME'));
")

echo "Table size: $TABLE_SIZE"
echo "BRIN index will be ~0.1% of table size (tiny!)"
echo ""

# Estimate BRIN size vs B-tree
BTREE_EST=$(psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -c "
SELECT pg_size_pretty(pg_relation_size('$TABLE_NAME') * 0.15);
")
BRIN_EST=$(psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -c "
SELECT pg_size_pretty(pg_relation_size('$TABLE_NAME') * 0.001);
")

echo "Estimated B-tree index: $BTREE_EST"
echo "Estimated BRIN index: $BRIN_EST"
echo ""

read -p "Create BRIN index? (yes/no): " CONFIRM
if [ "$CONFIRM" != "yes" ]; then
  exit 0
fi

# Create BRIN index
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
CREATE INDEX CONCURRENTLY $INDEX_NAME 
ON $TABLE_NAME USING BRIN ($TIME_COL) 
WITH (pages_per_range = 128);
"

# Summarize (for existing data)
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
SELECT brin_summarize_new_values('$INDEX_NAME');
"

ACTUAL_SIZE=$(psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -c "
SELECT pg_size_pretty(pg_relation_size('$INDEX_NAME'));
")

echo ""
echo "✅ BRIN index created: $INDEX_NAME"
echo "Actual size: $ACTUAL_SIZE"
echo ""
echo "Use for queries like:"
echo "SELECT * FROM $TABLE_NAME WHERE $TIME_COL BETWEEN '2025-01-01' AND '2025-01-31';"
```

**Use BRIN for:**
- Audit logs (append-only, query by date ranges)
- Event streams (time-ordered)
- Historical data (never updated, only inserted)

---

### 5.8 Duplicate Index Detection and Cleanup

```bash
#!/bin/bash
# find-duplicate-indexes.sh
# Detects overlapping indexes where one makes the other redundant

DB_HOST="prod-db.cluster-xxx.us-east-1.rds.amazonaws.com"
DB_NAME="production"
DB_USER="dbre_admin"

echo "=== Finding Duplicate/Overlapping Indexes ==="

psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
WITH idx_cols AS (
  SELECT 
    i.indexrelid::regclass as index_name,
    i.indrelid::regclass as table_name,
    string_agg(a.attname, ',' ORDER BY array_position(i.indkey, a.attnum)) as columns,
    pg_relation_size(i.indexrelid) as size_bytes
  FROM pg_index i
  JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
  WHERE i.indrelid::regclass::text LIKE 'users.%'
  GROUP BY i.indexrelid, i.indrelid
)
SELECT 
  ic1.table_name,
  ic1.index_name as redundant_index,
  ic1.columns as redundant_cols,
  pg_size_pretty(ic1.size_bytes) as redundant_size,
  ic2.index_name as superset_index,
  ic2.columns as superset_cols,
  pg_size_pretty(ic2.size_bytes) as superset_size,
  'DROP INDEX CONCURRENTLY ' || ic1.index_name || ';' as drop_command
FROM idx_cols ic1
JOIN idx_cols ic2 ON ic1.table_name = ic2.table_name
WHERE ic2.columns LIKE ic1.columns || ',%'  -- ic2 is superset
  AND ic1.index_name != ic2.index_name
  AND ic1.size_bytes > 10000000  -- >10MB
ORDER BY ic1.size_bytes DESC;
"

echo ""
echo "⚠️  Review carefully: superset index might not always replace subset"
echo "Example: index on (a) is NOT redundant if queries filter ONLY on (a)"
echo "         but index on (a,b) would be used for (a) AND (a,b) queries"
```

---

## Rollback Procedures

### 6.1 Emergency Index Rollback

```bash
#!/bin/bash
# rollback-index-change.sh
# Quick restore after bad index change

DB_HOST="prod-db.cluster-xxx.us-east-1.rds.amazonaws.com"
DB_NAME="production"
DB_USER="dbre_admin"

echo "=== Index Change Rollback ==="
echo "Recent changes:"
tail -20 /var/log/postgres-audits/index-changes.txt

read -p "Enter timestamp or index name to rollback: " SEARCH_TERM

# Find backup file
BACKUP_FILE=$(grep "$SEARCH_TERM" /var/log/postgres-audits/index-changes.txt | head -1)
echo "Found change: $BACKUP_FILE"

# Locate SQL backup
SQL_FILE=$(find /tmp -name "index-backup-*" -mtime -7 | grep -i "$SEARCH_TERM" | head -1)

if [ -z "$SQL_FILE" ]; then
  echo "❌ No backup found. Manual recovery needed."
  echo "Check: ls -lrt /tmp/index-backup-*"
  exit 1
fi

echo "Backup file: $SQL_FILE"
cat $SQL_FILE

read -p "Restore this index? (yes/no): " CONFIRM
if [ "$CONFIRM" == "yes" ]; then
  psql -h $DB_HOST -U $DB_USER -d $DB_NAME -f $SQL_FILE
  echo "✅ Index restored"
else
  echo "Rollback cancelled"
fi
```

---

### 6.2 Query Performance Comparison

```bash
#!/bin/bash
# compare-performance.sh BASELINE_TIMESTAMP
# Compares current performance against captured baseline

BASELINE_DIR="/var/log/postgres-baselines"
BASELINE_TS=$1

if [ -z "$BASELINE_TS" ]; then
  echo "Available baselines:"
  ls -lh $BASELINE_DIR/query_perf_*.csv
  echo ""
  echo "Usage: ./compare-performance.sh YYYYMMDD_HHMMSS"
  exit 1
fi

BASELINE_FILE="$BASELINE_DIR/query_perf_$BASELINE_TS.csv"
CURRENT_FILE="/tmp/current_perf.csv"

# Capture current state
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
COPY (
  SELECT 
    substring(query, 1, 500) as query,
    calls,
    total_exec_time,
    mean_exec_time
  FROM pg_stat_statements
  WHERE calls > 100
  ORDER BY total_exec_time DESC
  LIMIT 100
) TO '$CURRENT_FILE' CSV HEADER;
"

# Compare (simplified - use proper CSV diff tool in production)
echo "=== Performance Regression Check ==="
echo "Queries that got SLOWER:"

# This is a simple bash comparison - in production use Python/awk for proper CSV parsing
echo "TODO: Implement proper CSV comparison"
echo "Baseline: $BASELINE_FILE"
echo "Current: $CURRENT_FILE"
```

---

## Capacity Planning

### 8.1 Storage Growth Projection

```bash
#!/bin/bash
# project-storage-growth.sh
# Estimates when you'll hit storage limits

DB_HOST="prod-db.cluster-xxx.us-east-1.rds.amazonaws.com"
DB_NAME="production"
DB_USER="dbre_admin"

echo "=== Storage Growth Projection ==="

# Get current size
CURRENT_SIZE_GB=$(psql -h $DB_HOST -U $DB_USER -d $DB_NAME -t -c "
SELECT round(pg_database_size('$DB_NAME')::numeric / 1073741824, 2);
")

echo "Current database size: ${CURRENT_SIZE_GB} GB"

# Get growth rate (requires historical data - simplified here)
echo ""
echo "To calculate growth rate, run this query weekly and track:"
psql -h $DB_HOST -U $DB_USER -d $DB_NAME -c "
SELECT 
  now() as measured_at,
  pg_size_pretty(pg_database_size('$DB_NAME')) as total_size,
  pg_size_pretty(sum(pg_relation_size(schemaname||'.'||tablename))) as table_size,
  pg_size_pretty(sum(pg_total_relation_size(schemaname||'.'||tablename) - 
                     pg_relation_size(schemaname||'.'||tablename))) as index_size
FROM pg_stat_user_tables
WHERE schemaname = 'users';
"

# Manual projection
read -p "Enter weekly growth rate (GB/week): " GROWTH_RATE
read -p "Enter RDS storage limit (GB): " STORAGE_LIMIT

WEEKS_REMAINING=$(echo "($STORAGE_LIMIT - $CURRENT_SIZE_GB) / $GROWTH_RATE" | bc)

echo ""
echo "📊 Projection:"
echo "   Current: ${CURRENT_SIZE_GB} GB"
echo "   Limit: ${STORAGE_LIMIT} GB"
echo "   Growth: ${GROWTH_RATE} GB/week"
echo "   Time until limit: ${WEEKS_REMAINING} weeks"

if [ "$WEEKS_REMAINING" -lt 8 ]; then
  echo ""
  echo "⚠️  WARNING: Less than 8 weeks of capacity remaining"
  echo "Action items:"
  echo "1. Run weekly index audit to find optimization opportunities"
  echo "2. Consider partitioning large tables (events, audit logs)"
  echo "3. Archive old data if applicable"
  echo "4. Plan RDS storage increase"
fi
```

---

### 8.2 Cost Estimation for Index Optimization

```bash
#!/bin/bash
# estimate-savings.sh
# Calculates storage cost savings from index optimization

COST_PER_GB_MONTH=0.115  # RDS GP3 pricing (adjust for your region/type)

read -p "Total index space to free (GB): " SPACE_FREED_GB

MONTHLY_SAVINGS=$(echo "$SPACE_FREED_GB * $COST_PER_GB_MONTH" | bc -l)
ANNUAL_SAVINGS=$(echo "$MONTHLY_SAVINGS * 12" | bc -l)

echo ""
echo "💰 Cost Savings Estimate:"
echo "   Storage freed: ${SPACE_FREED_GB} GB"
echo "   Monthly savings: \$(printf "%.2f" $MONTHLY_SAVINGS)"
echo "   Annual savings: \$(printf "%.2f" $ANNUAL_SAVINGS)"
echo ""
echo "Note: Excludes IOPS/throughput improvements and backup storage savings"
```

---

## Appendix: Complete SQL Library

### A.1 Health Baseline (Copy-Paste)
