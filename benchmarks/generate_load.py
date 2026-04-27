#!/usr/bin/env python3
"""
generate_load.py — populate the retail Postgres database with realistic synthetic data.

Usage:
    python benchmarks/generate_load.py [--rows N]

N is the number of orders (default 100 000).  Customers, products, order items,
and inventory records are derived from N automatically.
"""

import argparse
import random
import sys
import uuid
from datetime import datetime, timedelta, timezone

import clickhouse_connect
import psycopg2
import psycopg2.extras
from faker import Faker

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

BATCH    = 1000
CH_BATCH = 50_000

CH_DSN = dict(host="localhost", port=8123, database="retail", username="default")

CATEGORIES = {
    "Electronics": (49.99, 1499.99),
    "Apparel":     (9.99,  199.99),
    "Home":        (14.99, 599.99),
    "Sports":      (19.99, 499.99),
    "Food":        (2.99,  49.99),
}

STATUS_POOL = (
    ["delivered"]   * 60
    + ["shipped"]   * 20
    + ["processing"] * 10
    + ["pending"]   * 5
    + ["cancelled"] * 5
)

WAREHOUSES = [1, 2, 3]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

fake = Faker()
rng  = random.Random()

# Short prefix unique to this invocation — prevents email/SKU collisions across runs.
_RUN_ID = uuid.uuid4().hex[:8]


def seasonal_timestamp(start: datetime, end: datetime) -> datetime:
    """Return a timestamp with seasonal weighting over the given window."""
    span = (end - start).total_seconds()
    t    = start + timedelta(seconds=rng.uniform(0, span))
    # Boost probability during Q4 (months 10-12) and summer (6-8)
    month = t.month
    if month in (10, 11, 12, 6, 7, 8):
        # Resample once more — effectively ~2× density in those months
        t2 = start + timedelta(seconds=rng.uniform(0, span))
        if t2.month in (10, 11, 12, 6, 7, 8):
            t = t2
    return t


def pareto_customer_index(n_customers: int) -> int:
    """
    Pick a customer index using a Pareto distribution so that
    ~20 % of customers generate ~80 % of orders.
    """
    # scipy not required — use the inverse CDF of Pareto(alpha=1.16)
    alpha = 1.16
    u     = rng.random()
    raw   = (1 - u) ** (-1 / alpha)           # Pareto variate ≥ 1
    # Map [1, ∞) → [0, n_customers-1], clamped
    idx   = int((raw - 1) / (raw) * n_customers)
    return min(idx, n_customers - 1)


def batched(iterable, size):
    buf = []
    for item in iterable:
        buf.append(item)
        if len(buf) >= size:
            yield buf
            buf = []
    if buf:
        yield buf


# ---------------------------------------------------------------------------
# Generators
# ---------------------------------------------------------------------------

def generate_customers(n: int):
    tiers = ["bronze"] * 50 + ["silver"] * 30 + ["gold"] * 15 + ["platinum"] * 5
    now   = datetime.now(tz=timezone.utc)
    for i in range(n):
        # _RUN_ID + sequential index guarantees uniqueness across multiple load runs.
        email = f"{_RUN_ID}.{i}.{fake.user_name()}@{fake.domain_name()}"
        yield (
            email,
            fake.name(),
            rng.choice(tiers),
            now - timedelta(days=rng.randint(0, 730)),
        )


def generate_products(n: int):
    category_list = list(CATEGORIES.keys())
    for i in range(n):
        category    = category_list[i % len(category_list)]
        lo, hi      = CATEGORIES[category]
        price       = round(rng.uniform(lo, hi), 2)
        cost        = round(price * rng.uniform(0.3, 0.6), 2)
        sku         = f"SKU-{_RUN_ID}-{i:06d}"
        name        = f"{fake.word().capitalize()} {fake.word().capitalize()}"
        created_at  = datetime.now(tz=timezone.utc) - timedelta(days=rng.randint(0, 730))
        yield (sku, name, category, price, cost, created_at)


