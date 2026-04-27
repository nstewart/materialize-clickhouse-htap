"""
Data-product correctness tests.

Verifies that Materialize data products and serving views reflect the
correct business logic by comparing against the authoritative Postgres source.
"""
import pytest


# ---------------------------------------------------------------------------
# order_detail join correctness
# ---------------------------------------------------------------------------

def test_order_detail_join_correctness(pg_cursor, mz_cursor):
    """
    Pick a known order_id from Postgres and verify that order_detail in
    Materialize returns the correct product_name, customer_email, and subtotal
    (quantity * unit_price) for each line item.
    """
    # Pick the first order_item from Postgres as the ground-truth reference.
    pg_cursor.execute(
        """
        SELECT
            oi.id            AS line_item_id,
            oi.order_id,
            oi.product_id,
            oi.quantity,
            oi.unit_price,
            (oi.quantity * oi.unit_price) AS subtotal,
            p.name           AS product_name,
            c.email          AS customer_email
        FROM order_items oi
        JOIN products p ON p.id = oi.product_id
        JOIN orders   o ON o.id = oi.order_id
        JOIN customers c ON c.id = o.customer_id
        ORDER BY oi.id
        LIMIT 1
        """
    )
    row = pg_cursor.fetchone()
    line_item_id, order_id, product_id, quantity, unit_price, subtotal, product_name, customer_email = row

    # Query Materialize for the matching row.
    mz_cursor.execute(
        """
        SELECT line_item_id, order_id, product_id, quantity, unit_price,
               subtotal, product_name, customer_email
        FROM order_detail
        WHERE line_item_id = %s
        """,
        (line_item_id,),
    )
    mz_row = mz_cursor.fetchone()
    assert mz_row is not None, f"line_item_id={line_item_id} not found in order_detail"

    mz_line_item_id, mz_order_id, mz_product_id, mz_quantity, mz_unit_price, mz_subtotal, mz_product_name, mz_customer_email = mz_row

    assert mz_order_id == order_id
    assert mz_product_id == product_id
    assert mz_quantity == quantity
    assert mz_product_name == product_name, f"product_name mismatch: PG={product_name!r}, MZ={mz_product_name!r}"
    assert mz_customer_email == customer_email, f"customer_email mismatch: PG={customer_email!r}, MZ={mz_customer_email!r}"
    assert abs(float(mz_subtotal) - float(subtotal)) < 0.01, (
        f"subtotal mismatch: PG={subtotal}, MZ={mz_subtotal}"
    )


# ---------------------------------------------------------------------------
# inventory_position correctness
# ---------------------------------------------------------------------------

def test_inventory_position_correctness(pg_cursor, mz_cursor):
    """
    Pick a known product+warehouse combination from Postgres and verify
    inventory_position in Materialize has the correct quantity and sku.
    """
    pg_cursor.execute(
        """
        SELECT i.product_id, i.warehouse_id, i.quantity, p.sku
        FROM inventory i
        JOIN products p ON p.id = i.product_id
        ORDER BY i.product_id, i.warehouse_id
        LIMIT 1
        """
    )
    product_id, warehouse_id, quantity, sku = pg_cursor.fetchone()

    mz_cursor.execute(
        """
        SELECT product_id, warehouse_id, quantity, sku
        FROM inventory_position
        WHERE product_id = %s AND warehouse_id = %s
        """,
        (product_id, warehouse_id),
    )
    mz_row = mz_cursor.fetchone()
    assert mz_row is not None, (
        f"inventory_position has no row for product_id={product_id}, warehouse_id={warehouse_id!r}"
    )
    mz_product_id, mz_warehouse_id, mz_quantity, mz_sku = mz_row

    assert mz_quantity == quantity, f"quantity mismatch: PG={quantity}, MZ={mz_quantity}"
    assert mz_sku == sku, f"sku mismatch: PG={sku!r}, MZ={mz_sku!r}"


# ---------------------------------------------------------------------------
# customer_profile lifetime_spend
# ---------------------------------------------------------------------------

def test_customer_profile_lifetime_spend(pg_cursor, mz_cursor):
    """
    Pick customer_id=1 (Alice), compute expected lifetime spend from Postgres,
    and verify customer_profile.lifetime_spend matches within $0.01.
    """
    customer_id = 1

    # Ground truth: sum of quantity * unit_price across all order_items for this customer.
    pg_cursor.execute(
        """
        SELECT COALESCE(SUM(oi.quantity * oi.unit_price), 0)
        FROM order_items oi
        JOIN orders o ON o.id = oi.order_id
        WHERE o.customer_id = %s
        """,
        (customer_id,),
    )
    expected_spend = float(pg_cursor.fetchone()[0])

    mz_cursor.execute(
        "SELECT lifetime_spend FROM customer_profile WHERE customer_id = %s",
        (customer_id,),
    )
    mz_row = mz_cursor.fetchone()
    assert mz_row is not None, f"customer_profile has no row for customer_id={customer_id}"
    mz_spend = float(mz_row[0])

    assert abs(mz_spend - expected_spend) < 0.01, (
        f"lifetime_spend mismatch for customer {customer_id}: "
        f"expected={expected_spend:.2f}, got={mz_spend:.2f}"
    )

