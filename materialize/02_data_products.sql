-- =============================================================================
-- Layer 2: Core Business Entities (Real-Time Data Products)
-- These are the ingredients — not answers to specific questions,
-- but fresh, composable business objects any consumer can assemble quickly.
-- All run on transform_sink_cluster.
-- NOTE: All NUMERIC columns cast to float8 for ClickHouse compatibility.
--
-- Equivalent Postgres queries require:
--   customer_profile      → multi-table GROUP BY + CASE tier logic
--   order_detail          → 4-way join with cost/margin arithmetic
--   inventory_position    → subquery aggregate join + computed day ratios
--   product_performance   → CTEs + window RANK() OVER (PARTITION BY ...)
-- Materialize serves all of these from pre-indexed arrangements.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Data Product: customer_profile
-- Canonical customer entity with lifetime metrics, tier classification,
-- and purchase diversity. Requires a 3-table join + GROUP BY in Postgres.
-- -----------------------------------------------------------------------------
CREATE MATERIALIZED VIEW customer_profile
IN CLUSTER transform_sink_cluster
AS
WITH base AS (
    SELECT
        c.id                                                          AS customer_id,
        c.email,
        c.name,
        c.tier,
        c.created_at,
        COUNT(DISTINCT o.id)                                          AS lifetime_order_count,
        COALESCE(SUM(oi.quantity * oi.unit_price)::float8, 0.0)       AS lifetime_spend,
        COUNT(DISTINCT p.category)::int                               AS distinct_categories_purchased,
        MAX(o.created_at)                                             AS last_order_date
    FROM customers c
    LEFT JOIN orders o       ON o.customer_id = c.id
    LEFT JOIN order_items oi ON oi.order_id = o.id
    LEFT JOIN products p     ON p.id = oi.product_id
    GROUP BY c.id, c.email, c.name, c.tier, c.created_at
)
SELECT
    customer_id, email, name, tier, created_at,
    lifetime_order_count,
    lifetime_spend,
    CASE
        WHEN lifetime_spend >= 5000 THEN 'platinum'
        WHEN lifetime_spend >= 1000 THEN 'gold'
        WHEN lifetime_spend >= 200  THEN 'silver'
        ELSE 'bronze'
    END                                                               AS computed_tier,
    (lifetime_spend / NULLIF(lifetime_order_count, 0))::float8        AS avg_order_value,
    distinct_categories_purchased,
    last_order_date,
    -- Pre-computed cross-customer rank. Postgres must aggregate all order_items
    -- for all customers to derive this; Materialize maintains it incrementally.
    RANK() OVER (ORDER BY lifetime_spend DESC)::int                   AS spend_rank
FROM base;

-- -----------------------------------------------------------------------------
-- Data Product: product_catalog
-- Canonical product entity with pricing and margin.
-- Simple projection — no aggregation required.
-- -----------------------------------------------------------------------------
CREATE MATERIALIZED VIEW product_catalog
IN CLUSTER transform_sink_cluster
AS
SELECT
    p.id                          AS product_id,
    p.sku,
    p.name,
    p.category,
    p.price::float8               AS price,
    p.cost::float8                AS cost,
    (p.price - p.cost)::float8    AS margin,
    p.created_at
FROM products p;

-- -----------------------------------------------------------------------------
-- Data Product: order_detail
-- Fully joined order entity: line items + products + customer.
-- Adds per-line cost, margin, and margin_pct columns.
-- In Postgres: 4-way join re-evaluated on every query; no pre-computation.
-- -----------------------------------------------------------------------------
CREATE MATERIALIZED VIEW order_detail
IN CLUSTER transform_sink_cluster
AS
SELECT
    oi.id                                                                    AS line_item_id,
    o.id                                                                     AS order_id,
    o.customer_id,
    o.status,
    o.created_at                                                             AS order_created_at,
    o.updated_at                                                             AS order_updated_at,
    oi.product_id,
    oi.quantity,
    oi.unit_price::float8                                                    AS unit_price,
    (oi.quantity * oi.unit_price)::float8                                    AS subtotal,
    p.sku,
    p.name                                                                   AS product_name,
    p.category,
    p.price::float8                                                          AS current_price,
    c.email                                                                  AS customer_email,
    c.tier                                                                   AS customer_tier,
    -- Cost and margin fields — expensive to compute per-query in Postgres.
    p.cost::float8                                                           AS unit_cost,
    ((oi.unit_price - p.cost) * oi.quantity)::float8                        AS line_margin,
    CASE
        WHEN oi.unit_price > 0
        THEN ((oi.unit_price - p.cost) / oi.unit_price)::float8
        ELSE 0.0::float8
    END                                                                      AS margin_pct
FROM orders o
JOIN order_items oi ON oi.order_id = o.id
JOIN products p     ON p.id = oi.product_id
JOIN customers c    ON c.id = o.customer_id;

