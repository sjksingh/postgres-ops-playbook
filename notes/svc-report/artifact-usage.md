# Artifact Usage Guide

## 📋 Quick Reference: Which Artifact for What?

| Artifact | Use When | Audience | Time Needed |
|----------|----------|----------|-------------|
| **Final Index Creation** | Creating the index NOW | You (DBA) | 5 min |
| **EXPLAIN Analysis** | Testing query performance | You (DBA) | 10 min |
| **Data Distribution** | Understanding query patterns | You + Dev Team | 15 min |
| **Incident Report** | Communicating to stakeholders | Leadership, Team | Read 5 min |
| **Concurrency Math** | Explaining WHY it broke | Technical audience | Read 10 min |
| **Smoking Gun Evidence** | Proving root cause | Senior Engineers, Mgmt | Read 5 min |
| **Business Context** | Understanding user impact | Product, Business | 20 min |

---

## 🎯 RIGHT NOW - Immediate Action 

### 1. **Final Index Creation - Reports Dedup Query**
**Purpose:** The actual SQL commands to fix the issue  
**Use it for:** Creating the index and verifying it works

**What to do:**
```bash
# Step 1: Open this artifact
# Step 2: Copy the CREATE INDEX command
# Step 3: Run it in your reports=> psql session

CREATE INDEX CONCURRENTLY idx_reports_dedup_active_v1
ON reports.reports (
  user_id, organization_id, report_type, format, created_at DESC
)
WHERE completed_at IS NULL;

# Step 4: Monitor progress (in another terminal)
SELECT phase, round(100.0 * blocks_done / nullif(blocks_total, 0), 1) AS "% complete"
FROM pg_stat_progress_create_index;

# Step 5: Verify index was created
SELECT indexrelname, pg_size_pretty(pg_relation_size(indexrelid))
FROM pg_stat_user_indexes
WHERE schemaname = 'reports' AND relname = 'reports'
  AND indexrelname = 'idx_reports_dedup_active_v1';
```

**Expected outcome:** Index created in ~5 minutes, no blocking

---

### 2. **EXPLAIN Analysis - Actual Slow Query**
**Purpose:** Test the query before and after index creation  
**Use it for:** Proving the index actually improves performance

**What to do:**
```bash
# BEFORE creating index:
# Run the first EXPLAIN query (with the managed-vendor-findings-csv example)
# Note the "Rows Removed by Filter: 151,472"
# Note the "Execution Time: 150.941 ms"

# AFTER creating index:
# Run the SAME EXPLAIN query again
# Look for: "Index Scan using idx_reports_dedup_active_v1"
# Note the improved execution time: should be 5-20ms
# Note rows scanned: should be 1-10 (not 151,472!)

# Save both EXPLAIN outputs - you'll need them for the report
```

**Expected outcome:** 
- Before: Parallel Index Scan, 151K rows filtered, 150ms
- After: Index Scan using new index, 1-10 rows, 5-20ms

---

## 📊 TODAY - Verification & Communication (Next 2 hours)

### 3. **Data Distribution - Prove Index Design**
**Purpose:** Understand the data patterns and prove the index helps  
**Use it for:** Showing your team WHY this index is the right solution

**What to do:**
```bash
# Run queries 1, 2, 3 from this artifact:
# 1. Shows power users (who has most incomplete reports)
# 2. Shows orgs with most incomplete reports  
# 3. Shows the improvement ratio (45-189x)

# Use the results in your presentation to leadership:
# "User X has 10,149 incomplete reports"
# "Current index scans 24,000 rows, new index scans 10 rows"
# "189x improvement in worst case"
```

**Expected outcome:** Data to support your index design decisions

---

### 4. **Smoking Gun Evidence - Complete Evidence Chain**
**Purpose:** Prove beyond doubt this is THE culprit query  
**Use it for:** When someone asks "Are you SURE this is the problem?"

