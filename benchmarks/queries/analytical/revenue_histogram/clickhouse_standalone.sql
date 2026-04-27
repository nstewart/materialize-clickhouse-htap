-- Revenue histogram against raw normalized ClickHouse tables.
-- Must JOIN orders + order_items at query time; the pre-joined orders_enriched
-- table used by ClickHouse (via Materialize) eliminates this JOIN cost.
SELECT
    floor(order_total / 50) * 50 AS bucket,
    count()                      AS order_count,
    sum(order_total)             AS total_revenue
FROM (
    SELECT
        o.id                             AS order_id,
        sum(oi.quantity * oi.unit_price) AS order_total
    FROM (SELECT * FROM retail.raw_orders FINAL) o
    JOIN (SELECT * FROM retail.raw_order_items FINAL) oi ON oi.order_id = o.id
    WHERE o.created_at >= now() - INTERVAL 90 DAY
    GROUP BY o.id
)
GROUP BY bucket
ORDER BY bucket
