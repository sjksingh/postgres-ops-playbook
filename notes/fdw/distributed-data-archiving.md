# PostgreSQL Foreign Data Wrapper (FDW) - Platform DBRE Guide

## Executive Summary

**Purpose:** Transparent distributed data archiving using Foreign Data Wrapper and table partitioning  
**Architecture:** Active data on primary instance, historical data on archive instances, unified query interface  
**Key Benefit:** Applications query single endpoint while PostgreSQL routes to appropriate instance  
**Use Cases:** Compliance archiving, cost optimization (hot/cold storage), operational independence

---

## Problem Statement

### Traditional Archiving Limitations

**Detached Partitions:**
- Data becomes inaccessible after detachment
- Requires manual reattachment for queries
- Complex application logic to handle missing data

**Backup-Based Archives:**
- Must restore backup to query old data
- Slow restore operations for ad-hoc queries
- No transparent access to historical data

**Separate Cluster Approach:**
- Applications manage multiple database connections
- Complex connection pooling and routing logic
- No unified query interface for time-series data

### FDW + Partitioning Solution

**Benefits:**
- ✅ Single application endpoint
- ✅ Transparent access to archived data
- ✅ Independent backups per instance
- ✅ Faster, targeted restores
- ✅ Easy decommissioning of old archives
- ✅ Different storage tiers (SSD for active, HDD for archive)

---

## Architecture Overview

### High-Level Design

```
┌─────────────────────────────────────────────────────────┐
│              Main Database Instance                      │
│                  (Port 5432)                            │
│                                                         │
│  ┌──────────────────────────────────────────────────┐  │
│  │     Partitioned Table: employees                  │  │
│  │  ┌───────────┬─────────────┬──────────────────┐  │  │
│  │  │ emp_2023  │  emp_2024   │    emp_2025      │  │  │
│  │  │ (Foreign) │  (Foreign)  │    (Local)       │  │  │
│  │  │  Archive  │   Archive   │   Active Data    │  │  │
│  │  └─────┬─────┴──────┬──────┴──────────────────┘  │  │
│  └────────┼────────────┼────────────────────────────┘  │
│           │            │                               │
│       FDW Connection   FDW Connection                  │
│           │            │                               │
└───────────┼────────────┼───────────────────────────────┘
            │            │
            ▼            ▼
┌───────────────────┐  ┌──────────────────────┐
│  Archive Instance │  │  Archive Instance    │
│  (Port 5433)      │  │  (Port 5434)         │
│  ┌─────────────┐  │  │  ┌────────────────┐  │
│  │  emp_2023   │  │  │  │   emp_2024     │  │
│  │ (Old Data)  │  │  │  │  (Less Old)    │  │
│  └─────────────┘  │  │  └────────────────┘  │
└───────────────────┘  └──────────────────────┘
```

### Query Routing Logic

```
Application Query: SELECT * FROM employees WHERE hire_date = '2024-06-15'
                              ↓
                   PostgreSQL Query Planner
                              ↓
                   [Partition Pruning]
                              ↓
                   Analyze WHERE clause: hire_date = '2024-06-15'
                              ↓
              Matches partition: emp_2024 (2024-01-01 to 2025-01-01)
                              ↓
                   Check partition type
                              ↓
                   Foreign Table Detected
                              ↓
          ┌──────────────────────────────────┐
          │  Foreign Scan on emp_2024        │
          │  - Connect to archive_server     │
          │  - Push down WHERE clause        │
          │  - Execute: SELECT * FROM        │
          │    emp_2024 WHERE hire_date =    │
          │    '2024-06-15'                  │
          │  - Fetch results                 │
          └──────────────────────────────────┘
                              ↓
                   Return results to application
```

### Data Flow

```
INSERT Flow:
-----------
Application → INSERT INTO employees (name, hire_date, ...) 
                             ↓
              PostgreSQL examines hire_date value
                             ↓
              ┌─────────────┴──────────────┐
              ▼                            ▼
    hire_date in [2025-01-01, 2026-01-01)   hire_date in [2024-01-01, 2025-01-01)
              ↓                            ↓
    Route to emp_2025 (Local)       Route to emp_2024 (Foreign)
              ↓                            ↓
    Write to local disk             FDW connection to archive
                                           ↓
                                    Write to archive instance


Query Flow with Aggregation:
---------------------------
Application → SELECT year, COUNT(*), AVG(salary) FROM employees GROUP BY year
                             ↓
              PostgreSQL Query Planner
                             ↓
              Scan all partitions (emp_2023, emp_2024, emp_2025)
                             ↓
         ┌──────────────┬────────────────┬──────────────┐
         ▼              ▼                ▼              
    emp_2023       emp_2024         emp_2025          
    (Foreign)      (Foreign)        (Local)           
         │              │                │             
    FDW to          FDW to          Local scan        
    Archive 1      Archive 2                          
         │              │                │             
    Partial         Partial         Partial           
    Aggregate       Aggregate       Aggregate         
         │              │                │             
         └──────────────┴────────────────┘             
                        ↓                              
              Combine partial aggregates              
                        ↓                              
              Return final results                    
```

---

## Foreign Data Wrapper (FDW) Fundamentals

### What FDW Does

**Core Capabilities:**
- **Seamless Integration:** Access remote PostgreSQL databases as local tables
- **Transparent Querying:** SELECT, INSERT, UPDATE, DELETE on remote data
- **Cross-Database JOINs:** Combine data from multiple instances
- **Query Push-Down:** PostgreSQL pushes filters/aggregations to remote server

### How FDW Works

