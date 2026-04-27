#!/usr/bin/env python3
"""
Kappa Architecture Live Demo
Postgres → Materialize → Redpanda → ClickHouse

Shows real-time propagation of a price change through every layer of the
pipeline with timing measurements at each hop.

Requirements:
    pip install rich psycopg2-binary clickhouse-connect
"""

from __future__ import annotations

import math
import sys
import time
import random
from datetime import datetime
from typing import Any

import psycopg2
import psycopg2.extensions
import psycopg2.extras
import clickhouse_connect
from rich.console import Console
from rich.panel import Panel
from rich.table import Table
from rich.live import Live
from rich.columns import Columns
from rich.text import Text
from rich import box

# =============================================================================
# Configuration
# =============================================================================

PG_DSN = dict(host="localhost", port=5432, dbname="retail", user="postgres", password="postgres")
MZ_DSN = dict(host="localhost", port=6875, dbname="materialize", user="materialize")
CH_HOST = "localhost"
CH_PORT = 8123
CH_DB   = "retail"

console = Console()

# =============================================================================
# Connection helpers
# =============================================================================

def connect_postgres() -> psycopg2.extensions.connection:
    conn = psycopg2.connect(**PG_DSN)
    conn.autocommit = False
    return conn


def connect_materialize() -> psycopg2.extensions.connection:
    conn = psycopg2.connect(**MZ_DSN)
    conn.autocommit = True
    return conn


def connect_clickhouse() -> clickhouse_connect.driver.client.Client:
    return clickhouse_connect.get_client(host=CH_HOST, port=CH_PORT, database=CH_DB)


def fetchall_dict(cursor) -> list[dict[str, Any]]:
    cols = [d[0] for d in cursor.description]
    return [dict(zip(cols, row)) for row in cursor.fetchall()]


# =============================================================================
# Rich helpers
# =============================================================================

def section(title: str) -> None:
    console.print()
    console.rule(f"[bold cyan]{title}[/bold cyan]")


def ok(msg: str) -> None:
    console.print(f"[green]✓[/green]  {msg}")


def info(msg: str) -> None:
    console.print(f"[cyan]ℹ[/cyan]  {msg}")


def warn(msg: str) -> None:
    console.print(f"[yellow]⚠[/yellow]  {msg}")


def err(msg: str) -> None:
    console.print(f"[red]✗[/red]  {msg}", file=sys.stderr)


def format_latency(seconds: float) -> str:
    if seconds < 1:
        return f"{seconds * 1000:.0f} ms"
    return f"{seconds:.2f} s"


# =============================================================================
# Demo steps
# =============================================================================

def select_product(
    pg: psycopg2.extensions.connection,
    mz: psycopg2.extensions.connection,
) -> tuple[int, str, float, float]:
    """
    Pick a random product from order_detail and compute the planned new price (+20%).
    Returns (product_id, product_name, old_price, new_price).
    Does NOT write to Postgres — that happens in step1 after SUBSCRIBE is open.
    """
    cur_mz = mz.cursor()
    cur_mz.execute("SELECT DISTINCT product_id FROM order_detail LIMIT 50")
    product_ids = [r[0] for r in cur_mz.fetchall()]
    cur_mz.close()

    if not product_ids:
        err("No products found in order_detail — is seed data loaded?")
        sys.exit(1)

    product_id = random.choice(product_ids)

    cur_pg = pg.cursor()
    cur_pg.execute("SELECT name, price FROM products WHERE id = %s", (product_id,))
    row = cur_pg.fetchone()
    if row is None:
        err(f"Product {product_id} not found in Postgres.")
        sys.exit(1)
    cur_pg.close()

    product_name, old_price = row
    new_price = round(float(old_price) * 1.20, 2)
    return product_id, product_name, float(old_price), new_price


