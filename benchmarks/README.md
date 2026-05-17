# Benchmarks

This directory contains load-generation and benchmarking scripts for the retail Kappa architecture demo:

```
Postgres (OLTP) → Materialize (real-time data products) → Redpanda → ClickHouse (OLAP)
```

---

## What the benchmark shows

| Query type | Served by | Why this fit |
|---|---|---|
| **Operational** — point lookups, customer-facing reads | **Materialize** | Results are pre-computed and indexed; reads return in < 15 ms regardless of dataset size |
| **Analytical, fixed shape** — histograms, cross-dimensional aggregations | **ClickHouse reading a Materialize pre-aggregated sink** | The aggregation is maintained incrementally by Materialize IVM; ClickHouse reads a small result table (~50–200 rows) with no GROUP BY at query time |
| **Analytical, ad-hoc shape** — cohort/funnel and other unpredictable aggregations | **ClickHouse columnar scan on the flat sink** | The query shape isn't known up front, so the flat `orders_summary` / `orders_enriched` sink is scanned at query time; columnar storage + vectorized execution keeps it fast |

The key distinction:

- **Operational queries** follow known access patterns. Materialize pre-indexes exactly that shape, so the answer is already in memory. Queries that require ranking one entity among all entities (e.g., customer spend rank among 100K customers) are structurally expensive in Postgres — they require a full-table aggregation regardless of how many rows the target entity has. Materialize maintains these aggregations incrementally.
- **Analytical queries** split into two cases. When the query shape is fixed, Materialize maintains a pre-aggregated MV and sinks the small result to ClickHouse — the CH query becomes a tiny scan with no GROUP BY. When the shape is ad-hoc, Materialize sinks the pre-joined flat table and ClickHouse aggregates at read time using its columnar engine. Either way, ClickHouse never resolves foreign keys at query time because Materialize already denormalized the data.

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

The script connects to all four systems (Postgres, Materialize, ClickHouse-via-Materialize, ClickHouse-standalone via Debezium), runs each query N times (default: 10), and reports avg/p90/max response time per system plus an empirically-measured freshness lag for each CDC path. Absolute numbers vary by hardware — run it on your own machine.

Indicative output (1M orders / 2.8M order items / 100K customers, single `m5.2xlarge`, 10 runs):

```
── OPERATIONAL QUERIES (pre-indexed data products) ──────────────────
  Query                                  Postgres   Materialize   CH (via MZ)   CH (standalone)
  Inventory lookup (by SKU)              224 ms      24 ms         11.5 ms       10.6 ms
  Customer orders + lifetime metrics     2.03 s      68.8 ms       1.05 s        301 ms
  Product performance (by SKU)           4.24 s      14.4 ms       2.07 s        13.7 ms

── ANALYTICAL QUERIES ───────────────────────────────────────────────
  Query                                  Postgres   Materialize   CH (via MZ)   CH (standalone)
  Revenue histogram (pre-aggregated)     489 ms      3.19 s        17.5 ms       27.7 ms
  Cross-dimensional (pre-aggregated)     3.32 s      4.26 s        27.2 ms       7.3 ms
  Cohort retention (flat-table scan)     1.10 s      5.51 s        332.8 ms      114.3 ms
```

Note: the Materialize analytical numbers are from the *unoptimized* path — scanning `order_detail` with no aggregation index. The same pre-aggregated MVs that feed the CH analytical sink (`revenue_histogram`, `sales_by_dim`) live in Materialize and would serve those two fixed-shape queries in milliseconds if queried directly. See the project [README](../README.md) for full reaction-time analysis (response + freshness lag).

---

## Operational queries: why Materialize fits

Materialize maintains **incrementally-updated, indexed views** served from memory:

- `customer_order_activity` — indexed on `customer_id`; includes pre-computed `spend_rank` (RANK over all customers by lifetime spend)
- `inventory_position` — indexed on `sku`; always current as inventory changes
- `product_performance` — indexed on `sku`; includes pre-computed `revenue_rank` and buyer loyalty metrics

Because Materialize has already done the join and aggregation work as data arrived, a read is a direct index lookup — O(1) rather than O(table size).

The largest response-time differences appear on queries that rank one entity among all entities. In Postgres, computing a customer's spend rank requires aggregating all 2.8M order items at query time — structurally unavoidable regardless of how many orders the target customer has, since no index eliminates the full scan. Materialize maintains the rank incrementally: the cost is paid once per write, not per read. This is why operational reads are routed there.

---

## Analytical queries: why ClickHouse fits

Two distinct mechanisms, one per query shape:

**Fixed shapes — revenue histogram, cross-dimensional aggregation.** Materialize maintains a pre-aggregated MV (`revenue_histogram`, `sales_by_dim`) incrementally and sinks it to ClickHouse as a small table (~50 rows for the histogram, ~203 for the cross-dim cube). The ClickHouse query reads the pre-bucketed result directly — no scan, no filter, no GROUP BY at query time. The work is done at write time in Materialize; ClickHouse serves the answer.

**Ad-hoc shapes — cohort retention.** No pre-aggregation exists, so ClickHouse scans the flat `orders_summary` sink (1M rows) at query time. Columnar storage reads only the referenced columns, vectorized execution applies SIMD across column batches, and parallel execution spreads the work across cores. The flat table has no joins to resolve because Materialize denormalized the data before it arrived.

Both paths benefit from Materialize having done the join work upstream. The split is between *who* does the aggregation: Materialize at write time (for fixed shapes) or ClickHouse at read time (for ad-hoc shapes).

---

## Why Materialize's analytical numbers look slow here

The `materialize.sql` files for the analytical queries are intentionally the **unoptimized** path: they scan `order_detail` directly with no index for the aggregation shape. Materialize's row-oriented in-memory store is well-suited to incremental maintenance of indexed views, less so to ad-hoc full-table scans for arbitrary aggregations — that's the workload ClickHouse's columnar engine is built for.

If you ran the same fixed-shape queries against the pre-aggregated MVs that already exist in `materialize/03_serving.sql` (the same MVs that feed the ClickHouse sink), Materialize would serve them in milliseconds — the data is already bucketed. We don't measure that path here because the point is to show what happens when you *don't* define a purpose-built MV. For truly ad-hoc shapes (cohort retention), defining a dedicated MV defeats the purpose; routing those to ClickHouse is the right fit.

---

## Query files

Each query directory contains one SQL file per system the runner exercises:

- `postgres.sql` — runs against Postgres
- `materialize.sql` — runs against Materialize
- `clickhouse.sql` — runs against the ClickHouse-via-Materialize path (reads from Materialize sinks)
- `clickhouse_optimized.sql` — runs against the ClickHouse-standalone path (Debezium CDC + ClickHouse-native pre-computation: projections, AggregatingMergeTree, refreshable MVs, HASHED dictionaries)

```
benchmarks/queries/
├── operational/
│   ├── inventory_lookup/
│   ├── customer_orders/
│   └── product_performance/
└── analytical/
    ├── revenue_histogram/
    ├── cross_dimensional/
    └── cohort_retention/
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
