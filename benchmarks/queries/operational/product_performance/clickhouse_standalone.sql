-- Product performance with category rank against raw normalized ClickHouse tables.
-- Must scan all order_items and recompute RANK() across every product in the
-- category — the same window function Materialize maintains incrementally.
WITH demand AS (
    SELECT
        oi.product_id,
        sum(oi.quantity)                    AS total_units_sold,
        sum(oi.quantity * oi.unit_price)    AS total_revenue,
        uniqExact(o.customer_id)            AS buyer_count
    FROM (SELECT * FROM retail.raw_order_items FINAL) oi
    JOIN (SELECT * FROM retail.raw_orders FINAL) o ON o.id = oi.order_id
    GROUP BY oi.product_id
),
repeat_buyers AS (
    SELECT
        product_id,
        countIf(order_count >= 2) AS repeat_buyer_count
    FROM (
        SELECT
            oi.product_id,
            o.customer_id,
            uniqExact(oi.order_id) AS order_count
        FROM (SELECT * FROM retail.raw_order_items FINAL) oi
        JOIN (SELECT * FROM retail.raw_orders FINAL) o ON o.id = oi.order_id
        GROUP BY oi.product_id, o.customer_id
    )
    GROUP BY product_id
),
ranked AS (
    SELECT
        p.id                                                       AS product_id,
        p.sku,
        p.name,
        p.category,
        p.price,
        p.cost,
        COALESCE(d.total_units_sold, 0)                           AS total_units_sold,
        COALESCE(d.total_revenue, 0)                              AS total_revenue,
        COALESCE(d.buyer_count, 0)                                AS buyer_count,
        COALESCE(rb.repeat_buyer_count, 0)                        AS repeat_buyer_count,
        if(COALESCE(d.buyer_count, 0) > 0,
           COALESCE(rb.repeat_buyer_count, 0) / COALESCE(d.buyer_count, 0),
           0)                                                      AS repeat_buyer_rate,
        rank() OVER (
            PARTITION BY p.category
            ORDER BY COALESCE(d.total_units_sold, 0) DESC
        )                                                          AS category_sales_rank
    FROM (SELECT * FROM retail.raw_products FINAL) p
    LEFT JOIN demand d ON d.product_id = p.id
    LEFT JOIN repeat_buyers rb ON rb.product_id = p.id
)
SELECT * FROM ranked WHERE sku = {sku:String}
