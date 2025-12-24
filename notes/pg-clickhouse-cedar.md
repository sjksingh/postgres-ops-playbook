# 🧪 PostgreSQL + ClickHouse + CedarDB — A DBRE-Driven Look at Analytics Execution Architectures

As a Staff DBRE, I spend a lot of time at the boundary between **OLTP systems, analytical workloads, and operational reliability**. Over the years, I’ve seen more teams adopt a two-system pattern:

* PostgreSQL for transactions
* ClickHouse (or Snowflake/BigQuery) for analytics

It works — but it also introduces **operational drag**:

* dual systems to manage
* ingestion pipelines to maintain
* sync lag & debugging overhead
* different execution models to reason about

CedarDB’s promise is compelling:

> *PostgreSQL-compatible + analytical performance, without leaving the Postgres ecosystem.*

The question isn’t *“Is it faster?”* — the real DBRE question is:

> **Does CedarDB eliminate enough operational complexity while delivering “good-enough” analytical performance — compared to ClickHouse — to justify consolidation?**

This post is not a benchmark scoreboard.
Instead, it is **an engineering investigation into execution behavior**, using the UK Price Paid dataset (~30M rows) across four engines:

* PostgreSQL HEAP
* PostgreSQL + pg_clickhouse FDW
* CedarDB
* ClickHouse

The goal was to understand **where each architecture wins, where it struggles, and why**.

---

## ⚙️ Test Environment (EC2 + Docker)

Everything was run inside Docker on EC2.

Hardware characteristics (for repeatability):

```bash
# CPU / Memory
lscpu
free -h

# Disk
lsblk
df -h

# Docker resource limits
docker info | grep -E 'CPUs|Memory'
```

ClickHouse + PostgreSQL + CedarDB were deployed via Docker Compose, and ingestion used the official ClickHouse public dataset ingestion pipeline to ensure consistency.

---

## 🧩 The Four Queries — Designed as Stress Patterns

Rather than synthetic micro-benchmarks, I designed **four realistic analytics patterns** that I routinely see in engineering & data workloads:

1️⃣ **Simple Aggregation (baseline rollups)**
2️⃣ **Time-bucketed aggregation**
3️⃣ **Year-over-year analytics with window functions**
4️⃣ **Percentiles + Top-N + joins (complex pipeline)**

Each query isn’t about SQL syntax — it’s about **forcing engines to reveal their execution model**:

* scan strategy
* grouping behavior
* spill / temp file usage
* pushdown vs orchestration
* vectorization vs executor overhead
* row vs column behavior under load

In the sections below, I’ll summarize **what actually happened** in Query 1–4 — but focus on the *why*.

(Full SQL, plans, and scripts:
👉 [https://github.com/sjksingh/sql-engine-triangle](https://github.com/sjksingh/sql-engine-triangle))

---

## 🔎 What Emerged Across the Queries

### **PostgreSQL HEAP — correctness first, flexibility always, execution cost grows**

Postgres consistently demonstrated:

* strong selective filtering
* stable semantics
* predictable correctness

But once grouping, sorting, or windowing expanded intermediate rows, the executor paid for:

* MVCC visibility checks
* buffer movement
* sorting & spill behavior
* JIT + planner overhead

This isn’t a “Postgres is slow” outcome.
It’s a reminder that PostgreSQL is fundamentally a **general-purpose OLTP executor**, not a vectorized analytic engine.

Postgres shines when:

* concurrency matters
* transactions matter
* correctness > throughput

But **it pays for that flexibility** in analytical pipelines.

---

### **CedarDB — reduces executor & MVCC drag, keeps Postgres compatibility**

CedarDB behaved like:

> *PostgreSQL semantics with significantly lower executor overhead.*

Patterns that were costly in Postgres HEAP ran dramatically faster because:

* less MVCC bookkeeping
* tighter aggregation execution
* minimal temp spill behavior
* smaller intermediate structures

It did not magically become ClickHouse — but it was often:

> “Fast enough to replace the separate analytics datastore for many workloads.”

From an operational perspective, that’s meaningful:

* one system instead of two
* no ingestion pipeline
* no FDW orchestration layer
* same skill set, extensions, tooling

This aligns well with **DBRE consolidation initiatives**.

---

### **pg_clickhouse FDW — PostgreSQL as a control plane, not an execution engine**

Where pushdown succeeded, performance improved dramatically — but…
the moment PostgreSQL needed to:

* handle windows
* join intermediate sets
* manage grouping locally

…it immediately re-inherited the **executor costs** of Query 1–3.

The takeaway:

> FDW pushdown works best when PostgreSQL isn’t part of the execution path — only the orchestration path.

When the result set grows, FDW becomes **a liability rather than an accelerator**.

This reinforced a lesson I see in production frequently:

* FDWs are great for *federation*
* They are not a substitute for *native column execution*

---

### **ClickHouse — thrives when analytics becomes a pipeline, not a query**

ClickHouse consistently excelled when queries evolved into:

* multi-stage pipelines
* joins + merges
* percentiles
* time-bucketed aggregation

Its advantages weren’t about *speed numbers* — they were architectural:

* columnar storage
* vectorized execution
* staged aggregation
* pipeline merging

Instead of “query execution”, it felt more like **dataflow execution**.

For analytics workloads that are:

* dashboard-driven
* exploration-heavy
* compute-intensive

ClickHouse remains the right tool.

---

## 🧭 Operational Takeaways (DBRE Lens)

From a **Staff DBRE perspective**, here’s how I frame the results:

### **When to keep PostgreSQL HEAP**

* transactional systems
* correctness & concurrency first
* analytics workload light or small-set

### **When CedarDB makes sense**

* analytics workload exists **inside** Postgres systems
* pushing data to ClickHouse adds ops burden
* analytics must be “good enough”, not extreme
* you want to consolidate systems without false promises

CedarDB ≠ “ClickHouse inside Postgres”.
CedarDB = *“Postgres execution model, optimized for analytics.”*

That distinction matters.

---

### **When to use ClickHouse alongside Postgres**

* high-cardinality analytics
* window & percentile pipelines
* high concurrency analytical access
* BI workloads at scale

Here, architectural specialization wins.

And that’s okay.
Not every consolidation effort should erase specialization.

---

## 🧠 The Real Lesson — It’s Not About Speed, It’s About **Behavior**

Benchmarks often chase numbers.

This exploration was about **execution behavior**:

* What happens when queries evolve from simple → complex?
* Where does executor overhead appear?
* When does pushdown stop helping?
* Where does architecture become the constraint?

As DBREs, our role is not to pick “the fastest database”.

Our role is to pick:

* the **right execution model**
* for the workload’s **operational reality**

CedarDB doesn’t eliminate ClickHouse.
ClickHouse doesn’t invalidate PostgreSQL.

They occupy **different structural roles** — and understanding that is the real engineering work.

---

## 📎 Full repo (plans, SQL, ingestion pipeline)

👉 [https://github.com/sjksingh/sql-engine-triangle](https://github.com/sjksingh/sql-engine-triangle)

If you’re working on similar hybrid architectures, I’d love to hear how your systems behave under comparable workloads — especially where trade-offs show up operationally.

This space is evolving fast — and as DBREs, we live right at that boundary.
