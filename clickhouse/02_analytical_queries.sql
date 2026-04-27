-- =============================================================================
-- FILE: 02_analytical_queries.sql
-- PURPOSE: Reference analytical queries demonstrating ClickHouse's columnar
--          strengths — vectorised aggregations, multi-dimensional grouping,
--          and window-function cohort analysis over large fact tables.
--
-- All queries use FINAL to force eager deduplication on the underlying
-- ReplacingMergeTree tables, guaranteeing correct results regardless of
-- whether background merges have completed.
--
-- Query index:
--   Q1  Revenue histogram          — $50-bucket distribution over last 90 days
--   Q2  Cross-dimensional revenue  — category × customer_tier × day-of-week
--   Q3  Cohort retention           — 30 / 60 / 90-day returning customers
--   Q4  Top 10 customers           — by lifetime spend
--   Q5  Category revenue (30 days) — simple dashboard query
--   Q6  Inventory health           — products below 10 units per warehouse
-- =============================================================================


-- =============================================================================
-- Q1: Revenue Histogram
-- Buckets order-level subtotals into $50 increments to show spend distribution
-- over the last 90 days. Useful for pricing and promotion analysis.
--
-- Method:
--   Aggregate to order_id first (sum line items), then bucket the order total
--   into $50 bands with floor(total / 50) * 50. ClickHouse evaluates the
--   inner aggregation in a single columnar pass before the outer bucketing.
-- =============================================================================
SELECT
    floor(order_total / 50) * 50                    AS bucket_start,
    floor(order_total / 50) * 50 + 49.99            AS bucket_end,
    count()                                          AS order_count,
    round(sum(order_total), 2)                       AS bucket_revenue
FROM (
    -- Collapse line items to order-level totals
    SELECT
        order_id,
        sum(subtotal) AS order_total
    FROM retail.orders_enriched FINAL
    WHERE order_created_at >= now() - INTERVAL 90 DAY
    GROUP BY order_id
) AS order_totals
GROUP BY bucket_start, bucket_end
ORDER BY bucket_start;


-- =============================================================================
-- Q2: Cross-Dimensional Revenue Breakdown
-- Revenue sliced by three dimensions simultaneously: product category,
-- customer tier (e.g. Bronze/Silver/Gold), and day of week.
--
-- Produces a cube suitable for pivot tables or heatmaps. ClickHouse handles
-- high-cardinality GROUP BY efficiently via hash aggregation in columnar mode.
-- =============================================================================
SELECT
    category,
    customer_tier,
    toDayOfWeek(order_created_at)                   AS day_of_week,    -- 1 = Monday … 7 = Sunday
    formatDateTime(order_created_at, '%A')           AS day_name,
    count(DISTINCT order_id)                         AS order_count,
    sum(quantity)                                    AS units_sold,
    round(sum(subtotal), 2)                          AS revenue,
    round(avg(subtotal), 2)                          AS avg_line_item_value
FROM retail.orders_enriched FINAL
WHERE order_created_at >= now() - INTERVAL 90 DAY
GROUP BY
    category,
    customer_tier,
    day_of_week,
    day_name
ORDER BY
    category,
    customer_tier,
    day_of_week;


