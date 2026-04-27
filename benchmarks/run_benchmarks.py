#!/usr/bin/env python3
"""
run_benchmarks.py — run all benchmark queries against Postgres, Materialize,
ClickHouse (via Materialize), and ClickHouse (optimized — Debezium CDC +
ClickHouse-native pre-computation).

Usage:
    python benchmarks/run_benchmarks.py [--runs N]

Requires: psycopg2-binary, clickhouse-connect, rich
"""
from __future__ import annotations

import argparse
import math
import random
import statistics
import time
from pathlib import Path

import clickhouse_connect
import psycopg2
import psycopg2.extras
from rich import box
from rich.console import Console
from rich.rule import Rule
from rich.table import Table
from rich.text import Text

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

QUERIES_DIR = Path(__file__).parent / "queries"

OPERATIONAL_QUERIES = [
    ("Inventory lookup (by SKU)",                      "operational/inventory_lookup"),
    ("Customer orders + lifetime metrics (all time)",  "operational/customer_orders"),
    ("Product performance (by SKU)",                   "operational/product_performance"),
]

ANALYTICAL_QUERIES = [
    ("Revenue histogram ($50 buckets, 90 d)", "analytical/revenue_histogram"),
    ("Revenue by category × tier × dow",      "analytical/cross_dimensional"),
    ("Cohort retention (30/60/90 d)",          "analytical/cohort_retention"),
]

DEFAULT_RUNS = 10

DISPLAY_NAMES = {
    "Postgres":             "Postgres",
    "Materialize":          "Materialize",
    "ClickHouse":           "ClickHouse (via Materialize)",
    "ClickHouse Optimized": "ClickHouse (optimized)",
}

# ---------------------------------------------------------------------------
# Connection helpers
# ---------------------------------------------------------------------------

def pg_connect(dsn: dict):
    return psycopg2.connect(**dsn)


def mz_connect(dsn: dict):
    conn = psycopg2.connect(**dsn)
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute("SET cluster = transform_sink_cluster")
    # SERIALIZABLE lets Materialize serve from the latest available snapshot
    # rather than waiting for the frontier to advance to wall-clock time.
    cur.execute("SET transaction_isolation = 'serializable'")
    cur.close()
    return conn


def ch_connect(dsn: dict):
    return clickhouse_connect.get_client(**dsn)


PG_DSN = dict(host="localhost", port=5432,  dbname="retail",      user="postgres",    password="postgres")
MZ_DSN = dict(host="localhost", port=6875,  dbname="materialize", user="materialize")
CH_DSN = dict(host="localhost", port=8123,  database="retail",    username="default")

# ---------------------------------------------------------------------------
# Query loading
# ---------------------------------------------------------------------------

def load_sql(subpath: str, system: str) -> str:
    p = QUERIES_DIR / subpath / f"{system}.sql"
    return p.read_text()


# ---------------------------------------------------------------------------
# Timing helpers
# ---------------------------------------------------------------------------

def time_pg(conn, sql: str, params: dict) -> float:
    cur = conn.cursor()
    t0 = time.perf_counter()
    cur.execute(sql, params)
    cur.fetchall()
    return time.perf_counter() - t0


def time_ch(client, sql: str, params: dict) -> float:
    # clickhouse-connect rejects trailing semicolons as multi-statement queries
    t0 = time.perf_counter()
    client.query(sql.rstrip().rstrip(";"), parameters=params)
    return time.perf_counter() - t0


def _percentile(sorted_ms: list[float], pct: float) -> float:
    n = len(sorted_ms)
    k = (n - 1) * pct / 100
    lo = int(k)
    frac = k - lo
    if lo >= n - 1:
        return sorted_ms[-1]
    return sorted_ms[lo] * (1 - frac) + sorted_ms[lo + 1] * frac


def compute_stats(times_sec: list[float]) -> dict:
    ms = sorted(t * 1000 for t in times_sec)
    return {
        "avg": statistics.mean(ms),
        "p90": _percentile(ms, 90),
        "max": ms[-1],
    }


def fmt_ms(ms: float) -> str:
    if ms < 1:
        return f"{ms:.2f} ms"
    if ms < 1000:
        return f"{ms:.1f} ms"
    return f"{ms / 1000:.2f} s"


def fmt_qps(avg_ms: float) -> str:
    q = 1000.0 / avg_ms if avg_ms > 0 else 0
    if q >= 1000:
        return f"{q / 1000:.1f}k QPS"
    return f"{q:.0f} QPS"


