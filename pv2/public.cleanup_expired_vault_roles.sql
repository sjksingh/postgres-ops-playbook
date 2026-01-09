CREATE OR REPLACE FUNCTION public.cleanup_expired_vault_roles(service_pattern text)
 RETURNS TABLE(service_name text, total_attempted integer, successfully_dropped integer, failed integer)
 LANGUAGE plpgsql
AS $function$
DECLARE
    role_record RECORD;
    schema_record RECORD;
    db_name TEXT;
    v_dropped INTEGER := 0;
    v_failed INTEGER := 0;
    v_total INTEGER;
    v_error_msg TEXT;
    member_role TEXT;
    default_acl_record RECORD;
BEGIN
    -- Get current database name
    SELECT current_database() INTO db_name;

    -- Get total count
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
            -- Step 1: CRITICAL - Revoke membership FROM platformv2 (or parent roles)
            BEGIN
                FOR member_role IN
                    SELECT pg_get_userbyid(roleid) as role_name
                    FROM pg_auth_members
                    WHERE pg_get_userbyid(member) = role_record.rolname
                LOOP
                    RAISE NOTICE 'Revoking % from %', member_role, role_record.rolname;
                    EXECUTE format('REVOKE %I FROM %I', member_role, role_record.rolname);
                END LOOP;
            EXCEPTION WHEN OTHERS THEN
                v_error_msg := SQLERRM;
                RAISE NOTICE 'Warning - member revocation for %: %', role_record.rolname, v_error_msg;
            END;

            -- Step 2: Revoke this role FROM other roles (where it was granted)
            BEGIN
                FOR member_role IN
                    SELECT pg_get_userbyid(member) as member_name
                    FROM pg_auth_members
                    WHERE pg_get_userbyid(roleid) = role_record.rolname
                LOOP
                    RAISE NOTICE 'Revoking % from %', role_record.rolname, member_role;
                    EXECUTE format('REVOKE %I FROM %I', role_record.rolname, member_role);
                END LOOP;
            EXCEPTION WHEN OTHERS THEN
                v_error_msg := SQLERRM;
                RAISE NOTICE 'Warning - role membership revocation for %: %', role_record.rolname, v_error_msg;
            END;

            -- Step 3: Clean up default ACL entries for this role
            BEGIN
                FOR default_acl_record IN
                    SELECT
                        defaclnamespace,
                        defaclobjtype,
                        pg_get_userbyid(defaclrole) as defaclrole_name,
                        n.nspname as schema_name
                    FROM pg_default_acl d
                    LEFT JOIN pg_namespace n ON n.oid = d.defaclnamespace
                    WHERE defaclacl::text LIKE '%' || role_record.rolname || '%'
                LOOP
                    RAISE NOTICE 'Cleaning default ACL in schema % for %',
                        COALESCE(default_acl_record.schema_name, 'PUBLIC'),
                        role_record.rolname;

                    -- Revoke default privileges based on object type
                    IF default_acl_record.defaclobjtype = 'r' THEN -- tables
                        IF default_acl_record.schema_name IS NOT NULL THEN
                            EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I REVOKE ALL ON TABLES FROM %I',
                                default_acl_record.defaclrole_name, default_acl_record.schema_name, role_record.rolname);
                        ELSE
                            EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I REVOKE ALL ON TABLES FROM %I',
                                default_acl_record.defaclrole_name, role_record.rolname);
                        END IF;
                    ELSIF default_acl_record.defaclobjtype = 'S' THEN -- sequences
                        IF default_acl_record.schema_name IS NOT NULL THEN
                            EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I REVOKE ALL ON SEQUENCES FROM %I',
                                default_acl_record.defaclrole_name, default_acl_record.schema_name, role_record.rolname);
                        ELSE
                            EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I REVOKE ALL ON SEQUENCES FROM %I',
                                default_acl_record.defaclrole_name, role_record.rolname);
                        END IF;
                    ELSIF default_acl_record.defaclobjtype = 'f' THEN -- functions
                        IF default_acl_record.schema_name IS NOT NULL THEN
                            EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I REVOKE ALL ON FUNCTIONS FROM %I',
                                default_acl_record.defaclrole_name, default_acl_record.schema_name, role_record.rolname);
                        ELSE
                            EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I REVOKE ALL ON FUNCTIONS FROM %I',
                                default_acl_record.defaclrole_name, role_record.rolname);
                        END IF;
                    ELSIF default_acl_record.defaclobjtype = 'T' THEN -- types
                        IF default_acl_record.schema_name IS NOT NULL THEN
                            EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I IN SCHEMA %I REVOKE ALL ON TYPES FROM %I',
                                default_acl_record.defaclrole_name, default_acl_record.schema_name, role_record.rolname);
                        ELSE
                            EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %I REVOKE ALL ON TYPES FROM %I',
                                default_acl_record.defaclrole_name, role_record.rolname);
                        END IF;
                    END IF;
                END LOOP;
            EXCEPTION WHEN OTHERS THEN
                v_error_msg := SQLERRM;
                RAISE NOTICE 'Warning - default ACL cleanup for %: %', role_record.rolname, v_error_msg;
            END;

            -- Step 4: Revoke database-level privileges
            BEGIN
                EXECUTE format('REVOKE ALL ON DATABASE %I FROM %I', db_name, role_record.rolname);
            EXCEPTION WHEN OTHERS THEN
                v_error_msg := SQLERRM;
                RAISE NOTICE 'Warning - database privileges for %: %', role_record.rolname, v_error_msg;
            END;

            -- Step 5: Revoke schema and object privileges
            FOR schema_record IN
                SELECT nspname
                FROM pg_namespace
                WHERE nspname NOT LIKE 'pg_%'
                  AND nspname != 'information_schema'
            LOOP
                BEGIN
                    EXECUTE format('REVOKE ALL ON SCHEMA %I FROM %I', schema_record.nspname, role_record.rolname);
                    EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA %I FROM %I', schema_record.nspname, role_record.rolname);
                    EXECUTE format('REVOKE ALL ON ALL SEQUENCES IN SCHEMA %I FROM %I', schema_record.nspname, role_record.rolname);
                    EXECUTE format('REVOKE ALL ON ALL FUNCTIONS IN SCHEMA %I FROM %I', schema_record.nspname, role_record.rolname);
                    EXECUTE format('REVOKE ALL ON ALL ROUTINES IN SCHEMA %I FROM %I', schema_record.nspname, role_record.rolname);
                EXCEPTION WHEN OTHERS THEN
                    -- Silently continue for schema-level errors
                    NULL;
                END;
            END LOOP;

            -- Step 6: Reassign and drop owned objects (should be minimal now)
            BEGIN
                EXECUTE format('REASSIGN OWNED BY %I TO platformv2', role_record.rolname);
                EXECUTE format('DROP OWNED BY %I CASCADE', role_record.rolname);
            EXCEPTION WHEN OTHERS THEN
                v_error_msg := SQLERRM;
                RAISE NOTICE 'Warning - owned objects for %: %', role_record.rolname, v_error_msg;
            END;

            -- Step 7: Final attempt to drop the role
            EXECUTE format('DROP ROLE IF EXISTS %I', role_record.rolname);
            v_dropped := v_dropped + 1;

            IF v_dropped % 50 = 0 THEN
                RAISE NOTICE 'Progress: % / % roles dropped', v_dropped, v_total;
            END IF;

        EXCEPTION WHEN OTHERS THEN
            v_failed := v_failed + 1;
            v_error_msg := SQLERRM;
            RAISE NOTICE 'FAILED to drop %: %', role_record.rolname, v_error_msg;
        END;
    END LOOP;

    RAISE NOTICE 'Cleanup complete for %: % dropped, % failed', service_pattern, v_dropped, v_failed;

    -- Return results
    RETURN QUERY SELECT service_pattern, v_total, v_dropped, v_failed;
END;
$function$;
