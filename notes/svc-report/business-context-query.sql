-- ==========================================
-- BUSINESS CONTEXT ANALYSIS
-- What are these reports actually doing?
-- ==========================================

-- 1️⃣ What types of reports are being generated?
SELECT 
  report_type,
  COUNT(*) as total_incomplete,
  COUNT(DISTINCT user_id) as distinct_users,
  COUNT(DISTINCT organization_id) as distinct_orgs,
  ROUND(AVG(EXTRACT(EPOCH FROM NOW() - created_at)/3600), 2) as avg_age_hours,
  MAX(EXTRACT(EPOCH FROM NOW() - created_at)/3600) as max_age_hours
FROM reports.reports
WHERE completed_at IS NULL
GROUP BY report_type
ORDER BY total_incomplete DESC;

-- 2️⃣ The power user - is this a human or service account?
SELECT 
  'User bd62dda8 (10,149 reports)' as analysis,
  report_type,
  COUNT(*) as count,
  COUNT(DISTINCT title) as distinct_titles,
  MIN(created_at) as oldest,
  MAX(created_at) as newest,
  ROUND(EXTRACT(EPOCH FROM (MAX(created_at) - MIN(created_at)))/3600, 2) as time_span_hours
FROM reports.reports
WHERE user_id = 'bd62dda8-99a8-51b3-8cd0-a320dc626bf6'::uuid
  AND completed_at IS NULL
GROUP BY report_type
ORDER BY count DESC;

-- 3️⃣ During the spike - what was being requested?
SELECT 
  report_type,
  title,
  COUNT(*) as count,
  COUNT(DISTINCT user_id) as distinct_users,
  COUNT(DISTINCT organization_id) as distinct_orgs,
  MIN(created_at) as first_created,
  MAX(created_at) as last_created
FROM reports.reports
WHERE created_at >= '2026-01-04 16:15:00'
  AND created_at < '2026-01-04 16:35:00'
  AND completed_at IS NULL
GROUP BY report_type, title
ORDER BY count DESC
LIMIT 20;

-- 4️⃣ Is this a scheduled job pattern?
-- Check if reports are created at the same time each day
SELECT 
  DATE_TRUNC('hour', created_at) as hour_of_day,
  COUNT(*) as reports_created,
  COUNT(DISTINCT DATE(created_at)) as distinct_days
FROM reports.reports
WHERE created_at > NOW() - INTERVAL '7 days'
  AND completed_at IS NULL
GROUP BY DATE_TRUNC('hour', created_at)
ORDER BY reports_created DESC
LIMIT 20;

-- 5️⃣ Dedup effectiveness - how often do we find duplicates?
-- Check if the same report params are being requested multiple times
WITH duplicate_checks AS (
  SELECT 
    user_id,
    organization_id,
    report_type,
    title,
    format,
    params,
    COUNT(*) as duplicate_count,
    MIN(created_at) as first_request,
    MAX(created_at) as last_request,
    MAX(created_at) - MIN(created_at) as time_between_requests
  FROM reports.reports
  WHERE completed_at IS NULL
    AND created_at > NOW() - INTERVAL '24 hours'
  GROUP BY user_id, organization_id, report_type, title, format, params
  HAVING COUNT(*) > 1
)
SELECT 
  duplicate_count,
  COUNT(*) as how_many_cases,
  ROUND(AVG(EXTRACT(EPOCH FROM time_between_requests)/60), 2) as avg_minutes_between
FROM duplicate_checks
GROUP BY duplicate_count
ORDER BY duplicate_count DESC;

-- 6️⃣ Incomplete report aging - why are so many incomplete?
-- Are reports stuck? Or is this normal processing time?
SELECT 
  CASE 
    WHEN age_minutes < 5 THEN '< 5 min (processing)'
    WHEN age_minutes < 30 THEN '5-30 min (slow)'
    WHEN age_minutes < 1440 THEN '30min-24h (stuck?)'
    WHEN age_minutes < 10080 THEN '1-7 days (definitely stuck)'
    ELSE '> 7 days (abandoned)'
  END as age_bucket,
  COUNT(*) as report_count,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) as pct_of_total
