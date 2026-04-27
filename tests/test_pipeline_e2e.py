"""
End-to-end pipeline propagation tests.

These tests mutate Postgres data and verify that changes propagate through
Materialize (via CDC) and on to ClickHouse (via Redpanda sink).

All mutations are fully reverted in teardown so the pipeline state is left
unchanged after the suite.
"""
import time
import pytest
import psycopg2

from conftest import wait_for_condition


# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------

def _pg_conn():
    """Open a fresh, autocommit Postgres connection (for teardown use)."""
    conn = psycopg2.connect(
        host="localhost", port=5432,
        dbname="retail", user="postgres", password="postgres",
    )
    conn.autocommit = True
    return conn


# ---------------------------------------------------------------------------
# test_price_update_propagates_to_materialize
# ---------------------------------------------------------------------------

def test_price_update_propagates_to_materialize(pg_conn, mz_conn):
    """
    UPDATE a product price in Postgres (+10%) and verify that
    order_detail.current_price reflects the new value in Materialize
    within 15 seconds.
    """
    product_id = 1  # ELEC-001 Wireless Headphones

    # Capture current price from Postgres.
    cur_pg = pg_conn.cursor()
    cur_pg.execute("SELECT price FROM products WHERE id = %s", (product_id,))
    original_price = float(cur_pg.fetchone()[0])
    new_price = round(original_price * 1.1, 2)

    try:
        # Apply the update.
        cur_pg.execute(
            "UPDATE products SET price = %s WHERE id = %s",
            (new_price, product_id),
        )

        # Poll Materialize until current_price reflects the new value.
        cur_mz = mz_conn.cursor()

        def price_updated():
            cur_mz.execute(
                "SELECT current_price FROM order_detail WHERE product_id = %s LIMIT 1",
                (product_id,),
            )
            row = cur_mz.fetchone()
            if row is None:
                return False
            return abs(float(row[0]) - new_price) < 0.01

        wait_for_condition(price_updated, timeout=15, interval=1)

        # Final assertion.
        cur_mz.execute(
            "SELECT current_price FROM order_detail WHERE product_id = %s LIMIT 1",
            (product_id,),
        )
        mz_price = float(cur_mz.fetchone()[0])
        assert abs(mz_price - new_price) < 0.01, (
            f"Materialize current_price={mz_price:.4f} does not match expected {new_price:.4f}"
        )
        cur_mz.close()

    finally:
        # Restore original price.
        cur_pg.execute(
            "UPDATE products SET price = %s WHERE id = %s",
            (original_price, product_id),
        )
        cur_pg.close()


# ---------------------------------------------------------------------------
# test_price_update_propagates_to_clickhouse
# ---------------------------------------------------------------------------

def test_price_update_propagates_to_clickhouse(pg_conn, ch_client):
    """
    UPDATE a product price in Postgres (+10%) and verify that
    orders_enriched.current_price in ClickHouse reflects the new value
    within 60 seconds (sink latency can be higher).
    """
    product_id = 2  # ELEC-002 USB Hub

    cur_pg = pg_conn.cursor()
    cur_pg.execute("SELECT price FROM products WHERE id = %s", (product_id,))
    original_price = float(cur_pg.fetchone()[0])
    new_price = round(original_price * 1.1, 2)

    try:
        cur_pg.execute(
            "UPDATE products SET price = %s WHERE id = %s",
            (new_price, product_id),
        )

        def ch_price_updated():
            result = ch_client.query(
                "SELECT current_price FROM retail.orders_enriched FINAL "
                "WHERE product_id = %(pid)s LIMIT 1",
                parameters={"pid": product_id},
            )
            if not result.result_rows:
                return False
            ch_price = float(result.result_rows[0][0])
            return abs(ch_price - new_price) < 0.01

        wait_for_condition(ch_price_updated, timeout=60, interval=2)

        result = ch_client.query(
            "SELECT current_price FROM retail.orders_enriched FINAL "
            "WHERE product_id = %(pid)s LIMIT 1",
            parameters={"pid": product_id},
        )
        ch_price = float(result.result_rows[0][0])
        assert abs(ch_price - new_price) < 0.01, (
            f"ClickHouse current_price={ch_price:.4f} does not match expected {new_price:.4f}"
        )

    finally:
        cur_pg.execute(
            "UPDATE products SET price = %s WHERE id = %s",
            (original_price, product_id),
        )
        cur_pg.close()


# ---------------------------------------------------------------------------
# test_new_order_appears_in_pipeline
# ---------------------------------------------------------------------------

