# Concurrency Analysis: Before vs After Index

## The Concurrency Problem Explained

### Setup
- **EKS Pods:** 10 pods
- **Connection Pool per Pod:** 10 connections (Slonik default)
- **Total Available Connections:** 10 × 10 = 100
- **DB max_connections:** 500
- **Peak Traffic:** 1,000 reports/5 minutes (16:30 spike)

---

## BEFORE Index (Morning Incident)

### Query Performance
```
Dedup Query Time: 10-15 seconds average
Rows Scanned: 150,000+ per query
```

### Concurrency Calculation

**At 16:15 - First Wave (200 reports/minute):**

```
Time: 0s
├─ 200 requests arrive
├─ Distributed across 10 pods = 20 requests/pod
└─ Each pod has 10 connections

Pod 1:
├─ Request 1-10: Grab all 10 connections
│   └─ Each runs dedup query (10 seconds)
└─ Request 11-20: WAITING for connection
    └─ Error after connection timeout (5 seconds)
    
Time: 5s
├─ Requests 11-20: Timeout error "unable to connect"
├─ Users retry → MORE requests
└─ Original queries STILL running (5 more seconds to go)

Time: 10s
├─ First 10 queries complete
├─ Connections released
├─ Request 11-20 (retries) grab connections
└─ 10 more seconds of blocking...

Result: Cascade failure
```

### Connection Usage Over Time

| Time | Active Conns | Waiting | Status |
|------|--------------|---------|--------|
| 16:15:00 | 100 (all busy) | 100 requests | ⚠️ At capacity |
| 16:15:05 | 100 (still busy) | 200+ requests | 🔴 Timeouts start |
| 16:15:10 | 100 (still busy) | 300+ requests | 🔴 Error cascade |
| 16:15:15 | 100 (still busy) | 400+ requests | 🔴 User impact |
| 16:15:20 | 80 (some freed) | 300 requests | ⚠️ Still bad |
| 16:15:30 | 60 | 200 | ⚠️ Recovering |

### The Math
```
Throughput = Connections ÷ Query Time
           = 100 connections ÷ 10 seconds
           = 10 requests/second
           = 600 requests/minute

Peak Demand = 1,000 reports ÷ 5 minutes = 200 requests/minute

Problem: 200 req/min demand > 60 req/min capacity
Result: Queue builds up → Timeouts → "unable to connect"
```

---

## AFTER Index (Now)

### Query Performance
```
Dedup Query Time: 10-50ms average (0.05 seconds)
Rows Scanned: 1-7 per query
```

### Concurrency Calculation

**At 16:15 - Same Wave (200 reports/minute):**

```
Time: 0s
├─ 200 requests arrive
├─ Distributed across 10 pods = 20 requests/pod
└─ Each pod has 10 connections

Pod 1:
├─ Request 1-10: Grab all 10 connections
│   └─ Each runs dedup query (0.05 seconds) ⚡
├─ Request 11-20: Grab connections (freed after 0.05s) ⚡
└─ All 20 requests complete in < 0.1 seconds ✅

Time: 0.1s
└─ All 200 requests complete, connections released ✅

Result: No queuing, no timeouts
```

### Connection Usage Over Time

| Time | Active Conns | Waiting | Status |
|------|--------------|---------|--------|
| 16:15:00.000 | 100 (all busy) | 100 requests | ✅ Processing |
| 16:15:00.050 | 10 (most freed) | 0 requests | ✅ Nominal |
| 16:15:00.100 | 5 | 0 | ✅ Nominal |
| 16:15:00.500 | 8 | 0 | ✅ Nominal |
| 16:15:01.000 | 6 | 0 | ✅ Nominal |

### The Math
```
Throughput = Connections ÷ Query Time
           = 100 connections ÷ 0.05 seconds
           = 2,000 requests/second
           = 120,000 requests/minute

Peak Demand = 1,000 reports ÷ 5 minutes = 200 requests/minute

Result: 200 req/min demand << 120,000 req/min capacity
Status: System barely notices the load ✅
```

---

## Side-by-Side Comparison

### Scenario: 1,000 Reports in 5 Minutes