def fmt_cell(stats: dict, is_winner: bool) -> Text:
    t = Text()
    if is_winner:
        t.append(f"{fmt_ms(stats['avg'])}  {fmt_qps(stats['avg'])}", style="bold green")
        t.append(" ✓", style="green")
    else:
        t.append(f"{fmt_ms(stats['avg'])}  {fmt_qps(stats['avg'])}")
    t.append(f"\np90 {fmt_ms(stats['p90'])}  max {fmt_ms(stats['max'])}", style="dim")
    return t


# ---------------------------------------------------------------------------
# Cluster readiness
# ---------------------------------------------------------------------------

_CPU_SETTLE_THRESHOLD = 200
_CPU_SETTLE_SAMPLES   = 3
_POLL_INTERVAL_S      = 2.0


def wait_for_cluster_ready(mz_conn, console) -> None:
    cur = mz_conn.cursor()

    console.print("  [dim]Waiting for indexes to hydrate...[/dim]", end="")
    while True:
        cur.execute("""
            SELECT COUNT(*) FROM mz_internal.mz_hydration_statuses h
            JOIN mz_objects o ON h.object_id = o.id
            WHERE h.hydrated = false
              AND o.type = 'index'
              AND o.id NOT LIKE 's%%'
        """)
        unhydrated = cur.fetchone()[0]
        if unhydrated == 0:
            break
        console.print(f" [{unhydrated} remaining]", end="")
        time.sleep(_POLL_INTERVAL_S)
    console.print(" [dim]done.[/dim]")

    console.print("  [dim]Waiting for transform_sink_cluster to settle...[/dim]", end="")
    settled = 0
    while settled < _CPU_SETTLE_SAMPLES:
        cur.execute("""
            SELECT u.cpu_percent, u.memory_percent,
                   m.memory_bytes / 1024 / 1024 AS memory_mb
            FROM mz_internal.mz_cluster_replica_utilization u
            JOIN mz_cluster_replicas r ON u.replica_id = r.id
            JOIN mz_clusters c ON r.cluster_id = c.id
            JOIN mz_internal.mz_cluster_replica_metrics m ON m.replica_id = r.id
            WHERE c.name = 'transform_sink_cluster'
        """)
        row = cur.fetchone()
        cpu    = float(row[0] or 0) if row else 0.0
        mem_mb = float(row[2] or 0) if row else 0.0
        if cpu < _CPU_SETTLE_THRESHOLD:
            settled += 1
            console.print(f" [CPU {cpu:.0f}% MEM {mem_mb:.0f} MB]", end="")
        else:
            settled = 0
            console.print(f" [dim][CPU {cpu:.0f}% — settling][/dim]", end="")
        if settled < _CPU_SETTLE_SAMPLES:
            time.sleep(_POLL_INTERVAL_S)
    console.print(" [dim]ready.[/dim]")

    console.print("  [dim]Waiting for materialization lag to reach steady-state...[/dim]", end="")
    while True:
        cur.execute("""
            SELECT COALESCE(MAX(EXTRACT(EPOCH FROM global_lag)), 0)
            FROM mz_internal.mz_materialization_lag
            WHERE object_id NOT LIKE 's%%'
        """)
        max_lag_s = cur.fetchone()[0] or 0.0
        if max_lag_s <= 1.0:
            break
        console.print(f" [dim][{max_lag_s:.1f} s behind][/dim]", end="")
        time.sleep(_POLL_INTERVAL_S)
    console.print(f" [dim]done ({max_lag_s * 1000:.0f} ms).[/dim]")

    cur.close()


# ---------------------------------------------------------------------------
# Data freshness measurement
# ---------------------------------------------------------------------------

