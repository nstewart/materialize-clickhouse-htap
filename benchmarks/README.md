# Benchmarks

This directory contains load-generation and benchmarking scripts for the retail Kappa architecture demo:

```
Postgres (OLTP) → Materialize (real-time data products) → Redpanda → ClickHouse (OLAP)
```

---

## What the benchmark shows

| Query type | Best tool | Why |
|---|---|---|
| **Operational** — point lookups, customer-facing reads | **Materialize** | Results are pre-computed and indexed; reads return in < 15 ms regardless of dataset size |
| **Ad-hoc analytical** — histograms, cross-dimensional aggregations, cohort analysis | **ClickHouse** | Columnar storage + vectorized execution makes full-table scans over millions of rows fast |

The key distinction:

- **Operational queries** follow known access patterns. Materialize pre-indexes exactly that shape, so the answer is already in memory. Queries that require ranking one entity among all entities (e.g., customer spend rank among 100K customers) are structurally expensive in Postgres — they require a full-table aggregation regardless of how many rows the target entity has. Materialize maintains these aggregations incrementally.
- **Analytical queries** are ad-hoc by nature. Pre-indexing every possible aggregation shape is not feasible. ClickHouse's columnar engine handles these without any upfront materialization — and because Materialize already denormalized the data before it arrived, ClickHouse queries a single flat table with no joins.

---

## How to run

### 1. Generate load data

```bash
make load            # 100 000 orders (default)
# or
make load ROWS=500000
# or directly:
python benchmarks/generate_load.py --rows 100000
```

This populates the Postgres `retail` database with:

| Table | Rows |
|---|---|
| `customers` | `ROWS / 10` |
| `products` | 500 |
| `orders` | `ROWS` |
| `order_items` | `~ROWS × 3` |
| `inventory` | `500 × 3 warehouses` |

Data characteristics:
- **Pareto order distribution** — 20% of customers generate 80% of orders
- **Seasonal timestamps** — spread over the last 2 years, with Q4 and summer peaks
- **Realistic status mix** — 60% delivered / 20% shipped / 10% processing / 10% pending+cancelled

Wait ~30 seconds after generating load for Materialize to fully catch up and for ClickHouse to receive all events via the Redpanda pipeline.

### 2. Run the benchmark

```bash
make bench
# or directly:
python benchmarks/run_benchmarks.py [--runs N]
```

The script connects to all three systems, runs each query N times (default: 10), and reports avg/p90/max latency and QPS per system, with a winner column showing the speedup vs Postgres.

Sample output (1M orders / 2.8M order items / 100K customers, 10 runs):

```
══════════════════════════════════════════════════════════════════════
  BENCHMARK: 1,000,050 orders, 2,795,260 order items, 100,010 customers  (10 runs each)
══════════════════════════════════════════════════════════════════════

── OPERATIONAL QUERIES (pre-indexed data products) ──────────────────
  Query                                  Postgres     Materialize     ClickHouse     Winner vs PG
  Inventory lookup (by SKU)              87.5 ms       4.2 ms ✓        7.5 ms        Materialize 21x faster
  Customer orders + lifetime metrics    831.5 ms       5.9 ms ✓      488.2 ms        Materialize 142x faster
  Product performance (by SKU)            2.58 s       9.0 ms ✓        1.39 s        Materialize 286x faster

── AD-HOC ANALYTICAL QUERIES (ClickHouse columnar scan on Materialize-enriched flat table) ──
  Revenue histogram ($50 buckets, 90 d)  278 ms       1.50 s          159 ms ✓       ClickHouse 1.7x faster
  Revenue by category × tier × dow       2.10 s       2.77 s          300 ms ✓       ClickHouse 7x faster
  Cohort retention (30/60/90 d)          886 ms       5.85 s          492 ms ✓       ClickHouse 1.8x faster

── CONCLUSION ────────────────────────────────────────────────────────
  Operational queries  → Materialize  (4.2–9.0 ms)
  Analytical queries   → ClickHouse   (159–492 ms)
  Source of truth      → Postgres
```

---

## Why Materialize wins for operational queries

Materialize maintains **incrementally-updated, indexed views** served from memory:

- `customer_order_activity` — indexed on `customer_id`; includes pre-computed `spend_rank` (RANK over all customers by lifetime spend)
- `inventory_position` — indexed on `sku`; always current as inventory changes
- `product_performance` — indexed on `sku`; includes pre-computed `revenue_rank` and buyer loyalty metrics

Because Materialize has already done the join and aggregation work as data arrived, a read is a direct index lookup — O(1) rather than O(table size).

The extreme multipliers (142x, 286x) come from queries that require ranking one entity among all entities. In Postgres, computing a customer's spend rank requires aggregating all 2.8M order items at query time. This is structurally unavoidable regardless of how many orders the target customer has — no index eliminates the full scan. Materialize maintains the rank incrementally; the cost is paid once per write, not per read.

---

## Why ClickHouse wins for ad-hoc analytical queries

ClickHouse stores each column separately on disk and reads only the columns referenced by a query. For a revenue histogram over 2.8M order items, it needs to read only `subtotal` and `order_created_at` — not the full row.

Combined with vectorized execution (SIMD operations on column batches) and parallel query execution across all CPU cores, ClickHouse handles multi-dimensional aggregations over millions of rows in hundreds of milliseconds with no pre-built index for the specific query shape.

Crucially, these queries hit a single flat table (`orders_enriched`) with no joins. Materialize pre-joined `order_items`, `orders`, `products`, and `customers` before the data arrived in ClickHouse. ClickHouse never needs to resolve foreign keys at query time.

---

## Why Materialize is slow for analytical queries

Without a purpose-built index, Materialize performs a full scan of a row-oriented in-memory store. For ad-hoc aggregations over 2.8M rows, this is slower than ClickHouse's columnar scan.

Materialize *could* be made faster for any of these specific queries by creating a dedicated materialized view (e.g., a pre-aggregated revenue-by-bucket view). But that defeats the purpose of ad-hoc analysis, and it's the wrong tool for the workload. ClickHouse answers questions you haven't defined in advance.

---

## Query files

```
benchmarks/queries/
├── operational/
│   ├── inventory_lookup/     postgres.sql  materialize.sql  clickhouse.sql
│   ├── customer_orders/      postgres.sql  materialize.sql  clickhouse.sql
│   └── product_performance/  postgres.sql  materialize.sql  clickhouse.sql
└── analytical/
    ├── revenue_histogram/    postgres.sql  materialize.sql  clickhouse.sql
    ├── cross_dimensional/    postgres.sql  materialize.sql  clickhouse.sql
    └── cohort_retention/     postgres.sql  materialize.sql  clickhouse.sql
```

---

## Python dependencies

```
psycopg2-binary
clickhouse-connect
faker
rich
```

Install with:

```bash
pip install -r requirements.txt
```
