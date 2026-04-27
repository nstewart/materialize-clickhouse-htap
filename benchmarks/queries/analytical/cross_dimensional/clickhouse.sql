-- Revenue by category × tier × day-of-week via Materialize pre-aggregated sink.
-- mz_sales_by_dim is maintained incrementally by Materialize IVM — updated at
-- write time, not on a batch schedule. ~203 rows (one per unique combination).
-- ClickHouse scans the full table in a single pass; no GROUP BY at query time.
SELECT
    category,
    customer_tier,
    day_of_week,
    revenue,
    line_item_count
FROM retail.mz_sales_by_dim FINAL
ORDER BY revenue DESC