def measure_freshness(pg_conn, mz_conn, ch_client, run_optimized: bool, console) -> tuple[float, float, float]:
    """
    Measure how long after a Postgres commit it takes for data to appear in
    Materialize, ClickHouse (via Materialize), and ClickHouse (optimized/Debezium).

    Returns (mz_ms, ch_via_mz_ms, cho_ms).
    cho_ms is measured by watching opt_products for the canary product_id.
    """
    canary_sku = f"CANARY-{random.randint(100_000, 999_999)}"
    canary_pid: int | None = None
    sub_conn:   psycopg2.extensions.connection | None = None
    pg_fresh:   psycopg2.extensions.connection | None = None

    try:
        pg_fresh = psycopg2.connect(**PG_DSN)
        cur      = pg_fresh.cursor()

        cur.execute(
            "INSERT INTO products (sku, name, category, price, cost) "
            "VALUES (%s, %s, %s, %s, %s) RETURNING id",
            (canary_sku, "Freshness Canary", "Test", 0.01, 0.01),
        )
        canary_pid = cur.fetchone()[0]
        cur.execute(
            "INSERT INTO inventory (product_id, warehouse_id, quantity, updated_at) "
            "VALUES (%s, %s, %s, NOW())",
            (canary_pid, "1", 1),
        )

        sub_conn = psycopg2.connect(**MZ_DSN)
        sub_cur  = sub_conn.cursor()
        sub_cur.execute("SET cluster = transform_sink_cluster")
        sub_cur.execute("SET transaction_isolation = 'serializable'")
        sub_cur.execute(
            "DECLARE sub CURSOR FOR SUBSCRIBE "
            "(SELECT 1 FROM inventory_position WHERE product_id = %s)",
            (canary_pid,),
        )

        console.print("  [dim]Measuring CDC freshness...[/dim]", end="")

        t0 = time.perf_counter()
        pg_fresh.commit()
        deadline = t0 + 30.0

        mz_ms: float | None = None
        while time.perf_counter() < deadline and mz_ms is None:
            sub_cur.execute("FETCH ALL sub WITH (TIMEOUT = '250ms')")
            for row in sub_cur.fetchall():
                if row[1] > 0:
                    mz_ms = (time.perf_counter() - t0) * 1000
                    break

        ch_ms: float | None = None
        while time.perf_counter() < deadline and ch_ms is None:
            r = ch_client.query(
                "SELECT 1 FROM retail.inventory_snapshots "
                "WHERE product_id = %(pid)s LIMIT 1",
                parameters={"pid": canary_pid},
            )
            if r.result_rows:
                ch_ms = (time.perf_counter() - t0) * 1000
            elif time.perf_counter() < deadline:
                time.sleep(0.25)

        cho_ms: float | None = None
        if run_optimized:
            while time.perf_counter() < deadline and cho_ms is None:
                r = ch_client.query(
                    "SELECT 1 FROM retail.opt_products "
                    "WHERE id = %(pid)s LIMIT 1",
                    parameters={"pid": canary_pid},
                )
                if r.result_rows:
                    cho_ms = (time.perf_counter() - t0) * 1000
                elif time.perf_counter() < deadline:
                    time.sleep(0.25)

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
        if pg_fresh is not None and canary_pid is not None:
            try:
                cur.execute("DELETE FROM inventory WHERE product_id = %s", (canary_pid,))
                cur.execute("DELETE FROM products  WHERE id = %s",         (canary_pid,))
                pg_fresh.commit()
            except Exception:
                pass
            pg_fresh.close()

    mz_result  = mz_ms  or 30_000.0
    ch_result  = ch_ms  or 30_000.0
    cho_result = cho_ms or 30_000.0

    summary = (
        f"  [dim]Materialize: {fmt_ms(mz_result)}, "
        f"ClickHouse (via Materialize): {fmt_ms(ch_result)}"
    )
    if run_optimized:
        summary += f", ClickHouse (optimized/Debezium): {fmt_ms(cho_result)}"
    summary += "[/dim]"
    console.print(summary)

    return mz_result, ch_result, cho_result


# ---------------------------------------------------------------------------
# Reaction time chart (log₁₀ scale)
# ---------------------------------------------------------------------------

def _log_pos(ms: float, max_log: float, width: int) -> int:
    if ms <= 0:
        return 0
    return min(width, round(math.log10(max(ms, 0.5)) / max_log * width))


