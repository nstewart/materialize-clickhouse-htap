SELECT
    p.category,
    c.tier                                              AS customer_tier,
    EXTRACT(ISODOW FROM o.created_at)::int              AS day_of_week,
    SUM(oi.quantity * oi.unit_price)                    AS revenue,
    COUNT(oi.id)                                        AS line_item_count
FROM orders      o
JOIN customers   c  ON c.id         = o.customer_id
JOIN order_items oi ON oi.order_id  = o.id
JOIN products    p  ON p.id         = oi.product_id
GROUP BY p.category, c.tier, EXTRACT(ISODOW FROM o.created_at)::int
ORDER BY revenue DESC;
