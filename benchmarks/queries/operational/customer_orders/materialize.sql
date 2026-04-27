-- Materialize serves pre-computed rows from customer_order_activity, indexed on
-- customer_id. spend_rank is maintained incrementally in customer_profile — no
-- full-table scan at query time.
SELECT
    line_item_id, order_id, customer_id, status,
    order_created_at, order_updated_at,
    product_id, quantity, unit_price, subtotal, line_margin,
    sku, product_name, category, current_price,
    customer_email, customer_tier,
    computed_tier, avg_order_value, distinct_categories_purchased, last_order_date,
    spend_rank
FROM customer_order_activity
WHERE customer_id = %(customer_id)s
ORDER BY order_created_at DESC