def render_reaction_chart(
    console,
    title: str,
    query_names: list[str],
    pg_ms: list[float],
    mz_ms: list[float],
    ch_ms: list[float],
    fresh_mz_ms: float,
    fresh_ch_ms: float,
    bar_width: int = 46,
    cho_ms: list[float] | None = None,
    cho_cdc_ms: float = 0.0,
    cho_batch_ms: list[float] | None = None,
) -> None:
    """Render a log-scaled reaction-time bar chart.

    cho_batch_ms: per-query average batch scheduling wait for ClickHouse
    optimized (refresh_interval / 2). None means no batch layer (raw CDC only).
    Rendered as a distinct ▒ segment between CDC lag (░) and response (█).
    """
    PG_FRESH = 0.0

    systems = [
        ("Postgres",                     PG_FRESH,    pg_ms),
        ("Materialize",                  fresh_mz_ms, mz_ms),
        ("ClickHouse (via Materialize)", fresh_ch_ms, ch_ms),
    ]

    cho_batch = cho_batch_ms or ([0.0] * len(cho_ms) if cho_ms else [])

    max_total = max(
        fresh + resp
        for _, fresh, resp_list in systems
        for resp in resp_list
    )
    if cho_ms is not None:
        for resp, batch in zip(cho_ms, cho_batch):
            max_total = max(max_total, cho_cdc_ms + batch + resp)
    max_log = math.log10(max(max_total, 1.0))

    has_batch = cho_ms is not None and cho_batch_ms is not None

    all_names = [n for n, *_ in systems] + (["ClickHouse (optimized)"] if cho_ms is not None else [])
    name_col  = max(len(n) for n in all_names)

    console.print()
    console.print(Rule(
        f" {title} — Reaction time (log₁₀ ms scale, each step = 10×) ",
        style="dim",
    ))
    console.print()
    console.print("  [dim]░░░ freshness lag (time until data reflects the latest write)[/dim]")
    if has_batch:
        console.print("  [dim]▒▒▒ avg batch scheduling wait (refresh_interval ÷ 2)[/dim]")
    console.print("  [dim]███ query response time (measured by this benchmark)[/dim]")
    console.print()

    for q_idx, q_name in enumerate(query_names):
        console.print(f"  [bold]{q_name}[/bold]")

        for sys_name, fresh_ms, resp_list in systems:
            resp_ms  = resp_list[q_idx]
            total_ms = fresh_ms + resp_ms

            total_chars = _log_pos(total_ms, max_log, bar_width)
            fresh_chars = round(total_chars * fresh_ms / total_ms) if total_ms > 0 else 0
            resp_chars  = total_chars - fresh_chars

            bar = Text()
            if fresh_chars > 0:
                bar.append("░" * fresh_chars, style="dim yellow")
            if resp_chars > 0:
                bar.append("█" * resp_chars)

            label = (
                f"  {fmt_ms(fresh_ms)} fresh"
                f" + {fmt_ms(resp_ms)} response"
                f" = {fmt_ms(total_ms)}"
            )
            row = Text()
            row.append(f"    {sys_name:<{name_col}}  ")
            row.append_text(bar)
            row.append(" " * (bar_width - total_chars))
            row.append(label, style="dim")
            console.print(row)

        if cho_ms is not None:
            resp_ms  = cho_ms[q_idx]
            batch_ms = cho_batch[q_idx]
            total_ms = cho_cdc_ms + batch_ms + resp_ms

            total_chars = _log_pos(total_ms, max_log, bar_width)
            if total_ms > 0:
                cdc_chars   = round(total_chars * cho_cdc_ms / total_ms)
                batch_chars = round(total_chars * batch_ms   / total_ms)
                resp_chars  = total_chars - cdc_chars - batch_chars
            else:
                cdc_chars = batch_chars = resp_chars = 0

            bar = Text()
            if cdc_chars > 0:
                bar.append("░" * cdc_chars,   style="dim yellow")
            if batch_chars > 0:
                bar.append("▒" * batch_chars, style="dim cyan")
            if resp_chars > 0:
                bar.append("█" * resp_chars)

            if batch_ms > 0:
                label = (
                    f"  {fmt_ms(cho_cdc_ms)} CDC"
                    f" + {fmt_ms(batch_ms)} avg batch"
                    f" + {fmt_ms(resp_ms)} resp"
                    f" = {fmt_ms(total_ms)}"
                )
            else:
                label = (
                    f"  {fmt_ms(cho_cdc_ms)} fresh"
                    f" + {fmt_ms(resp_ms)} response"
                    f" = {fmt_ms(total_ms)}"
                )
            row = Text()
            row.append(f"    {'ClickHouse (optimized)':<{name_col}}  ")
            row.append_text(bar)
            row.append(" " * (bar_width - total_chars))
            row.append(label, style="dim")
            console.print(row)

        console.print()

    prefix_width = 4 + name_col + 2
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

    indent = " " * prefix_width
    console.print(indent + "".join(tick_line))
    console.print(indent + "".join(label_line))
    console.print()