```
Client Query: SELECT * FROM remote_table WHERE id > 100
                        ↓
         ┌──────────────────────────────┐
         │  PostgreSQL Query Planner    │
         │  - Identifies foreign table  │
         │  - Determines pushdown ops   │
         └──────────────┬───────────────┘
                        ▼
         ┌──────────────────────────────┐
         │    postgres_fdw Module       │
         │  - Establishes connection    │
         │  - Translates SQL query      │
         └──────────────┬───────────────┘
                        ▼
         ┌──────────────────────────────┐
         │    Remote PostgreSQL         │
         │  - Executes: SELECT * FROM   │
         │    remote_table WHERE id>100 │
         │  - Returns result set        │
         └──────────────┬───────────────┘
                        ▼
         ┌──────────────────────────────┐
         │    postgres_fdw Module       │
         │  - Fetches results           │
         │  - Formats as local data     │
         └──────────────┬───────────────┘
                        ▼
              Return to client
```

### FDW Components

**1. Foreign Server (Connection Definition)**
```sql
CREATE SERVER archive_server 
    FOREIGN DATA WRAPPER postgres_fdw 
    OPTIONS (
        host 'archive.example.com',
        dbname 'archive_db',
        port '5432',
        fetch_size '10000'  -- Rows per network round-trip
    );
```

**2. User Mapping (Authentication)**
```sql
CREATE USER MAPPING FOR local_user 
    SERVER archive_server 
    OPTIONS (
        user 'remote_user',
        password 'remote_password'
    );
```

**3. Foreign Table (Schema Definition)**
```sql
CREATE FOREIGN TABLE remote_employees (
    id INTEGER,
    name TEXT,
    hire_date DATE
) SERVER archive_server
OPTIONS (table_name 'employees');
```

---

## Implementation Guide

### Environment Setup

**Docker Compose Configuration:**

```yaml
version: '3.8'

services:
  postgres_main:
    image: postgres:16
    container_name: pg_main
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres123
      POSTGRES_DB: appdb
    ports:
      - "5432:5432"
    volumes:
      - pg_main_data:/var/lib/postgresql/data
    networks:
      - pg_network
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5

  postgres_archive:
    image: postgres:16
    container_name: pg_archive
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres123
      POSTGRES_DB: archive_db
    ports:
      - "5433:5432"
    volumes:
      - pg_archive_data:/var/lib/postgresql/data
    networks:
      - pg_network
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 10s
      timeout: 5s
      retries: 5

networks:
  pg_network:
    driver: bridge

volumes:
  pg_main_data:
  pg_archive_data:
```

**Start Environment:**
```bash
docker-compose up -d

# Verify both instances are running
docker-compose ps

# Check network connectivity
docker exec pg_main pg_isready -h postgres_archive -p 5432
```

---

### Step 1: Configure Main Instance

**Connect to main instance:**
```bash
docker exec -it pg_main psql -U postgres -d appdb
```

**Create partitioned table:**
```sql
-- Parent table with partitioning key
CREATE TABLE employees (
    id SERIAL,
    name TEXT NOT NULL,
    hire_date DATE NOT NULL,
    department TEXT,
    salary DECIMAL(10,2)
) PARTITION BY RANGE (hire_date);

-- Local partition for current year (2025)
CREATE TABLE emp_2025 PARTITION OF employees 
    FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');

-- Indexes for performance
CREATE INDEX idx_emp_2025_date ON emp_2025(hire_date);
CREATE INDEX idx_emp_2025_name ON emp_2025(name);
CREATE INDEX idx_emp_2025_dept ON emp_2025(department);
```

**Enable and configure FDW:**
```sql
-- Enable postgres_fdw extension
CREATE EXTENSION postgres_fdw;

-- Define connection to archive instance
CREATE SERVER archive_server 
    FOREIGN DATA WRAPPER postgres_fdw 
    OPTIONS (
        host 'postgres_archive',     -- Docker container name
        dbname 'archive_db',          -- Target database
        port '5432',                  -- Internal container port
        fetch_size '10000',           -- Batch size for fetches
        use_remote_estimate 'true'    -- Use remote stats for planning
    );

-- Create user mapping for authentication
CREATE USER MAPPING FOR postgres 
    SERVER archive_server 
    OPTIONS (
        user 'postgres',
        password 'postgres123'
    );
```

**Verify FDW configuration:**
```sql
-- Check server definition
SELECT srvname, srvoptions 
FROM pg_foreign_server;

-- Check user mapping
SELECT umuser, umoptions 
FROM pg_user_mapping 
JOIN pg_foreign_server ON umserver = oid;
```

---

### Step 2: Configure Archive Instance

**Connect to archive instance:**
```bash
docker exec -it pg_archive psql -U postgres -d archive_db
```

**Create archive table:**
```sql
-- Table with identical structure to main instance
CREATE TABLE emp_2024 (
    id SERIAL,
    name TEXT NOT NULL,
    hire_date DATE NOT NULL,
    department TEXT,
    salary DECIMAL(10,2),
    -- Constraint ensures data integrity
    CHECK (hire_date >= '2024-01-01' AND hire_date < '2025-01-01')
);

-- Create same indexes as main instance
CREATE INDEX idx_emp_2024_date ON emp_2024(hire_date);
CREATE INDEX idx_emp_2024_name ON emp_2024(name);
CREATE INDEX idx_emp_2024_dept ON emp_2024(department);

-- Insert sample archived data
INSERT INTO emp_2024 (name, hire_date, department, salary) VALUES
    ('Alice Johnson', '2024-03-15', 'Engineering', 95000.00),
    ('Bob Smith', '2024-06-22', 'Sales', 75000.00),
    ('Carol White', '2024-09-10', 'HR', 68000.00),
    ('David Brown', '2024-11-05', 'Engineering', 102000.00);

-- Verify data
SELECT COUNT(*), MIN(hire_date), MAX(hire_date) FROM emp_2024;
```

---

### Step 3: Link Foreign Table as Partition

**Return to main instance:**
```bash
docker exec -it pg_main psql -U postgres -d appdb
```

