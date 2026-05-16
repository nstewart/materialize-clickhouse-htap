"""
Regression test for kafka_poll_timeout_ms=100 on ClickHouse Kafka engine tables.

Inserts a single canary row into Postgres and measures how long it takes to
appear in ClickHouse's inventory_snapshots table via the full pipeline:

  Postgres → Materialize (CDC) → Redpanda (Kafka sink) → ClickHouse

Asserts arrival within 2 seconds. With the default kafka_poll_timeout_ms=500
this would regularly exceed 2 s (MZ tick ~250 ms + CH poll ~500 ms = ~750 ms
worst case, but often >1 s end-to-end). With 100 ms the budget is comfortable.
"""
import time
import random

import psycopg2
import pytest

from conftest import wait_for_condition


_FRESHNESS_BUDGET_S = 2.5


@pytest.fixture
def canary_product(pg_conn):
    """Insert a minimal product + inventory row; remove it after the test."""
    sku = f"CANARY-{random.randint(100_000, 999_999)}"
    cur = pg_conn.cursor()

    cur.execute(
        "INSERT INTO products (sku, name, category, price, cost) "
        "VALUES (%s, %s, %s, %s, %s) RETURNING id",
        (sku, "Kafka Poll Canary", "Test", 0.01, 0.01),
    )
    product_id = cur.fetchone()[0]

    cur.execute(
        "INSERT INTO inventory (product_id, warehouse_id, quantity, updated_at) "
        "VALUES (%s, %s, %s, NOW())",
        (product_id, "W1", 1),
    )

    yield product_id, sku

    cur.execute("DELETE FROM inventory WHERE product_id = %s", (product_id,))
    cur.execute("DELETE FROM products WHERE id = %s", (product_id,))


def test_clickhouse_freshness_within_budget(canary_product, ch_client):
    """
    Canary row must appear in ClickHouse inventory_snapshots within
    _FRESHNESS_BUDGET_S seconds of the Postgres commit.
    """
    product_id, sku = canary_product

    t0 = time.perf_counter()

    wait_for_condition(
        lambda: bool(
            ch_client.query(
                "SELECT 1 FROM retail.inventory_snapshots "
                "WHERE product_id = %(pid)s LIMIT 1",
                parameters={"pid": product_id},
            ).result_rows
        ),
        timeout=_FRESHNESS_BUDGET_S,
        interval=0.05,
    )

    elapsed = time.perf_counter() - t0
    assert elapsed < _FRESHNESS_BUDGET_S, (
        f"ClickHouse freshness {elapsed:.2f}s exceeded budget of {_FRESHNESS_BUDGET_S}s — "
        f"check kafka_poll_timeout_ms on inventory_snapshots Kafka engine table"
    )