# ---------------------------------------------------------------------------
# Sampling
# ---------------------------------------------------------------------------

def sample_params(pg_conn) -> dict:
    cur = pg_conn.cursor()

    cur.execute("""
        SELECT customer_id FROM orders
        GROUP BY customer_id ORDER BY COUNT(*) DESC LIMIT 1
    """)
    customer_id = cur.fetchone()[0]

    cur.execute("SELECT id FROM orders ORDER BY id LIMIT 1")
    order_id = cur.fetchone()[0]

    cur.execute("SELECT sku FROM products ORDER BY id LIMIT 1")
    sku = cur.fetchone()[0]

    cur.execute("""
        SELECT warehouse_id FROM inventory
        GROUP BY warehouse_id ORDER BY COUNT(*) DESC LIMIT 1
    """)
    warehouse_id = cur.fetchone()[0]

    return dict(customer_id=customer_id, order_id=order_id, sku=sku, warehouse_id=warehouse_id)


def db_counts(pg_conn) -> dict:
    cur = pg_conn.cursor()
    cur.execute("SELECT COUNT(*) FROM orders")
    orders = cur.fetchone()[0]
    cur.execute("SELECT COUNT(*) FROM order_items")
    items = cur.fetchone()[0]
    cur.execute("SELECT COUNT(*) FROM customers")
    customers = cur.fetchone()[0]
    return dict(orders=orders, items=items, customers=customers)


# ---------------------------------------------------------------------------
# Optimized readiness check
# ---------------------------------------------------------------------------

def check_optimized_ready(ch_client, console, timeout_s: int = 120) -> bool:
    """Wait up to timeout_s for Debezium to populate opt_products, then return True/False."""
    deadline = time.perf_counter() + timeout_s
    first = True
    while time.perf_counter() < deadline:
        try:
            count = ch_client.query(
                "SELECT count() FROM retail.opt_products"
            ).result_rows[0][0]
            if count > 0:
                if not first:
                    console.print(" [dim]done.[/dim]")
                return True
        except Exception:
            pass
        if first:
            console.print(
                "  [dim]Waiting for Debezium snapshot to populate opt_products...[/dim]",
                end="",
            )
            first = False
        console.print(" [dim]·[/dim]", end="")
        time.sleep(3)
    if not first:
        console.print(" [dim]timed out.[/dim]")
    return False


# ---------------------------------------------------------------------------
# Benchmark runner
# ---------------------------------------------------------------------------

