SELECT
    warehouse_id, quantity, product_name, category,
    price, cost, total_units_sold, stock_to_sales_ratio
FROM inventory_position
WHERE sku = %(sku)s