def test_new_order_appears_in_pipeline(pg_conn, mz_conn, ch_client):
    """
    Insert a new customer, product, order, and order_item into Postgres.
    Verify the row appears in:
      - Materialize order_detail within 15 s
      - ClickHouse orders_enriched FINAL within 60 s
    Then clean up all inserted rows.
    """
    cur = pg_conn.cursor()

    # Track inserted IDs for cleanup.
    new_customer_id = new_product_id = new_order_id = new_item_id = None

    try:
        # Insert customer.
        cur.execute(
            "INSERT INTO customers (email, name, tier) VALUES (%s, %s, %s) RETURNING id",
            ("test.e2e@example.com", "E2E Test Customer", "standard"),
        )
        new_customer_id = cur.fetchone()[0]

        # Insert product.
        cur.execute(
            "INSERT INTO products (sku, name, category, price, cost) "
            "VALUES (%s, %s, %s, %s, %s) RETURNING id",
            ("TEST-E2E-001", "E2E Test Widget", "Electronics", 9.99, 4.99),
        )
        new_product_id = cur.fetchone()[0]

        # Insert order.
        cur.execute(
            "INSERT INTO orders (customer_id, status) VALUES (%s, %s) RETURNING id",
            (new_customer_id, "pending"),
        )
        new_order_id = cur.fetchone()[0]

        # Insert order_item.
        cur.execute(
            "INSERT INTO order_items (order_id, product_id, quantity, unit_price) "
            "VALUES (%s, %s, %s, %s) RETURNING id",
            (new_order_id, new_product_id, 3, 9.99),
        )
        new_item_id = cur.fetchone()[0]

        expected_subtotal = 3 * 9.99

        # --- Poll Materialize ---
        mz_cur = mz_conn.cursor()

        def order_in_mz():
            mz_cur.execute(
                "SELECT line_item_id, subtotal, product_name, customer_email "
                "FROM order_detail WHERE order_id = %s",
                (new_order_id,),
            )
            return mz_cur.fetchone() is not None

        wait_for_condition(order_in_mz, timeout=15, interval=1)

        mz_cur.execute(
            "SELECT line_item_id, subtotal, product_name, customer_email "
            "FROM order_detail WHERE order_id = %s",
            (new_order_id,),
        )
        mz_row = mz_cur.fetchone()
        assert mz_row is not None, f"order_id={new_order_id} not found in Materialize order_detail"
        mz_item_id, mz_subtotal, mz_product_name, mz_customer_email = mz_row
        assert mz_item_id == new_item_id
        assert abs(float(mz_subtotal) - expected_subtotal) < 0.01
        assert mz_product_name == "E2E Test Widget"
        assert mz_customer_email == "test.e2e@example.com"
        mz_cur.close()

        # --- Poll ClickHouse ---
        def order_in_ch():
            result = ch_client.query(
                "SELECT line_item_id, subtotal, product_name, customer_email "
                "FROM retail.orders_enriched FINAL "
                "WHERE order_id = %(oid)s",
                parameters={"oid": new_order_id},
            )
            return len(result.result_rows) > 0

        wait_for_condition(order_in_ch, timeout=60, interval=2)

        result = ch_client.query(
            "SELECT line_item_id, subtotal, product_name, customer_email "
            "FROM retail.orders_enriched FINAL "
            "WHERE order_id = %(oid)s",
            parameters={"oid": new_order_id},
        )
        assert len(result.result_rows) > 0, (
            f"order_id={new_order_id} not found in ClickHouse orders_enriched FINAL"
        )
        ch_item_id, ch_subtotal, ch_product_name, ch_customer_email = result.result_rows[0]
        assert ch_item_id == new_item_id
        assert abs(float(ch_subtotal) - expected_subtotal) < 0.01
        assert ch_product_name == "E2E Test Widget"
        assert ch_customer_email == "test.e2e@example.com"

    finally:
        # Clean up in reverse dependency order.
        if new_item_id is not None:
            cur.execute("DELETE FROM order_items WHERE id = %s", (new_item_id,))
        if new_order_id is not None:
            cur.execute("DELETE FROM orders WHERE id = %s", (new_order_id,))
        if new_product_id is not None:
            cur.execute("DELETE FROM products WHERE id = %s", (new_product_id,))
        if new_customer_id is not None:
            cur.execute("DELETE FROM customers WHERE id = %s", (new_customer_id,))
        cur.close()


# ---------------------------------------------------------------------------
# test_price_change_propagates_current_price_end_to_end
# ---------------------------------------------------------------------------