def run_query_suite(
    label: str,
    query_list: list[tuple[str, str]],
    pg_conn,
    mz_conn,
    ch_client,
    run_optimized: bool,
    params: dict,
    runs: int,
    console: Console,
) -> tuple[list[str], list[float], list[float], list[float], list[float]]:
    table = Table(
        box=box.SIMPLE_HEAD,
        show_header=True,
        header_style="bold cyan",
        padding=(0, 1),
    )
    table.add_column("Query",                         style="bold",    min_width=34)
    table.add_column("Postgres",                      justify="right", min_width=20, no_wrap=True)
    table.add_column("Materialize",                   justify="right", min_width=20, no_wrap=True)
    table.add_column("ClickHouse\n(via Materialize)",  justify="right", min_width=20, no_wrap=True)
    if run_optimized:
        table.add_column("ClickHouse\n(optimized)",   justify="right", min_width=20, no_wrap=True)
    table.add_column("Fastest\nresponse",             justify="left",  min_width=22, no_wrap=True)

    names: list[str] = []
    pg_avgs, mz_avgs, ch_avgs, cho_avgs = [], [], [], []

    n_queries = len(query_list)
    for q_num, (name, subpath) in enumerate(query_list, 1):
        pg_sql  = load_sql(subpath, "postgres")
        mz_sql  = load_sql(subpath, "materialize")
        ch_sql  = load_sql(subpath, "clickhouse")
        cho_sql_path = QUERIES_DIR / subpath / "clickhouse_optimized.sql"
        cho_sql = cho_sql_path.read_text() if run_optimized and cho_sql_path.exists() else ""

        pg_times, mz_times, ch_times, cho_times = [], [], [], []
        extra = " / cho" if (run_optimized and cho_sql) else ""
        for run_i in range(runs):
            console.print(
                f"  [dim]query {q_num}/{n_queries}  run {run_i + 1}/{runs}  "
                f"pg / mz / ch{extra}...[/dim]",
                end="\r",
            )
            pg_times.append(time_pg(pg_conn, pg_sql, params))
            mz_times.append(time_pg(mz_conn, mz_sql, params))
            ch_times.append(time_ch(ch_client, ch_sql, params))
            if run_optimized and cho_sql:
                cho_times.append(time_ch(ch_client, cho_sql, params))
        console.print(" " * 80, end="\r")

        pg_s  = compute_stats(pg_times)
        mz_s  = compute_stats(mz_times)
        ch_s  = compute_stats(ch_times)
        cho_s = compute_stats(cho_times) if cho_times else None

        names.append(name)
        pg_avgs.append(pg_s["avg"])
        mz_avgs.append(mz_s["avg"])
        ch_avgs.append(ch_s["avg"])
        cho_avgs.append(cho_s["avg"] if cho_s else 0.0)

        best = min(
            pg_s["avg"], mz_s["avg"], ch_s["avg"],
            *(([cho_s["avg"]] if cho_s else [])),
        )
        row_cells = [
            name,
            fmt_cell(pg_s,  pg_s["avg"]  == best),
            fmt_cell(mz_s,  mz_s["avg"]  == best),
            fmt_cell(ch_s,  ch_s["avg"]  == best),
        ]
        if run_optimized:
            row_cells.append(fmt_cell(cho_s, cho_s is not None and cho_s["avg"] == best) if cho_s else Text("—"))
        # Name the fastest-response system and its time — no speedup ratio, since
        # response time is only one ingredient in total reaction time (freshness + response).
        avgs_for_best = {
            "Postgres":   pg_s["avg"],
            "Materialize": mz_s["avg"],
            "ClickHouse (via Materialize)": ch_s["avg"],
        }
        if cho_s:
            avgs_for_best["ClickHouse (optimized)"] = cho_s["avg"]
        fastest_name = min(avgs_for_best, key=avgs_for_best.__getitem__)
        fastest_ms   = avgs_for_best[fastest_name]
        row_cells.append(Text(f"{fastest_name}\n{fmt_ms(fastest_ms)} response", style="dim"))
        table.add_row(*row_cells)

    console.print(Rule(f" {label} ", style="dim"))
    console.print(table)
    return names, pg_avgs, mz_avgs, ch_avgs, cho_avgs


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="Run Kappa architecture benchmarks")
    parser.add_argument("--runs", type=int, default=DEFAULT_RUNS,
                        help=f"Number of timed executions per query (default: {DEFAULT_RUNS})")
    args = parser.parse_args()
    runs = args.runs

    console = Console(width=190)

    console.print()
    console.print("[bold]Connecting to databases...[/bold]")

    pg_conn   = pg_connect(PG_DSN)
    mz_conn   = mz_connect(MZ_DSN)
    ch_client = ch_connect(CH_DSN)

    run_optimized = check_optimized_ready(ch_client, console)
    if not run_optimized:
        console.print(
            "  [yellow]ClickHouse optimized tables still empty after 120 s — "
            "check Debezium connector status at http://localhost:8084/connectors[/yellow]"
        )

    counts = db_counts(pg_conn)
    params = sample_params(pg_conn)

    console.print(
        f"\n[bold yellow]"
        f"{'=' * 70}\n"
        f"  BENCHMARK: {counts['orders']:,} orders, "
        f"{counts['items']:,} order items, "
        f"{counts['customers']:,} customers  ({runs} runs each)\n"
        f"{'=' * 70}"
        f"[/bold yellow]\n"
    )
    console.print(
        f"  Sampling params — customer_id=[cyan]{params['customer_id']}[/cyan]  "
        f"order_id=[cyan]{params['order_id']}[/cyan]  "
        f"sku=[cyan]{params['sku']}[/cyan]\n"
    )

    wait_for_cluster_ready(mz_conn, console)
    console.print()

    fresh_mz_ms, fresh_ch_ms, fresh_cho_ms = measure_freshness(
        pg_conn, mz_conn, ch_client, run_optimized, console
    )
    console.print()

    op_names, op_pg, op_mz, op_ch, op_cho = run_query_suite(
        "OPERATIONAL QUERIES (pre-indexed data products)",
        OPERATIONAL_QUERIES,
        pg_conn, mz_conn, ch_client, run_optimized,
        params, runs, console,
    )

    an_names, an_pg, an_mz, an_ch, an_cho = run_query_suite(
        "AD-HOC ANALYTICAL QUERIES (ClickHouse columnar scan on Materialize-enriched flat table)",
        ANALYTICAL_QUERIES,
        pg_conn, mz_conn, ch_client, run_optimized,
        params, runs, console,
    )

    # Per-query avg batch wait (refresh_interval / 2) for ClickHouse optimized.
    # Operational: inventory=raw CDC (0), customer_orders=customer_rank (1s/2),
    #              product_performance=product_category_rank (5s/2)
    # Analytical:  revenue_histogram=opt_order_totals (30s/2),
    #              cross_dimensional=opt_sales_by_dim (30s/2),
    #              cohort_retention=opt_order_totals (30s/2)
    op_batch_ms = [0.0, 500.0, 2500.0]
    an_batch_ms = [15_000.0, 15_000.0, 15_000.0]

    render_reaction_chart(
        console, "OPERATIONAL QUERIES",
        op_names, op_pg, op_mz, op_ch,
        fresh_mz_ms, fresh_ch_ms,
        cho_ms=op_cho if run_optimized else None,
        cho_cdc_ms=fresh_cho_ms,
        cho_batch_ms=op_batch_ms if run_optimized else None,
    )
    render_reaction_chart(
        console, "ANALYTICAL QUERIES",
        an_names, an_pg, an_mz, an_ch,
        fresh_mz_ms, fresh_ch_ms,
        cho_ms=an_cho if run_optimized else None,
        cho_cdc_ms=fresh_cho_ms,
        cho_batch_ms=an_batch_ms if run_optimized else None,
    )

    def _conclude(pg_avgs, mz_avgs, ch_avgs, cho_avgs, fresh_mz, fresh_ch, fresh_cho):
        totals = {
            "Postgres":    (sum(pg_avgs),  0.0,       "blue"),
            "Materialize": (sum(mz_avgs),  fresh_mz,  "purple"),
            "ClickHouse":  (sum(ch_avgs),  fresh_ch,  "yellow"),
        }
        if run_optimized and any(v > 0 for v in cho_avgs):
            totals["ClickHouse Optimized"] = (sum(cho_avgs), fresh_cho, "cyan")

        winner = min(totals, key=lambda s: totals[s][0])
        avgs, fresh, color = totals[winner]

        avgs_map = {
            "Postgres": pg_avgs, "Materialize": mz_avgs,
            "ClickHouse": ch_avgs, "ClickHouse Optimized": cho_avgs,
        }
        avgs_list = avgs_map[winner]
        lo, hi = min(avgs_list), max(avgs_list)
        range_str = f"{lo:.1f}–{hi:.1f} ms"
        fresh_str = (
            "0 ms freshness lag" if winner == "Postgres"
            else f"{fmt_ms(fresh)} freshness lag"
        )
        return DISPLAY_NAMES[winner], color, range_str, fresh_str

    op_winner, op_color, op_range, op_fresh = _conclude(
        op_pg, op_mz, op_ch, op_cho, fresh_mz_ms, fresh_ch_ms, fresh_cho_ms,
    )
    an_winner, an_color, an_range, an_fresh = _conclude(
        an_pg, an_mz, an_ch, an_cho, fresh_mz_ms, fresh_ch_ms, fresh_cho_ms,
    )
    src_pg_range = f"{min(op_pg):.1f}–{max(op_pg):.1f} ms"

    console.print(Rule(" CONCLUSION ", style="dim"))
    console.print(
        f"  [bold]Operational queries[/bold]  → [{op_color}]{op_winner}[/{op_color}]  ({op_range} response, {op_fresh})\n"
        f"  [bold]Analytical queries[/bold]   → [{an_color}]{an_winner}[/{an_color}]  ({an_range} response, {an_fresh})\n"
        f"  [bold]Source of truth[/bold]      → [blue]Postgres[/blue]       ({src_pg_range} response, 0 ms freshness lag)\n"
    )
    if run_optimized:
        console.print(
            "  [dim]ClickHouse (optimized) freshness = CDC lag (~2-3 s via Debezium) "
            "+ up to 30 s refresh window for pre-aggregated analytical tables[/dim]\n"
        )

    pg_conn.close()
    mz_conn.close()
    ch_client.close()


if __name__ == "__main__":
    main()
