-- Revenue by category × customer tier × day-of-week against raw normalized tables.
-- Requires a 4-way JOIN across all tables; ClickHouse (via Materialize) reads
-- a single pre-joined flat table with no JOIN overhead.
SELECT
    p.category,
    c.tier                           AS customer_tier,
    toDayOfWeek(o.created_at)        AS day_of_week,
    sum(oi.quantity * oi.unit_price) AS revenue,
    count()                          AS line_item_count
FROM (SELECT * FROM retail.raw_orders FINAL) o
JOIN (SELECT * FROM retail.raw_customers FINAL) c  ON c.id  = o.customer_id
JOIN (SELECT * FROM retail.raw_order_items FINAL) oi ON oi.order_id = o.id
JOIN (SELECT * FROM retail.raw_products FINAL) p   ON p.id  = oi.product_id
GROUP BY p.category, c.tier, day_of_week
ORDER BY revenue DESC