**Create foreign table partition:**
```sql
-- Attach archive table as foreign partition
CREATE FOREIGN TABLE emp_2024 PARTITION OF employees 
    FOR VALUES FROM ('2024-01-01') TO ('2025-01-01')
    SERVER archive_server
    OPTIONS (
        table_name 'emp_2024',
        fetch_size '10000'
    );

-- Insert current year data (goes to local partition)
INSERT INTO employees (name, hire_date, department, salary) VALUES
    ('Eve Davis', '2025-04-12', 'Engineering', 105000.00),
    ('Frank Miller', '2025-07-20', 'Product', 92000.00),
    ('Grace Lee', '2025-10-08', 'Engineering', 110000.00);

-- Verify partition setup
SELECT 
    tablename,
    schemaname,
    CASE 
        WHEN tablename LIKE '%_202[0-4]' THEN 'Foreign (Archive)'
        ELSE 'Local (Active)'
    END AS location
FROM pg_tables 
WHERE tablename LIKE 'emp_%'
ORDER BY tablename;
```

---

### Step 4: Query Across Instances

**Unified queries:**
```sql
-- Query spans both instances transparently
SELECT 
    EXTRACT(YEAR FROM hire_date) AS year,
    COUNT(*) AS employee_count,
    AVG(salary) AS avg_salary,
    MIN(salary) AS min_salary,
    MAX(salary) AS max_salary
FROM employees
GROUP BY EXTRACT(YEAR FROM hire_date)
ORDER BY year;

-- Expected output:
-- year | employee_count | avg_salary | min_salary | max_salary
-- -----+----------------+------------+------------+------------
-- 2024 |              4 |   85000.00 |   68000.00 |  102000.00
-- 2025 |              3 |  102333.33 |   92000.00 |  110000.00
```

**Verify partition pruning:**
```sql
-- Query only 2024 data (should hit only foreign partition)
EXPLAIN (ANALYZE, VERBOSE, COSTS, BUFFERS)
SELECT * FROM employees 
WHERE hire_date BETWEEN '2024-01-01' AND '2024-12-31';

-- Output shows:
-- Foreign Scan on public.emp_2024
--   Output: id, name, hire_date, department, salary
--   Remote SQL: SELECT id, name, hire_date, department, salary 
--               FROM public.emp_2024 
--               WHERE ((hire_date >= '2024-01-01'::date) 
--               AND (hire_date <= '2024-12-31'::date))
```

**Cross-partition queries:**
```sql
-- Find top earners across all years
SELECT name, hire_date, department, salary
FROM employees
ORDER BY salary DESC
LIMIT 5;

-- Department statistics across all partitions
SELECT 
    department,
    COUNT(*) AS total_employees,
    AVG(salary) AS avg_salary,
    MIN(hire_date) AS earliest_hire,
    MAX(hire_date) AS latest_hire
FROM employees
GROUP BY department
ORDER BY avg_salary DESC;

-- Time-series analysis
SELECT 
    DATE_TRUNC('month', hire_date) AS hire_month,
    COUNT(*) AS hires,
    AVG(salary) AS avg_starting_salary
FROM employees
WHERE hire_date >= '2024-01-01'
GROUP BY DATE_TRUNC('month', hire_date)
ORDER BY hire_month;
```

---

### Step 5: Data Modifications

**INSERT operations:**
```sql
-- Insert automatically routes to correct partition based on hire_date
INSERT INTO employees (name, hire_date, department, salary)
VALUES ('Hannah Green', '2024-12-15', 'Sales', 79000.00);

-- Verify it went to archive (foreign partition)
SELECT COUNT(*) FROM emp_2024 WHERE name = 'Hannah Green';
```

**UPDATE operations:**
```sql
-- Update works across partitions
UPDATE employees 
SET salary = salary * 1.05 
WHERE department = 'Engineering';

-- Verify updates applied to both local and foreign partitions
SELECT name, hire_date, salary, 
       CASE WHEN EXTRACT(YEAR FROM hire_date) = 2024 
            THEN 'Archive' ELSE 'Active' END AS location
FROM employees 
WHERE department = 'Engineering'
ORDER BY hire_date;
```

**DELETE operations:**
```sql
-- Delete from archive partition
DELETE FROM employees 
WHERE hire_date < '2024-06-01' AND department = 'HR';

-- Verify deletion on archive instance
-- (Connect to archive and check)
```

---

## Annual Archiving Workflow

### Overview

```
Year End Process:
-----------------
1. Create new archive table on archive instance
2. Create temporary foreign table on main instance
3. Copy data from local partition to archive
4. Verify data integrity
5. Detach and drop local partition
6. Attach foreign partition pointing to archive
7. Create new local partition for upcoming year
```

### Step-by-Step Migration

**1. Prepare Archive Instance (December 2025)**

```bash
docker exec -it pg_archive psql -U postgres -d archive_db
```

```sql
-- Create table for 2025 archive
CREATE TABLE emp_2025 (
    id SERIAL,
    name TEXT NOT NULL,
    hire_date DATE NOT NULL,
    department TEXT,
    salary DECIMAL(10,2),
    CHECK (hire_date >= '2025-01-01' AND hire_date < '2026-01-01')
);

-- Create indexes (same as main instance)
CREATE INDEX idx_emp_2025_date ON emp_2025(hire_date);
CREATE INDEX idx_emp_2025_name ON emp_2025(name);
CREATE INDEX idx_emp_2025_dept ON emp_2025(department);

-- Grant permissions
GRANT SELECT, INSERT, UPDATE, DELETE ON emp_2025 TO postgres;
```

**2. Migrate Data from Main Instance**

```bash
docker exec -it pg_main psql -U postgres -d appdb
```

```sql
-- Create temporary foreign table for migration
CREATE FOREIGN TABLE emp_2025_temp
    SERVER archive_server
    OPTIONS (table_name 'emp_2025');

-- Copy data to archive (this may take time for large tables)
INSERT INTO emp_2025_temp 
SELECT * FROM emp_2025;

-- Verify migration
SELECT 
    (SELECT COUNT(*) FROM emp_2025) AS source_count,
    (SELECT COUNT(*) FROM emp_2025_temp) AS archive_count,
    (SELECT SUM(salary) FROM emp_2025) AS source_sum_salary,
    (SELECT SUM(salary) FROM emp_2025_temp) AS archive_sum_salary;

-- Verify date ranges
SELECT 
    'Source' AS location, 
    MIN(hire_date) AS min_date, 
    MAX(hire_date) AS max_date 
FROM emp_2025
UNION ALL
SELECT 
    'Archive' AS location, 
    MIN(hire_date), 
    MAX(hire_date) 
FROM emp_2025_temp;
```