def open_subscribe(
    product_id: int,
) -> tuple[psycopg2.extensions.connection, psycopg2.extensions.cursor]:
    """
    Open a SUBSCRIBE cursor on order_detail for the given product_id.
    Must be called BEFORE the Postgres write so no CDC event is missed.

    Returns (sub_conn, sub_cur). Both must be kept alive until step2 completes;
    the caller is responsible for rollback + close in a finally block.

    psycopg2 defaults to autocommit=False, which keeps DECLARE and subsequent
    FETCH calls in a single implicit transaction — required for the server-side
    cursor to survive across multiple FETCH calls.
    """
    sub_conn = psycopg2.connect(**MZ_DSN)
    sub_cur  = sub_conn.cursor()
    # SERIALIZABLE (not the default STRICT SERIALIZABLE) lets Materialize serve
    # from the latest available snapshot rather than waiting for its internal
    # clock to advance to wall-clock time. Required for reliable SUBSCRIBE
    # behaviour after a large bulk load when the IVM backlog may lag wall clock.
    sub_cur.execute("SET transaction_isolation = 'serializable'")
    sub_cur.execute(
        "DECLARE sub CURSOR FOR SUBSCRIBE "
        "(SELECT current_price, product_name FROM order_detail WHERE product_id = %s)",
        (product_id,),
    )
    return sub_conn, sub_cur


def step1_price_change(
    pg: psycopg2.extensions.connection,
    product_id: int,
    product_name: str,
    old_price: float,
    new_price: float,
) -> datetime:
    """
    Write the price change to Postgres.
    SUBSCRIBE must already be open before this is called.
    """
    section("Step 1 — Simulate Price Change in Postgres")

    info(f"Selected product: [bold]{product_name}[/bold] (id={product_id})")
    info(f"Price change: [yellow]${old_price:.2f}[/yellow] → [green]${new_price:.2f}[/green] (+20%)")

    pg_update_time = datetime.utcnow()
    cur_pg = pg.cursor()
    cur_pg.execute("UPDATE products SET price = %s WHERE id = %s", (new_price, product_id))
    pg.commit()
    cur_pg.close()

    ok(f"Postgres updated at {pg_update_time.strftime('%H:%M:%S.%f')[:-3]} UTC")
    return pg_update_time


def step2_materialize_reflection(
    mz: psycopg2.extensions.connection,
    sub_cur: psycopg2.extensions.cursor,
    product_id: int,
    new_price: float,
) -> datetime | None:
    """
    Watch the pre-opened SUBSCRIBE cursor for the price change.

    sub_cur must have been obtained from open_subscribe() *before* the Postgres
    write in step1 — this ensures no CDC event is missed between the write and
    the cursor setup.

    Uses the DECLARE cursor FOR SUBSCRIBE … / FETCH ALL … WITH (TIMEOUT) pattern:
    each FETCH returns a finite batch at the current logical timestamp, so
    psycopg2's synchronous execute() handles it without modification.
    """
    section("Step 2 — Price Reflected in Materialize (order_detail)")
    info(f"Watching SUBSCRIBE on order_detail for product_id={product_id}...")

    mz_seen_time: datetime | None = None
    deadline = time.time() + 30

    while time.time() < deadline:
        remaining = deadline - time.time()
        if remaining <= 0:
            break
        sub_cur.execute("FETCH ALL sub WITH (TIMEOUT = '250ms')")
        for row in sub_cur.fetchall():
            # Columns: mz_timestamp, mz_diff (multiplicity), current_price, product_name
            # mz_diff > 0 = insertion, < 0 = retraction; may be > 1 when rows consolidate
            _ts, mz_diff, current_price, product_name = row
            if mz_diff > 0 and abs(float(current_price) - new_price) < 0.005:
                mz_seen_time = datetime.utcnow()
                console.print(
                    f"  [green]✓[/green]  {product_name}: "
                    f"current_price = [green]${float(current_price):.2f}[/green]"
                )
                break
        if mz_seen_time:
            break

    if mz_seen_time is None:
        warn("Materialize did not reflect the price change within 30s.")
        return None

    # Display a sample of the updated rows via the shared sync connection.
    display_cur = mz.cursor()
    display_cur.execute(
        "SELECT line_item_id, order_id, product_name, current_price, quantity "
        "FROM order_detail WHERE product_id = %s ORDER BY order_id DESC LIMIT 5",
        (product_id,),
    )
    rows = fetchall_dict(display_cur)
    display_cur.close()

    t = Table(
        title=f"order_detail — product_id {product_id} (updated price)",
        box=box.ROUNDED,
        header_style="bold magenta",
    )
    for col in ("line_item_id", "order_id", "product_name", "current_price", "quantity"):
        t.add_column(col)
    for r in rows:
        t.add_row(
            str(r["line_item_id"]),
            str(r["order_id"]),
            str(r.get("product_name", "")),
            f"[green]${float(r.get('current_price', 0)):.2f}[/green]",
            str(r.get("quantity", "")),
        )
    console.print(t)
    ok(f"Materialize reflected price at {mz_seen_time.strftime('%H:%M:%S.%f')[:-3]} UTC")
    return mz_seen_time


