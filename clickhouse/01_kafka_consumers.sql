-- =============================================================================
-- FILE: 01_kafka_consumers.sql
-- PURPOSE: Kafka engine source tables (read from Redpanda) and Materialized
--          Views that route decoded records into the destination tables.
--
-- Run AFTER 00_tables.sql. Each pipeline follows the same two-object pattern:
--
--   kafka_*_raw (Kafka engine)
--     Reads raw JSON from a Redpanda topic. ClickHouse consumes from this
--     table internally; it is not queried directly.
--
--   *_consumer (Materialized View)
--     Attached TO the destination ReplacingMergeTree table. Runs on every
--     batch the Kafka engine delivers, converting ISO-8601 timestamp strings
--     to DateTime64 and writing rows into the target table.
--
-- Timestamp handling:
--   Materialize emits timestamps as ISO-8601 strings (e.g. "2024-03-15T10:23:45.123456Z").
--   The Kafka engine table stores them as Nullable(String) to tolerate missing
--   or malformed values. The MV uses parseDateTime64BestEffortOrZero, which
--   returns the epoch (1970-01-01) for unparseable input rather than failing
--   the entire batch — a safe fallback that keeps the pipeline running while
--   making bad rows easy to detect in dashboards.
--
-- Consumer groups:
--   Each Kafka engine table creates its own durable consumer group in Redpanda.
--   Offsets are committed by ClickHouse after each batch is written to the MV
--   target, giving at-least-once delivery semantics. The ReplacingMergeTree
--   deduplicates retries at merge time (or at query time via FINAL).
-- =============================================================================

-- =============================================================================
-- PIPELINE 1: orders-enriched
-- Source topic : orders-enriched  (key = line_item_id)
-- Destination  : retail.orders_enriched
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Kafka source table — orders-enriched topic
-- Reads one JSON object per Kafka message. ClickHouse maps JSON field names
-- to column names automatically via JSONEachRow format.
-- kafka_skip_broken_messages = 10 lets the consumer skip up to 10 malformed
-- messages per batch rather than stalling on a single bad record.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS retail.kafka_orders_enriched_raw
(
    line_item_id     Int64,
    order_id         Int64,
    customer_id      Int64,
    status           String,
    order_created_at Nullable(String),  -- Unix ms from Materialize (e.g. "1704448800000.000"); converted in MV
    order_updated_at Nullable(String),  -- Unix ms from Materialize; converted in MV
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
ENGINE = Kafka
SETTINGS
    kafka_broker_list          = 'redpanda:9092',
    kafka_topic_list           = 'orders-enriched',
    kafka_group_name           = 'clickhouse-orders-consumer',
    kafka_format               = 'JSONEachRow',
    kafka_skip_broken_messages = 10,
    kafka_poll_timeout_ms      = 50,
    kafka_flush_interval_ms    = 50;

-- -----------------------------------------------------------------------------
-- Materialized View — routes Kafka records into retail.orders_enriched
-- Converts Nullable(String) timestamps to DateTime64(6, 'UTC').
-- assumeNotNull is safe here because parseDateTime64BestEffortOrZero handles
-- NULL by returning epoch (0), matching the behaviour for bad strings.
-- -----------------------------------------------------------------------------
CREATE MATERIALIZED VIEW IF NOT EXISTS retail.orders_enriched_consumer
TO retail.orders_enriched
AS
SELECT
    line_item_id,
    order_id,
    customer_id,
    status,
    -- Materialize JSON sink emits timestamptz as Unix milliseconds (e.g. "1704448800000.000")
    fromUnixTimestamp64Milli(toInt64(toFloat64OrZero(assumeNotNull(order_created_at)))) AS order_created_at,
    fromUnixTimestamp64Milli(toInt64(toFloat64OrZero(assumeNotNull(order_updated_at)))) AS order_updated_at,
    product_id,
    quantity,
    unit_price,
    subtotal,
    sku,
    product_name,
    category,
    current_price,
    customer_email,
    customer_tier,
    unit_cost,
    line_margin,
    margin_pct
FROM retail.kafka_orders_enriched_raw;

-- =============================================================================
-- PIPELINE 2: orders-summary
-- Source topic : orders-summary  (key = order_id)
-- Destination  : retail.orders_summary
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Kafka source table — orders-summary topic
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS retail.kafka_orders_summary_raw
(
    order_id         Int64,
    customer_id      Int64,
    status           String,
    order_created_at Nullable(String),  -- Unix ms from Materialize; converted in MV
    order_updated_at Nullable(String),  -- Unix ms from Materialize; converted in MV
    customer_tier    String,
    order_total      Float64,
    total_items      Int32,
    line_item_count  Int32
)
ENGINE = Kafka
SETTINGS
    kafka_broker_list          = 'redpanda:9092',
    kafka_topic_list           = 'orders-summary',
    kafka_group_name           = 'clickhouse-orders-summary-consumer',
    kafka_format               = 'JSONEachRow',
    kafka_skip_broken_messages = 10,
    kafka_poll_timeout_ms      = 50,
    kafka_flush_interval_ms    = 50;

-- -----------------------------------------------------------------------------
-- Materialized View — routes order summary records into retail.orders_summary
-- -----------------------------------------------------------------------------
CREATE MATERIALIZED VIEW IF NOT EXISTS retail.orders_summary_consumer
TO retail.orders_summary
AS
SELECT
    order_id,
    customer_id,
    status,
    fromUnixTimestamp64Milli(toInt64(toFloat64OrZero(assumeNotNull(order_created_at)))) AS order_created_at,
    fromUnixTimestamp64Milli(toInt64(toFloat64OrZero(assumeNotNull(order_updated_at)))) AS order_updated_at,
    customer_tier,
    order_total,
    total_items,
    line_item_count
FROM retail.kafka_orders_summary_raw;

-- =============================================================================
-- PIPELINE 3: inventory-snapshots
-- Source topic : inventory-snapshots  (key = (product_id, warehouse_id))
-- Destination  : retail.inventory_snapshots
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Kafka source table — inventory-snapshots topic
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS retail.kafka_inventory_snapshots_raw
(
    product_id   Int64,
    warehouse_id String,
    quantity     Int32,
    updated_at   Nullable(String),  -- Unix ms from Materialize; converted in MV
    sku          String,
    product_name String,
    category     String,
    price        Float64,
    cost                Float64,
    total_units_sold    Float64,
    stock_to_sales_ratio Nullable(Float64)
)
ENGINE = Kafka
SETTINGS
    kafka_broker_list          = 'redpanda:9092',
    kafka_topic_list           = 'inventory-snapshots',
    kafka_group_name           = 'clickhouse-inventory-consumer',
    kafka_format               = 'JSONEachRow',
    kafka_skip_broken_messages = 10,
    kafka_poll_timeout_ms      = 50,
    kafka_flush_interval_ms    = 50;

-- -----------------------------------------------------------------------------
-- Materialized View — routes inventory records into retail.inventory_snapshots
-- -----------------------------------------------------------------------------
CREATE MATERIALIZED VIEW IF NOT EXISTS retail.inventory_snapshots_consumer
TO retail.inventory_snapshots
AS
SELECT
    product_id,
    warehouse_id,
    quantity,
    fromUnixTimestamp64Milli(toInt64(toFloat64OrZero(assumeNotNull(updated_at)))) AS updated_at,
    sku,
    product_name,
    category,
    price,
    cost,
    total_units_sold,
    stock_to_sales_ratio
FROM retail.kafka_inventory_snapshots_raw;
