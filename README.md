# Agentic HTAP Reference Architecture

### OLTP · IVM · OLAP

This repo defines the **Agentic HTAP pattern**: route OLTP writes, operational reads, and analytical reads to the engine built for each.

The result: lower end-to-end reaction time than single-system HTAP — because work moves from read time to write time.

> **The core tradeoff:** Materialize pays the join and aggregation cost once at write time. ClickHouse pays it on every read.

```
  14:32:33.012  Postgres     price: $299.99 → $359.99
  14:32:33.274  Materialize  reflected (+288 ms)
  14:32:36.432  ClickHouse   reflected (+3.6 s)
```

```
Write → [~300 ms] → Materialize (<10 ms reads)
      → [~3.6 s]  → ClickHouse (<100 ms scans)
```

A write lands in Postgres. Materialize reflects it in ~300 ms as a fully joined, indexed result; ClickHouse receives it ~3.6 s later as a scan-optimized table.

```
Postgres   ──┐
SQL Server ──┼──[CDC]──► Materialize ──[Kafka sink]──► Redpanda ──[Kafka engine]──► ClickHouse
MySQL      ──┘               │
                             └──[indexes]──► Applications / Agents (< 10 ms)
```

Try it:

```bash
make up && make init   # start all 5 services (~60 seconds)
make demo              # watch a price change propagate end-to-end
```

*This repo uses a single Postgres instance to keep the demo focused — the pattern extends to any number of OLTP sources.*

## The Three Requirements

A HTAP system needs three things working together:


| Requirement                       | Role                                                                   | Access pattern                                                                          |
| --------------------------------- | ---------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| **OLTP — Writes**                 | Durable, consistent writes at scale                                    | Normalized schema, ACID transactions, point writes                                      |
| **IVM — Real-time data products** | Continually and incrementally computed, indexed views of current state | Known access patterns, current entity state, ~1 second freshness; < 10 ms point lookups |
| **OLAP — Analytical reads**       | Full-dataset scans with arbitrary aggregation shapes                   | Ad-hoc queries over denormalized flat tables                                            |


These requirements conflict. OLTP writes often target normalized schemas: one fact in one row, referential integrity, transactional consistency. Operational reads require incrementally maintained, indexed results: at scale, ranking one customer among 100K others requires aggregating every row, and no index eliminates that scan. Analytical reads need a denormalized flat table: OLAP engines read individual columns across millions of rows, and JOIN resolution at query time defeats the columnar advantage.

**Why not batch ETL or Flink?** Batch ETL solves analytical reads but not operational reads — the latency is too high, and join logic outside the database becomes fragile as schemas evolve. Stream processors like Flink reduce latency but shift complexity into application code: reconstructing transactions, maintaining joins, and building a separate serving layer on top.

**IVM is the bridge.** An IVM engine reads from OLTP databases via CDC, joins and aggregates incrementally as writes arrive, serves operational reads from in-memory indexes, and continuously feeds a pre-joined flat table to the OLAP engine — all from the same consistent computation. In microservice architectures where each service owns its own database, the IVM layer joins across all of them at a unified logical timestamp, without synchronous cross-service calls or duplicated business logic.

## When to Use This Pattern

This stack is built for engineers shipping **real-time data products that need to be trusted** — where stale or inconsistent data isn't a UX inconvenience, it's a correctness problem. Three use cases where the IVM layer earns its place:

### Context for AI agents

AI agents and LLM pipelines need accurate, current context about the state of the world. When a model is asked to reason about a customer, an order, or an inventory position, the answer needs to reflect the latest committed state — not a cache from 30 seconds ago, not a partial transaction where the order exists but the line items haven't arrived yet. Materialize serves that context from pre-joined indexed views with sub-10ms response, at the same logical timestamp across every field in the result. The agent gets a consistent snapshot of reality to reason from, not a stitched-together approximation.

### Event-driven architectures

`SUBSCRIBE` turns Materialize into a reliable event source. Services receive each state change the moment it's committed — inventory crossing a reorder threshold, a customer moving spend tiers, an order completing — with no polling interval and no coordination overhead. Because the change is derived from a consistently maintained view rather than raw CDC, downstream services see business events (customer reached Platinum tier) rather than database mutations (row updated in customers where id = 4381). The IVM layer does the stateful join that turns raw writes into meaningful events.

### Interactive, data-intensive UIs