def generate_orders(n: int, customer_ids: list[int]):
    end   = datetime.now(tz=timezone.utc)
    start = end - timedelta(days=730)
    for _ in range(n):
        cid        = customer_ids[pareto_customer_index(len(customer_ids))]
        created_at = seasonal_timestamp(start, end)
        updated_at = created_at + timedelta(hours=rng.randint(0, 72))
        status     = rng.choice(STATUS_POOL)
        yield (cid, status, created_at, updated_at)


def generate_order_items(order_ids: list[int], product_ids: list[int]):
    for oid in order_ids:
        n_items = max(1, int(rng.expovariate(1 / 3)))   # avg 3 items
        seen    = set()
        for _ in range(n_items):
            pid = rng.choice(product_ids)
            if pid in seen:
                continue
            seen.add(pid)
            quantity   = rng.randint(1, 5)
            unit_price = round(rng.uniform(2.99, 999.99), 2)
            yield (oid, pid, quantity, unit_price)


def generate_inventory(product_ids: list[int]):
    for pid in product_ids:
        for wid in WAREHOUSES:
            quantity   = rng.randint(0, 500)
            updated_at = datetime.now(tz=timezone.utc) - timedelta(hours=rng.randint(0, 48))
            yield (pid, wid, quantity, updated_at)


# ---------------------------------------------------------------------------
# Database helpers
# ---------------------------------------------------------------------------

def connect():
    return psycopg2.connect(
        host="localhost",
        port=5432,
        dbname="retail",
        user="postgres",
        password="postgres",
    )


def insert_batched(cur, sql: str, rows, label: str):
    total = 0
    for batch in batched(rows, BATCH):
        cur.executemany(sql, batch)
        total += len(batch)
        print(f"  {label}: {total:,} rows inserted", end="\r", flush=True)
    print(f"  {label}: {total:,} rows inserted")
    return total


def insert_returning(cur, sql: str, rows, label: str) -> list[int]:
    """Insert in batches using execute_values and collect returned IDs."""
    ids   = []
    total = 0
    for batch in batched(rows, BATCH):
        returned = psycopg2.extras.execute_values(cur, sql, batch, fetch=True)
        ids.extend(r[0] for r in returned)
        total += len(batch)
        print(f"  {label}: {total:,} rows inserted", end="\r", flush=True)
    print(f"  {label}: {total:,} rows inserted")
    return ids


# ---------------------------------------------------------------------------
# ClickHouse raw-table sync
# ---------------------------------------------------------------------------

def _ch_load(label: str, pg_conn, ch, sql: str, table: str, columns: list):
    total = 0
    with pg_conn.cursor(f"cur_{label}") as cur:
        cur.execute(sql)
        while True:
            batch = cur.fetchmany(CH_BATCH)
            if not batch:
                break
            ch.insert(table, batch, column_names=columns)
            total += len(batch)
            print(f"  {label}: {total:,}", end="\r", flush=True)
    pg_conn.rollback()
    print(f"  {label}: {total:,}")


