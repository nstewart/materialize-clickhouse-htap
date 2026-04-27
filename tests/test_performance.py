"""
Performance baseline tests.

These are soft checks: they print actual latencies and assert generous upper
bounds appropriate for a local Docker environment.  They are not meant to
block CI on marginal timing fluctuations — the assertions are intentionally
loose.
"""
import time
import pytest


# ---------------------------------------------------------------------------
# Materialize operational query latency
# ---------------------------------------------------------------------------

def test_materialize_operational_query_latency(pg_cursor, mz_conn):
    """
    Query customer_order_activity by customer_id (indexed).
    Expected latency: < 500 ms on local Docker.
    """
    # Use a real customer_id from Postgres so the query is non-trivial.
    pg_cursor.execute("SELECT id FROM customers ORDER BY id LIMIT 1")
    customer_id = pg_cursor.fetchone()[0]

    cur = mz_conn.cursor()
    start = time.perf_counter()
    cur.execute(
        "SELECT * FROM customer_order_activity WHERE customer_id = %s",
        (customer_id,),
    )
    rows = cur.fetchall()
    elapsed_ms = (time.perf_counter() - start) * 1000
    cur.close()

    print(f"\ncustomer_order_activity latency: {elapsed_ms:.1f} ms ({len(rows)} rows)")
    # Threshold is 2000 ms: the first query on a Materialize session triggers
    # view compilation and can take 750–1000 ms on local Docker. Sub-sequent
    # queries on the same connection drop to ~10 ms.
    assert elapsed_ms < 2000, (
        f"customer_order_activity query took {elapsed_ms:.1f} ms (threshold: 2000 ms)"
    )


# ---------------------------------------------------------------------------
# ClickHouse analytical query latency
# ---------------------------------------------------------------------------

def test_clickhouse_analytical_query_latency(ch_client):
    """
    Revenue histogram query over orders_enriched FINAL.
    Buckets subtotal into $50 bands, counts orders and sums revenue per bucket.
    Expected latency: < 5000 ms on local Docker with seed data.
    """
    query = """
        SELECT
            floor(subtotal / 50) * 50  AS bucket_start,
            COUNT(*)                    AS order_count,
            SUM(subtotal)               AS bucket_revenue
        FROM retail.orders_enriched FINAL
        GROUP BY bucket_start
        ORDER BY bucket_start
    """
    start = time.perf_counter()
    result = ch_client.query(query)
    elapsed_ms = (time.perf_counter() - start) * 1000
    rows = result.result_rows

    print(f"\nClickHouse revenue histogram latency: {elapsed_ms:.1f} ms ({len(rows)} buckets)")
    for bucket_start, order_count, bucket_revenue in rows:
        print(f"  bucket ${bucket_start:.0f}–${bucket_start+50:.0f}: "
              f"{order_count} items, ${bucket_revenue:.2f} revenue")

    assert elapsed_ms < 5000, (
        f"ClickHouse analytical query took {elapsed_ms:.1f} ms (threshold: 5000 ms)"
    )