Dashboards and UIs that surface per-entity operational state alongside population-level context — a customer's orders alongside their spend rank among all customers, a product's inventory alongside its sales rank within its category — need the data pre-joined and pre-ranked before the request arrives. Materialize maintains this continuously. The UI reads directly from indexed views and returns in milliseconds even as the dataset grows to millions of entities.

### When Postgres + Debezium + ClickHouse is the right choice instead

If the requirement is purely analytical — ad-hoc aggregations over the full dataset, no per-entity operational serving, no event-driven downstream consumers — then Debezium pushing CDC directly into ClickHouse delivers sub-100ms query times with ~2.4 s freshness and three fewer moving parts. ClickHouse's own pre-aggregation facilities (refreshable materialized views, dictionaries, AggregatingMergeTree) handle most OLAP workloads without a second database in the loop. This benchmark includes that path as "ClickHouse (standalone)" — the numbers show where each architecture wins.

### What to watch for at scale

You pay for the hardware required to maintain and serve these data products continuously. The core question is ROI: for your workload, does doing the join and aggregation work once at write time — and holding the results in memory and on local disk — cost less than doing it on every read? For operational queries with known access patterns and high read rates, the answer is usually yes. For ad-hoc analytical shapes with unpredictable query patterns, it may not be — which is why this architecture routes those to ClickHouse instead.

## For AI Agents

Agents operate in decision loops: query data, reason, act. Latency compounds per step. Agents also frequently need two kinds of reads in the same interaction:

- **Entity context:** *"What is the current state of this customer? What is their spend rank among all customers?"* Must reflect the latest write and return in milliseconds.
- **Analytical context:** *"What revenue patterns exist across all customers in this segment over the past 90 days?"* Requires a full-table scan that cannot be pre-indexed per entity.

Traditional stacks force a tradeoff: serve entity context from a cache (stale) or hit the OLAP system for everything (too slow for agentic loops). IVM eliminates the tradeoff. Agents that need to react to changes — rather than just query current state — can use `SUBSCRIBE` to receive each update the moment it's committed, with no polling interval adding latency to the decision loop. The benchmark demonstrates it: a query that ranks one customer among 100K by lifetime spend returns in **5.9 ms** from Materialize (including the full order history join) because the rank is maintained incrementally — the same data that feeds ClickHouse analytical queries.

## Stack

### The pattern


| Role                                              | Solution                                                 |
| ------------------------------------------------- | -------------------------------------------------------- |
| OLTP — transactional writes                       | One or more relational databases (Postgres, MySQL, etc.) |
| IVM — CDC, incremental views, operational serving | IVM engine                                               |
| OLAP — ad-hoc analytical reads                    | Columnar OLAP engine                                     |


The IVM engine can push directly to the OLAP engine or via an intermediate event bus depending on the implementation. In this stack, Materialize sinks to ClickHouse via Redpanda (a Kafka-compatible broker), which decouples the two systems and allows ClickHouse to consume at its own pace.

### This implementation


| Component       | Role                                                                                                                                                |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Postgres**    | OLTP — transactional writes, referential integrity, source of truth                                                                                 |
| **Materialize** | IVM — CDC from Postgres, incremental denormalization at consistent timestamps, operational serving via in-memory indexes, analytical sink via Kafka |
| **Redpanda**    | Kafka-compatible broker — event transport between Materialize and ClickHouse, and between Debezium and ClickHouse                                   |
| **ClickHouse**  | OLAP — ad-hoc analytical queries over the pre-joined flat table; also receives Debezium CDC directly for the standalone path                        |
| **Debezium**    | CDC connector — reads Postgres WAL and publishes row-level changes to Redpanda topics for the ClickHouse standalone path                            |


#### On Correctness

Materialize's Postgres source reads via logical replication, which preserves transaction boundaries. A transaction that inserts an order and five order items arrives as a single atomic change — Materialize will never expose a state where the order exists but its line items do not. All derived views are evaluated at the same logical timestamp, so a query against `customer_order_activity` always sees `order_detail` and `customer_profile` from the same consistent point in time; no join across two data products can observe a partially-applied transaction.

The Kafka sink streams changes from Materialize's consistent state as individual row upserts. ClickHouse converges to the latest state via ReplacingMergeTree + FINAL. **The transactional consistency guarantee holds only at the Materialize serving layer.** Both ClickHouse paths — the via-Materialize sink path and the Debezium-direct standalone path — are eventually consistent: either can observe a partial transaction (for example, an order exists but its line items have not yet arrived), and two columns in the same query can reflect state from different logical timestamps. This is the appropriate tradeoff for analytical queries that aggregate over millions of rows where per-row consistency is not required. It is the wrong tradeoff for operational reads that must never expose partial state — those belong on the Materialize serving layer.

