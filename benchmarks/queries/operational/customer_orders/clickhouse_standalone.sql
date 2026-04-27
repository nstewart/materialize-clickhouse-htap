-- Customer orders with spend rank against raw normalized ClickHouse tables.
-- The inner subquery must aggregate all 2.8M order_items across all customers
-- just to rank one customer — the same rank Materialize maintains incrementally.
SELECT
    oi.id                            AS line_item_id,
    o.id                             AS order_id,
    o.customer_id,
    o.status,
    o.created_at                     AS order_created_at,
    o.updated_at                     AS order_updated_at,
    oi.product_id,
    oi.quantity,
    oi.unit_price,
    oi.quantity * oi.unit_price      AS subtotal,
    p.sku,
    p.name                           AS product_name,
    p.category,
    p.price                          AS current_price,
    c.email                          AS customer_email,
    c.tier                           AS customer_tier,
    r.spend_rank
FROM (SELECT * FROM retail.raw_orders FINAL) o
JOIN (SELECT * FROM retail.raw_order_items FINAL) oi ON oi.order_id = o.id
JOIN (SELECT * FROM retail.raw_products FINAL) p ON p.id = oi.product_id
JOIN (SELECT * FROM retail.raw_customers FINAL) c ON c.id = o.customer_id
JOIN (
    SELECT
        customer_id,
        rank() OVER (ORDER BY lifetime_spend DESC) AS spend_rank
    FROM (
        SELECT
            o2.customer_id,
            sum(oi2.quantity * oi2.unit_price) AS lifetime_spend
        FROM (SELECT * FROM retail.raw_orders FINAL) o2
        JOIN (SELECT * FROM retail.raw_order_items FINAL) oi2 ON oi2.order_id = o2.id
        GROUP BY o2.customer_id
    )
) r ON r.customer_id = o.customer_id
WHERE o.customer_id = {customer_id:Int64}
ORDER BY o.created_at DESC