def sync_raw_to_clickhouse():
    """Bulk-load all Postgres tables into ClickHouse raw_ tables.

    Called after the Postgres load so the standalone ClickHouse benchmark
    comparison has data.  Opens its own connections to avoid interfering with
    any in-flight Postgres transaction.
    """
    print("\nSyncing raw tables to ClickHouse (standalone benchmark)...")
    pg = connect()
    ch = clickhouse_connect.get_client(**CH_DSN)
    try:
        _ch_load(
            "raw_customers", pg, ch,
            "SELECT id, email, name, tier, created_at FROM customers ORDER BY id",
            "retail.raw_customers", ["id", "email", "name", "tier", "created_at"],
        )
        _ch_load(
            "raw_products", pg, ch,
            "SELECT id, sku, name, category, price, cost, created_at FROM products ORDER BY id",
            "retail.raw_products", ["id", "sku", "name", "category", "price", "cost", "created_at"],
        )
        _ch_load(
            "raw_orders", pg, ch,
            "SELECT id, customer_id, status, created_at, updated_at FROM orders ORDER BY id",
            "retail.raw_orders", ["id", "customer_id", "status", "created_at", "updated_at"],
        )
        _ch_load(
            "raw_order_items", pg, ch,
            "SELECT id, order_id, product_id, quantity, unit_price FROM order_items ORDER BY id",
            "retail.raw_order_items", ["id", "order_id", "product_id", "quantity", "unit_price"],
        )
        _ch_load(
            "raw_inventory", pg, ch,
            "SELECT product_id, warehouse_id, quantity, updated_at FROM inventory ORDER BY product_id, warehouse_id",
            "retail.raw_inventory", ["product_id", "warehouse_id", "quantity", "updated_at"],
        )
        print("ClickHouse raw table sync complete.")
    finally:
        pg.close()
        ch.close()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Generate retail load data")
    parser.add_argument("--rows", type=int, default=100_000,
                        help="Number of orders to generate (default: 100 000)")
    args = parser.parse_args()

    n_orders    = args.rows
    n_customers = max(10, n_orders // 10)
    n_products  = 500

    print(f"\nGenerating retail data:")
    print(f"  customers : {n_customers:,}")
    print(f"  products  : {n_products:,}")
    print(f"  orders    : {n_orders:,}")
    print(f"  order_items (est.): {n_orders * 3:,}")
    print(f"  inventory : {n_products * len(WAREHOUSES):,}")
    print()

    conn = connect()
    try:
        with conn:
            cur = conn.cursor()

            # ------------------------------------------------------------------
            # Customers
            # ------------------------------------------------------------------
            print("Inserting customers...")
            customer_ids = insert_returning(
                cur,
                "INSERT INTO customers (email, name, tier, created_at) VALUES %s RETURNING id",
                generate_customers(n_customers),
                "customers",
            )

            # ------------------------------------------------------------------
            # Products
            # ------------------------------------------------------------------
            print("Inserting products...")
            product_ids = insert_returning(
                cur,
                "INSERT INTO products (sku, name, category, price, cost, created_at) VALUES %s RETURNING id",
                generate_products(n_products),
                "products",
            )

            # ------------------------------------------------------------------
            # Orders
            # ------------------------------------------------------------------
            print("Inserting orders...")
            order_ids = insert_returning(
                cur,
                "INSERT INTO orders (customer_id, status, created_at, updated_at) VALUES %s RETURNING id",
                generate_orders(n_orders, customer_ids),
                "orders",
            )

            # ------------------------------------------------------------------
            # Order items
            # ------------------------------------------------------------------
            print("Inserting order_items...")
            n_items = insert_batched(
                cur,
                "INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES (%s, %s, %s, %s)",
                generate_order_items(order_ids, product_ids),
                "order_items",
            )

            # ------------------------------------------------------------------
            # Inventory
            # ------------------------------------------------------------------
            print("Inserting inventory...")
            insert_batched(
                cur,
                """INSERT INTO inventory (product_id, warehouse_id, quantity, updated_at)
                   VALUES (%s, %s, %s, %s)
                   ON CONFLICT (product_id, warehouse_id) DO UPDATE
                     SET quantity   = EXCLUDED.quantity,
                         updated_at = EXCLUDED.updated_at""",
                generate_inventory(product_ids),
                "inventory",
            )

        print("\nData generation complete.")
        print(f"  customers : {len(customer_ids):,}")
        print(f"  products  : {len(product_ids):,}")
        print(f"  orders    : {len(order_ids):,}")
        print(f"  order_items: {n_items:,}")
        print(f"  inventory : {len(product_ids) * len(WAREHOUSES):,}")

        sync_raw_to_clickhouse()

    except Exception as exc:
        conn.rollback()
        print(f"\nERROR: {exc}", file=sys.stderr)
        sys.exit(1)
    finally:
        conn.close()


if __name__ == "__main__":
    main()
