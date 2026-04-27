-- =============================================================================
-- FILE: 03_optimized_tables.sql
-- PURPOSE: ClickHouse-native optimized tables for the "ClickHouse (optimized)"
--          benchmark column. Populated via Debezium → Redpanda CDC (sub-second
--          freshness), NOT via batch ETL or the Materialize pipeline.
--
-- Optimizations vs. raw_* tables:
--   opt_orders      ORDER BY (customer_id, id)   — O(log n) customer filter
--   opt_order_items ORDER BY (product_id, order_id, id) — O(log n) product filter
--   opt_products    projection by sku             — O(1) SKU lookup
--   customer_spend_agg  AggregatingMergeTree      — incremental lifetime spend
--   customer_rank       refreshable MV (1s)       — pre-computed RANK()
--   product_category_rank refreshable MV (5s)     — pre-computed product stats + rank
--
-- These are the ClickHouse-native answers to what Materialize maintains
-- incrementally: aggregation-at-insert-time and scheduled pre-computation
-- rather than continuous IVM.
-- =============================================================================

CREATE DATABASE IF NOT EXISTS retail;

-- -----------------------------------------------------------------------------
-- opt_customers
-- Direct mirror of Postgres customers. Simple ReplacingMergeTree.
-- Not a performance bottleneck — customers are a small dimension table.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS retail.opt_customers
(
    id         Int64,
    email      String,
    name       String,
    tier       String,
    created_at DateTime64(6, 'UTC')
)
ENGINE = ReplacingMergeTree()
ORDER BY id
SETTINGS index_granularity = 8192;

-- -----------------------------------------------------------------------------
-- opt_products
-- Direct mirror of Postgres products.
-- PROJECTION sku_lookup: pre-sorts data by sku so WHERE sku = ? is a range
-- scan rather than a full-table scan. Makes inventory_lookup and
-- product_performance by SKU go from O(n) to O(log n).
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS retail.opt_products
(
    id         Int64,
    sku        String,
    name       String,
    category   String,
    price      Float64,
    cost       Float64,
    created_at DateTime64(6, 'UTC')
)
ENGINE = ReplacingMergeTree()
ORDER BY id
SETTINGS index_granularity = 8192,
         deduplicate_merge_projection_mode = 'drop';

ALTER TABLE retail.opt_products MODIFY SETTING deduplicate_merge_projection_mode = 'drop';
ALTER TABLE retail.opt_products ADD PROJECTION IF NOT EXISTS sku_lookup
(SELECT * ORDER BY sku);
ALTER TABLE retail.opt_products MATERIALIZE PROJECTION sku_lookup;

-- -----------------------------------------------------------------------------
-- opt_orders
-- ORDER BY (customer_id, id): all orders for a customer are co-located on disk.
-- A WHERE customer_id = ? query becomes a range scan over a small sorted run
-- rather than a full-table scan. Critical for customer_orders query.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS retail.opt_orders
(
    id          Int64,
    customer_id Int64,
    status      String,
    created_at  DateTime64(6, 'UTC'),
    updated_at  DateTime64(6, 'UTC')
)
ENGINE = ReplacingMergeTree(updated_at)
ORDER BY (customer_id, id)
SETTINGS index_granularity = 8192;

-- -----------------------------------------------------------------------------
-- opt_order_items
-- ORDER BY (product_id, order_id, id): all items for a product are co-located.
-- Enables fast product-level aggregation (total_units_sold, total_revenue)
-- without scanning the full 2.8M row table. Critical for product_performance
-- and inventory_lookup stock_to_sales_ratio.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS retail.opt_order_items
(
    id         Int64,
    order_id   Int64,
    product_id Int64,
    quantity   Int32,
    unit_price Float64
)
ENGINE = ReplacingMergeTree()
ORDER BY (product_id, order_id, id)
SETTINGS index_granularity = 8192,
         deduplicate_merge_projection_mode = 'drop';

ALTER TABLE retail.opt_order_items MODIFY SETTING deduplicate_merge_projection_mode = 'drop';
ALTER TABLE retail.opt_order_items ADD PROJECTION IF NOT EXISTS order_lookup
(SELECT * ORDER BY (order_id, id));
ALTER TABLE retail.opt_order_items MATERIALIZE PROJECTION order_lookup;

-- -----------------------------------------------------------------------------
-- opt_inventory
-- Direct mirror of Postgres inventory.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS retail.opt_inventory
(
    product_id   Int64,
    warehouse_id String,
    quantity     Int32,
    updated_at   DateTime64(6, 'UTC')
)
ENGINE = ReplacingMergeTree(updated_at)
ORDER BY (product_id, warehouse_id)
SETTINGS index_granularity = 8192;