**The boundary:** Materialize is the system of truth for current state; ClickHouse is for aggregated insight over large data.

### Compared to single-system HTAP

Single-system HTAP databases (TiDB, SingleStore) handle all workloads in one engine with architectural compromises across the write, operational, and analytical paths. This stack routes each workload to the system it is built for: Postgres for transactional writes, Materialize for stateful incremental computation, ClickHouse for columnar analytical scans. Each system operates at its natural performance ceiling.

## Architecture

Materialize maintains three layers. Each layer has a specific role; the boundaries are not arbitrary.

### Layer 1 — Sources (CDC from OLTP databases)

Raw change events entering Materialize via CDC. In this implementation a single Postgres instance is the source; in production deployments this layer typically covers multiple databases — one per service in a microservice architecture. Materialize maintains a separate CDC connection per source database, and all sources share the same logical time model, so joins across sources in Layer 2 are consistent.

Postgres logical replication emits changes at transaction granularity: all row mutations within a single Postgres transaction arrive together and are assigned the same logical timestamp. This is the foundation of end-to-end consistency — a transaction that touches `orders`, `order_items`, and `inventory` in one commit is never partially visible in any downstream derived object. This layer mirrors source tables into Materialize with no transformation or aggregation. Runs on `source_cluster` so ingestion throughput scales independently from compute.


| Object          | Description                         |
| --------------- | ----------------------------------- |
| `retail_source` | Postgres logical replication source |
| `customers`     | Mirrored from Postgres              |
| `products`      | Mirrored from Postgres              |
| `orders`        | Mirrored from Postgres              |
| `order_items`   | Mirrored from Postgres              |
| `inventory`     | Mirrored from Postgres              |


### Layer 2 — Real-Time Data Products

*The core business entities of the domain, maintained incrementally.*

Reusable materialized views that stay current as Postgres changes. These are the stable data products that multiple consumers share — both the operational path and the ClickHouse sink read from here. Layer 3 is kept thin because Layer 2 does the expensive join and aggregation work once, continuously, as data arrives. All views in this layer execute against the same consistent logical timestamp: a join between `orders` and `order_items` cannot see rows from different transactions, and a `RANK()` over `lifetime_spend` reflects the same set of committed writes as the spend values it ranks.


| Data Product         | Description                                                                                                              |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `customer_profile`   | Customer lifetime spend, order count, computed tier, and spend rank (RANK over all customers — maintained incrementally) |
| `product_catalog`    | Product with current price, category, and margin                                                                         |
| `order_detail`       | Fully denormalized: line items + products + customer in a single flat row — the source for the Kafka sink                |
| `inventory_position` | Current stock per product per warehouse with stock-to-sales ratio                                                        |


### Layer 3 — Serving

Layer 3 has two outputs from the same underlying computation.

**Operational path — served directly by Materialize to applications and agents:**

Thin views with indexes. The index is what makes the difference: Materialize has already maintained the join and aggregation; the index makes the lookup O(1) at query time. For reactive applications, `SUBSCRIBE` streams each change the moment it's committed — eliminating polling latency entirely. The demo uses this for the Materialize step.


| Serving Product           | Index         | Latency | Use Case                                                       |
| ------------------------- | ------------- | ------- | -------------------------------------------------------------- |
| `customer_order_activity` | `customer_id` | < 10 ms | Customer orders with full profile context including spend rank |
| `inventory_position`      | `sku`         | < 10 ms | Inventory lookup by SKU                                        |
| `product_performance`     | `sku`         | < 15 ms | Sales rank and buyer loyalty by SKU                            |


**Analytical path — sent to ClickHouse via Kafka:**

Two categories of sink serve different query families:

**Ad-hoc sinks** — pre-joined flat tables that preserve full row detail. ClickHouse can aggregate freely at query time, so these suit exploratory or unpredictable query shapes:


| Object               | Kafka Topic           | ClickHouse Table                           | Query family                                                                |
| -------------------- | --------------------- | ------------------------------------------ | --------------------------------------------------------------------------- |
| `order_detail`       | `orders-enriched`     | `orders_enriched` (ReplacingMergeTree)     | Item-level detail; flexible aggregation (cohort retention, funnel analysis) |
| `order_summary`      | `orders-summary`      | `orders_summary` (ReplacingMergeTree)      | Order-level detail; flexible temporal queries                               |
| `inventory_position` | `inventory-snapshots` | `inventory_snapshots` (ReplacingMergeTree) | Inventory replenishment                                                     |


