-- Runs against the order_detail MV; no index exists for this aggregation shape,
-- so Materialize must do a full scan — this is the intentionally unoptimized case.
WITH first_orders AS (
    SELECT
        customer_id,
        MIN(order_created_at) AS first_order_date
    FROM order_detail
    GROUP BY customer_id
),
cohort_activity AS (
    SELECT
        DATE_TRUNC('month', fo.first_order_date)              AS cohort_month,
        FLOOR(
            EXTRACT(EPOCH FROM (od.order_created_at - fo.first_order_date))
            / (30 * 86400)
        )::int                                                AS months_after_first,
        od.customer_id
    FROM order_detail od
    JOIN first_orders fo ON fo.customer_id = od.customer_id
    WHERE FLOOR(
        EXTRACT(EPOCH FROM (od.order_created_at - fo.first_order_date))
        / (30 * 86400)
    ) BETWEEN 0 AND 3
)
SELECT
    cohort_month,
    months_after_first,
    COUNT(DISTINCT customer_id) AS customers
FROM cohort_activity
GROUP BY cohort_month, months_after_first
ORDER BY cohort_month, months_after_first;