**3. Replace Local Partition with Foreign Partition**

```sql
-- Detach local partition (data remains, just unlinked)
ALTER TABLE employees DETACH PARTITION emp_2025;

-- Drop local partition (data is now safely in archive)
DROP TABLE emp_2025;

-- Reattach as foreign partition
CREATE FOREIGN TABLE emp_2025 PARTITION OF employees 
    FOR VALUES FROM ('2025-01-01') TO ('2026-01-01')
    SERVER archive_server
    OPTIONS (table_name 'emp_2025');

-- Clean up temporary table
DROP FOREIGN TABLE emp_2025_temp;

-- Verify partition is now foreign
SELECT 
    schemaname,
    tablename,
    CASE WHEN c.relkind = 'f' THEN 'Foreign' 
         ELSE 'Local' END AS table_type
FROM pg_tables t
JOIN pg_class c ON t.tablename = c.relname
WHERE tablename LIKE 'emp_%'
ORDER BY tablename;
```

**4. Create New Local Partition**

```sql
-- Create partition for 2026 (new current year)
CREATE TABLE emp_2026 PARTITION OF employees 
    FOR VALUES FROM ('2026-01-01') TO ('2027-01-01');

-- Create indexes
CREATE INDEX idx_emp_2026_date ON emp_2026(hire_date);
CREATE INDEX idx_emp_2026_name ON emp_2026(name);
CREATE INDEX idx_emp_2026_dept ON emp_2026(department);

-- Verify complete partition setup
SELECT 
    parent.relname AS parent_table,
    child.relname AS partition_name,
    pg_get_expr(child.relpartbound, child.oid) AS partition_bounds,
    CASE WHEN child.relkind = 'f' THEN 'Foreign' 
         ELSE 'Local' END AS partition_type
FROM pg_inherits
JOIN pg_class parent ON pg_inherits.inhparent = parent.oid
JOIN pg_class child ON pg_inherits.inhrelid = child.oid
WHERE parent.relname = 'employees'
ORDER BY partition_bounds;
```

**5. Post-Migration Validation**

```sql
-- Test queries span all partitions
SELECT 
    EXTRACT(YEAR FROM hire_date) AS year,
    COUNT(*) AS count,
    CASE WHEN EXTRACT(YEAR FROM hire_date) = 2026 THEN 'Local'
         ELSE 'Archive' END AS location
FROM employees
GROUP BY EXTRACT(YEAR FROM hire_date)
ORDER BY year;

-- Test INSERT to new partition
INSERT INTO employees (name, hire_date, department, salary)
VALUES ('Test User', '2026-01-15', 'Engineering', 100000.00);

-- Verify it went to local partition
SELECT COUNT(*) FROM emp_2026 WHERE name = 'Test User';
```

---

## Monitoring and Maintenance

### Health Check View

```sql
CREATE OR REPLACE VIEW archive_health AS
SELECT 
    'emp_2026 (local)' AS partition,
    'Local' AS type,
    COUNT(*) AS row_count,
    pg_size_pretty(pg_total_relation_size('emp_2026')) AS size,
    pg_size_pretty(pg_total_relation_size('emp_2026') - pg_relation_size('emp_2026')) AS index_size,
    MIN(hire_date) AS earliest_date,
    MAX(hire_date) AS latest_date,
    CURRENT_TIMESTAMP AS checked_at
FROM emp_2026
UNION ALL
SELECT 
    'emp_2025 (archive)' AS partition,
    'Foreign' AS type,
    COUNT(*) AS row_count,
    NULL AS size,  -- Size is on remote server
    NULL AS index_size,
    MIN(hire_date) AS earliest_date,
    MAX(hire_date) AS latest_date,
    CURRENT_TIMESTAMP AS checked_at
FROM emp_2025
UNION ALL
SELECT 
    'emp_2024 (archive)' AS partition,
    'Foreign' AS type,
    COUNT(*) AS row_count,
    NULL AS size,
    NULL AS index_size,
    MIN(hire_date) AS earliest_date,
    MAX(hire_date) AS latest_date,
    CURRENT_TIMESTAMP AS checked_at
FROM emp_2024;

-- Query the monitoring view
SELECT * FROM archive_health ORDER BY partition DESC;
```

### Connection Monitoring

```sql
-- Check active FDW connections
SELECT 
    datname,
    usename,
    application_name,
    client_addr,
    state,
    query_start,
    state_change,
    query
FROM pg_stat_activity
WHERE application_name LIKE 'postgres_fdw%'
ORDER BY query_start DESC;

-- FDW connection statistics
SELECT 
    server_name,
    COUNT(*) AS active_connections,
    MAX(query_start) AS last_query_time
FROM pg_stat_activity a
JOIN pg_foreign_server s ON a.application_name LIKE '%' || s.srvname || '%'
WHERE application_name LIKE 'postgres_fdw%'
GROUP BY server_name;
```

### Performance Monitoring

```sql
-- Query performance by partition
CREATE OR REPLACE VIEW partition_query_stats AS
SELECT 
    schemaname,
    tablename,
    CASE WHEN c.relkind = 'f' THEN 'Foreign' ELSE 'Local' END AS partition_type,
    seq_scan,
    seq_tup_read,
    idx_scan,
    idx_tup_fetch,
    n_tup_ins,
    n_tup_upd,
    n_tup_del,
    last_vacuum,
    last_analyze
FROM pg_stat_user_tables t
JOIN pg_class c ON t.relname = c.relname
WHERE t.schemaname = 'public' 
  AND t.tablename LIKE 'emp_%'
ORDER BY tablename;

-- Query the view
SELECT * FROM partition_query_stats;
```

