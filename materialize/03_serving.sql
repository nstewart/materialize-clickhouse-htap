-- =============================================================================
-- Layer 3: Serving Products
-- Thin last-mile views indexed for specific access patterns.
-- Operational path: served directly by Materialize to applications.
-- Analytical path: sinked to ClickHouse via Redpanda.
-- All objects run on transform_sink_cluster.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Serving Product: customer_order_activity
-- Powers: "show me this customer's current orders with their full profile context"
-- Joins order_detail with customer_profile to surface computed tier,
-- avg order value, category breadth, and recency — fields that require
-- multi-table aggregation in Postgres but are pre-indexed here.
-- Indexed on customer_id for sub-10ms lookups.
-- -----------------------------------------------------------------------------
CREATE VIEW customer_order_activity AS
SELECT
    od.*,
    cp.computed_tier,
    cp.avg_order_value,
    cp.distinct_categories_purchased,
    cp.last_order_date,
    cp.spend_rank
FROM order_detail od
JOIN customer_profile cp ON cp.customer_id = od.customer_id;

CREATE INDEX customer_order_activity_customer_idx
IN CLUSTER transform_sink_cluster
ON customer_order_activity (customer_id);

CREATE INDEX customer_profile_customer_idx
IN CLUSTER transform_sink_cluster
ON customer_profile (customer_id);

-- -----------------------------------------------------------------------------
-- Serving Product: inventory_position by SKU
-- Powers: "how much of this product do we have, and where?"
-- Indexed on sku for sub-10ms lookups.
-- -----------------------------------------------------------------------------
CREATE INDEX inventory_position_sku_idx
IN CLUSTER transform_sink_cluster
ON inventory_position (sku);

-- -----------------------------------------------------------------------------
-- Serving Product: product_performance by SKU
-- Powers: "what is the sales rank and buyer loyalty for this product?"
-- RANK() result is pre-computed in the MV; this index makes SKU lookups instant.
-- -----------------------------------------------------------------------------
CREATE INDEX product_performance_sku_idx
IN CLUSTER transform_sink_cluster
ON product_performance (sku);

-- -----------------------------------------------------------------------------
-- Analytical Sink: order_detail → Redpanda → ClickHouse
-- Upsert envelope: key = line_item_id (unique per line item)
-- -----------------------------------------------------------------------------
-- NOT ENFORCED: line_item_id is unique (it's the order_items PK),
-- but Materialize cannot prove uniqueness through a JOIN chain.
CREATE SINK orders_enriched_sink
IN CLUSTER transform_sink_cluster
FROM order_detail
INTO KAFKA CONNECTION redpanda_conn (TOPIC 'orders-enriched')
KEY (line_item_id) NOT ENFORCED
FORMAT JSON
ENVELOPE UPSERT;

-- -----------------------------------------------------------------------------
-- Analytical Sink: order_summary → Redpanda → ClickHouse
-- Order-level aggregate (1M rows) vs. line-item-level orders_enriched (2.8M).
-- Designed for order-level query families: cohort retention, revenue histogram.
-- Upsert envelope: key = order_id (unique per order)
-- -----------------------------------------------------------------------------
CREATE SINK orders_summary_sink
IN CLUSTER transform_sink_cluster
FROM order_summary
INTO KAFKA CONNECTION redpanda_conn (TOPIC 'orders-summary')
KEY (order_id) NOT ENFORCED
FORMAT JSON
ENVELOPE UPSERT;

-- -----------------------------------------------------------------------------
-- Analytical Sink: inventory_position → Redpanda → ClickHouse
-- Upsert envelope: key = (product_id, warehouse_id)
-- -----------------------------------------------------------------------------
-- NOT ENFORCED: (product_id, warehouse_id) is the inventory PK,
-- but uniqueness cannot be proven through the JOIN with products.
CREATE SINK inventory_snapshots_sink
IN CLUSTER transform_sink_cluster
FROM inventory_position
INTO KAFKA CONNECTION redpanda_conn (TOPIC 'inventory-snapshots')
KEY (product_id, warehouse_id) NOT ENFORCED
FORMAT JSON
ENVELOPE UPSERT;

-- -----------------------------------------------------------------------------
-- Pre-aggregated Sink: sales_by_dim → Redpanda → ClickHouse
-- ~203 rows: one per (category, customer_tier, day_of_week) combination.
-- Maintained incrementally by Materialize IVM — no batch refresh needed.
-- Enables the cross-dimensional analytical query to scan ~203 rows in
-- ClickHouse instead of aggregating 2.8M order_detail rows at query time.
-- -----------------------------------------------------------------------------
CREATE MATERIALIZED VIEW sales_by_dim
IN CLUSTER transform_sink_cluster
AS
SELECT
    category,
    customer_tier,
    extract(dow FROM order_created_at)::int  AS day_of_week,
    SUM(subtotal)::float8                    AS revenue,
    COUNT(*)::int                            AS line_item_count
FROM order_detail
GROUP BY category, customer_tier, extract(dow FROM order_created_at);

CREATE SINK sales_by_dim_sink
IN CLUSTER transform_sink_cluster
FROM sales_by_dim
INTO KAFKA CONNECTION redpanda_conn (TOPIC 'sales-by-dim')
KEY (category, customer_tier, day_of_week) NOT ENFORCED
FORMAT JSON
ENVELOPE UPSERT;

-- -----------------------------------------------------------------------------
-- Pre-aggregated Sink: revenue_histogram → Redpanda → ClickHouse
-- ~20-50 rows: one per $50 revenue bucket within the trailing 90-day window.
-- Materialize maintains this as a sliding-window view using mz_now(): as
-- orders age out of the window, their buckets are decremented automatically.
-- ClickHouse receives a ~50-row table ready for instant retrieval — no
-- 1M-row scan or 90-day filter applied at query time.
-- -----------------------------------------------------------------------------
CREATE MATERIALIZED VIEW revenue_histogram
IN CLUSTER transform_sink_cluster
AS
SELECT
    (floor(order_total / 50.0) * 50.0)::float8  AS bucket,
    COUNT(*)::int                                AS order_count,
    SUM(order_total)::float8                     AS total_revenue
FROM order_summary
WHERE order_created_at + INTERVAL '90 days' >= mz_now()
GROUP BY floor(order_total / 50.0) * 50.0;

CREATE SINK revenue_histogram_sink
IN CLUSTER transform_sink_cluster
FROM revenue_histogram
INTO KAFKA CONNECTION redpanda_conn (TOPIC 'revenue-histogram')
KEY (bucket) NOT ENFORCED
FORMAT JSON
ENVELOPE UPSERT;
