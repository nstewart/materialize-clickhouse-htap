WITH demand AS (
    SELECT
        oi.product_id,
        SUM(oi.quantity)                                    AS total_units_sold,
        SUM(oi.quantity * oi.unit_price)                    AS total_revenue,
        COUNT(DISTINCT o.customer_id)                       AS buyer_count
    FROM order_items oi
    JOIN orders o ON o.id = oi.order_id
    GROUP BY oi.product_id
),
repeat_buyers AS (
    SELECT product_id, COUNT(*) AS repeat_buyer_count
    FROM (
        SELECT oi.product_id, o.customer_id
        FROM order_items oi
        JOIN orders o ON o.id = oi.order_id
        GROUP BY oi.product_id, o.customer_id
        HAVING COUNT(DISTINCT o.id) >= 2
    ) rb
    GROUP BY product_id
),
ranked AS (
    SELECT
        p.id                                                AS product_id,
        p.sku,
        p.name,
        p.category,
        p.price::float                                      AS price,
        p.cost::float                                       AS cost,
        COALESCE(d.total_units_sold, 0)                     AS total_units_sold,
        COALESCE(d.total_revenue, 0)::float                 AS total_revenue,
        COALESCE(d.buyer_count, 0)                          AS buyer_count,
        COALESCE(r.repeat_buyer_count, 0)                   AS repeat_buyer_count,
        CASE
            WHEN COALESCE(d.buyer_count, 0) > 0
            THEN COALESCE(r.repeat_buyer_count, 0)::float / d.buyer_count
            ELSE 0.0
        END                                                 AS repeat_buyer_rate,
        RANK() OVER (
            PARTITION BY p.category
            ORDER BY COALESCE(d.total_units_sold, 0) DESC
        )                                                   AS category_sales_rank
    FROM products p
    LEFT JOIN demand        d ON d.product_id = p.id
    LEFT JOIN repeat_buyers r ON r.product_id = p.id
)
SELECT * FROM ranked WHERE sku = %(sku)s
