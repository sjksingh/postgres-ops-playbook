/*
This query lists all user-defined FOREIGN KEY constraints in the database,
including origin and referenced columns, ON UPDATE/DELETE actions,
and whether the constraint is currently validated.

Purpose:
- To understand table relationships and constraint behavior.
- Helpful for debugging performance issues related to MultiXacts,
  locking, and cascading foreign key actions.

Context:
- Heavy foreign key usage, particularly with cascading ON UPDATE/DELETE actions,
  can increase row-level locking and MultiXact usage.
- This becomes especially relevant in high-concurrency workloads.

Excludes:
- System schemas: pg_catalog, information_schema, pg_toast
- System tables: Only includes ordinary and partitioned tables
*/

WITH fk_info AS (
    SELECT
        c.oid AS constraint_oid,
        c.conname AS constraint_name,
        ns.nspname AS fk_origin_schema,
        tbl.relname AS fk_origin_table,
        c.conrelid,                          -- OID of the origin (child) table
        c.conkey AS fk_origin_columns_attnum, -- Origin column attnums
        fns.nspname AS fk_referenced_schema,
        ftbl.relname AS fk_referenced_table,
        c.confrelid,                         -- OID of the referenced (parent) table
        c.confkey AS fk_referenced_columns_attnum, -- Referenced column attnums
        c.confupdtype,                       -- ON UPDATE action
        c.confdeltype,                       -- ON DELETE action
        c.convalidated                       -- Whether the constraint is validated
    FROM
        pg_catalog.pg_constraint c
    JOIN pg_catalog.pg_class tbl ON c.conrelid = tbl.oid
    JOIN pg_catalog.pg_namespace ns ON tbl.relnamespace = ns.oid
    JOIN pg_catalog.pg_class ftbl ON c.confrelid = ftbl.oid
    JOIN pg_catalog.pg_namespace fns ON ftbl.relnamespace = fns.oid
    WHERE
        c.contype = 'f'  -- Foreign keys only
        AND ns.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
        AND tbl.relkind IN ('r', 'p')  -- Ordinary and partitioned tables only
)
SELECT
    fi.constraint_name,
    fi.fk_origin_schema,
    fi.fk_origin_table,
    -- Map origin column attnums to column names
    (
        SELECT array_agg(a.attname ORDER BY pg_catalog.array_position(fi.fk_origin_columns_attnum, a.attnum))
        FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = fi.conrelid
          AND a.attnum = ANY(fi.fk_origin_columns_attnum)
    ) AS fk_origin_columns,
    fi.fk_referenced_schema,
    fi.fk_referenced_table,
    -- Map referenced column attnums to column names
    (
        SELECT array_agg(a.attname ORDER BY pg_catalog.array_position(fi.fk_referenced_columns_attnum, a.attnum))
        FROM pg_catalog.pg_attribute a
        WHERE a.attrelid = fi.confrelid
          AND a.attnum = ANY(fi.fk_referenced_columns_attnum)
    ) AS fk_referenced_columns,
    -- Decode ON UPDATE behavior
    CASE fi.confupdtype
        WHEN 'a' THEN 'NO ACTION'
        WHEN 'r' THEN 'RESTRICT'
        WHEN 'c' THEN 'CASCADE'
        WHEN 'n' THEN 'SET NULL'
        WHEN 'd' THEN 'SET DEFAULT'
        ELSE fi.confupdtype::text
    END AS on_update,
    -- Decode ON DELETE behavior
    CASE fi.confdeltype
        WHEN 'a' THEN 'NO ACTION'
        WHEN 'r' THEN 'RESTRICT'
        WHEN 'c' THEN 'CASCADE'
        WHEN 'n' THEN 'SET NULL'
        WHEN 'd' THEN 'SET DEFAULT'
        ELSE fi.confdeltype::text
    END AS on_delete,
    fi.convalidated AS is_validated
FROM
    fk_info fi
ORDER BY
    fi.fk_origin_schema,
    fi.fk_origin_table,
    fi.constraint_name;