def step3_clickhouse_arrival(
    ch: clickhouse_connect.driver.client.Client,
    product_id: int,
    new_price: float,
) -> datetime | None:
    """
    Poll ClickHouse orders_enriched FINAL for the updated current_price.
    Returns first-seen time or None.
    """
    section("Step 3 — Price Arrival in ClickHouse (orders_enriched)")
    info(f"Polling ClickHouse every 500ms (up to 30s) for product_id={product_id}, current_price ≈ ${new_price:.2f}...")

    deadline = time.time() + 30
    ch_seen_time: datetime | None = None
    rows: list[dict] = []

    while time.time() < deadline:
        result = ch.query(
            """
            SELECT
                order_id,
                product_name,
                current_price,
                quantity,
                order_created_at
            FROM retail.orders_enriched FINAL
            WHERE product_id = %(product_id)s
            ORDER BY order_created_at DESC
            LIMIT 5
            """,
            parameters={"product_id": product_id},
        )
        rows = [dict(zip(result.column_names, row)) for row in result.result_rows]

        if rows:
            sample_price = float(rows[0].get("current_price", 0))
            if abs(sample_price - new_price) < 0.005:
                ch_seen_time = datetime.utcnow()
                break

        remaining = int(deadline - time.time())
        current = rows[0]["current_price"] if rows else "no data"
        console.print(
            f"  [yellow]waiting...[/yellow] ({remaining}s remaining, "
            f"current_price={current})"
        )
        time.sleep(0.5)

    if ch_seen_time is None:
        warn("ClickHouse did not reflect the price change within 30s.")
        if rows:
            info("Last seen rows (price not yet updated):")
        else:
            info("No rows found for this product in ClickHouse yet.")
        return None

    t = Table(
        title=f"orders_enriched FINAL — product_id {product_id} (updated price)",
        box=box.ROUNDED,
        header_style="bold magenta",
    )
    for col in ("order_id", "product_name", "current_price", "quantity", "order_created_at"):
        t.add_column(col)
    for r in rows:
        t.add_row(
            str(r["order_id"]),
            str(r.get("product_name", "")),
            f"[green]${float(r.get('current_price', 0)):.2f}[/green]",
            str(r.get("quantity", "")),
            str(r.get("order_created_at", "")),
        )
    console.print(t)
    ok(f"ClickHouse confirmed price at {ch_seen_time.strftime('%H:%M:%S.%f')[:-3]} UTC")
    return ch_seen_time


def _log_pos(ms: float, max_log: float, width: int) -> int:
    if ms <= 0:
        return 0
    return min(width, round(math.log10(max(ms, 0.5)) / max_log * width))


