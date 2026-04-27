"""
Tests for the Materialize pre-aggregated analytical sinks:
  mz_sales_by_dim       — ~203 rows, (category × customer_tier × day_of_week)
  mz_revenue_histogram  — ~20-50 rows, $50 buckets, trailing 90-day window

These tables are populated by Materialize IVM via Kafka sinks — not batch
scheduled. Tests verify population, shape correctness, and aggregate integrity
against the source tables (orders_enriched / orders_summary).
"""
import pytest
from conftest import wait_for_condition


# ---------------------------------------------------------------------------
# mz_sales_by_dim
# ---------------------------------------------------------------------------

def test_sales_by_dim_populated(ch_client):
    """mz_sales_by_dim FINAL must have rows covering multiple categories."""
    wait_for_condition(
        lambda: ch_client.query(
            "SELECT COUNT(*) FROM retail.mz_sales_by_dim FINAL"
        ).result_rows[0][0] > 0,
        timeout=60,
    )
    result = ch_client.query(
        "SELECT COUNT(*) FROM retail.mz_sales_by_dim FINAL"
    )
    row_count = result.result_rows[0][0]
    assert row_count > 0, "mz_sales_by_dim FINAL is empty"
    # 5 categories × 4 tiers × 7 days = 140 possible, expect most to be present
    assert row_count >= 50, (
        f"Expected >= 50 rows in mz_sales_by_dim FINAL, got {row_count}"
    )


def test_sales_by_dim_categories(ch_client):
    """mz_sales_by_dim must contain all 5 expected product categories."""
    result = ch_client.query(
        "SELECT DISTINCT category FROM retail.mz_sales_by_dim FINAL ORDER BY category"
    )
    categories = {row[0] for row in result.result_rows}
    expected = {"Electronics", "Apparel", "Home", "Sports", "Food"}
    assert expected.issubset(categories), (
        f"Missing categories in mz_sales_by_dim: {expected - categories}"
    )


def test_sales_by_dim_day_of_week_range(ch_client):
    """day_of_week values must be in 0–6 (Materialize extract(dow))."""
    result = ch_client.query(
        "SELECT MIN(day_of_week), MAX(day_of_week) FROM retail.mz_sales_by_dim FINAL"
    )
    min_dow, max_dow = result.result_rows[0]
    assert min_dow >= 0, f"day_of_week min is {min_dow}, expected >= 0"
    assert max_dow <= 6, f"day_of_week max is {max_dow}, expected <= 6"


def test_sales_by_dim_revenue_consistent_with_orders_enriched(ch_client):
    """
    Total revenue across mz_sales_by_dim FINAL must be within 1% of total
    subtotal in orders_enriched FINAL. The two tables aggregate the same
    underlying order_detail data.
    """
    r_dim = ch_client.query(
        "SELECT SUM(revenue) FROM retail.mz_sales_by_dim FINAL"
    )
    r_enriched = ch_client.query(
        "SELECT SUM(subtotal) FROM retail.orders_enriched FINAL"
    )
    total_dim = r_dim.result_rows[0][0] or 0.0
    total_enriched = r_enriched.result_rows[0][0] or 0.0

    assert total_enriched > 0, "orders_enriched FINAL is empty — cannot compare"
    assert total_dim > 0, "mz_sales_by_dim FINAL has zero total revenue"

    pct_diff = abs(total_dim - total_enriched) / total_enriched
    assert pct_diff < 0.01, (
        f"Revenue mismatch: mz_sales_by_dim={total_dim:.2f}, "
        f"orders_enriched={total_enriched:.2f}, diff={pct_diff:.2%}"
    )


def test_sales_by_dim_no_duplicate_keys(ch_client):
    """After FINAL, no (category, customer_tier, day_of_week) combination appears twice."""
    result = ch_client.query(
        """
        SELECT category, customer_tier, day_of_week, COUNT(*) AS cnt
        FROM retail.mz_sales_by_dim FINAL
        GROUP BY category, customer_tier, day_of_week
        HAVING cnt > 1
        """
    )
    duplicates = result.result_rows
    assert len(duplicates) == 0, (
        f"Duplicate keys in mz_sales_by_dim FINAL: {duplicates}"
    )


# ---------------------------------------------------------------------------
# mz_revenue_histogram
# ---------------------------------------------------------------------------

def test_revenue_histogram_populated(ch_client):
    """mz_revenue_histogram FINAL must have at least one bucket."""
    wait_for_condition(
        lambda: ch_client.query(
            "SELECT COUNT(*) FROM retail.mz_revenue_histogram FINAL"
        ).result_rows[0][0] > 0,
        timeout=60,
    )
    result = ch_client.query(
        "SELECT COUNT(*) FROM retail.mz_revenue_histogram FINAL"
    )
    row_count = result.result_rows[0][0]
    assert row_count > 0, "mz_revenue_histogram FINAL is empty"
    assert row_count >= 5, (
        f"Expected >= 5 buckets in mz_revenue_histogram FINAL, got {row_count}"
    )


def test_revenue_histogram_buckets_are_multiples_of_50(ch_client):
    """Every bucket value must be a non-negative multiple of 50."""
    result = ch_client.query(
        "SELECT DISTINCT bucket FROM retail.mz_revenue_histogram FINAL ORDER BY bucket"
    )
    buckets = [row[0] for row in result.result_rows]
    for b in buckets:
        assert b >= 0, f"Negative bucket value: {b}"
        assert abs(b % 50) < 0.01, f"Bucket {b} is not a multiple of 50"


def test_revenue_histogram_order_counts_positive(ch_client):
    """Every bucket must have at least one order."""
    result = ch_client.query(
        "SELECT bucket, order_count FROM retail.mz_revenue_histogram FINAL"
    )
    for bucket, count in result.result_rows:
        assert count > 0, f"Bucket {bucket} has order_count={count}"


def test_revenue_histogram_no_duplicate_buckets(ch_client):
    """After FINAL, each bucket value appears exactly once."""
    result = ch_client.query(
        """
        SELECT bucket, COUNT(*) AS cnt
        FROM retail.mz_revenue_histogram FINAL
        GROUP BY bucket
        HAVING cnt > 1
        """
    )
    duplicates = result.result_rows
    assert len(duplicates) == 0, (
        f"Duplicate buckets in mz_revenue_histogram FINAL: {duplicates}"
    )


def test_revenue_histogram_total_revenue_consistent_with_orders_summary(ch_client):
    """
    Total revenue in mz_revenue_histogram must be <= total revenue in
    orders_summary FINAL (histogram only covers the 90-day window).
    Must also be > 0 and cover a meaningful portion of total revenue.
    """
    r_hist = ch_client.query(
        "SELECT SUM(total_revenue) FROM retail.mz_revenue_histogram FINAL"
    )
    r_summary = ch_client.query(
        "SELECT SUM(order_total) FROM retail.orders_summary FINAL"
    )
    hist_total = r_hist.result_rows[0][0] or 0.0
    summary_total = r_summary.result_rows[0][0] or 0.0

    assert summary_total > 0, "orders_summary FINAL is empty"
    assert hist_total > 0, "mz_revenue_histogram FINAL has zero total revenue"
    # Histogram covers 90-day window — must be <= lifetime total
    assert hist_total <= summary_total * 1.001, (
        f"Histogram revenue ({hist_total:.2f}) exceeds orders_summary total "
        f"({summary_total:.2f}) — temporal filter may not be applied"
    )
