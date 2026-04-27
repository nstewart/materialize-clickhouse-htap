-- Inventory lookup using ClickHouse-native optimizations:
--   product_by_sku      dictionary (HASHED, LIFETIME 5–30 s): O(1) SKU → product attrs
--   product_stats_by_id dictionary (HASHED, LIFETIME 5–30 s): O(1) product_id → units sold
--   opt_inventory       ORDER BY (product_id, warehouse_id): point lookup per product_id
--
-- All data accesses are O(1) dictionary hash lookups or O(log n) primary-key range scans.
-- No FINAL subquery JOINs, no full-table scans. Dictionaries serve pre-loaded in-memory
-- data on their own reload schedule, independent of the main query path.
SELECT
    warehouse_id,
    quantity,
    dictGet('retail.product_by_sku', 'name',     {sku:String})  AS product_name,
    dictGet('retail.product_by_sku', 'category', {sku:String})  AS category,
    dictGet('retail.product_by_sku', 'price',    {sku:String})  AS price,
    dictGet('retail.product_by_sku', 'cost',     {sku:String})  AS cost,
    dictGetOrDefault('retail.product_stats_by_id', 'total_units_sold',
        dictGet('retail.product_by_sku', 'id', {sku:String}),
        toFloat64(0))                                            AS total_units_sold,
    if(dictGetOrDefault('retail.product_stats_by_id', 'total_units_sold',
           dictGet('retail.product_by_sku', 'id', {sku:String}),
           toFloat64(0)) > 0,
       toFloat64(quantity) / dictGetOrDefault('retail.product_stats_by_id', 'total_units_sold',
           dictGet('retail.product_by_sku', 'id', {sku:String}),
           toFloat64(0)),
       NULL)                                                      AS stock_to_sales_ratio
FROM retail.opt_inventory FINAL
WHERE product_id = toInt64(dictGet('retail.product_by_sku', 'id', {sku:String}))