-- -----------------------------------------------------------------------------
-- customer_spend_agg
-- AggregatingMergeTree: maintains running lifetime_spend per customer.
-- Populated by customer_spend_agg_mv (in 04_optimized_consumers.sql) which
-- fires on every opt_order_items insert and aggregates incrementally.
-- Query with: sumMerge(lifetime_spend) — no full order_items scan needed.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS retail.customer_spend_agg
(
    customer_id    Int64,
    lifetime_spend AggregateFunction(sum, Float64)
)
ENGINE = AggregatingMergeTree()
ORDER BY customer_id
SETTINGS index_granularity = 8192;

-- -----------------------------------------------------------------------------
-- customer_rank
-- Pre-computed customer spend ranking, refreshed every 1 second.
-- ClickHouse's answer to Materialize's incrementally-maintained RANK() OVER
-- (ORDER BY lifetime_spend DESC). The tradeoff: stale by up to 1 second
-- (batch refresh) vs. immediately consistent (IVM). For most workloads the
-- 1-second staleness is acceptable; for real-time leaderboards it is not.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS retail.customer_rank
(
    customer_id  Int64,
    total_spend  Float64,
    spend_rank   UInt64
)
ENGINE = ReplacingMergeTree()
ORDER BY customer_id
SETTINGS index_granularity = 8192;

CREATE MATERIALIZED VIEW IF NOT EXISTS retail.customer_rank_refresh
REFRESH EVERY 1 SECOND
TO retail.customer_rank
AS
SELECT
    customer_id,
    total_spend,
    rank() OVER (ORDER BY total_spend DESC) AS spend_rank
FROM (
    SELECT customer_id, sumMerge(lifetime_spend) AS total_spend
    FROM retail.customer_spend_agg
    GROUP BY customer_id
);

-- -----------------------------------------------------------------------------
-- product_category_rank
-- Pre-computed product stats (total_units_sold, total_revenue, buyer_count,
-- repeat_buyer_rate) plus category-scoped rank, refreshed every 5 seconds.
-- The product_performance query becomes a single point lookup on this table
-- (via sku projection) rather than scanning 2.8M order_items + window function
-- at query time.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS retail.product_category_rank
(
    product_id         Int64,
    sku                String,
    name               String,
    category           String,
    price              Float64,
    cost               Float64,
    total_units_sold   Float64,
    total_revenue      Float64,
    buyer_count        UInt64,
    repeat_buyer_count UInt64,
    repeat_buyer_rate  Float64,
    category_sales_rank UInt64
)
ENGINE = ReplacingMergeTree()
ORDER BY product_id
SETTINGS index_granularity = 8192,
         deduplicate_merge_projection_mode = 'drop';

ALTER TABLE retail.product_category_rank MODIFY SETTING deduplicate_merge_projection_mode = 'drop';
ALTER TABLE retail.product_category_rank ADD PROJECTION IF NOT EXISTS sku_lookup
(SELECT * ORDER BY sku);
ALTER TABLE retail.product_category_rank MATERIALIZE PROJECTION sku_lookup;

CREATE MATERIALIZED VIEW IF NOT EXISTS retail.product_category_rank_refresh
REFRESH EVERY 5 SECOND
TO retail.product_category_rank
AS
WITH items AS (SELECT * FROM retail.opt_order_items FINAL),
     orders AS (SELECT * FROM retail.opt_orders FINAL),
     products AS (SELECT * FROM retail.opt_products FINAL),
demand AS (
    SELECT
        product_id,
        sum(toFloat64(quantity))                         AS total_units_sold,
        sum(toFloat64(quantity) * toFloat64(unit_price)) AS total_revenue
    FROM items
    GROUP BY product_id
),
buyers AS (
    SELECT oi.product_id, uniqExact(o.customer_id) AS buyer_count
    FROM items oi
    JOIN orders o ON o.id = oi.order_id
    GROUP BY oi.product_id
),
repeat AS (
    SELECT product_id, countIf(order_count >= 2) AS repeat_buyer_count
    FROM (
        SELECT oi.product_id, o.customer_id, uniqExact(oi.order_id) AS order_count
        FROM items oi
        JOIN orders o ON o.id = oi.order_id
        GROUP BY oi.product_id, o.customer_id
    )
    GROUP BY product_id
),
stats AS (
    SELECT
        p.id                                                          AS product_id,
        p.sku,
        p.name,
        p.category,
        p.price,
        p.cost,
        COALESCE(d.total_units_sold, 0)                              AS total_units_sold,
        COALESCE(d.total_revenue, 0)                                 AS total_revenue,
        COALESCE(b.buyer_count, 0)                                   AS buyer_count,
        COALESCE(r.repeat_buyer_count, 0)                            AS repeat_buyer_count,
        if(COALESCE(b.buyer_count, 0) > 0,
           COALESCE(r.repeat_buyer_count, 0) / COALESCE(b.buyer_count, 1),
           0)                                                         AS repeat_buyer_rate
    FROM products p
    LEFT JOIN demand d ON d.product_id = p.id
    LEFT JOIN buyers b ON b.product_id = p.id
    LEFT JOIN repeat r ON r.product_id = p.id
)
SELECT
    product_id, sku, name, category, price, cost,
    total_units_sold, total_revenue, buyer_count,
    repeat_buyer_count, repeat_buyer_rate,
    rank() OVER (PARTITION BY category ORDER BY total_units_sold DESC) AS category_sales_rank
