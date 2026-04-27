-- Cohort retention from orders_summary (order-level sink, 1M rows).
-- One scan vs. orders_enriched's 2.8M line-item rows.
WITH first_orders AS (
    SELECT customer_id, min(order_created_at) AS first_order_date
    FROM retail.orders_summary FINAL
    GROUP BY customer_id
)
SELECT
    toStartOfMonth(fo.first_order_date)                                         AS cohort_month,
    floor(dateDiff('day', fo.first_order_date, os.order_created_at) / 30)      AS months_after_first,
    uniqExact(os.customer_id)                                                   AS customers
FROM (SELECT customer_id, order_created_at FROM retail.orders_summary FINAL) AS os
JOIN first_orders fo ON fo.customer_id = os.customer_id
GROUP BY cohort_month, months_after_first
ORDER BY cohort_month, months_after_first