### Backup Strategy

**Main Instance Backup (Active Data Only):**
```bash
# Backup only current year partition
docker exec pg_main pg_dump -U postgres -d appdb \
    --table=emp_2026 \
    --table=employees \
    --format=custom \
    --file=/tmp/main_backup_$(date +%Y%m%d).dump

# Backup entire main database (excluding foreign tables data)
docker exec pg_main pg_dump -U postgres -d appdb \
    --exclude-table-data='emp_202[0-5]' \
    --format=custom \
    --file=/tmp/main_full_backup_$(date +%Y%m%d).dump
```

**Archive Instance Backup (Historical Data):**
```bash
# Backup individual archive table
docker exec pg_archive pg_dump -U postgres -d archive_db \
    --table=emp_2024 \
    --format=custom \
    --file=/tmp/archive_2024_$(date +%Y%m%d).dump

# Backup entire archive database
docker exec pg_archive pg_dump -U postgres -d archive_db \
    --format=custom \
    --file=/tmp/archive_full_backup_$(date +%Y%m%d).dump
```

**Parallel Backup Strategy:**
```bash
#!/bin/bash
# parallel_backup.sh

DATE=$(date +%Y%m%d)

# Backup main and archives in parallel
(
    docker exec pg_main pg_dump -U postgres -d appdb \
        --exclude-table-data='emp_202[0-5]' \
        -Fc -f /tmp/main_${DATE}.dump
) &

(
    docker exec pg_archive pg_dump -U postgres -d archive_db \
        -Fc -f /tmp/archive_${DATE}.dump
) &

wait
echo "Backups completed: main_${DATE}.dump, archive_${DATE}.dump"
```

**Restore Procedure:**
```bash
# Restore main instance
docker exec pg_main pg_restore -U postgres -d appdb \
    --clean --if-exists \
    /tmp/main_backup.dump

# Restore specific archive table
docker exec pg_archive pg_restore -U postgres -d archive_db \
    --table=emp_2024 \
    /tmp/archive_2024_backup.dump

# Recreate FDW connections after restore
docker exec -it pg_main psql -U postgres -d appdb <<EOF
CREATE EXTENSION IF NOT EXISTS postgres_fdw;
-- Re-create server and user mappings
-- Re-create foreign table partitions
EOF
```

---

## Production Best Practices

### Security

**1. Dedicated Service Accounts:**
```sql
-- On archive instance: create read-only service account
CREATE ROLE fdw_reader WITH LOGIN PASSWORD 'strong_password_here';
GRANT CONNECT ON DATABASE archive_db TO fdw_reader;
GRANT USAGE ON SCHEMA public TO fdw_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO fdw_reader;

-- For write access (if needed for archiving)
CREATE ROLE fdw_writer WITH LOGIN PASSWORD 'another_strong_password';
GRANT CONNECT ON DATABASE archive_db TO fdw_writer;
GRANT USAGE ON SCHEMA public TO fdw_writer;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO fdw_writer;

-- On main instance: update user mapping
ALTER USER MAPPING FOR postgres SERVER archive_server
    OPTIONS (SET user 'fdw_reader', SET password 'strong_password_here');
```

**2. SSL/TLS Connection:**
```sql
-- Require encrypted connections
ALTER SERVER archive_server 
    OPTIONS (ADD sslmode 'require');

-- For certificate verification
ALTER SERVER archive_server 
    OPTIONS (
        SET sslmode 'verify-full',
        ADD sslcert '/path/to/client-cert.pem',
        ADD sslkey '/path/to/client-key.pem',
        ADD sslrootcert '/path/to/root-ca.pem'
    );
```

**3. Password Management:**
```sql
-- Store passwords in .pgpass file instead of user mapping
-- Format: hostname:port:database:username:password
-- Example .pgpass:
-- archive.example.com:5432:archive_db:fdw_reader:strong_password

-- Create user mapping without password
CREATE USER MAPPING FOR postgres 
    SERVER archive_server 
    OPTIONS (user 'fdw_reader');
```

**4. Network Security:**
```yaml
# docker-compose.yml - restrict network access
services:
  postgres_main:
    networks:
      - pg_internal
      - external
  
  postgres_archive:
    networks:
      - pg_internal  # Only accessible via internal network

networks:
  pg_internal:
    internal: true
  external:
    driver: bridge
```

### Performance Tuning

**1. FDW Server Options:**
```sql
-- Optimize fetch size based on query patterns
ALTER SERVER archive_server 
    OPTIONS (SET fetch_size '50000');  -- Larger for analytical queries

-- Enable remote cost estimates for better query planning
ALTER SERVER archive_server 
    OPTIONS (SET use_remote_estimate 'true');

-- Enable async execution for parallel queries
ALTER SERVER archive_server 
    OPTIONS (SET async_capable 'true');

-- Connection pooling
ALTER SERVER archive_server 
    OPTIONS (
        SET keep_connections 'on',
        SET extensions 'postgres_fdw'
    );
```

**2. Index Strategy:**
```sql
-- Archive tables should have same indexes as local tables
-- On archive instance:
CREATE INDEX CONCURRENTLY idx_emp_2024_dept_salary 
    ON emp_2024(department, salary DESC);

CREATE INDEX CONCURRENTLY idx_emp_2024_hire_date_dept 
    ON emp_2024(hire_date, department);

-- Partial indexes for common filters
CREATE INDEX CONCURRENTLY idx_emp_2024_engineering 
    ON emp_2024(hire_date) 
    WHERE department = 'Engineering';
```

**3. Statistics and ANALYZE:**
```sql
-- On archive instance: keep statistics current
ANALYZE VERBOSE emp_2024;

-- Set statistics target for better planning
ALTER TABLE emp_2024 
    ALTER COLUMN hire_date SET STATISTICS 1000;

-- Main instance: import foreign table statistics
IMPORT FOREIGN SCHEMA public 
    LIMIT TO (emp_2024)
    FROM SERVER archive_server 
    INTO public 
    OPTIONS (import_default 'true');
```

