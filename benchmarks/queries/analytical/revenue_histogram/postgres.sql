SELECT
    FLOOR(order_total / 50) * 50  AS bucket,
    COUNT(*)                      AS order_count,
    SUM(order_total)              AS total_revenue
FROM (
    SELECT o.id, SUM(oi.quantity * oi.unit_price) AS order_total
    FROM orders o
    JOIN order_items oi ON oi.order_id = o.id
    WHERE o.created_at >= NOW() - INTERVAL '90 days'
    GROUP BY o.id
) sub
GROUP BY FLOOR(order_total / 50) * 50
ORDER BY bucket;
