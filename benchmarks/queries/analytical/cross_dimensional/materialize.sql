-- Runs against the order_detail MV; no index exists for this aggregation shape,
-- so Materialize must do a full scan — this is the intentionally unoptimized case.
SELECT
    category,
    customer_tier,
    EXTRACT(ISODOW FROM order_created_at)::int  AS day_of_week,
    SUM(subtotal)                               AS revenue,
    COUNT(*)                                    AS line_item_count
FROM order_detail
GROUP BY category, customer_tier, EXTRACT(ISODOW FROM order_created_at)::int
ORDER BY revenue DESC;