-- =============================================================================
-- Q3: Cohort Retention Analysis
-- For each cohort (defined by the month a customer placed their first order),
-- counts how many customers placed at least one additional order at 30, 60,
-- and 90-day marks after their cohort month's start.
--
-- Method:
--   1. Derive each customer's first-order month (cohort_month).
--   2. For every subsequent order, compute days since cohort start.
--   3. Use conditional aggregation to bucket into 30/60/90-day windows.
--
-- Note: retention windows are cumulative — a customer active at day 90 is
-- also counted in the 30- and 60-day windows. Adjust the BETWEEN clauses
-- for exclusive windows if preferred.
-- =============================================================================
WITH cohorts AS (
    -- Step 1: Identify each customer's cohort month (month of first order)
    SELECT
        customer_id,
        toStartOfMonth(min(order_created_at))   AS cohort_month
    FROM retail.orders_enriched FINAL
    GROUP BY customer_id
),
customer_orders AS (
    -- Step 2: Join all orders to their cohort, compute days-since-cohort
    SELECT
        o.customer_id,
        c.cohort_month,
        dateDiff('day', c.cohort_month, o.order_created_at) AS days_since_cohort
    FROM retail.orders_enriched FINAL AS o
    INNER JOIN cohorts AS c USING (customer_id)
    -- Exclude orders that define the cohort itself (day 0 = cohort month)
    WHERE o.order_created_at >= c.cohort_month + INTERVAL 1 DAY
)
-- Step 3: Aggregate retention counts per cohort month
SELECT
    cohort_month,
    count(DISTINCT customer_id)                                                 AS cohort_size,
    count(DISTINCT IF(days_since_cohort BETWEEN 1  AND 30,  customer_id, NULL)) AS retained_30d,
    count(DISTINCT IF(days_since_cohort BETWEEN 1  AND 60,  customer_id, NULL)) AS retained_60d,
    count(DISTINCT IF(days_since_cohort BETWEEN 1  AND 90,  customer_id, NULL)) AS retained_90d,
    round(count(DISTINCT IF(days_since_cohort BETWEEN 1 AND 30, customer_id, NULL))
          / count(DISTINCT customer_id) * 100, 1)                               AS retention_rate_30d_pct,
    round(count(DISTINCT IF(days_since_cohort BETWEEN 1 AND 60, customer_id, NULL))
          / count(DISTINCT customer_id) * 100, 1)                               AS retention_rate_60d_pct,
    round(count(DISTINCT IF(days_since_cohort BETWEEN 1 AND 90, customer_id, NULL))
          / count(DISTINCT customer_id) * 100, 1)                               AS retention_rate_90d_pct
FROM customer_orders
GROUP BY cohort_month
ORDER BY cohort_month;


-- =============================================================================
-- Q4: Top 10 Customers by Lifetime Spend
-- Ranks customers by total revenue across all time. Useful for VIP programs,
-- account management prioritisation, and fraud monitoring.
--
-- LIMIT 10 is pushed down by ClickHouse's query planner — it reads only the
-- top-N rows from each aggregation shard rather than materialising the full
-- sorted result set.
-- =============================================================================
SELECT
    customer_id,
    any(customer_email)                             AS customer_email,   -- email is stable per customer
    any(customer_tier)                              AS customer_tier,    -- current tier (latest value)
    count(DISTINCT order_id)                        AS total_orders,
    sum(quantity)                                   AS total_units,
    round(sum(subtotal), 2)                         AS lifetime_spend,
    round(avg(subtotal), 2)                         AS avg_line_item_value,
    round(sum(subtotal) / count(DISTINCT order_id), 2) AS avg_order_value,
    min(order_created_at)                           AS first_order_at,
    max(order_created_at)                           AS last_order_at
FROM retail.orders_enriched FINAL
GROUP BY customer_id
ORDER BY lifetime_spend DESC
LIMIT 10;


-- =============================================================================
-- Q5: Revenue by Category — Last 30 Days (Dashboard Query)
-- Straightforward single-table aggregation; deliberately simple to serve as
-- a fast dashboard tile. ClickHouse reads only the category and subtotal
-- columns, skipping all others due to columnar storage.
-- =============================================================================
SELECT
    category,
    count(DISTINCT order_id)                        AS order_count,
    sum(quantity)                                   AS units_sold,
    round(sum(subtotal), 2)                         AS revenue,
    round(avg(unit_price), 2)                       AS avg_unit_price,
    round(sum(subtotal) / count(DISTINCT order_id), 2) AS avg_order_value
FROM retail.orders_enriched FINAL
WHERE order_created_at >= now() - INTERVAL 30 DAY
GROUP BY category
ORDER BY revenue DESC;


-- =============================================================================
-- Q6: Inventory Health — Products Below 10 Units
-- Surfaces low-stock positions with warehouse breakdown so replenishment teams
-- can act before stockouts. Uses FINAL on inventory_snapshots to ensure
-- current quantities reflect the latest Materialize UPSERT.
--
-- Products with quantity = 0 appear first within each category so that
-- complete stockouts are immediately visible.
-- =============================================================================
SELECT
    i.category,
    i.product_id,
    i.sku,
    i.product_name,
    i.warehouse_id,
    i.quantity,
    i.price,
    round(i.quantity * i.price, 2)                  AS inventory_value,
    i.updated_at,
    CASE
        WHEN i.quantity  = 0 THEN 'OUT_OF_STOCK'
        WHEN i.quantity <= 5 THEN 'CRITICAL'
        ELSE                      'LOW'
    END                                             AS stock_status
FROM retail.inventory_snapshots FINAL AS i
WHERE i.quantity < 10
ORDER BY
    i.category,
    i.quantity ASC,      -- stockouts (0) sort first within each category
    i.product_id,
    i.warehouse_id;
