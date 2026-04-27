-- Revenue histogram via Materialize pre-aggregated sliding-window sink.
-- mz_revenue_histogram is maintained by Materialize IVM with a mz_now()-based
-- 90-day temporal filter: as orders age out, their buckets are decremented
-- automatically. ~20-50 rows (one per $50 bucket in the current window).
-- ClickHouse reads the pre-bucketed result directly — no scan, no filter, no GROUP BY.
SELECT
    bucket,
    order_count,
    total_revenue
FROM retail.mz_revenue_histogram FINAL
ORDER BY bucket
