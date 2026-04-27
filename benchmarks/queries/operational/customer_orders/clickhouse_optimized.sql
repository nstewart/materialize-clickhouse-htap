-- Customer orders using ClickHouse-native optimizations:
--   opt_orders      ORDER BY (customer_id, id) → WHERE customer_id=? is a range
--                   scan over a sorted run, not a full-table scan
--   opt_order_items order_lookup projection ORDER BY (order_id, id) →
--                   the IN (order_ids) filter uses the projection rather than
--                   scanning 2.8M rows in primary ORDER BY (product_id, order_id, id)
--   customer_rank   pre-computed RANK() refreshed every 1 second by a refreshable
--                   MV — no runtime RANK() over 100K customers needed
-- The spend_rank is at most 1 second stale (vs. Materialize's IVM which updates
-- immediately on every write).
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
    toFloat64(oi.quantity) * oi.unit_price AS subtotal,
    p.sku,
    p.name                           AS product_name,
    p.category,
    p.price                          AS current_price,
    c.email                          AS customer_email,
    c.tier                           AS customer_tier,
    r.spend_rank
FROM (SELECT * FROM retail.opt_orders FINAL WHERE customer_id = {customer_id:Int64}) o
JOIN (
    SELECT * FROM retail.opt_order_items FINAL
    WHERE order_id IN (
        SELECT id FROM retail.opt_orders FINAL WHERE customer_id = {customer_id:Int64}
    )
) oi ON oi.order_id = o.id
JOIN (SELECT * FROM retail.opt_products FINAL) p     ON p.id = oi.product_id
JOIN (SELECT * FROM retail.opt_customers FINAL WHERE id = {customer_id:Int64}) c ON c.id = o.customer_id
LEFT JOIN retail.customer_rank r                     ON r.customer_id = o.customer_id
ORDER BY o.created_at DESC