**Pre-aggregated sinks** — Materialize IVM maintains the aggregation continuously; ClickHouse reads a small pre-bucketed result with no scan, no filter, no GROUP BY at query time. Use these when the query shape is fixed:


| Object                 | Kafka Topic         | ClickHouse Table                            | Query family                                                  |
| ---------------------- | ------------------- | ------------------------------------------- | ------------------------------------------------------------- |
| `sales_by_dim` MV      | `sales-by-dim`      | `mz_sales_by_dim` (ReplacingMergeTree)      | Revenue by category × customer tier × day-of-week (~203 rows) |
| `revenue_histogram` MV | `revenue-histogram` | `mz_revenue_histogram` (ReplacingMergeTree) | $50-bucket histogram, trailing 90-day window (~50 rows)       |


### Cluster Topology

```
source_cluster          → Layer 1: CDC source ingestion
transform_sink_cluster  → Layer 2: Data products + Layer 3: Serving + Sinks
```

> **Production note:** Use three clusters — source, transform, sink — for independent scaling and failure isolation. See [Materialize operational guidelines](https://materialize.com/docs/manage/operational-guidelines/).

## Benchmarks

Numbers below are from a 10-run benchmark against 1M orders / 2.8M order items / 100K customers. Results are reproducible: run `make load && make bench` on your own hardware; absolute numbers will vary by machine.

These benchmarks measure **response time** — how quickly each system returns a result once a query is issued against data already in the system. This is distinct from **reaction time**: the end-to-end latency from a write landing in Postgres to an updated result being available to read, which includes CDC propagation, incremental view maintenance, and sink delivery. `make bench` measures both and renders a combined chart; `make demo` measures freshness lag live.

### Reaction time = freshness lag + response time

Freshness values are from a local 10-run benchmark (Materialize ~288 ms via CDC, ClickHouse ~3.6 s via Kafka sink or Debezium). Run `make bench` to see values from your environment.

```
░░░ freshness lag (time until data reflects the latest write)
▒▒▒ avg batch scheduling wait (refresh_interval ÷ 2)
███ query response time

Operational — Customer orders + spend rank
  Postgres                      ████████████████████████████████████████
  Materialize                   ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░█
  ClickHouse (via Materialize)  ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░██████████
  ClickHouse (standalone)       ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒▒▒▒▒██
                                |          |          |          |         |
                                1ms        10ms       100ms      1s        10s

Analytical — Revenue histogram ($50 buckets, 90 d)
  Postgres                      ██████████████████████████████
  Materialize                   ░░░░██████████████████████████████████
  ClickHouse (via Materialize)  ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
  ClickHouse (standalone)       ░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                                |          |          |          |         |
                                1ms        10ms       100ms      1s        10s
```

**Operational — Customer orders + spend rank**


| System                       | Freshness lag | Avg batch wait | Response | Total reaction time |
| ---------------------------- | ------------- | -------------- | -------- | ------------------- |
| Postgres                     | 0 ms          | —              | 1.89 s   | **1.89 s**          |
| Materialize                  | 288 ms        | —              | 5.9 ms   | **294 ms**          |
| ClickHouse (via Materialize) | 3.59 s        | —              | 1.04 s   | **4.64 s**          |
| ClickHouse (standalone)      | 3.60 s        | 500 ms         | 168.7 ms | **4.27 s**          |


**Analytical — Revenue histogram ($50 buckets, 90 d)**


| System                       | Freshness lag | Avg batch wait | Response | Total reaction time |
| ---------------------------- | ------------- | -------------- | -------- | ------------------- |
| Postgres                     | 0 ms          | —              | 570.4 ms | **570.4 ms**        |
| Materialize                  | 288 ms        | —              | 2.77 s   | **3.05 s**          |
| ClickHouse (via Materialize) | 3.59 s        | —              | 6.2 ms   | **3.60 s**          |
| ClickHouse (standalone)      | 3.60 s        | 15 s           | 14.6 ms  | **18.6 s**          |


The chart is not a ranking — each system reflects a deliberate design tradeoff:

- **Postgres** has zero freshness lag (reads from the same store as writes) but response time grows with dataset size for aggregation-heavy queries
- **Materialize** absorbs a ~288 ms CDC propagation delay but response time stays flat regardless of dataset size because results are maintained incrementally — making total reaction time faster than Postgres for operational queries
- **ClickHouse (via Materialize)** has a larger freshness lag (CDC delay plus Kafka sink pipeline) but fast columnar response for full-table scans — the right routing choice when ~3.6 s staleness is acceptable, not when minimizing total reaction time
- **ClickHouse (standalone)** is the best-effort standalone: Debezium CDC (~3.6 s) plus a per-query batch scheduling wait (`▒▒▒`) — `refresh_interval ÷ 2` on average — before results reflect the latest write. For analytical queries with 30 s refresh MVs this adds ~15 s of batch wait on top of CDC lag. For operational queries the ClickHouse-native techniques (projections, ORDER BY layouts, AggregatingMergeTree, HASHED dictionaries) narrow the response-time gap with Materialize but can't close it — `FINAL` deduplication runs before predicates, so even a `WHERE customer_id = ?` point lookup deduplicates the full table first. Materialize pays that cost once at write time; ClickHouse pays it per query at read time

```bash
make load   # seed 1M orders
make bench  # run comparison (accepts --runs N)
```

### Operational Queries

Known access patterns benchmarked across four systems. ClickHouse (via Materialize) reads from Materialize-enriched, pre-joined denormalized tables. ClickHouse (standalone) uses Debezium CDC directly into ClickHouse-native tables with ORDER BY layouts tuned per query, projections, AggregatingMergeTree for incremental aggregation, and refreshable MVs for pre-computed rankings.


| Query                              | Postgres | Materialize  | CH via Materialize | CH standalone |
| ---------------------------------- | -------- | ------------ | ------------------ | ------------- |
| Inventory lookup (by SKU)          | 262 ms   | **4.7 ms ✓** | 6.6 ms             | 7.0 ms        |
| Customer orders + lifetime metrics | 1.89 s   | **5.9 ms ✓** | 1.04 s             | 168.7 ms      |
| Product performance (by SKU)       | 6.15 s   | **3.0 ms ✓** | 2.33 s             | 16.7 ms       |


**Inventory lookup (by SKU)**

```
  Postgres                      █████████████████████████████
  Materialize                   ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
  ClickHouse (via Materialize)  ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
  ClickHouse (standalone)       ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
                                |           |           |           |
                                1ms         10ms        100ms       1s
```


| System                       | Freshness lag | Avg batch wait | Response | Total reaction time |
| ---------------------------- | ------------- | -------------- | -------- | ------------------- |
| Postgres                     | 0 ms          | —              | 262.1 ms | **262.1 ms**        |
| Materialize                  | 288 ms        | —              | 4.7 ms   | **292.8 ms**        |
| ClickHouse (via Materialize) | 3.59 s        | —              | 6.6 ms   | **3.60 s**          |
| ClickHouse (standalone)      | 3.60 s        | —              | 7.0 ms   | **3.61 s**          |


**Customer orders + lifetime metrics**

```
  Postgres                      ████████████████████████████████████████
  Materialize                   ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░█
  ClickHouse (via Materialize)  ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░██████████
  ClickHouse (standalone)       ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▒▒▒▒▒██
                                |           |           |           |
                                1ms         10ms        100ms       1s
```


| System                       | Freshness lag | Avg batch wait | Response | Total reaction time |
| ---------------------------- | ------------- | -------------- | -------- | ------------------- |
| Postgres                     | 0 ms          | —              | 1.89 s   | **1.89 s**          |
| Materialize                  | 288 ms        | —              | 5.9 ms   | **294 ms**          |
| ClickHouse (via Materialize) | 3.59 s        | —              | 1.04 s   | **4.64 s**          |
| ClickHouse (standalone)      | 3.60 s        | 500 ms         | 168.7 ms | **4.27 s**          |


**Product performance (by SKU)**

```
  Postgres                      ██████████████████████████████████████████████
  Materialize                   ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
  ClickHouse (via Materialize)  ░░░░░░░░░░░░░░░░░░░░░░░░░░░░██████████████████
  ClickHouse (standalone)       ░░░░░░░░░░░░░░░░░░░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                                |           |           |           |
                                1ms         10ms        100ms       1s
```


| System                       | Freshness lag | Avg batch wait | Response | Total reaction time |
| ---------------------------- | ------------- | -------------- | -------- | ------------------- |
| Postgres                     | 0 ms          | —              | 6.15 s   | **6.15 s**          |
| Materialize                  | 288 ms        | —              | 3.0 ms   | **291 ms**          |
| ClickHouse (via Materialize) | 3.59 s        | —              | 2.33 s   | **5.93 s**          |
| ClickHouse (standalone)      | 3.60 s        | 2.50 s         | 16.7 ms  | **6.12 s**          |


**Why Postgres is slow:** the customer orders query must rank one customer by lifetime spend among all 100K customers. That requires aggregating all 2.8M order items at query time regardless of how many orders that customer has — there is no index that avoids the full scan. Product performance has the same structural problem: ranking one SKU by revenue requires reading every order item. These are not indexing failures; they are structurally unavoidable in a system that computes on read.

**Why Materialize is fast:** the rank is maintained incrementally. When a new order arrives, Materialize updates the affected customer's spend and recomputes the rank. The cost is paid once per write, not per read. The query hits an in-memory index and returns immediately. Materialize maintains joins across all inputs: when a customer's tier changes, every derived view that joins on customer data reflects it immediately — the change propagates from whichever table it lands in. ClickHouse's non-refreshable incremental MVs fire on insert to the source table only; a change to a join dependency elsewhere leaves the pre-computed result stale. The refreshable MVs in the standalone benchmark path avoid that correctness gap by re-running the full query on a schedule, but the batch scheduling wait is the cost of that fix.

**What ClickHouse standalone achieves:** this is the best possible version of ClickHouse for this workload — ORDER BY (customer_id, id) for orders, order_lookup projection for order_items, AggregatingMergeTree for incremental spend, refreshable MVs for pre-computed RANK() and product stats, HASHED dictionaries for O(1) dimension lookups. The gap narrows dramatically: inventory at 7.0 ms and product performance at 16.7 ms both come within striking distance. But for customer orders, even with the order_lookup projection and pre-computed rankings, 168.7 ms vs Materialize's 5.9 ms reflects a structural difference in where deduplication happens. `FINAL` runs before predicates: ClickHouse must deduplicate the full `opt_orders` table and the full `opt_order_items` table to determine which version of each row survives, then filter to the target customer. The join spans four tables — each fully deduplicated before the join executes. Materialize eliminates this cost entirely: the index holds already-deduplicated current state, so the query hits a pre-built result and returns immediately. Even the best possible ClickHouse configuration cannot eliminate read-time recomputation — it can only reduce it.

**Why Materialize wins operational queries overall:** with CDC freshness of ~288 ms, Materialize's total reaction time for operational queries is under 300 ms. Both ClickHouse paths carry ~3.6 s freshness lag — so even before counting query time, they are already behind.

**Result:** Materialize delivers sub-300 ms total reaction time for operational queries. Both ClickHouse paths exceed 3.6 s before a query executes.

### Analytical Queries

Analytical queries split into two categories: fixed shapes → pre-aggregate in Materialize, send the small result to ClickHouse; ad-hoc shapes → scan the pre-joined flat table in ClickHouse at query time.

Two patterns serve these categories. For fixed query shapes, Materialize pre-aggregates at write time and ClickHouse reads a small result table directly. For ad-hoc or exploratory shapes, Materialize sinks the pre-joined flat table and ClickHouse aggregates at query time.

ClickHouse (via Materialize) uses pre-aggregated sinks for the cross-dimensional and histogram queries; it falls back to the full flat table for cohort retention (ad-hoc shape). ClickHouse (standalone) uses Debezium-fed pre-aggregated tables refreshed every 30 seconds.

Response time alone does not determine which system delivers results soonest after a write. Every ClickHouse path carries a ~3.6 s freshness lag before the query executes; Materialize reflects writes in ~288 ms. **Reaction time — freshness lag + response — is the decisive comparison for data-currency-sensitive applications.** The chart below integrates both.


| Query                                    | Postgres | Materialize | ClickHouse (via Materialize) | ClickHouse (standalone) |
| ---------------------------------------- | -------- | ----------- | ---------------------------- | ----------------------- |
| Revenue histogram ($50 buckets, 90 d)    | 570.4 ms | 2.77 s      | 6.2 ms (pre-aggregated)      | 14.6 ms                 |
| Revenue by category × tier × day-of-week | 4.93 s   | 4.04 s      | 8.5 ms (pre-aggregated)      | 5.4 ms                  |
| Cohort retention (30/60/90 d)            | 1.54 s   | 8.31 s      | 424.3 ms (flat table)        | 143.5 ms                |


*Columns show response time only. See the reaction-time chart for total latency including freshness lag.*

> **A note on the ClickHouse standalone refresh interval.** The pre-aggregated MVs here use a 30 s refresh interval — conservative but typical per [ClickHouse guidance](https://github.com/ClickHouse/clickhouse-docs/blob/main/docs/best-practices/use_materialized_views.md) (interval should exceed query time; for 5–15 ms queries, anywhere from 1 s to several minutes is defensible). Both CH paths share the same ~3.6 s CDC floor; any non-zero refresh interval adds `interval / 2` average batch wait on top — so CH standalone's total reaction time always exceeds CH via Materialize's by approximately `refresh_interval / 2`. The right value depends on your re-aggregation cost and freshness SLA; tighter intervals close the gap.

**Revenue histogram ($50 buckets, 90 d)**

```
  Postgres                      ██████████████████████████████
  Materialize                   ░░░░██████████████████████████████████
  ClickHouse (via Materialize)  ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
  ClickHouse (standalone)       ░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                                |          |          |         |          |
                                1ms        10ms       100ms     1s         10s
```


| System                       | Freshness lag | Avg batch wait | Response | Total reaction time |
| ---------------------------- | ------------- | -------------- | -------- | ------------------- |
| Postgres                     | 0 ms          | —              | 570.4 ms | **570.4 ms**        |
| Materialize                  | 288 ms        | —              | 2.77 s   | **3.05 s**          |
| ClickHouse (via Materialize) | 3.59 s        | —              | 6.2 ms   | **3.60 s**          |
| ClickHouse (standalone)      | 3.60 s        | 15.00 s        | 14.6 ms  | **18.61 s**         |


**Revenue by category × tier × day-of-week**

```
  Postgres                      ████████████████████████████████████████
  Materialize                   ░░░████████████████████████████████████
  ClickHouse (via Materialize)  ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░
  ClickHouse (standalone)       ░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                                |          |          |         |          |
                                1ms        10ms       100ms     1s         10s
```


| System                       | Freshness lag | Avg batch wait | Response | Total reaction time |
| ---------------------------- | ------------- | -------------- | -------- | ------------------- |
| Postgres                     | 0 ms          | —              | 4.93 s   | **4.93 s**          |
| Materialize                  | 288 ms        | —              | 4.04 s   | **4.33 s**          |
| ClickHouse (via Materialize) | 3.59 s        | —              | 8.5 ms   | **3.60 s**          |
| ClickHouse (standalone)      | 3.60 s        | 15.00 s        | 5.4 ms   | **18.60 s**         |


**Cohort retention (30/60/90 d)**

```
  Postgres                      ██████████████████████████████████
  Materialize                   ░█████████████████████████████████████████
  ClickHouse (via Materialize)  ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░████
  ClickHouse (standalone)       ░░░░░░░░░▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒
                                |          |          |         |          |
                                1ms        10ms       100ms     1s         10s
```


| System                       | Freshness lag | Avg batch wait | Response | Total reaction time |
| ---------------------------- | ------------- | -------------- | -------- | ------------------- |
| Postgres                     | 0 ms          | —              | 1.54 s   | **1.54 s**          |
| Materialize                  | 288 ms        | —              | 8.31 s   | **8.60 s**          |
| ClickHouse (via Materialize) | 3.59 s        | —              | 424.3 ms | **4.02 s**          |
| ClickHouse (standalone)      | 3.60 s        | 15.00 s        | 143.5 ms | **18.74 s**         |


**Two sink patterns, two tradeoffs — measured by reaction time:**

*Pre-aggregated sinks* (revenue histogram, cross-dimensional): Materialize IVM maintains the aggregation continuously — ~50 rows for the histogram, ~203 rows for category × tier × day-of-week. ClickHouse reads the pre-bucketed result in single-digit milliseconds (6.2 ms histogram, 8.5 ms cross-dimensional), but the 3.59 s sink pipeline yields ~3.60 s total reaction time. Materialize's own continuously maintained MV reaches the same result in ~3.05 s total reaction time (288 ms freshness + 2.77 s scan). The ClickHouse sink path is the right choice when analytical load should be isolated from the Materialize serving cluster; route directly to Materialize when minimizing time from write to result is the priority.

*Ad-hoc sinks* (cohort retention): Materialize sinks `orders_summary` as a 1M-row pre-joined flat table. ClickHouse standalone achieves the shortest response time (143.5 ms vs 424.3 ms via flat-table scan), but its 15 s batch window produces 18.74 s total reaction time. ClickHouse via Materialize reaches 4.02 s total — substantially fresher. Choose ClickHouse for cohort queries when query shapes are unpredictable and ~4 s staleness is acceptable; design a pre-aggregated Materialize MV when the cohort definition is fixed and freshness matters.

**Designing sinks for query families.** Each Materialize sink is maintained incrementally from the same CDC stream — the cost is paid once at write time, not per query per reader. The other side of that tradeoff: each pre-aggregated sink is a dataflow Materialize runs continuously, consuming hardware resources (CPU, memory, and disk) whether anyone reads from it or not. For the low-cardinality results here (~50 and ~203 rows) the footprint is negligible; for higher-cardinality groupings (say, per-customer-per-day) it becomes a real sizing consideration.


| Query family                              | Materialize sink                                | Shape                          | ClickHouse standalone table                |
| ----------------------------------------- | ----------------------------------------------- | ------------------------------ | ------------------------------------------ |
| Revenue histogram                         | `revenue_histogram` MV → `mz_revenue_histogram` | **pre-aggregated** (~50 rows)  | `opt_order_totals` — pre-totaled (30 s)    |
| Cross-dimensional (category × tier × dow) | `sales_by_dim` MV → `mz_sales_by_dim`           | **pre-aggregated** (~203 rows) | `opt_sales_by_dim` — pre-aggregated (30 s) |
| Temporal / cohort / funnel                | `orders_summary` → `orders_summary`             | flat (1M rows)                 | `opt_order_totals` — pre-totaled (30 s)    |
| Product performance                       | `inventory_snapshots`                           | flat                           | `product_category_rank` — pre-ranked (5 s) |
| Customer rank                             | via `customer_order_activity` index             | flat                           | `customer_rank` — pre-ranked (1 s)         |


**Why Materialize is slow for ad-hoc analytical queries:** without a purpose-built index or pre-aggregated MV for a specific aggregation shape, Materialize falls back to a full scan of its row-oriented store (memory and local disk). For fixed shapes, the pre-aggregated sinks demonstrate the fix — and because Materialize updates them continuously, they achieve better reaction time than the equivalent ClickHouse sink path (e.g., 3.05 s vs 3.60 s total for the histogram). For truly ad-hoc or unpredictable shapes, route to ClickHouse and accept the ~3.6 s sink delay as the price of flexible aggregation.

**Result:** for fixed analytical shapes, Materialize's continuously maintained sinks deliver better reaction time than the ClickHouse sink path. For ad-hoc shapes, ClickHouse wins on response time — you pay the ~3.6 s freshness lag as the cost of flexible aggregation.

## Production Considerations

- **Three-cluster Materialize**: source / transform / sink for independent scaling
- **Avro + Schema Registry**: upgrade from JSON for schema evolution support (Redpanda includes a Schema Registry)
- **Secrets management**: use Materialize secrets (`CREATE SECRET`) instead of plaintext passwords
- **ReplacingMergeTree + FINAL**: all ClickHouse analytical queries must use `FINAL` for correct deduplication after CDC upserts
- **Tombstone handling**: Materialize upsert deletes produce Kafka tombstones; ClickHouse skips unparseable messages by default — verify this matches your delete semantics

## Run it

### Local (Docker)

```bash
make up && make init   # start all 5 services, apply schema, seed data (~60 seconds)
make demo              # watch a price change propagate end-to-end
```

`make demo` inserts a price change into Postgres and prints the propagation latency at each hop.

```bash
make load    # seed 1M orders (requires init)
make bench   # run latency comparison across all three systems
make test    # full test suite
```

### AWS (ephemeral EC2)

Runs the full stack on a single `m5.2xlarge` EC2 instance. The instance is created on demand and deleted when you're done — no lingering costs.

**Prerequisites:** AWS CLI configured (`aws configure`) with EC2 permissions.

```bash
make aws-debug   # verify credentials and permissions before spending anything
make aws-up      # provision EC2, sync files, start all 5 Docker services (~3 min)
make aws-init    # initialize Materialize pipeline
make aws-load    # seed 1M orders
make aws-bench   # run benchmark — output streams to your terminal
make aws-demo    # run live demo — output streams to your terminal
make aws-down    # terminate instance, delete all AWS resources
```

All state (instance ID, key, IP) is stored in `.state/` which is git-ignored. To use a different instance type: `INSTANCE_TYPE=m5.4xlarge make aws-up`.

## Testing

```bash
make test
```

Tests cover: connectivity, data product correctness, end-to-end pipeline, ClickHouse deduplication, backfill, and performance baselines.