"""
Tests for benchmarks/generate_load.py.

These tests exercise the load generator directly against the live Postgres
database so that bugs like the insert_returning / execute_values ID-collection
issue are caught before a user runs `make load`.
"""
import sys
import os
import pytest
import psycopg2
import psycopg2.extras

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "benchmarks"))
from generate_load import (
    insert_returning,
    insert_batched,
    generate_customers,
    generate_products,
    generate_orders,
    generate_order_items,
    generate_inventory,
    WAREHOUSES,
)


@pytest.fixture
def pg_cursor_transactional(pg_conn):
    """
    Cursor that rolls back after each test so load-generator tests don't
    leave rows in the database.
    """
    pg_conn.autocommit = False
    cur = pg_conn.cursor()
    yield cur
    pg_conn.rollback()
    pg_conn.autocommit = True


# ---------------------------------------------------------------------------
# Core regression: insert_returning must return the inserted IDs
# ---------------------------------------------------------------------------

def test_insert_returning_gives_nonempty_ids(pg_cursor_transactional):
    """
    Regression for the execute_values / fetchall double-consume bug.

    The buggy version called cur.fetchall() after execute_values(fetch=True),
    which consumed the cursor twice and returned an empty list.  The generator
    then called customer_ids[pareto_customer_index(0)] → IndexError.
    """
    cur = pg_cursor_transactional
    ids = insert_returning(
        cur,
        "INSERT INTO customers (email, name, tier, created_at) VALUES %s RETURNING id",
        generate_customers(5),
        "customers",
    )
    assert len(ids) == 5, (
        f"insert_returning returned {len(ids)} IDs instead of 5 — "
        "likely the execute_values double-consume bug"
    )
    assert all(isinstance(i, int) and i > 0 for i in ids), \
        "All returned IDs must be positive integers"


def test_insert_returning_ids_are_unique(pg_cursor_transactional):
    """Each INSERT RETURNING id must yield distinct database-assigned IDs."""
    cur = pg_cursor_transactional
    ids = insert_returning(
        cur,
        "INSERT INTO customers (email, name, tier, created_at) VALUES %s RETURNING id",
        generate_customers(10),
        "customers",
    )
    assert len(ids) == len(set(ids)), "Returned IDs must be unique"


def test_insert_returning_ids_match_actual_rows(pg_cursor_transactional):
    """IDs returned by insert_returning must exist in the table."""
    cur = pg_cursor_transactional
    ids = insert_returning(
        cur,
        "INSERT INTO customers (email, name, tier, created_at) VALUES %s RETURNING id",
        generate_customers(3),
        "customers",
    )
    cur.execute("SELECT id FROM customers WHERE id = ANY(%s)", (ids,))
    found = {r[0] for r in cur.fetchall()}
    assert set(ids) == found


# ---------------------------------------------------------------------------
# Downstream: orders generation requires non-empty customer_ids
# ---------------------------------------------------------------------------

def test_orders_generation_uses_customer_ids(pg_cursor_transactional):
    """
    If customer_ids is empty, generate_orders raises IndexError immediately.
    This test ensures the full customer → orders dependency works end-to-end.
    """
    cur = pg_cursor_transactional

    customer_ids = insert_returning(
        cur,
        "INSERT INTO customers (email, name, tier, created_at) VALUES %s RETURNING id",
        generate_customers(10),
        "customers",
    )
    assert len(customer_ids) > 0, "Precondition: customer_ids must be non-empty"

    order_ids = insert_returning(
        cur,
        "INSERT INTO orders (customer_id, status, created_at, updated_at) VALUES %s RETURNING id",
        generate_orders(20, customer_ids),
        "orders",
    )
    assert len(order_ids) == 20


# ---------------------------------------------------------------------------
# Full mini-pipeline smoke test
# ---------------------------------------------------------------------------

def test_full_load_mini_pipeline(pg_cursor_transactional):
    """
    Runs all five insert stages with small row counts to confirm the entire
    load generator works without error.  Catches cross-stage dependency bugs.
    """
    cur = pg_cursor_transactional

    customer_ids = insert_returning(
        cur,
        "INSERT INTO customers (email, name, tier, created_at) VALUES %s RETURNING id",
        generate_customers(5),
        "customers",
    )
    assert len(customer_ids) == 5

    product_ids = insert_returning(
        cur,
        "INSERT INTO products (sku, name, category, price, cost, created_at) VALUES %s RETURNING id",
        generate_products(5),
        "products",
    )
    assert len(product_ids) == 5

    order_ids = insert_returning(
        cur,
        "INSERT INTO orders (customer_id, status, created_at, updated_at) VALUES %s RETURNING id",
        generate_orders(10, customer_ids),
        "orders",
    )
    assert len(order_ids) == 10

    n_items = insert_batched(
        cur,
        "INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES (%s, %s, %s, %s)",
        generate_order_items(order_ids, product_ids),
        "order_items",
    )
    assert n_items > 0

    n_inv = insert_batched(
        cur,
        """INSERT INTO inventory (product_id, warehouse_id, quantity, updated_at)
           VALUES (%s, %s, %s, %s)
           ON CONFLICT (product_id, warehouse_id) DO UPDATE
             SET quantity   = EXCLUDED.quantity,
                 updated_at = EXCLUDED.updated_at""",
        generate_inventory(product_ids),
        "inventory",
    )
    assert n_inv == len(product_ids) * len(WAREHOUSES)