**4. Query Optimization:**
```sql
-- Use explicit partition pruning hints
SELECT * FROM employees
WHERE hire_date >= '2024-01-01' 
  AND hire_date < '2025-01-01'  -- PostgreSQL prunes to emp_2024 only
  AND department = 'Engineering';

-- Avoid functions that prevent pushdown
-- Bad: WHERE EXTRACT(YEAR FROM hire_date) = 2024
-- Good: WHERE hire_date >= '2024-01-01' AND hire_date < '2025-01-01'

-- Enable parallel query on foreign tables (PostgreSQL 14+)
SET max_parallel_workers_per_gather = 4;
```

---

## Troubleshooting Guide

### Issue 1: Connection Refused

**Symptoms:**
```
ERROR: could not connect to server "archive_server"
DETAIL: could not connect to server: Connection refused
```

**Diagnosis:**
```sql
-- Check server configuration
SELECT srvname, srvoptions FROM pg_foreign_server;

-- Test network connectivity
\! docker exec pg_main pg_isready -h postgres_archive -p 5432

-- Check archive instance is running
\! docker-compose ps postgres_archive
```

**Solutions:**
```bash
# Restart archive instance
docker-compose restart postgres_archive

# Verify network connectivity
docker exec pg_main ping -c 3 postgres_archive

# Check firewall rules (production)
sudo iptables -L -n | grep 5432

# Verify PostgreSQL is listening
docker exec pg_archive netstat -tlnp | grep 5432
```

### Issue 2: Authentication Failed

**Symptoms:**
```
ERROR: password authentication failed for user "fdw_reader"
```

**Diagnosis:**
```sql
-- Check user mapping
SELECT * FROM pg_user_mapping 
JOIN pg_foreign_server ON umserver = oid;

-- On archive instance: verify user exists
SELECT usename, usesuper FROM pg_user WHERE usename = 'fdw_reader';
```

**Solutions:**
```sql
-- Update user mapping with correct credentials
ALTER USER MAPPING FOR postgres SERVER archive_server
    OPTIONS (SET password 'correct_password');

-- On archive instance: reset password
ALTER USER fdw_reader WITH PASSWORD 'new_strong_password';

-- Verify pg_hba.conf allows connection
-- On archive instance:
-- Add: host archive_db fdw_reader pg_main md5
```

### Issue 3: Table Not Found

**Symptoms:**
```
ERROR: relation "public.emp_2024" does not exist
```

**Diagnosis:**
```bash
# Connect to archive instance
docker exec -it pg_archive psql -U postgres -d archive_db

# Check table exists
\dt emp_*

# Check schema
\dn

# Verify table in correct database
\l
```

**Solutions:**
```sql
-- Specify schema explicitly in foreign table
DROP FOREIGN TABLE IF EXISTS emp_2024;

CREATE FOREIGN TABLE emp_2024 PARTITION OF employees 
    FOR VALUES FROM ('2024-01-01') TO ('2025-01-01')
    SERVER archive_server
    OPTIONS (
        schema_name 'public',
        table_name 'emp_2024'
    );

-- Or use IMPORT FOREIGN SCHEMA
IMPORT FOREIGN SCHEMA public 
    LIMIT TO (emp_2024)
    FROM SERVER archive_server 
    INTO public;
```

### Issue 4: Slow Query Performance

**Symptoms:**
- Queries take much longer than expected
- High network traffic
- Timeouts on large result sets

**Diagnosis:**
```sql
-- Check query plan
EXPLAIN (ANALYZE, VERBOSE, BUFFERS)
SELECT * FROM employees WHERE hire_date BETWEEN '2024-01-01' AND '2024-12-31';

-- Look for:
-- - Foreign Scan with remote SQL showing pushed predicates
-- - High execution time on foreign scan
-- - Large number of rows fetched
```

**Solutions:**
```sql
-- 1. Increase fetch size
ALTER SERVER archive_server 
    OPTIONS (SET fetch_size '100000');

-- 2. Create missing indexes on archive
-- (Connect to archive instance)
CREATE INDEX CONCURRENTLY idx_emp_2024_compound 
    ON emp_2024(hire_date, department);

-- 3. Enable remote estimates
ALTER SERVER archive_server 
    OPTIONS (SET use_remote_estimate 'true');

-- 4. Use LIMIT for large result sets
SELECT * FROM employees 
WHERE hire_date BETWEEN '2024-01-01' AND '2024-12-31'
LIMIT 1000;

-- 5. Check network latency
\! docker exec pg_main ping -c 10 postgres_archive | grep avg
```

### Issue 5: Partition Pruning Not Working

**Symptoms:**
- Queries scan all partitions instead of just relevant ones
- EXPLAIN shows Foreign Scan on multiple partitions

**Diagnosis:**
```sql
-- Check partition constraints
SELECT 
    child.relname AS partition,
    pg_get_expr(child.relpartbound, child.oid) AS bounds
FROM pg_inherits
JOIN pg_class parent ON inhparent = parent.oid
JOIN pg_class child ON inhrelid = child.oid
WHERE parent.relname = 'employees';

-- Check query predicate
EXPLAIN (ANALYZE, VERBOSE)
SELECT * FROM employees WHERE hire_date = '2024-06-15';
```

**Solutions:**
```sql
-- Ensure WHERE clause matches partition key
-- Bad: WHERE EXTRACT(YEAR FROM hire_date) = 2024
-- Good: WHERE hire_date BETWEEN '2024-01-01' AND '2024-12-31'

-- Enable constraint exclusion
SET constraint_exclusion = partition;  -- or 'on'

-- Ensure CHECK constraints exist on archive tables
ALTER TABLE emp_2024 ADD CHECK (
    hire_date >= '2024-01-01' AND hire_date < '2025-01-01'
);
```

---

## Decommissioning Old Archives

