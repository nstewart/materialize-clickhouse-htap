WITH demand AS (
    SELECT product_id, SUM(quantity)::float AS total_units_sold
    FROM order_items
    GROUP BY product_id
)
SELECT
    i.warehouse_id,
    i.quantity,
    p.name                                                  AS product_name,
    p.category,
    p.price::float,
    p.cost::float,
    COALESCE(d.total_units_sold, 0)                         AS total_units_sold,
    CASE
        WHEN COALESCE(d.total_units_sold, 0) > 0
        THEN i.quantity::float / d.total_units_sold::float
        ELSE NULL
    END                                                     AS stock_to_sales_ratio
FROM inventory i
JOIN products p ON p.id = i.product_id
LEFT JOIN demand d ON d.product_id = i.product_id
WHERE p.sku = %(sku)s