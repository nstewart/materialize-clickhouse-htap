-- Inventory lookup against raw normalized ClickHouse tables.
-- Must JOIN products + order_items at query time to compute stock_to_sales_ratio —
-- the same computation Materialize maintains incrementally and pre-indexes.
SELECT
    i.warehouse_id,
    i.quantity,
    p.name                                                        AS product_name,
    p.category,
    p.price,
    p.cost,
    COALESCE(s.total_units_sold, 0)                              AS total_units_sold,
    if(COALESCE(s.total_units_sold, 0) > 0,
       i.quantity / COALESCE(s.total_units_sold, 0),
       NULL)                                                      AS stock_to_sales_ratio
FROM (SELECT * FROM retail.raw_inventory FINAL) i
JOIN (SELECT * FROM retail.raw_products FINAL) p ON p.id = i.product_id
LEFT JOIN (
    SELECT product_id, sum(quantity) AS total_units_sold
    FROM retail.raw_order_items FINAL
    GROUP BY product_id
) s ON s.product_id = i.product_id
WHERE p.sku = {sku:String}
