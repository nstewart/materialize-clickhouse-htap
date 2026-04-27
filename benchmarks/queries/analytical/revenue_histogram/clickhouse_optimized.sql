-- Revenue histogram using ClickHouse-native optimizations:
--   opt_order_totals  pre-computed order_total per order, refreshed every 30 s.
--                     One scan of 1M rows with no JOIN — same row count as the
--                     Materialize orders_summary sink but fed by Debezium CDC.
-- Tradeoff vs. ClickHouse (via Materialize): up to 30 s stale (batch refresh)
-- vs. continuously maintained (Materialize IVM + Kafka sink, ~2.4 s freshness).
SELECT
    floor(order_total / 50) * 50 AS bucket,
    count()                      AS order_count,
    sum(order_total)             AS total_revenue
FROM retail.opt_order_totals FINAL
WHERE order_created_at >= now() - INTERVAL 90 DAY
GROUP BY bucket
ORDER BY bucket
