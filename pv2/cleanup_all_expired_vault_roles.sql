CREATE OR REPLACE FUNCTION public.cleanup_all_expired_vault_roles()
RETURNS TABLE(
    service_name text,
    total_attempted integer,
    successfully_dropped integer,
    failed integer
)
LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE NOTICE '================================================';
    RAISE NOTICE 'Starting cleanup of ALL expired Vault roles';
    RAISE NOTICE '================================================';

    RETURN QUERY
        SELECT * FROM cleanup_expired_vault_roles('migratio')
        UNION ALL
        SELECT * FROM cleanup_expired_vault_roles('svc_file')
        UNION ALL
        SELECT * FROM cleanup_expired_vault_roles('svc_noti')
        UNION ALL
        SELECT * FROM cleanup_expired_vault_roles('svc_user');
END;
$function$;