FROM stats;

-- -----------------------------------------------------------------------------
-- opt_order_totals
-- Pre-computed order-level totals: one row per order with order_total already
-- summed from opt_order_items. Refreshed every 30 seconds.
-- Enables revenue histogram and cohort retention to scan 1M rows instead of
-- joining 2.8M opt_order_items × opt_orders at query time.
-- ORDER BY order_id keeps cohort self-join efficient.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS retail.opt_order_totals
(
    order_id         Int64,
    customer_id      Int64,
    customer_tier    String,
    order_created_at DateTime64(6, 'UTC'),
    order_total      Float64
)
ENGINE = ReplacingMergeTree()
ORDER BY order_id
SETTINGS index_granularity = 8192;

CREATE MATERIALIZED VIEW IF NOT EXISTS retail.opt_order_totals_refresh
REFRESH EVERY 30 SECOND
TO retail.opt_order_totals
AS
SELECT
    o.id                                                      AS order_id,
    o.customer_id,
    c.tier                                                    AS customer_tier,
    o.created_at                                              AS order_created_at,
    sum(toFloat64(oi.quantity) * oi.unit_price)               AS order_total
FROM (SELECT * FROM retail.opt_orders FINAL) o
JOIN (SELECT * FROM retail.opt_order_items FINAL) oi ON oi.order_id = o.id
JOIN (SELECT * FROM retail.opt_customers FINAL) c  ON c.id = o.customer_id
GROUP BY o.id, o.customer_id, c.tier, o.created_at;

-- -----------------------------------------------------------------------------
-- opt_sales_by_dim
-- Pre-aggregated revenue by (category, customer_tier, day_of_week).
-- Refreshed every 30 seconds. The cross_dimensional query becomes a single
-- scan of this tiny table (~hundreds of rows) rather than a 4-way JOIN
-- across 2.8M opt_order_items at query time.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS retail.opt_sales_by_dim
(
    category      String,
    customer_tier String,
    day_of_week   UInt8,
    revenue       Float64,
    line_item_count UInt64
)
ENGINE = ReplacingMergeTree()
ORDER BY (category, customer_tier, day_of_week)
SETTINGS index_granularity = 8192;

CREATE MATERIALIZED VIEW IF NOT EXISTS retail.opt_sales_by_dim_refresh
REFRESH EVERY 30 SECOND
TO retail.opt_sales_by_dim
AS
SELECT
    p.category,
    c.tier                                                    AS customer_tier,
    toDayOfWeek(o.created_at)                                 AS day_of_week,
    sum(toFloat64(oi.quantity) * oi.unit_price)               AS revenue,
    count()                                                   AS line_item_count
FROM (SELECT * FROM retail.opt_order_items FINAL) oi
JOIN (SELECT * FROM retail.opt_orders FINAL) o    ON o.id  = oi.order_id
JOIN (SELECT * FROM retail.opt_products FINAL) p  ON p.id  = oi.product_id
JOIN (SELECT * FROM retail.opt_customers FINAL) c ON c.id  = o.customer_id
GROUP BY p.category, c.tier, day_of_week;

-- -----------------------------------------------------------------------------
-- product_by_sku  (dictionary)
-- In-memory hash table keyed by sku string. Backed by opt_products FINAL,
-- reloaded every 5–30 seconds. Replaces the opt_products FINAL subquery JOIN
-- in inventory_lookup: dictGet() is O(1) vs O(log n) range scan + FINAL merge.
-- -----------------------------------------------------------------------------
CREATE DICTIONARY IF NOT EXISTS retail.product_by_sku
(
    sku      String,
    id       UInt64,
    name     String,
    category String,
    price    Float64,
    cost     Float64
)
PRIMARY KEY sku
SOURCE(CLICKHOUSE(QUERY 'SELECT sku, toUInt64(id) AS id, name, category, price, cost FROM retail.opt_products FINAL'))
LAYOUT(HASHED())
LIFETIME(MIN 5 MAX 30);

-- -----------------------------------------------------------------------------
-- product_stats_by_id  (dictionary)
-- In-memory hash table keyed by product_id UInt64. Backed by
-- product_category_rank FINAL (itself refreshed every 5 s). Replaces the
-- product_category_rank FINAL LEFT JOIN in inventory_lookup with a single
-- O(1) dictGetOrDefault() call — no subquery, no FINAL scan.
-- -----------------------------------------------------------------------------
CREATE DICTIONARY IF NOT EXISTS retail.product_stats_by_id
(
    product_id       UInt64,
    total_units_sold Float64
)
PRIMARY KEY product_id
SOURCE(CLICKHOUSE(QUERY 'SELECT toUInt64(product_id) AS product_id, toFloat64(total_units_sold) AS total_units_sold FROM retail.product_category_rank FINAL'))
LAYOUT(HASHED())
LIFETIME(MIN 5 MAX 30);
