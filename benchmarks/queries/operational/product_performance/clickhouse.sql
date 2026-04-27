SELECT
    sku, category, total_units_sold, total_revenue,
    buyer_count, repeat_buyer_count, repeat_buyer_rate, category_sales_rank
FROM (
    SELECT
        d.sku                                                                   AS sku,
        cat.category                                                            AS category,
        d.total_units_sold                                                      AS total_units_sold,
        d.total_revenue                                                         AS total_revenue,
        d.buyer_count                                                           AS buyer_count,
        rb.repeat_buyer_count                                                   AS repeat_buyer_count,
        if(d.buyer_count > 0, rb.repeat_buyer_count / d.buyer_count, 0)        AS repeat_buyer_rate,
        rank() OVER (
            PARTITION BY cat.category
            ORDER BY d.total_units_sold DESC
        )                                                                       AS category_sales_rank
    FROM (
        SELECT sku, sum(quantity) AS total_units_sold, sum(subtotal) AS total_revenue,
               uniqExact(customer_id) AS buyer_count
        FROM retail.orders_enriched FINAL
        GROUP BY sku
    ) AS d
    JOIN (
        SELECT sku, countIf(order_count >= 2) AS repeat_buyer_count
        FROM (
            SELECT sku, customer_id, uniqExact(order_id) AS order_count
            FROM retail.orders_enriched FINAL
            GROUP BY sku, customer_id
        )
        GROUP BY sku
    ) AS rb ON rb.sku = d.sku
    JOIN (SELECT DISTINCT sku, category FROM retail.orders_enriched FINAL) AS cat ON cat.sku = d.sku
)
WHERE sku = {sku:String}