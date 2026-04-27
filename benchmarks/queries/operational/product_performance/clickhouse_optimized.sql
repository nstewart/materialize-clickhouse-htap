-- Product performance using ClickHouse-native optimizations:
--   product_category_rank  pre-computed table refreshed every 5 seconds, with a
--                          sku projection — a SKU lookup hits the projection
--                          (sorted by sku) rather than scanning 526 products.
--   No runtime window RANK(), no full order_items scan, no JOINs at query time.
-- Tradeoff vs. Materialize: up to 5 seconds stale vs. immediately consistent.
SELECT
    product_id,
    sku,
    name,
    category,
    price,
    cost,
    total_units_sold,
    total_revenue,
    buyer_count,
    repeat_buyer_count,
    repeat_buyer_rate,
    category_sales_rank
FROM retail.product_category_rank FINAL
WHERE sku = {sku:String}
