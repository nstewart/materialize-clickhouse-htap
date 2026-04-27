WITH first_orders AS (
    SELECT
        customer_id,
        MIN(created_at) AS first_order_date
    FROM orders
    GROUP BY customer_id
),
cohort_activity AS (
    SELECT
        DATE_TRUNC('month', fo.first_order_date)              AS cohort_month,
        FLOOR(
            EXTRACT(EPOCH FROM (o.created_at - fo.first_order_date))
            / (30 * 86400)
        )::int                                                AS months_after_first,
        o.customer_id
    FROM orders o
    JOIN first_orders fo ON fo.customer_id = o.customer_id
    WHERE FLOOR(
        EXTRACT(EPOCH FROM (o.created_at - fo.first_order_date))
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
