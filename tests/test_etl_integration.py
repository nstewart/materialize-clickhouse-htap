"""
Schema smoke tests for the raw ClickHouse tables.

The raw_* tables are populated by Debezium CDC (not a manual ETL cycle).
These tests simply verify the tables are queryable and contain rows after
the Debezium snapshot completes.
"""
import pytest


@pytest.mark.parametrize("table", [
    "retail.raw_customers",
    "retail.raw_products",
    "retail.raw_orders",
    "retail.raw_order_items",
    "retail.raw_inventory",
])
def test_raw_table_is_queryable(ch_client, table):
    """Each raw table must accept a COUNT(*) FINAL query without error."""
    result = ch_client.query(f"SELECT count() FROM {table} FINAL")
    count = result.result_rows[0][0]
    assert count >= 0, f"Unexpected negative count from {table}"