### When to Decommission

**Retention Policy Examples:**
- **Financial:** 7-10 years for tax/audit compliance
- **Healthcare:** HIPAA requires 6 years minimum
- **GDPR:** Right to deletion may require earlier removal
- **SOX:** 7 years for public company records

### Decommissioning Procedure

**Step 1: Verify Retention Requirements**
```sql
-- Check partition age and size
SELECT 
    schemaname,
    tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size,
    (SELECT MIN(hire_date) FROM employees WHERE hire_date >= '2020-01-01' AND hire_date < '2021-01-01') AS earliest_date,
    AGE(CURRENT_DATE, (SELECT MIN(hire_date) FROM employees WHERE hire_date >= '2020-01-01' AND hire_date < '2021-01-01')) AS age
FROM pg_tables 
WHERE tablename = 'emp_2020';
```

**Step 2: Final Backup Before Decommission**
```bash
# Create final backup with timestamp
docker exec pg_archive pg_dump -U postgres -d archive_db \
    --table=emp_2020 \
    --format=custom \
    --file=/backups/FINAL_emp_2020_$(date +%Y%m%d).dump

# Verify backup integrity
docker exec pg_archive pg_restore --list /backups/FINAL_emp_2020_*.dump
```

**Step 3: Detach from Main Instance**
```sql
-- Connect to main instance
-- Detach foreign partition
ALTER TABLE employees DETACH PARTITION emp_2020;

-- Drop foreign table definition
DROP FOREIGN TABLE emp_2020;

-- Verify partition is removed
SELECT * FROM pg_inherits 
JOIN pg_class ON inhrelid = oid 
WHERE relname = 'emp_2020';  -- Should return 0 rows
```

**Step 4: Archive Data Export (Optional)**
```bash
# Export to long-term storage format (CSV/Parquet)
docker exec pg_archive psql -U postgres -d archive_db -c \
    "COPY emp_2020 TO STDOUT WITH CSV HEADER" > emp_2020_archive.csv

# Compress for storage
gzip emp_2020_archive.csv

# Move to cold storage (S3, Glacier, tape)
aws s3 cp emp_2020_archive.csv.gz s3://long-term-archive/employees/
```

**Step 5: Drop from Archive Instance**
```bash
# Connect to archive instance
docker exec -it pg_archive psql -U postgres -d archive_db
```

```sql
-- Final verification before drop
SELECT COUNT(*), MIN(hire_date), MAX(hire_date) FROM emp_2020;

-- Drop table
DROP TABLE emp_2020;

-- Verify removal
\dt emp_*
```

**Step 6: Clean Up FDW Objects (If No Longer Needed)**
```sql
-- On main instance
-- If this was the only table on this archive instance
DROP USER MAPPING IF EXISTS FOR postgres SERVER old_archive_2020;
DROP SERVER IF EXISTS old_archive_2020;
```

**Step 7: Decommission Archive Instance**
```bash
# Stop container
docker-compose stop postgres_archive_2020

# Remove container
docker-compose rm -f postgres_archive_2020

# Remove volume (CAUTION: irreversible)
docker volume rm project_pg_archive_2020_data

# Update docker-compose.yml to remove service definition
```

### Audit Trail

```sql
-- Create decommission log table
CREATE TABLE archive_decommission_log (
    id SERIAL PRIMARY KEY,
    table_name TEXT NOT NULL,
    partition_range TEXT,
    row_count BIGINT,
    size_bytes BIGINT,
    earliest_date DATE,
    latest_date DATE,
    backup_location TEXT,
    decommissioned_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    decommissioned_by TEXT DEFAULT CURRENT_USER,
    retention_reason TEXT
);

-- Log decommission
INSERT INTO archive_decommission_log 
    (table_name, partition_range, row_count, size_bytes, 
     earliest_date, latest_date, backup_location, retention_reason)
SELECT 
    'emp_2020',
    '2020-01-01 to 2021-01-01',
    COUNT(*),
    pg_total_relation_size('emp_2020'),
    MIN(hire_date),
    MAX(hire_date),
    's3://long-term-archive/employees/emp_2020_archive.csv.gz',
    '7-year retention period expired'
FROM emp_2020;
```

---

## Key Metrics and KPIs

### Performance Metrics

**Query Latency by Partition Type:**
```sql
CREATE VIEW fdw_query_performance AS
SELECT 
    CASE WHEN query LIKE '%emp_202[0-4]%' THEN 'Foreign (Archive)'
         WHEN query LIKE '%emp_202[5-9]%' THEN 'Local (Active)'
         ELSE 'Unknown' END AS partition_type,
    COUNT(*) AS query_count,
    AVG(total_exec_time) AS avg_exec_time_ms,
    PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY total_exec_time) AS median_exec_time_ms,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY total_exec_time) AS p95_exec_time_ms,
    PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY total_exec_time) AS p99_exec_time_ms
FROM pg_stat_statements
WHERE query LIKE '%employees%'
GROUP BY partition_type;
```

**Data Distribution:**
```sql
SELECT 
    'Total Rows' AS metric,
    SUM(row_count)::TEXT AS value
FROM (
    SELECT COUNT(*) AS row_count FROM emp_2024
    UNION ALL
    SELECT COUNT(*) FROM emp_2025
    UNION ALL
    SELECT COUNT(*) FROM emp_2026
) AS combined
UNION ALL
SELECT 
    'Archive Ratio',
    ROUND(100.0 * SUM(CASE WHEN tbl LIKE '%202[0-4]' THEN cnt ELSE 0 END) / SUM(cnt), 2)::TEXT || '%'
FROM (
    SELECT 'emp_2024' AS tbl, COUNT(*) AS cnt FROM emp_2024
    UNION ALL
    SELECT 'emp_2025', COUNT(*) FROM emp_2025
    UNION ALL
    SELECT 'emp_2026', COUNT(*) FROM emp_2026
) AS dist;
```

### Storage Metrics