def render_freshness_bars(
    mz_lag_s: float,
    ch_lag_s: float,
    bar_width: int = 46,
) -> None:
    """
    Horizontal log₁₀-scaled bar showing data freshness lag for each system.
    Postgres is always 0 (writes are immediately visible to co-located readers).
    Materialize and ClickHouse lag are the propagation times measured this run.
    See `make bench` for the full reaction time chart that adds query response time.
    """
    mz_ms = mz_lag_s * 1000
    ch_ms = ch_lag_s * 1000
    max_ms  = max(ch_ms, 1.0)
    max_log = math.log10(max_ms)

    console.print()
    console.rule(
        "[bold cyan]Data Freshness — time until a write is visible (log₁₀ ms scale, each step = 10×)[/bold cyan]"
    )
    console.print()

    rows = [
        ("Postgres",    0.0,   "blue"),
        ("Materialize", mz_ms, "green"),
        ("ClickHouse",  ch_ms, "cyan"),
    ]
    name_col = max(len(n) for n, *_ in rows)

    for sys_name, fresh_ms, color in rows:
        chars = _log_pos(fresh_ms, max_log, bar_width)
        if fresh_ms <= 0:
            bar_str = "[dim](0 — writes are immediately visible)[/dim]"
            label   = ""
        else:
            bar_str = f"[{color}]{'█' * chars}[/{color}]"
            label   = f"  [dim]{format_latency(fresh_ms / 1000)}[/dim]"
        console.print(f"  {sys_name:<{name_col}}  {bar_str}{label}")

    # Axis ticks
    tick_line  = [" "] * bar_width
    label_line = [" "] * (bar_width + 8)
    for exp in range(5):
        ms  = 10 ** exp
        pos = _log_pos(ms, max_log, bar_width)
        if pos >= bar_width:
            break
        tick_line[pos] = "|"
        lbl = f"{ms}ms" if ms < 1000 else f"{ms // 1000}s"
        for i, ch in enumerate(lbl):
            if pos + i < len(label_line):
                label_line[pos + i] = ch

    indent = "  " + " " * name_col + "  "
    console.print(indent + "".join(tick_line))
    console.print(indent + "".join(label_line))
    console.print()
    console.print(
        "  [dim]Run [bold]make bench[/bold] for the full reaction time chart "
        "(freshness lag + query response time per query).[/dim]"
    )


def step4_summary(
    product_id: int,
    old_price: float,
    new_price: float,
    pg_time: datetime,
    mz_time: datetime | None,
    ch_time: datetime | None,
) -> None:
    section("Step 4 — End-to-End Propagation Summary")

    t = Table(
        title="Price Change Propagation Timeline",
        box=box.DOUBLE_EDGE,
        header_style="bold white",
        show_lines=True,
    )
    t.add_column("Layer",           style="bold")
    t.add_column("Event",           style="dim")
    t.add_column("Timestamp (UTC)", style="cyan")
    t.add_column("Latency",         justify="right")

    t.add_row(
        "PostgreSQL",
        f"UPDATE products SET price={new_price} (was {old_price})",
        pg_time.strftime("%H:%M:%S.%f")[:-3],
        "[dim]baseline[/dim]",
    )

    if mz_time:
        mz_lag = (mz_time - pg_time).total_seconds()
        t.add_row(
            "Materialize",
            "order_detail.current_price reflected",
            mz_time.strftime("%H:%M:%S.%f")[:-3],
            f"[yellow]+{format_latency(mz_lag)}[/yellow]",
        )
    else:
        t.add_row("Materialize", "order_detail.current_price reflected", "[red]timeout[/red]", "[red]>30s[/red]")

    if ch_time:
        ch_lag = (ch_time - pg_time).total_seconds()
        ch_from_mz = (ch_time - mz_time).total_seconds() if mz_time else None
        extra = f"  (+{format_latency(ch_from_mz)} from Materialize)" if ch_from_mz else ""
        t.add_row(
            "ClickHouse",
            "orders_enriched FINAL.current_price reflected",
            ch_time.strftime("%H:%M:%S.%f")[:-3],
            f"[green]+{format_latency(ch_lag)}[/green]{extra}",
        )
    else:
        t.add_row("ClickHouse", "orders_enriched.current_price reflected", "[red]timeout[/red]", "[red]>30s[/red]")

    console.print(t)

    arch = Text.assemble(
        ("PostgreSQL", "bold blue"),
        (" ──[CDC/pgx]──► ", "dim"),
        ("Materialize", "bold magenta"),
        (" ──[Kafka sink]──► ", "dim"),
        ("Redpanda", "bold yellow"),
        (" ──[Kafka engine]──► ", "dim"),
        ("ClickHouse", "bold green"),
    )
    console.print(Panel(arch, title="Kappa Architecture Data Flow", border_style="cyan"))

    if mz_time and ch_time:
        render_freshness_bars(
            mz_lag_s=(mz_time - pg_time).total_seconds(),
            ch_lag_s=(ch_time - pg_time).total_seconds(),
        )