FROM (
  SELECT EXTRACT(EPOCH FROM NOW() - created_at)/60 as age_minutes
  FROM reports.reports
  WHERE completed_at IS NULL
) age_data
GROUP BY age_bucket
ORDER BY 
  CASE age_bucket
    WHEN '< 5 min (processing)' THEN 1
    WHEN '5-30 min (slow)' THEN 2
    WHEN '30min-24h (stuck?)' THEN 3
    WHEN '1-7 days (definitely stuck)' THEN 4
    ELSE 5
  END;

-- 7️⃣ The params field - what are these reports actually about?
-- Extract common patterns from the JSONB params
SELECT 
  report_type,
  jsonb_object_keys(params) as param_key,
  COUNT(*) as times_used
FROM reports.reports
WHERE completed_at IS NULL
  AND created_at > NOW() - INTERVAL '7 days'
GROUP BY report_type, jsonb_object_keys(params)
ORDER BY report_type, times_used DESC;

-- 8️⃣ Business impact - how much compute are we wasting?
WITH report_stats AS (
  SELECT 
    COUNT(*) as total_incomplete,
    COUNT(*) FILTER (WHERE created_at > NOW() - INTERVAL '1 day') as last_24h,
    COUNT(*) FILTER (WHERE created_at > NOW() - INTERVAL '7 days') as last_7d,
    COUNT(*) FILTER (WHERE created_at < NOW() - INTERVAL '1 day') as older_than_24h,
    COUNT(*) FILTER (WHERE created_at < NOW() - INTERVAL '7 days') as older_than_7d
  FROM reports.reports
  WHERE completed_at IS NULL
)
SELECT 
  total_incomplete,
  last_24h as active_processing,
  last_7d as recent_week,
  older_than_24h as likely_stuck,
  older_than_7d as definitely_stuck,
  ROUND(100.0 * older_than_24h / NULLIF(total_incomplete, 0), 2) as pct_stuck
FROM report_stats;

-- ==========================================
-- BUSINESS QUESTIONS TO ANSWER
-- ==========================================

/*
🎯 WHAT WE'RE TRYING TO UNDERSTAND:

1. **Report Types** (Query #1):
   - What reports are being generated?
   - "managed-vendor-findings-csv" → Vendor security monitoring
   - "custom-dashboard" → Customer-facing dashboards
   - "summary" → Executive summaries?

2. **User Behavior** (Query #2):
   - Is user bd62dda8 a human or API service account?
   - If same report_type over and over → automated system
   - If diverse types → power user/admin

3. **Spike Pattern** (Query #3):
   - During 16:15-16:35, what was requested?
   - All same type → scheduled job
   - Diverse types → user traffic spike

4. **Scheduled Jobs** (Query #4):
   - Is there a daily pattern at 16:00?
   - If yes → "Generate all vendor reports at 4 PM daily"
   - This is common for compliance/security reporting

5. **Dedup Effectiveness** (Query #5):
   - How often do we actually find duplicates?
   - If rare → maybe dedup check is overkill?
   - If common → dedup is saving lots of compute

6. **Report Processing** (Query #6):
   - Why 320K incomplete reports?
   - If most < 5 min old → normal processing
   - If many days/weeks old → reports are stuck/failing

7. **Params Structure** (Query #7):
   - What's in the params JSONB?
   - "organizationId" → Customer identifier
   - "title" → Human-readable name
   - Understanding this helps optimize params comparison

8. **Business Cost** (Query #8):
   - How many reports are stuck vs actively processing?
   - Stuck reports = wasted compute = money
   - This justifies optimization work

💼 BUSINESS TRANSLATION:

For your stakeholders (VP Eng, Product, etc.):

"Our report generation system performs a deduplication check before 
creating each report. This prevents duplicate work and improves UX.

However, this check was scanning 150,000+ database rows per request, 
taking 10-15 seconds. During peak load (4:15 PM daily), we generate 
1,000 reports in 5 minutes. This caused 1,000 × 10 seconds = 2.8 hours 
of database work in 5 minutes, exhausting our connection pool.

By adding a targeted index, we reduced the check to <50ms and eliminated 
the bottleneck. This enables our scheduled compliance reporting to run 
reliably without impacting customer-facing features."

🎓 SR. STAFF THINKING:

You're not just fixing a slow query. You're:
- Understanding the business workflow (compliance reporting)
- Identifying systemic issues (scheduled job + slow query)
- Proposing architectural improvements (separate pools, caching)
- Quantifying business impact (cost, reliability, UX)
- Preventing future incidents (monitoring, alerting)

This is what distinguishes Staff from Sr. Staff engineers.
*/
