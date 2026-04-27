-- Revenue by category × tier × day-of-week using ClickHouse-native optimizations:
--   opt_sales_by_dim  pre-aggregated table with 203 rows (one per unique
--                     category × tier × day_of_week combination), refreshed every
--                     30 s. Eliminates the 4-way JOIN across 2.8M order_items at
--                     query time — a single small-table scan returns the result.
-- Tradeoff vs. ClickHouse (via Materialize): up to 30 s stale (batch refresh)
-- vs. ~2.4 s freshness from the Materialize-enriched orders_enriched sink.
SELECT
    category,
    customer_tier,
    day_of_week,
    revenue,
    line_item_count
FROM retail.opt_sales_by_dim FINAL
ORDER BY revenue DESC
