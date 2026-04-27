-- To rank this customer among all 100K customers, Postgres must first aggregate
-- all 2.8M order_items across every customer, then run RANK() over the result.
-- This full-table scan is structurally unavoidable regardless of per-customer fanout.
WITH all_customer_spend AS (
    SELECT o.customer_id,
           COALESCE(SUM(oi.quantity * oi.unit_price), 0)::float  AS lifetime_spend
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.id
    GROUP BY o.customer_id
),
ranked AS (
    SELECT customer_id,
           RANK() OVER (ORDER BY lifetime_spend DESC)::int AS spend_rank
    FROM all_customer_spend
),
customer_metrics AS (
    SELECT
        o.customer_id,
        COUNT(DISTINCT o.id)                                AS lifetime_order_count,
        COALESCE(SUM(oi.quantity * oi.unit_price), 0)       AS lifetime_spend,
        COUNT(DISTINCT p.category)                          AS distinct_categories_purchased,
        MAX(o.created_at)                                   AS last_order_date
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.id
    JOIN products p     ON p.id = oi.product_id
    WHERE o.customer_id = %(customer_id)s
    GROUP BY o.customer_id
)
SELECT
    oi.id                                                   AS line_item_id,
    o.id                                                    AS order_id,
    o.customer_id,
    o.status,
    o.created_at                                            AS order_created_at,
    o.updated_at                                            AS order_updated_at,
    oi.product_id,
    oi.quantity,
    oi.unit_price,
    (oi.quantity * oi.unit_price)                           AS subtotal,
    ((oi.unit_price - p.cost) * oi.quantity)                AS line_margin,
    p.sku,
    p.name                                                  AS product_name,
    p.category,
    p.price                                                 AS current_price,
    c.email                                                 AS customer_email,
    c.tier                                                  AS customer_tier,
    CASE
        WHEN cm.lifetime_spend >= 5000 THEN 'platinum'
        WHEN cm.lifetime_spend >= 1000 THEN 'gold'
        WHEN cm.lifetime_spend >= 200  THEN 'silver'
        ELSE 'bronze'
    END                                                     AS computed_tier,
    (cm.lifetime_spend / NULLIF(cm.lifetime_order_count, 0))::float AS avg_order_value,
    cm.distinct_categories_purchased,
    cm.last_order_date,
    r.spend_rank
FROM orders o
JOIN order_items oi   ON oi.order_id   = o.id
JOIN products p       ON p.id          = oi.product_id
JOIN customers c      ON c.id          = o.customer_id
JOIN customer_metrics cm ON cm.customer_id = o.customer_id
JOIN ranked r         ON r.customer_id = o.customer_id
WHERE o.customer_id = %(customer_id)s
ORDER BY o.created_at DESC