**What to do:**
```bash
# Don't run queries - this is a READ document
# Use it when:
# - Presenting to senior engineers
# - Writing the incident report
# - Someone challenges your root cause analysis

# Key sections to reference:
# - Evidence #1: pg_stat_statements (historical proof)
# - Evidence #4: Timeline correlation (16:15 spike)
# - Evidence #6: Index improvement projection
```

**Expected outcome:** Confidence in your analysis, buy-in from skeptics

---

## 📝 THIS WEEK - Documentation & Presentation (Next 3 days)

### 5. **Post-Incident Report - Connection Spike 2026-01-04**
**Purpose:** Official incident documentation  
**Use it for:** Sharing with your team, leadership, and for future reference

**What to do:**
```bash
# Day 1 (Today): Fill in the blanks
# - Add your name
# - Verify all timestamps match your actual incident
# - Add links to your CloudWatch graphs
# - Customize for your company's format

# Day 2: Share with stakeholders
# - Send to: Database team, Platform team, Dev team leads
# - Schedule: 30-minute incident review meeting
# - Present: Timeline, root cause, solution, prevention

# Day 3: Archive and document
# - Add to your team wiki/Confluence
# - Tag it: "incident-report", "performance", "postgresql"
# - Reference in your performance review (Sr. Staff work!)
```

**Expected outcome:** Professional documentation of your investigation and resolution

**Key audiences:**
- **Dev Team:** "Query Rewrite" section - they need to fix the EXTRACT() issue
- **Leadership:** "Executive Summary" - business impact and resolution
- **Your Manager:** "Lessons Learned" - shows systematic thinking
- **Future You:** When this happens again in 6 months, you have the playbook

---

### 6. **Concurrency Analysis - Before vs After**
**Purpose:** Explain the root cause in terms of system capacity  
**Use it for:** Teaching others about database concurrency and capacity planning

**What to do:**
```bash
# Use this document when:
# - Presenting to engineering team (brown bag lunch?)
# - Explaining to senior engineers why it broke
# - Justifying the index to leadership (cost/benefit)
# - Teaching junior DBREs about concurrency

# Key sections to highlight:
# - "The Math" section (throughput calculations)
# - "Before vs After" comparison table
# - "The Compounding Effect" (why 100 slow queries = outage)
```

**Expected outcome:** Team understands it wasn't just "slow query", it was a capacity problem

**Best used for:**
- Technical deep-dive presentations
- Database team knowledge sharing
- Justifying future capacity planning work
- Your performance review (shows systems thinking)

---

### 7. **Business Context Analysis**
**Purpose:** Understand what the query does from a business perspective  
**Use it for:** Discussions with Product team about optimization opportunities

**What to do:**
```bash
# Run the queries in this artifact to understand:
# - What reports are being generated? (Query #1)
# - Is this a scheduled job? (Query #4)
# - How effective is deduplication? (Query #5)
# - Are reports getting stuck? (Query #6)

# Use results for:
# - Product discussion: "Do we need dedup for every report type?"
# - Dev team: "Should we cache dedup results in Redis?"
# - Architecture: "Should we separate report generation from API?"
```

**Expected outcome:** Business-aware technical decisions, not just technical fixes

---

## 🎯 Usage Flowchart

```
┌─────────────────────────────────────────────────┐
│ RIGHT NOW (30 minutes)                          │
├─────────────────────────────────────────────────┤
│ 1. Final Index Creation                         │
│    → Create the index                           │
│    → Monitor progress                           │
│    → Verify success                             │
│                                                  │
│ 2. EXPLAIN Analysis                             │
│    → Run EXPLAIN before                         │
│    → Create index                               │
│    → Run EXPLAIN after                          │
│    → Compare results                            │
└─────────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────────┐
│ TODAY (2 hours)                                 │
├─────────────────────────────────────────────────┤
│ 3. Data Distribution                            │
│    → Run analysis queries                       │
│    → Document results                           │
│                                                  │
│ 4. Smoking Gun Evidence                         │
│    → READ for confidence                        │
│    → Use in discussions                         │
└─────────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────────┐
│ THIS WEEK (3 days)                              │
├─────────────────────────────────────────────────┤
│ 5. Post-Incident Report                         │
│    → Customize for your company                 │
│    → Share with stakeholders                    │
│    → Archive for future reference               │
│                                                  │
│ 6. Concurrency Analysis                         │
│    → Use in technical presentations             │
│    → Teach team about capacity planning         │
│                                                  │
│ 7. Business Context                             │
│    → Discuss with Product team                  │
│    → Plan architectural improvements            │
└─────────────────────────────────────────────────┘
```

