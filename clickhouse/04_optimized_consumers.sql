-- =============================================================================
-- FILE: 04_optimized_consumers.sql
-- PURPOSE: Kafka engine tables + routing MVs that consume from Debezium CDC
--          topics and write into the optimized destination tables.
--
-- Run AFTER 03_optimized_tables.sql.
--
-- Data flow:
--   Postgres WAL → Debezium → Redpanda (dbz.public.*) → Kafka engine tables
--   → MVs → opt_* destination tables
--   → chained MVs → customer_spend_agg, product_units_agg
--
-- Topic naming: Debezium uses prefix.schema.table → dbz.public.orders etc.
--
-- Timestamp handling:
--   Debezium emits TIMESTAMPTZ as ISO 8601 strings (e.g. "2024-01-15T10:30:00Z")
--   with time.precision.mode=connect. parseDateTime64BestEffortOrZero handles
--   these correctly and returns the epoch for any unparseable value.
--
-- Decimal handling:
--   decimal.handling.mode=double in the connector ensures NUMERIC columns
--   arrive as JSON floats — no string-to-decimal conversion needed in the MV.
--
-- Consumer groups:
--   Each Kafka engine table uses its own consumer group. Offsets are committed
--   after each successful batch write, giving at-least-once delivery.
--   ReplacingMergeTree deduplicates any retried rows at merge/FINAL time.
-- =============================================================================

-- =============================================================================
-- PIPELINE: dbz.public.customers → opt_customers
-- =============================================================================

CREATE TABLE IF NOT EXISTS retail.kafka_dbz_customers_raw
(
    id         Int64,
    email      String,
    name       String,
    tier       String,
    created_at Nullable(String)
)
ENGINE = Kafka
SETTINGS
    kafka_broker_list          = 'redpanda:9092',
    kafka_topic_list           = 'dbz.public.customers',
    kafka_group_name           = 'clickhouse-dbz-customers',
    kafka_format               = 'JSONEachRow',
    kafka_skip_broken_messages = 10,
    kafka_flush_interval_ms    = 1000,
    kafka_poll_timeout_ms      = 100;

CREATE MATERIALIZED VIEW IF NOT EXISTS retail.opt_customers_consumer
TO retail.opt_customers AS
SELECT
    id,
    email,
    name,
    tier,
    parseDateTime64BestEffortOrZero(assumeNotNull(created_at), 6, 'UTC') AS created_at
FROM retail.kafka_dbz_customers_raw;

-- =============================================================================
-- PIPELINE: dbz.public.products → opt_products
-- =============================================================================

CREATE TABLE IF NOT EXISTS retail.kafka_dbz_products_raw
(
    id         Int64,
    sku        String,
    name       String,
    category   String,
    price      Float64,
    cost       Float64,
    created_at Nullable(String)
)
ENGINE = Kafka
SETTINGS
    kafka_broker_list          = 'redpanda:9092',
    kafka_topic_list           = 'dbz.public.products',
    kafka_group_name           = 'clickhouse-dbz-products',
    kafka_format               = 'JSONEachRow',
    kafka_skip_broken_messages = 10,
    kafka_flush_interval_ms    = 1000,
    kafka_poll_timeout_ms      = 100;

CREATE MATERIALIZED VIEW IF NOT EXISTS retail.opt_products_consumer
TO retail.opt_products AS
SELECT
    id,
    sku,
    name,
    category,
    price,
    cost,
    parseDateTime64BestEffortOrZero(assumeNotNull(created_at), 6, 'UTC') AS created_at
FROM retail.kafka_dbz_products_raw;

-- =============================================================================
-- PIPELINE: dbz.public.orders → opt_orders
-- =============================================================================

CREATE TABLE IF NOT EXISTS retail.kafka_dbz_orders_raw
(
    id          Int64,
    customer_id Int64,
    status      String,
    created_at  Nullable(String),
    updated_at  Nullable(String)
)
ENGINE = Kafka
SETTINGS
    kafka_broker_list          = 'redpanda:9092',
    kafka_topic_list           = 'dbz.public.orders',
    kafka_group_name           = 'clickhouse-dbz-orders',
    kafka_format               = 'JSONEachRow',
    kafka_skip_broken_messages = 10,
    kafka_flush_interval_ms    = 1000,
    kafka_poll_timeout_ms      = 100;

CREATE MATERIALIZED VIEW IF NOT EXISTS retail.opt_orders_consumer
TO retail.opt_orders AS
SELECT
    id,
    customer_id,
    status,
    parseDateTime64BestEffortOrZero(assumeNotNull(created_at), 6, 'UTC') AS created_at,
    parseDateTime64BestEffortOrZero(assumeNotNull(updated_at), 6, 'UTC') AS updated_at
FROM retail.kafka_dbz_orders_raw;

-- =============================================================================
-- PIPELINE: dbz.public.order_items → opt_order_items + customer_spend_agg
-- =============================================================================

CREATE TABLE IF NOT EXISTS retail.kafka_dbz_order_items_raw
(
    id         Int64,
    order_id   Int64,
    product_id Int64,
    quantity   Int32,
    unit_price Float64
)
ENGINE = Kafka
SETTINGS
    kafka_broker_list          = 'redpanda:9092',
    kafka_topic_list           = 'dbz.public.order_items',
    kafka_group_name           = 'clickhouse-dbz-order-items',
    kafka_format               = 'JSONEachRow',
    kafka_skip_broken_messages = 10,
    kafka_flush_interval_ms    = 1000,
    kafka_poll_timeout_ms      = 100;

-- Route decoded rows into the destination table.
CREATE MATERIALIZED VIEW IF NOT EXISTS retail.opt_order_items_consumer
TO retail.opt_order_items AS
SELECT id, order_id, product_id, quantity, unit_price
FROM retail.kafka_dbz_order_items_raw;

-- Maintain incremental lifetime_spend per customer.
-- Fires when opt_order_items receives rows; JOINs opt_orders for customer_id.
-- At snapshot time, orders arrive before order_items, so the JOIN resolves.
CREATE MATERIALIZED VIEW IF NOT EXISTS retail.customer_spend_agg_mv
TO retail.customer_spend_agg AS
SELECT
    o.customer_id,
    sumState(toFloat64(oi.quantity) * oi.unit_price) AS lifetime_spend
FROM retail.opt_order_items oi
JOIN retail.opt_orders o ON o.id = oi.order_id
GROUP BY o.customer_id;

-- =============================================================================
-- PIPELINE: dbz.public.inventory → opt_inventory
-- =============================================================================

CREATE TABLE IF NOT EXISTS retail.kafka_dbz_inventory_raw
(
    product_id   Int64,
    warehouse_id String,
    quantity     Int32,
    updated_at   Nullable(String)
)
ENGINE = Kafka
SETTINGS
    kafka_broker_list          = 'redpanda:9092',
    kafka_topic_list           = 'dbz.public.inventory',
    kafka_group_name           = 'clickhouse-dbz-inventory',
    kafka_format               = 'JSONEachRow',
    kafka_skip_broken_messages = 10,
    kafka_flush_interval_ms    = 1000,
    kafka_poll_timeout_ms      = 100;

CREATE MATERIALIZED VIEW IF NOT EXISTS retail.opt_inventory_consumer
TO retail.opt_inventory AS
SELECT
    product_id,
    warehouse_id,
    quantity,
    parseDateTime64BestEffortOrZero(assumeNotNull(updated_at), 6, 'UTC') AS updated_at
FROM retail.kafka_dbz_inventory_raw;
