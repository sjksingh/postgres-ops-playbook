/*
Tablespace Disk Usage Monitoring

Purpose:
Help identify potential exhaustion of data disks or tablespaces where user data (tables, indexes, etc.) reside.

Context:
- PostgreSQL stores persistent data in tablespaces, which are mapped to directories on the host filesystem.
- If a tablespace fills up, INSERT, UPDATE, and CREATE operations may fail with “No space left on device”.
- While PostgreSQL doesn't expose filesystem free space, it can report space consumption at the tablespace and relation level.

Primary monitoring of actual free space must be done at the OS level.

*/

-- 🟢 Total Disk Usage Per Tablespace
SELECT
    spcname AS tablespace_name,
    pg_catalog.pg_tablespace_location(oid) AS tablespace_location, -- Filesystem path for the tablespace
    pg_catalog.pg_size_pretty(pg_catalog.pg_tablespace_size(oid)) AS total_size_used
FROM
    pg_catalog.pg_tablespace
ORDER BY
    pg_catalog.pg_tablespace_size(oid) DESC;

-- 🟡 Largest Relations (Tables + Indexes) by Size — run per database
-- Use this to find space-heavy objects quickly.
SELECT
    n.nspname AS schema_name,
    c.relname AS relation_name,
    CASE c.relkind
        WHEN 'r' THEN 'TABLE'
        WHEN 'i' THEN 'INDEX'
        WHEN 'S' THEN 'SEQUENCE'
        WHEN 'v' THEN 'VIEW'
        WHEN 'm' THEN 'MATERIALIZED VIEW'
        WHEN 'c' THEN 'COMPOSITE TYPE'
        WHEN 't' THEN 'TOAST TABLE'
        WHEN 'f' THEN 'FOREIGN TABLE'
        ELSE c.relkind::text
    END AS relation_type,
    pg_catalog.pg_size_pretty(pg_catalog.pg_total_relation_size(c.oid)) AS total_size
FROM
    pg_catalog.pg_class c
LEFT JOIN
    pg_catalog.pg_namespace n ON n.oid = c.relnamespace
WHERE
    n.nspname NOT IN ('pg_catalog', 'information_schema')
    AND c.relpersistence <> 't' -- Exclude temporary relations
    AND pg_catalog.pg_table_is_visible(c.oid)
ORDER BY
    pg_catalog.pg_total_relation_size(c.oid) DESC
LIMIT 50;
