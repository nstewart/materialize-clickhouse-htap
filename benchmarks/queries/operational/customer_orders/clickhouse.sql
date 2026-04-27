-- ClickHouse must also aggregate all orders_enriched to rank customers —
-- spend_rank is not pre-stored in the table.
SELECT
    oe.line_item_id, oe.order_id, oe.customer_id, oe.status,
    oe.order_created_at, oe.order_updated_at,
    oe.product_id, oe.quantity, oe.unit_price, oe.subtotal, oe.line_margin,
    oe.sku, oe.product_name, oe.category, oe.current_price,
    oe.customer_email, oe.customer_tier,
    r.spend_rank
FROM (
    SELECT * FROM retail.orders_enriched FINAL
    WHERE customer_id = {customer_id:Int64}
) AS oe
JOIN (
    SELECT
        customer_id,
        rank() OVER (ORDER BY lifetime_spend DESC) AS spend_rank
    FROM (
        SELECT customer_id, sum(subtotal) AS lifetime_spend
        FROM retail.orders_enriched FINAL
        GROUP BY customer_id
    )
) AS r ON r.customer_id = oe.customer_id
ORDER BY oe.order_created_at DESC