---

## 📋 Checklist: What to Do With Each Artifact

### ✅ Immediate (Next 30 min)
- [ ] Open "Final Index Creation"
- [ ] Copy CREATE INDEX command
- [ ] Run in production database
- [ ] Monitor pg_stat_progress_create_index
- [ ] Verify index created successfully
- [ ] Run EXPLAIN before/after from "EXPLAIN Analysis"
- [ ] Take screenshots of improvement

### ✅ Today (Next 2 hours)
- [ ] Run queries from "Data Distribution"
- [ ] Document results (power users, improvement ratios)
- [ ] Read "Smoking Gun Evidence"
- [ ] Prepare 5-minute summary for your manager
- [ ] Check pg_stat_statements for improvement

### ✅ This Week
- [ ] Customize "Post-Incident Report"
- [ ] Share with Database team
- [ ] Present to Dev team (query rewrite needed)
- [ ] Present to leadership (5-min exec summary)
- [ ] Archive in team wiki/Confluence
- [ ] Schedule follow-up: monitoring & alerting

### ✅ Long-term (Next Month)
- [ ] Use "Concurrency Analysis" for team training
- [ ] Use "Business Context" for Product discussions
- [ ] Document in runbook
- [ ] Add to your performance review notes
- [ ] Create monitoring dashboard
- [ ] Set up alerts for similar issues

---

## 💡 Pro Tips

### For Presentations

**To Management (5 min):**
- Use: "Post-Incident Report" Executive Summary
- Focus: Business impact, resolution time, prevention
- Metrics: 200x faster, 99.95% DB load reduction, zero errors

**To Engineering Team (30 min):**
- Use: "Concurrency Analysis" + "Smoking Gun Evidence"
- Focus: Technical depth, root cause, systemic fix
- Teach: Capacity planning, index design, query optimization

**To Product Team (15 min):**
- Use: "Business Context Analysis"
- Focus: User impact, workflow optimization opportunities
- Discuss: Alternative deduplication strategies, caching

### For Documentation

**In your Wiki:**
- Post-Incident Report (full document)
- Link to all artifacts
- Tag: incident-2026-01-04, postgresql, performance

**In your Runbook:**
- Create new page: "Report Query Performance"
- Include: Index design rationale, EXPLAIN examples
- Add: Monitoring queries, alert thresholds

**In your Performance Review:**
- Highlight: Systematic investigation (OODA Loop)
- Emphasize: Cross-functional impact (DB, App, Product)
- Quantify: 200x improvement, 99.95% load reduction
- Show: Sr. Staff level thinking (systems, not just queries)

---

## 🎯 One-Line Summary for Each

1. **Final Index Creation** → "Copy-paste SQL to fix the issue"
2. **EXPLAIN Analysis** → "Prove the fix works with before/after"
3. **Data Distribution** → "Understand the data, justify the design"
4. **Smoking Gun Evidence** → "Irrefutable proof this is the culprit"
5. **Post-Incident Report** → "Official documentation for stakeholders"
6. **Concurrency Analysis** → "Teach others why it broke"
7. **Business Context** → "Connect technical fix to business value"

---

## 🚀 Start Here Right Now

**Priority 1 (Urgent):**
```sql
-- From "Final Index Creation" artifact
CREATE INDEX CONCURRENTLY idx_reports_dedup_active_v1
ON reports.reports (
  user_id, organization_id, report_type, format, created_at DESC
)
WHERE completed_at IS NULL;
```
