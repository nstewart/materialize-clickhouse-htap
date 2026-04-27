-- =============================================================================
-- FILE: 05_mz_analytical_sinks.sql
-- PURPOSE: ClickHouse destination tables for Materialize pre-aggregated sinks.
--
-- These tables receive continuously maintained aggregates from Materialize IVM,
-- not batch-scheduled refreshes. Materialize updates them incrementally as
-- writes arrive in Postgres — the window is always current, not stale by N s.
--
-- This demonstrates the incremental ClickHouse native table pattern:
-- Materialize computes the aggregation once at write time and delivers a
-- tiny pre-aggregated result set to ClickHouse. The CH query becomes a
-- trivial small-table scan rather than a full GROUP BY over millions of rows.
--
-- Pipelines follow the same two-object pattern as 01_kafka_consumers.sql:
--   kafka_*_raw   (Kafka engine)  — reads from Redpanda topic
--   *_consumer    (MV → table)    — routes into destination ReplacingMergeTree
-- =============================================================================

-- =============================================================================
-- PIPELINE 1: sales-by-dim
-- Source topic  : sales-by-dim  (key = (category, customer_tier, day_of_week))
-- Destination   : retail.mz_sales_by_dim
-- Rows          : ~203 (one per unique category × customer_tier × day_of_week)
-- =============================================================================

CREATE TABLE IF NOT EXISTS retail.mz_sales_by_dim
(
    category        String,
    customer_tier   String,
    day_of_week     Int32,
    revenue         Float64,
    line_item_count Int32
)
ENGINE = ReplacingMergeTree()
ORDER BY (category, customer_tier, day_of_week)
SETTINGS index_granularity = 8192;

CREATE TABLE IF NOT EXISTS retail.kafka_mz_sales_by_dim_raw
(
    category        String,
    customer_tier   String,
    day_of_week     Int32,
    revenue         Float64,
    line_item_count Int32
)
ENGINE = Kafka
SETTINGS
    kafka_broker_list          = 'redpanda:9092',
    kafka_topic_list           = 'sales-by-dim',
    kafka_group_name           = 'clickhouse-sales-by-dim-consumer',
    kafka_format               = 'JSONEachRow',
    kafka_skip_broken_messages = 10,
    kafka_flush_interval_ms    = 1000;

CREATE MATERIALIZED VIEW IF NOT EXISTS retail.mz_sales_by_dim_consumer
TO retail.mz_sales_by_dim
AS
SELECT
    category,
    customer_tier,
    day_of_week,
    revenue,
    line_item_count
FROM retail.kafka_mz_sales_by_dim_raw;

-- =============================================================================
-- PIPELINE 2: revenue-histogram
-- Source topic  : revenue-histogram  (key = bucket)
-- Destination   : retail.mz_revenue_histogram
-- Rows          : ~20-50 (one per $50 bucket in the trailing 90-day window)
-- Note          : Materialize maintains this as a sliding-window view using
--                 mz_now(). The window is always current — no stale data.
-- =============================================================================

CREATE TABLE IF NOT EXISTS retail.mz_revenue_histogram
(
    bucket        Float64,
    order_count   Int32,
    total_revenue Float64
)
ENGINE = ReplacingMergeTree()
ORDER BY bucket
SETTINGS index_granularity = 8192;

CREATE TABLE IF NOT EXISTS retail.kafka_mz_revenue_histogram_raw
(
    bucket        Float64,
    order_count   Int32,
    total_revenue Float64
)
ENGINE = Kafka
SETTINGS
    kafka_broker_list          = 'redpanda:9092',
    kafka_topic_list           = 'revenue-histogram',
    kafka_group_name           = 'clickhouse-revenue-histogram-consumer',
    kafka_format               = 'JSONEachRow',
    kafka_skip_broken_messages = 10,
    kafka_flush_interval_ms    = 1000;

CREATE MATERIALIZED VIEW IF NOT EXISTS retail.mz_revenue_histogram_consumer
TO retail.mz_revenue_histogram
AS
SELECT bucket, order_count, total_revenue
FROM retail.kafka_mz_revenue_histogram_raw;