```sql
CREATE VIEW storage_metrics AS
SELECT 
    schemaname,
    tablename,
    CASE WHEN c.relkind = 'f' THEN 'Foreign' ELSE 'Local' END AS type,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS total_size,
    pg_size_pretty(pg_relation_size(schemaname||'.'||tablename)) AS table_size,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename) - 
                   pg_relation_size(schemaname||'.'||tablename)) AS indexes_size,
    (SELECT COUNT(*) FROM pg_indexes WHERE schemaname = t.schemaname AND tablename = t.tablename) AS index_count
FROM pg_tables t
JOIN pg_class c ON t.tablename = c.relname
WHERE t.schemaname = 'public' AND t.tablename LIKE 'emp_%'
ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;
```

---

## Real-World Applications

### 1. E-Commerce Platform

**Scenario:** Online retailer with 10 years of order history

```
Main Instance (5432):
  - orders_2024 (Local)  → Active orders, fast SSD
  - orders_2025 (Local)  → Current year
  
Archive Instance 1 (5433):
  - orders_2020 (Archive)
  - orders_2021 (Archive)
  - orders_2022 (Archive)
  
Archive Instance 2 (5434):
  - orders_2017 (Archive)
  - orders_2018 (Archive)
  - orders_2019 (Archive)
  
Cold Storage (S3):
  - orders_2015.csv.gz
  - orders_2016.csv.gz
```

**Benefits:**
- Fast queries on recent orders (local SSD)
- Compliance: 7-year retention accessible via SQL
- Cost: Archive on HDD, cold storage on S3 Glacier

### 2. Healthcare Records (HIPAA)

**Scenario:** Hospital with 15 years of patient records

```
Main Instance:
  - patient_records_2024 (Local)
  - patient_records_2025 (Local)
  
Archive Instance (Encrypted):
  - patient_records_2010-2023 (Foreign partitions)
  - Encrypted at rest
  - Audit logging enabled
  - 6-year minimum retention
```

**Compliance:**
- HIPAA requires 6 years minimum
- FDW maintains audit trail
- Encrypted connections (SSL/TLS)
- Role-based access control

### 3. Financial Services (SOX)

**Scenario:** Bank with transaction history

```
Main Instance:
  - transactions_2025_Q1 (Local)
  - transactions_2025_Q2 (Local)
  
Archive by Quarter:
  - transactions_2024_Q* (Foreign)
  - transactions_2023_Q* (Foreign)
  - 7-year retention for SOX
```

**Features:**
- Quarterly partitioning for faster archival
- Immutable archive storage
- Point-in-time recovery
- Regulatory reporting queries span all years

### 4. SaaS Analytics

**Scenario:** SaaS platform with user activity logs

```
Main Instance:
  - user_events_2025_12 (Local) → Current month
  
Archive by Month:
  - user_events_2025_01 through 2025_11 (Foreign)
  - user_events_2024_* (Foreign)
  - Monthly aggregates pre-computed
```

**Optimization:**
- Monthly partition = faster monthly reports
- Aggregated views on archive for dashboards
- Raw data available for deep dives

---

## Migration Checklist

### Pre-Migration
- [ ] Document current data retention requirements
- [ ] Identify partitioning strategy (yearly, quarterly, monthly)
- [ ] Size archive instances based on data volume
- [ ] Plan network connectivity (VPC, security groups)
- [ ] Design backup strategy per instance
- [ ] Create runbooks for annual archiving workflow

### Implementation
- [ ] Set up archive instance(s)
- [ ] Enable postgres_fdw extension on main instance
- [ ] Create foreign server definitions
- [ ] Configure user mappings with appropriate credentials
- [ ] Create partitioned table structure
- [ ] Create local partition for current period
- [ ] Create archive tables with identical schema
- [ ] Create foreign table partitions
- [ ] Create indexes on archive tables (match main instance)
- [ ] Verify partition pruning with EXPLAIN
- [ ] Test queries across partitions
- [ ] Test INSERT/UPDATE/DELETE operations

### Production Readiness
- [ ] Implement SSL/TLS for FDW connections
- [ ] Configure dedicated service accounts (no superuser)
- [ ] Set up monitoring views and dashboards
- [ ] Create alerts for FDW connection failures
- [ ] Document backup procedures for each instance
- [ ] Test backup and restore procedures
- [ ] Create decommissioning procedures
- [ ] Train team on architecture and operations
- [ ] Update application documentation

### Post-Migration
- [ ] Monitor query performance (local vs foreign)
- [ ] Tune fetch_size and other FDW parameters
- [ ] Review and optimize slow queries
- [ ] Verify backups are running successfully
- [ ] Test annual archiving workflow in non-prod
- [ ] Schedule next archiving cycle
- [ ] Review storage costs and optimization opportunities

---

## Key Takeaways

1. **Transparent Access:** FDW + Partitioning provides seamless access to distributed data without application changes

2. **Operational Independence:** Each instance can be backed up, scaled, and maintained separately

3. **Cost Optimization:** Use different storage tiers—fast SSD for active data, cheaper HDD for archives

4. **Flexible Retention:** Easy to add/remove archive instances as retention requirements change

5. **Query Performance:** Partition pruning ensures queries only hit relevant instances

6. **Compliance-Ready:** Maintains historical data accessibility for regulatory requirements (GDPR, HIPAA, SOX)

7. **Scalability:** Distribute storage and query load across multiple instances

8. **Production Considerations:** SSL/TLS, dedicated accounts, monitoring, and proper backup strategies are essential

---

## References

- **Source Article:** [Medium - PostgreSQL FDW Data Archiving](https://medium.com/@mojtababanaei_64736/postgresql-foreign-data-wrapper-a-practical-guide-to-distributed-data-archiving-7fe7dd6c54c3)
- **PostgreSQL FDW Documentation:** https://www.postgresql.org/docs/current/postgres-fdw.html
- **Table Partitioning Guide:** https://www.postgresql.org/docs/current/ddl-partitioning.html
---