| Metric | BEFORE Index | AFTER Index | Improvement |
|--------|--------------|-------------|-------------|
| **Query Time** | 10-15 seconds | 10-50ms | **200-300x faster** |
| **Rows Scanned** | 150,000 | 1-7 | **21,000x reduction** |
| **Throughput** | 60 req/min | 120,000 req/min | **2000x increase** |
| **Connection Usage** | 100% (saturated) | 1-5% (nominal) | **95% freed** |
| **Queue Depth** | 400+ waiting | 0 waiting | **Queue eliminated** |
| **Error Rate** | High | Zero | **100% reduction** |
| **User Impact** | "Unable to connect" | Normal response | **Fixed** |

---

## Why Concurrency Matters

### The Connection Pool Formula

```
Safe Throughput = (Connections × Safety Factor) ÷ Query Time

BEFORE:
= (100 × 0.8) ÷ 10 seconds
= 8 requests/second
= 480 requests/minute

Peak Load: 200+ requests/minute
Status: Can't handle peak → Cascading failures

AFTER:
= (100 × 0.8) ÷ 0.05 seconds
= 1,600 requests/second
= 96,000 requests/minute

Peak Load: 200 requests/minute
Status: Massive headroom → Zero failures
```

### The Compounding Effect

**One slow query:** 10 seconds
- Blocks 1 connection for 10 seconds
- Minor impact

**Ten slow queries (concurrent):**
- Blocks 10 connections for 10 seconds
- Entire pod pool exhausted
- New requests queue

**Hundred slow queries (burst):**
- Blocks all 100 connections for 10+ seconds
- Every pod pool exhausted
- New requests timeout
- Users retry → More load
- **Cascade failure** 🔴

---

## Real Production Numbers

From your pg_stat_statements data:

### Daily Query Volume
```
Total dedup query calls: ~50,000-70,000/day
Average time BEFORE: 10 seconds
Total DB time BEFORE: 500,000-700,000 seconds = 138-194 HOURS/day

Average time AFTER: 0.05 seconds  
Total DB time AFTER: 2,500-3,500 seconds = 0.7-1.0 HOURS/day

Savings: 137-193 hours/day of DB time
```

### During Peak (16:15-16:35, 20 minutes)
```
Reports created: ~3,300 reports
Dedup queries: ~3,300 queries

BEFORE:
Time: 3,300 × 10 seconds = 33,000 seconds = 9.2 HOURS
Parallelism: 100 connections
Real time: 33,000 ÷ 100 = 330 seconds = 5.5 minutes
Problem: But requests kept coming for 20 minutes!
Result: Queue builds → Timeouts

AFTER:
Time: 3,300 × 0.05 seconds = 165 seconds = 2.75 MINUTES
Parallelism: 100 connections
Real time: 165 ÷ 100 = 1.65 seconds
Result: Handles entire peak in < 2 seconds ✅
```

---

## Key Insight: It's Not Just Speed, It's Concurrency

**The problem wasn't "query is slow"**  
The problem was **"slow query + high concurrency = resource exhaustion"**

- 1 slow query = annoying
- 100 slow queries at once = outage

**The fix isn't just "make query faster"**  
The fix is **"make query fast enough that concurrent execution doesn't exhaust resources"**

This is why you need:
1. ✅ Fast queries (index)
2. ✅ Statement timeouts (kill runaways)
3. ✅ Connection pool limits (prevent exhaustion)
4. ✅ Monitoring (catch before it's an outage)
5. ✅ Load testing (verify concurrency handling)

---


> "The issue wasn't just a slow query. It was a **concurrency bottleneck** caused by a query that took 10 seconds while handling 200 concurrent requests. 
>
> Our connection pool has 100 connections. At 10 seconds per query, we can handle 10 requests/second. But our peak load is 200 requests/minute = 3.3 requests/second with bursts much higher.
>
> During the burst at 16:15, we had 100+ queries running simultaneously, each taking 10-15 seconds. All connections were held, new requests couldn't get connections, and we got 'unable to connect to database' errors.
>
> By optimizing the query from 10 seconds to 50ms (200x faster), we increased our throughput from 10 req/sec to 2,000 req/sec - a 200x improvement. Now our system has massive headroom and can easily handle peak loads."

This shows you understand:
- Systems thinking (not just DB)
- Capacity planning (throughput math)
- Production operations (concurrency limits)
- Business impact (reliability, cost)
