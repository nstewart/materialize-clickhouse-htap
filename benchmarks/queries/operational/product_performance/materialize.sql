SELECT
    product_id, sku, name, category, price, cost,
    total_units_sold, total_revenue,
    buyer_count, repeat_buyer_count, repeat_buyer_rate, category_sales_rank
FROM product_performance
WHERE sku = %(sku)s