def test_price_change_propagates_current_price_end_to_end(pg_conn, mz_conn, ch_client):
    """
    Verify that a product price change propagates through the full pipeline and
    lands in ClickHouse orders_enriched.current_price — not unit_price.

    This test explicitly guards against confusing the two columns:
      - unit_price:   price locked in at order time; must NEVER change after insert
      - current_price: live product price from Postgres; must reflect every update

    Pipeline path exercised:
      Postgres products.price
        → Materialize order_detail.current_price  (CDC + IVM)
        → Redpanda orders-enriched topic          (Kafka sink)
        → ClickHouse orders_enriched.current_price (Kafka engine)
    """
    product_id = 3  # distinct from product_ids used in the other price tests

    cur_pg = pg_conn.cursor()
    cur_pg.execute("SELECT price FROM products WHERE id = %s", (product_id,))
    original_price = float(cur_pg.fetchone()[0])
    new_price = round(original_price * 1.20, 2)

    # Snapshot unit_price before the update — it must not move.
    result = ch_client.query(
        "SELECT unit_price FROM retail.orders_enriched FINAL "
        "WHERE product_id = %(pid)s LIMIT 1",
        parameters={"pid": product_id},
    )
    if not result.result_rows:
        pytest.skip(f"No orders for product_id={product_id} in ClickHouse — run make init first")
    locked_unit_price = float(result.result_rows[0][0])

    try:
        cur_pg.execute(
            "UPDATE products SET price = %s WHERE id = %s",
            (new_price, product_id),
        )

        # Step 1: Materialize order_detail.current_price must reflect new price.
        cur_mz = mz_conn.cursor()

        def mz_updated():
            cur_mz.execute(
                "SELECT current_price FROM order_detail WHERE product_id = %s LIMIT 1",
                (product_id,),
            )
            row = cur_mz.fetchone()
            return row is not None and abs(float(row[0]) - new_price) < 0.01

        wait_for_condition(mz_updated, timeout=15, interval=1)
        cur_mz.close()

        # Step 2: ClickHouse orders_enriched.current_price must reflect new price.
        def ch_updated():
            r = ch_client.query(
                "SELECT current_price FROM retail.orders_enriched FINAL "
                "WHERE product_id = %(pid)s LIMIT 1",
                parameters={"pid": product_id},
            )
            return r.result_rows and abs(float(r.result_rows[0][0]) - new_price) < 0.01

        wait_for_condition(ch_updated, timeout=60, interval=2)

        result = ch_client.query(
            "SELECT current_price, unit_price FROM retail.orders_enriched FINAL "
            "WHERE product_id = %(pid)s LIMIT 1",
            parameters={"pid": product_id},
        )
        ch_current_price = float(result.result_rows[0][0])
        ch_unit_price = float(result.result_rows[0][1])

        assert abs(ch_current_price - new_price) < 0.01, (
            f"current_price={ch_current_price:.4f} should reflect updated price {new_price:.4f}"
        )
        assert abs(ch_unit_price - locked_unit_price) < 0.01, (
            f"unit_price={ch_unit_price:.4f} must not change — it is locked at order-time "
            f"price {locked_unit_price:.4f}. Check that the sink/demo is querying current_price, "
            f"not unit_price."
        )

    finally:
        cur_pg.execute(
            "UPDATE products SET price = %s WHERE id = %s",
            (original_price, product_id),
        )
        cur_pg.close()


# ---------------------------------------------------------------------------
# test_inventory_update_propagates
# ---------------------------------------------------------------------------

def test_inventory_update_propagates(pg_conn, mz_conn):
    """
    UPDATE inventory quantity in Postgres (+100) and verify that
    inventory_position in Materialize reflects the new quantity within 15 s.
    """
    product_id = 5   # APPR-001 Sweater
    warehouse_id = "east"

    cur_pg = pg_conn.cursor()
    cur_pg.execute(
        "SELECT quantity FROM inventory WHERE product_id = %s AND warehouse_id = %s",
        (product_id, warehouse_id),
    )
    original_qty = cur_pg.fetchone()[0]
    new_qty = original_qty + 100

    try:
        cur_pg.execute(
            "UPDATE inventory SET quantity = %s, updated_at = NOW() "
            "WHERE product_id = %s AND warehouse_id = %s",
            (new_qty, product_id, warehouse_id),
        )

        cur_mz = mz_conn.cursor()

        def qty_updated():
            cur_mz.execute(
                "SELECT quantity FROM inventory_position "
                "WHERE product_id = %s AND warehouse_id = %s",
                (product_id, warehouse_id),
            )
            row = cur_mz.fetchone()
            if row is None:
                return False
            return row[0] == new_qty

        wait_for_condition(qty_updated, timeout=15, interval=1)

        cur_mz.execute(
            "SELECT quantity FROM inventory_position "
            "WHERE product_id = %s AND warehouse_id = %s",
            (product_id, warehouse_id),
        )
        mz_qty = cur_mz.fetchone()[0]
        assert mz_qty == new_qty, (
            f"inventory_position quantity={mz_qty} does not match expected {new_qty}"
        )
        cur_mz.close()

    finally:
        cur_pg.execute(
            "UPDATE inventory SET quantity = %s, updated_at = NOW() "
            "WHERE product_id = %s AND warehouse_id = %s",
            (original_qty, product_id, warehouse_id),
        )
        cur_pg.close()
