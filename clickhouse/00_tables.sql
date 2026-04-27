-- =============================================================================
-- FILE: 00_tables.sql
-- PURPOSE: Create the retail database and destination ReplacingMergeTree tables.
--
-- These tables are the final landing zone for data originating in Postgres,
-- streamed through Materialize (as enriched views), and published to Redpanda
-- (Kafka-compatible) before being consumed by ClickHouse.
--
-- Data flow:
--   Postgres → Materialize → Redpanda → ClickHouse (Kafka engine MV → here)
--
-- Deduplication strategy:
--   ReplacingMergeTree deduplicates rows sharing the same ORDER BY key,
--   keeping the row with the greatest version column value. Deduplication
--   happens at background merge time, so all reads MUST use FINAL to force
--   eager deduplication at query time and return correct results.
-- =============================================================================

CREATE DATABASE IF NOT EXISTS retail;

-- -----------------------------------------------------------------------------
-- retail.orders_enriched
-- Destination table for order line items enriched by Materialize's
-- order_detail view (joined across orders, order_items, products, customers).
--
-- Partitioned by order_created_at month so that historical month partitions
-- become immutable quickly and background merges stay cheap.
--
-- Version column: order_updated_at
--   When Materialize retracts and re-emits a row (UPSERT via Kafka), the new
--   row carries a later order_updated_at, so ReplacingMergeTree keeps it.
--
-- IMPORTANT: All queries against this table must use FINAL for correct results.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS retail.orders_enriched
(
    line_item_id     Int64,
    order_id         Int64,
    customer_id      Int64,
    status           String,
    order_created_at DateTime64(6, 'UTC'),
    order_updated_at DateTime64(6, 'UTC'),
    product_id       Int64,
    quantity         Int32,
    unit_price       Float64,
    subtotal         Float64,
    sku              String,
    product_name     String,
    category         String,
    current_price    Float64,
    customer_email   String,
    customer_tier    String,
    unit_cost        Float64,
    line_margin      Float64,
    margin_pct       Float64
)
ENGINE = ReplacingMergeTree(order_updated_at)
PARTITION BY toYYYYMM(order_created_at)
ORDER BY (line_item_id)
SETTINGS index_granularity = 8192;

-- -----------------------------------------------------------------------------
-- retail.orders_summary
-- Order-level aggregate sourced from Materialize's order_summary view via the
-- orders-summary Kafka topic. One row per order (1M rows) vs. one row per line
-- item in orders_enriched (2.8M rows). Designed for order-level query families:
-- cohort retention, revenue histogram, funnel analysis.
--
-- Version column: order_updated_at
--   Materialize emits a new UPSERT on any status change; the later
--   order_updated_at wins deduplication.
--
-- IMPORTANT: All queries against this table must use FINAL for correct results.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS retail.orders_summary
(
    order_id         Int64,
    customer_id      Int64,
    status           String,
    order_created_at DateTime64(6, 'UTC'),
    order_updated_at DateTime64(6, 'UTC'),
    customer_tier    String,
    order_total      Float64,
    total_items      Int32,
    line_item_count  Int32
)
ENGINE = ReplacingMergeTree(order_updated_at)
PARTITION BY toYYYYMM(order_created_at)
ORDER BY (order_id)
SETTINGS index_granularity = 8192;

-- -----------------------------------------------------------------------------
-- retail.inventory_snapshots
-- Destination table for inventory positions enriched by Materialize's
-- inventory_position view (joined across inventory and products).
--
-- No time-based partition: inventory rows are updated in place by warehouse,
-- so cardinality stays bounded and a single partition is appropriate.
--
-- Version column: updated_at
--   Each Materialize UPSERT carries the latest updated_at from the source,
--   ensuring the most-recent snapshot survives deduplication.
--
-- IMPORTANT: All queries against this table must use FINAL for correct results.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS retail.inventory_snapshots
(
    product_id   Int64,
    warehouse_id String,
    quantity     Int32,
    updated_at   DateTime64(6, 'UTC'),
    sku          String,
    product_name String,
    category     String,
    price        Float64,
    cost                Float64,
    total_units_sold    Float64,
    stock_to_sales_ratio Nullable(Float64)
)
ENGINE = ReplacingMergeTree(updated_at)
ORDER BY (product_id, warehouse_id)
SETTINGS index_granularity = 8192;
