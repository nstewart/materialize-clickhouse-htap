-- Raw normalized tables for standalone ClickHouse benchmarking.
-- These mirror the Postgres source tables directly (no pre-joining, no aggregation)
-- and are bulk-loaded by generate_load.py after each Postgres seed.
-- Queries against these tables must JOIN at read time, demonstrating the cost
-- of receiving normalized data without an IVM layer.

CREATE DATABASE IF NOT EXISTS retail;

CREATE TABLE IF NOT EXISTS retail.raw_customers (
    id         Int64,
    email      String,
    name       String,
    tier       String,
    created_at DateTime64(6, 'UTC')
) ENGINE = ReplacingMergeTree(created_at)
ORDER BY id;

CREATE TABLE IF NOT EXISTS retail.raw_products (
    id         Int64,
    sku        String,
    name       String,
    category   String,
    price      Decimal(10, 2),
    cost       Decimal(10, 2),
    created_at DateTime64(6, 'UTC')
) ENGINE = ReplacingMergeTree(created_at)
ORDER BY id;

CREATE TABLE IF NOT EXISTS retail.raw_orders (
    id          Int64,
    customer_id Int64,
    status      String,
    created_at  DateTime64(6, 'UTC'),
    updated_at  DateTime64(6, 'UTC')
) ENGINE = ReplacingMergeTree(updated_at)
ORDER BY id;

CREATE TABLE IF NOT EXISTS retail.raw_order_items (
    id         Int64,
    order_id   Int64,
    product_id Int64,
    quantity   Int32,
    unit_price Decimal(10, 2)
) ENGINE = ReplacingMergeTree()
ORDER BY id;

CREATE TABLE IF NOT EXISTS retail.raw_inventory (
    product_id   Int64,
    warehouse_id String,
    quantity     Int32,
    updated_at   DateTime64(6, 'UTC')
) ENGINE = ReplacingMergeTree(updated_at)
ORDER BY (product_id, warehouse_id);
