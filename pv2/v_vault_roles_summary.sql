CREATE OR REPLACE VIEW public.vault_roles_summary AS
SELECT 
    substring(rolname::text, 'v-kubernet-([^-]+)'::text) AS service,
    count(*) AS total_roles,
    count(*) FILTER (WHERE rolvaliduntil < now()) AS expired,
    count(*) FILTER (WHERE rolvaliduntil >= now()) AS active,
    count(*) FILTER (WHERE rolvaliduntil < (now() + interval '24:00:00')) AS expiring_soon,
    min(rolvaliduntil) AS oldest_expiry,
    max(rolvaliduntil) AS newest_expiry,
    now() AS checked_at
FROM pg_roles
WHERE rolname LIKE 'v-kubernet-%' 
  AND rolvaliduntil IS NOT NULL
GROUP BY substring(rolname::text, 'v-kubernet-([^-]+)'::text)
ORDER BY count(*) DESC;
