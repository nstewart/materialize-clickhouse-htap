-- Cohort retention using ClickHouse-native optimizations:
--   opt_order_totals  pre-computed order-level table with one row per order,
--                     ORDER BY order_id. Same 1M-row scan as orders_summary
--                     but fed by Debezium CDC rather than Materialize sink.
-- The self-join pattern is identical to the via-Materialize query; the
-- advantage here is Debezium CDC freshness (~2.4 s) vs Materialize sink
-- freshness (~2.4 s) — effectively the same. Included for completeness.
WITH first_orders AS (
    SELECT customer_id, min(order_created_at) AS first_order_date
    FROM retail.opt_order_totals FINAL
    GROUP BY customer_id
)
SELECT
    toStartOfMonth(fo.first_order_date)                                          AS cohort_month,
    floor(dateDiff('day', fo.first_order_date, ot.order_created_at) / 30)       AS months_after_first,
    uniqExact(ot.customer_id)                                                    AS customers
FROM (SELECT customer_id, order_created_at FROM retail.opt_order_totals FINAL) AS ot
JOIN first_orders fo ON fo.customer_id = ot.customer_id
GROUP BY cohort_month, months_after_first
ORDER BY cohort_month, months_after_first