-- -----------------------------------------------------------------------------
-- Data Product: inventory_position
-- Current stock per product per warehouse with lifetime demand metrics.
-- In Postgres: the total_units_sold field requires a full order_items aggregation
-- subquery or CTE — expensive even for a single-SKU lookup.
-- Note: time-relative metrics (avg daily demand) are omitted because Materialize
-- prohibits NOW() in materialized view definitions. total_units_sold is the
-- expensive-to-compute field; per-day rates belong in analytical queries.
-- -----------------------------------------------------------------------------
CREATE MATERIALIZED VIEW inventory_position
IN CLUSTER transform_sink_cluster
AS
SELECT
    i.product_id,
    i.warehouse_id,
    i.quantity,
    i.updated_at,
    p.sku,
    p.name                                                                      AS product_name,
    p.category,
    p.price::float8                                                             AS price,
    p.cost::float8                                                              AS cost,
    -- Demand sub-aggregate: total lifetime units sold for this product.
    -- Requires aggregating the entire order_items table in Postgres.
    COALESCE(demand.total_units_sold, 0.0)::float8                              AS total_units_sold,
    -- Stock-to-sales ratio: how many times current stock covers historical demand.
    CASE
        WHEN COALESCE(demand.total_units_sold, 0) > 0
        THEN i.quantity::float8 / demand.total_units_sold::float8
        ELSE NULL
    END                                                                         AS stock_to_sales_ratio
FROM inventory i
JOIN products p ON p.id = i.product_id
LEFT JOIN (
    SELECT product_id, SUM(quantity)::float8 AS total_units_sold
    FROM order_items
    GROUP BY product_id
) demand ON demand.product_id = i.product_id;

-- -----------------------------------------------------------------------------
-- Data Product: order_summary
-- Order-level aggregate derived from order_detail.
-- One row per order vs. one row per line item in order_detail (2.8M rows).
-- Powers order-level analytical queries (cohort retention, revenue histogram)
-- via the orders-summary Kafka sink → ClickHouse, where scanning 1M order rows
-- beats scanning 2.8M line-item rows even for pre-joined data.
-- -----------------------------------------------------------------------------
CREATE MATERIALIZED VIEW order_summary
IN CLUSTER transform_sink_cluster
AS
SELECT
    order_id,
    customer_id,
    status,
    order_created_at,
    MAX(order_updated_at)              AS order_updated_at,
    customer_tier,
    SUM(subtotal)::float8              AS order_total,
    SUM(quantity)::int                 AS total_items,
    COUNT(*)::int                      AS line_item_count
FROM order_detail
GROUP BY order_id, customer_id, status, order_created_at, customer_tier;

-- -----------------------------------------------------------------------------
-- Data Product: product_performance
-- Per-product sales velocity, revenue, and buyer loyalty metrics.
-- In Postgres: requires two CTEs + RANK() window function evaluated at
-- query time across the full products + orders + order_items join space.
-- Materialize pre-computes and indexes the RANK() result.
-- -----------------------------------------------------------------------------
CREATE MATERIALIZED VIEW product_performance
IN CLUSTER transform_sink_cluster
AS
WITH demand AS (
    -- Total units, revenue, and unique buyers per product.
    SELECT
        oi.product_id,
        SUM(oi.quantity)::float8                 AS total_units_sold,
        SUM(oi.quantity * oi.unit_price)::float8 AS total_revenue,
        COUNT(DISTINCT o.customer_id)            AS buyer_count
    FROM order_items oi
    JOIN orders o ON o.id = oi.order_id
    GROUP BY oi.product_id
),
repeat_buyers AS (
    -- Customers who placed 2+ distinct orders containing this product.
    SELECT product_id, COUNT(*)::int AS repeat_buyer_count
    FROM (
        SELECT oi.product_id, o.customer_id
        FROM order_items oi
        JOIN orders o ON o.id = oi.order_id
        GROUP BY oi.product_id, o.customer_id
        HAVING COUNT(DISTINCT o.id) >= 2
    ) rb
    GROUP BY product_id
)
SELECT
    p.id                                                                          AS product_id,
    p.sku,
    p.name,
    p.category,
    p.price::float8                                                               AS price,
    p.cost::float8                                                                AS cost,
    COALESCE(d.total_units_sold, 0.0)                                             AS total_units_sold,
    COALESCE(d.total_revenue, 0.0)                                                AS total_revenue,
    COALESCE(d.buyer_count, 0)::int                                               AS buyer_count,
    COALESCE(r.repeat_buyer_count, 0)                                             AS repeat_buyer_count,
    CASE
        WHEN COALESCE(d.buyer_count, 0) > 0
        THEN COALESCE(r.repeat_buyer_count, 0)::float8 / d.buyer_count::float8
        ELSE 0.0
    END                                                                           AS repeat_buyer_rate,
    -- RANK() within category by units sold — Postgres must re-sort on every query.
    RANK() OVER (
        PARTITION BY p.category
        ORDER BY COALESCE(d.total_units_sold, 0) DESC
    )::int                                                                        AS category_sales_rank
FROM products p
LEFT JOIN demand d        ON d.product_id = p.id
LEFT JOIN repeat_buyers r ON r.product_id = p.id;
