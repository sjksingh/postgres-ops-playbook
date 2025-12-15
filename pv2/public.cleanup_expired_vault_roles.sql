CREATE OR REPLACE FUNCTION public.cleanup_expired_vault_roles(service_pattern text)
RETURNS TABLE(
    service_name text,
    total_attempted integer,
    successfully_dropped integer,
    failed integer
)
LANGUAGE plpgsql
AS $function$
DECLARE
    role_record RECORD;
    schema_name TEXT;
    db_name TEXT;
    v_dropped INTEGER := 0;
    v_failed INTEGER := 0;
    v_total INTEGER;
BEGIN
    -- Get current database name
    SELECT current_database() INTO db_name;

    -- Get total count of expired roles
    SELECT COUNT(*) INTO v_total
    FROM pg_roles
    WHERE rolname LIKE 'v-kubernet-' || service_pattern || '%'
      AND rolvaliduntil IS NOT NULL
      AND rolvaliduntil < NOW();

    RAISE NOTICE 'Starting cleanup of % expired % roles...', v_total, service_pattern;

    -- Process each expired role
    FOR role_record IN
        SELECT rolname, rolvaliduntil
        FROM pg_roles
        WHERE rolname LIKE 'v-kubernet-' || service_pattern || '%'
          AND rolvaliduntil IS NOT NULL
          AND rolvaliduntil < NOW()
        ORDER BY rolvaliduntil ASC
    LOOP
        BEGIN
            -- Revoke database-level privileges
            BEGIN
                EXECUTE format('REVOKE ALL ON DATABASE %I FROM %I', db_name, role_record.rolname);
            EXCEPTION WHEN OTHERS THEN NULL; END;

            -- Revoke from all schemas
            FOR schema_name IN
                SELECT nspname
                FROM pg_namespace
                WHERE nspname NOT LIKE 'pg_%'
                  AND nspname != 'information_schema'
            LOOP
                BEGIN
                    EXECUTE format('REVOKE ALL ON SCHEMA %I FROM %I', schema_name, role_record.rolname);
                    EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA %I FROM %I', schema_name, role_record.rolname);
                    EXECUTE format('REVOKE ALL ON ALL SEQUENCES IN SCHEMA %I FROM %I', schema_name, role_record.rolname);
                    EXECUTE format('REVOKE ALL ON ALL FUNCTIONS IN SCHEMA %I FROM %I', schema_name, role_record.rolname);
                EXCEPTION WHEN OTHERS THEN NULL; END;
            END LOOP;

            -- Clean up default privileges
            FOR schema_name IN
                SELECT nspname
                FROM pg_namespace
                WHERE nspname IN ('public', 'contacts', 'file_vault', 'max', 'notifications', 'observations', 'users')
            LOOP
                BEGIN
                    EXECUTE format(
                        'ALTER DEFAULT PRIVILEGES FOR ROLE platformv2 IN SCHEMA %I REVOKE ALL ON TABLES FROM %I',
                        schema_name, role_record.rolname
                    );
                    EXECUTE format(
                        'ALTER DEFAULT PRIVILEGES FOR ROLE platformv2 IN SCHEMA %I REVOKE ALL ON SEQUENCES FROM %I',
                        schema_name, role_record.rolname
                    );
                    EXECUTE format(
                        'ALTER DEFAULT PRIVILEGES FOR ROLE platformv2 IN SCHEMA %I REVOKE ALL ON FUNCTIONS FROM %I',
                        schema_name, role_record.rolname
                    );
                    EXECUTE format(
                        'ALTER DEFAULT PRIVILEGES FOR ROLE platformv2 IN SCHEMA %I REVOKE ALL ON TYPES FROM %I',
                        schema_name, role_record.rolname
                    );
                EXCEPTION WHEN OTHERS THEN NULL; END;
            END LOOP;

            -- Reassign and drop owned objects
            BEGIN
                EXECUTE format('REASSIGN OWNED BY %I TO platformv2', role_record.rolname);
            EXCEPTION WHEN OTHERS THEN NULL; END;

            BEGIN
                EXECUTE format('DROP OWNED BY %I CASCADE', role_record.rolname);
            EXCEPTION WHEN OTHERS THEN NULL; END;

            -- Drop the role
            EXECUTE format('DROP ROLE %I', role_record.rolname);
            v_dropped := v_dropped + 1;

            IF v_dropped % 10 = 0 THEN
                RAISE NOTICE 'Progress: % / % roles dropped', v_dropped, v_total;
            END IF;

        EXCEPTION WHEN OTHERS THEN
            v_failed := v_failed + 1;
            RAISE NOTICE 'Failed to drop %: %', role_record.rolname, SQLERRM;
        END;
    END LOOP;

    RAISE NOTICE 'Cleanup complete for %: % dropped, % failed', service_pattern, v_dropped, v_failed;

    -- Return results
    RETURN QUERY SELECT service_pattern, v_total, v_dropped, v_failed;
END;
$function$;
