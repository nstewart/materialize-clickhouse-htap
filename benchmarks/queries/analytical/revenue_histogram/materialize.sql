-- Runs against the order_detail MV; no index exists for this aggregation shape,
-- so Materialize must do a full scan — this is the intentionally unoptimized case.
SELECT
    FLOOR(subtotal / 50) * 50  AS bucket,
    COUNT(*)                   AS order_count,
    SUM(subtotal)              AS total_revenue
FROM (
    SELECT order_id, SUM(subtotal) AS subtotal
    FROM order_detail
    WHERE order_created_at > NOW() - INTERVAL '90 days'
    GROUP BY order_id
) sub
GROUP BY FLOOR(subtotal / 50) * 50
ORDER BY bucket;
