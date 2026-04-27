"""
Connectivity and baseline-data tests.

Verifies that all four services (Postgres, Materialize, ClickHouse, Redpanda)
are reachable and that the expected schema objects and seed-data row counts
are present.
"""
import pytest


# ---------------------------------------------------------------------------
# Postgres
# ---------------------------------------------------------------------------

def test_postgres_reachable(pg_cursor):
    """Postgres is up and seed tables have expected row counts."""
    pg_cursor.execute("SELECT 1")
    assert pg_cursor.fetchone()[0] == 1

    pg_cursor.execute("SELECT COUNT(*) FROM customers")
    assert pg_cursor.fetchone()[0] >= 10, "Expected at least 10 customers (seed data)"

    pg_cursor.execute("SELECT COUNT(*) FROM products")
    assert pg_cursor.fetchone()[0] >= 20, "Expected at least 20 products (seed data)"

    pg_cursor.execute("SELECT COUNT(*) FROM orders")
    assert pg_cursor.fetchone()[0] >= 50, "Expected at least 50 orders (seed data)"


# ---------------------------------------------------------------------------
# Materialize
# ---------------------------------------------------------------------------

def test_materialize_reachable(mz_cursor):
    """Materialize is up and order_detail has at least 100 rows (one per order_item)."""
    mz_cursor.execute("SELECT 1")
    assert mz_cursor.fetchone()[0] == 1

    mz_cursor.execute("SELECT COUNT(*) FROM order_detail")
    count = mz_cursor.fetchone()[0]
    assert count >= 100, f"Expected order_detail to have >= 100 rows, got {count}"


def test_materialize_data_products_exist(mz_cursor):
    """All four core data-product materialized views must exist."""
    mz_cursor.execute("SHOW MATERIALIZED VIEWS")
    rows = mz_cursor.fetchall()
    names = {row[0] for row in rows}
    for expected in ("customer_profile", "product_catalog", "order_detail", "inventory_position"):
        assert expected in names, f"Materialized view '{expected}' not found; found: {names}"


def test_materialize_serving_views_exist(mz_cursor):
    """Serving views must exist."""
    mz_cursor.execute("SHOW VIEWS")
    rows = mz_cursor.fetchall()
    names = {row[0] for row in rows}
    for expected in ("customer_order_activity",):
        assert expected in names, f"View '{expected}' not found; found: {names}"


# ---------------------------------------------------------------------------
# ClickHouse
# ---------------------------------------------------------------------------

def test_clickhouse_reachable(ch_client):
    """ClickHouse is up and orders_enriched has at least 100 rows (after FINAL)."""
    result = ch_client.query("SELECT 1")
    assert result.result_rows[0][0] == 1

    result = ch_client.query("SELECT COUNT(*) FROM retail.orders_enriched FINAL")
    count = result.result_rows[0][0]
    assert count >= 100, f"Expected orders_enriched to have >= 100 rows FINAL, got {count}"


def test_clickhouse_tables_exist(ch_client):
    """Both destination ReplacingMergeTree tables must exist with rows."""
    for table in ("retail.orders_enriched", "retail.inventory_snapshots"):
        result = ch_client.query(f"SELECT COUNT(*) FROM {table} FINAL")
        count = result.result_rows[0][0]
        assert count > 0, f"Expected {table} to have > 0 rows FINAL, got {count}"


def test_clickhouse_raw_tables_exist(ch_client):
    """All five raw normalized tables must exist (created by clickhouse/02_raw_tables.sql)."""
    raw_tables = [
        "retail.raw_customers",
        "retail.raw_products",
        "retail.raw_orders",
        "retail.raw_order_items",
        "retail.raw_inventory",
    ]
    result = ch_client.query("SHOW TABLES FROM retail")
    existing = {row[0] for row in result.result_rows}
    for table in raw_tables:
        short = table.split(".")[1]
        assert short in existing, (
            f"Raw table '{table}' not found in ClickHouse. "
            "Run 'make init' to apply clickhouse/02_raw_tables.sql."
        )
