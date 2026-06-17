# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A HTAP (Hybrid Transactional/Analytical Processing) reference architecture with a push-based pipeline:

**PostgreSQL** (OLTP writes) → **Materialize** (CDC + incremental view maintenance) → **Redpanda** (Kafka transport) → **ClickHouse** (OLAP analytics)

Operational queries with known access patterns are served from Materialize (<10ms via indexed views). Ad-hoc analytical queries are served from ClickHouse. Both consume from the same consistent Materialize computation layer.

## Commands

```bash
make up      # Start all 4 services (Postgres, Materialize, Redpanda, ClickHouse)
make init    # Apply schema and initialize the full pipeline
make test    # Run pytest suite (pytest tests/ -v --timeout=120)
make demo    # Live price-change propagation demo showing end-to-end latency
make load    # Seed 1M synthetic orders (requires init first)
make bench   # Run performance comparison across all 3 systems
make reset   # Teardown and reinitialize from scratch
make down    # Stop and remove containers
```

Python dependencies: `pip install -r requirements.txt` (psycopg2-binary, clickhouse-connect, faker, rich, pytest, pytest-timeout)

## Architecture: Three Materialize Layers

SQL files in `materialize/` build up in layers:

1. **`00_connection.sql`** — clusters, secrets, Postgres connection
2. **`01_sources.sql`** — CDC sources from Postgres logical replication
3. **`02_data_products.sql`** — 4 reusable materialized views: `customer_profile`, `product_catalog`, `order_detail` (4-way join), `inventory_position`
4. **`03_serving.sql`** — indexed serving views (`customer_order_activity`, `product_performance`) + Kafka sinks to Redpanda topics `orders-enriched` and `inventory-snapshots`

Initialization order matters: `scripts/init.sh` applies SQL in sequence across all 3 systems with retry logic and health-check waits.

## ClickHouse Correctness

All ClickHouse tables use `ReplacingMergeTree`. Queries against `orders_enriched` and `inventory_snapshots` must use `FINAL` for correct deduplication — merges happen asynchronously in the background.

## Service Ports

| Service | Port |
|---------|------|
| Postgres | 5432 |
| Materialize | 6875 |
| Redpanda (Kafka) | 19092 |
| ClickHouse HTTP | 8123 |
| ClickHouse native | 9000 |

Connection config lives in `.env` (copy from `.env.example`). All Python scripts load it via `python-dotenv` or explicit `os.environ` reads.

## Tests

`tests/conftest.py` provides connection fixtures and a `wait_for_condition()` helper used throughout. Pipeline e2e tests insert into Postgres and assert the row eventually appears in both Materialize and ClickHouse. The 120s timeout covers the full propagation lag.

## Benchmarks

`benchmarks/queries/` contains 6 query sets (3 operational, 3 analytical), each with Postgres/Materialize/ClickHouse variants. The benchmark runner measures avg/p90/max latency across all 3 systems. Expected results: Materialize is 21–203x faster for operational queries (21x inventory, 59x customer orders, 203x product performance); ClickHouse is 1.8–11x faster for analytical queries. Freshness medians (250 ms Materialize tick rate): Materialize ~185 ms via CDC, ClickHouse standalone ~505 ms via Debezium, ClickHouse via Materialize ~700 ms via the Kafka sink (the sink path is slowest because the join is materialized upstream before the row lands).
