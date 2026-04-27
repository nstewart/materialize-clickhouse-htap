-- Cohort retention against raw normalized ClickHouse tables.
-- This query only needs raw_orders (no JOIN to other tables), so performance
-- difference vs ClickHouse (via Materialize) shows the overhead of FINAL on
-- a raw ReplacingMergeTree vs the pre-compacted orders_enriched table.
WITH first_orders AS (
    SELECT customer_id, min(created_at) AS first_order_date
    FROM retail.raw_orders FINAL
    GROUP BY customer_id
)
SELECT
    toStartOfMonth(fo.first_order_date)                            AS cohort_month,
    floor(dateDiff('day', fo.first_order_date, o.created_at) / 30) AS months_after_first,
    uniqExact(o.customer_id)                                        AS customers
FROM (SELECT * FROM retail.raw_orders FINAL) o
JOIN first_orders fo ON fo.customer_id = o.customer_id
GROUP BY cohort_month, months_after_first
ORDER BY cohort_month, months_after_first