def restore_price(pg: psycopg2.extensions.connection, product_id: int, old_price: float) -> None:
    section("Cleanup — Restoring Original Price")
    cur = pg.cursor()
    cur.execute("UPDATE products SET price = %s WHERE id = %s", (old_price, product_id))
    pg.commit()
    cur.close()
    ok(f"Restored product_id={product_id} price to ${old_price:.2f}")


# =============================================================================
# Main
# =============================================================================

def main() -> None:
    console.print(Panel.fit(
        "[bold cyan]Kappa Architecture Live Demo[/bold cyan]\n"
        "[dim]Postgres → Materialize → Redpanda → ClickHouse[/dim]",
        border_style="cyan",
    ))

    section("Connecting to services")

    try:
        pg = connect_postgres()
        ok("PostgreSQL   localhost:5432")
    except Exception as exc:
        err(f"Cannot connect to PostgreSQL: {exc}")
        sys.exit(1)

    try:
        mz = connect_materialize()
        ok("Materialize  localhost:6875")
    except Exception as exc:
        err(f"Cannot connect to Materialize: {exc}")
        sys.exit(1)

    try:
        ch = connect_clickhouse()
        ok("ClickHouse   localhost:8123")
    except Exception as exc:
        err(f"Cannot connect to ClickHouse: {exc}")
        sys.exit(1)

    product_id: int   = -1
    old_price:  float = 0.0
    sub_conn:   psycopg2.extensions.connection | None = None
    sub_cur:    psycopg2.extensions.cursor     | None = None

    try:
        section("Setup — Select product and open SUBSCRIBE")
        product_id, product_name, old_price, new_price = select_product(pg, mz)
        info(f"Selected product: [bold]{product_name}[/bold] (id={product_id})")
        info(f"Planned price change: [yellow]${old_price:.2f}[/yellow] → [green]${new_price:.2f}[/green] (+20%)")
        sub_conn, sub_cur = open_subscribe(product_id)
        ok(f"SUBSCRIBE open on order_detail — waiting for product_id={product_id}")

        pg_time = step1_price_change(pg, product_id, product_name, old_price, new_price)
        mz_time = step2_materialize_reflection(mz, sub_cur, product_id, new_price)
        ch_time = step3_clickhouse_arrival(ch, product_id, new_price)
        step4_summary(product_id, old_price, new_price, pg_time, mz_time, ch_time)

    except KeyboardInterrupt:
        console.print("\n[yellow]Interrupted by user.[/yellow]")
    finally:
        if sub_conn is not None:
            try:
                sub_conn.rollback()
            except Exception:
                pass
            try:
                sub_conn.close()
            except Exception:
                pass

        if product_id != -1 and old_price != 0.0:
            try:
                restore_price(pg, product_id, old_price)
            except Exception as exc:
                warn(f"Could not restore price: {exc}")

        pg.close()
        mz.close()
        ch.close()
        ok("All connections closed. Demo complete.")


if __name__ == "__main__":
    main()
