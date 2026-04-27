"""
Tests for benchmarks/run_benchmarks.py and the benchmark SQL queries.

Validates that every benchmark query executes without error against all four
systems (Postgres, Materialize, ClickHouse via Materialize, ClickHouse standalone),
so regressions in the SQL files are caught before a user runs make bench.
"""
import sys
import os
from pathlib import Path

import pytest
import psycopg2
import clickhouse_connect

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "benchmarks"))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
from run_benchmarks import (
    load_sql, sample_params, OPERATIONAL_QUERIES, ANALYTICAL_QUERIES,
    render_reaction_chart, fmt_ms,
)
from demo import render_freshness_bars

from rich.console import Console

QUERIES_DIR = Path(__file__).parent.parent / "benchmarks" / "queries"


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(scope="module")
def bench_pg():
    conn = psycopg2.connect(
        host="localhost", port=5432, dbname="retail",
        user="postgres", password="postgres",
    )
    conn.autocommit = True
    yield conn
    conn.close()


@pytest.fixture(scope="module")
def bench_mz():
    conn = psycopg2.connect(
        host="localhost", port=6875, dbname="materialize", user="materialize",
    )
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute("SET cluster = transform_sink_cluster")
    cur.execute("SET transaction_isolation = 'serializable'")
    cur.close()
    yield conn
    conn.close()


@pytest.fixture(scope="module")
def bench_ch():
    client = clickhouse_connect.get_client(
        host="localhost", port=8123, database="retail",
    )
    yield client
    client.close()


@pytest.fixture(scope="module")
def params(bench_pg):
    return sample_params(bench_pg)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def run_pg(conn, subpath, system, params):
    sql = load_sql(subpath, system)
    cur = conn.cursor()
    cur.execute(sql, params)
    cur.fetchall()
    cur.close()


def run_ch(client, subpath, params):
    sql = load_sql(subpath, "clickhouse").rstrip().rstrip(";")
    client.query(sql, parameters=params)


ALL_QUERIES = OPERATIONAL_QUERIES + ANALYTICAL_QUERIES
QUERY_IDS   = [name for name, _ in ALL_QUERIES]
SUBPATHS    = [subpath for _, subpath in ALL_QUERIES]

STANDALONE_IDS     = [f"{subpath.split('/')[-1]}" for _, subpath in ALL_QUERIES]
STANDALONE_SUBPATHS = SUBPATHS


# ---------------------------------------------------------------------------
# Postgres — all queries parse and execute
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("subpath", SUBPATHS, ids=QUERY_IDS)
def test_postgres_query_runs(bench_pg, params, subpath):
    run_pg(bench_pg, subpath, "postgres", params)


# ---------------------------------------------------------------------------
# Materialize — all queries parse and execute
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("subpath", SUBPATHS, ids=QUERY_IDS)
def test_materialize_query_runs(bench_mz, params, subpath):
    run_pg(bench_mz, subpath, "materialize", params)


# ---------------------------------------------------------------------------
# ClickHouse — all queries parse and execute (no trailing semicolons)
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("subpath", SUBPATHS, ids=QUERY_IDS)
def test_clickhouse_query_runs(bench_ch, params, subpath):
    run_ch(bench_ch, subpath, params)


# ---------------------------------------------------------------------------
# Guard: ClickHouse SQL files must not end with a semicolon
# (clickhouse-connect rejects trailing semicolons as multi-statement queries)
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("subpath", SUBPATHS, ids=QUERY_IDS)
def test_clickhouse_sql_no_trailing_semicolon(subpath):
    sql = load_sql(subpath, "clickhouse")
    assert not sql.rstrip().endswith(";"), (
        f"benchmarks/queries/{subpath}/clickhouse.sql ends with ';' — "
        "clickhouse-connect rejects trailing semicolons as multi-statement queries"
    )


# ---------------------------------------------------------------------------
# Guard: Materialize SQL files must not use mz_now() for interval arithmetic
# (mz_now() returns mz_timestamp; interval subtraction requires timestamptz)
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("subpath", SUBPATHS, ids=QUERY_IDS)
def test_materialize_sql_no_mz_now_interval(subpath):
    sql = load_sql(subpath, "materialize")
    assert "mz_now()" not in sql, (
        f"benchmarks/queries/{subpath}/materialize.sql uses mz_now() — "
        "use NOW() instead for ad-hoc benchmark queries; mz_now() - interval "
        "is not supported outside temporal materialized views"
    )


# ---------------------------------------------------------------------------
# Chart rendering — no IndexError at boundary freshness values
# ---------------------------------------------------------------------------

def _null_console() -> Console:
    return Console(file=open(os.devnull, "w"))


@pytest.mark.parametrize("fresh_mz_ms,fresh_ch_ms,with_optimized,with_batch", [
    (100.0,   500.0,   False, False),   # 3-system, sub-second freshness
    (2000.0,  5000.0,  False, False),   # 3-system, typical Docker values
    (1.0,     1.0,     False, False),   # 3-system, minimum non-zero
    (30000.0, 30000.0, False, False),   # 3-system, timeout sentinel
    (265.0,   6100.0,  True,  False),   # 4-system, CDC-only optimized
    (265.0,   6100.0,  True,  True),    # 4-system with batch scheduling segments
])
def test_render_reaction_chart_no_index_error(fresh_mz_ms, fresh_ch_ms, with_optimized, with_batch):
    """render_reaction_chart must not raise IndexError for any freshness or batch value."""
    console = _null_console()
    cho_ms     = [150.0, 900.0] if with_optimized else None
    cho_batch  = [0.0, 15_000.0] if (with_optimized and with_batch) else None
    render_reaction_chart(
        console,
        title="Test",
        query_names=["q1", "q2"],
        pg_ms=[100.0, 500.0],
        mz_ms=[10.0, 20.0],
        ch_ms=[200.0, 1000.0],
        fresh_mz_ms=fresh_mz_ms,
        fresh_ch_ms=fresh_ch_ms,
        cho_ms=cho_ms,
        cho_cdc_ms=850.0 if with_optimized else 0.0,
        cho_batch_ms=cho_batch,
    )


# ---------------------------------------------------------------------------
# ClickHouse standalone — all queries parse and execute
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("subpath", STANDALONE_SUBPATHS, ids=STANDALONE_IDS)
def test_clickhouse_standalone_query_runs(bench_ch, params, subpath):
    """clickhouse_standalone.sql must execute without error against raw_ tables."""
    sql = load_sql(subpath, "clickhouse_standalone").rstrip().rstrip(";")
    bench_ch.query(sql, parameters=params)


@pytest.mark.parametrize("subpath", STANDALONE_SUBPATHS, ids=STANDALONE_IDS)
def test_clickhouse_standalone_sql_no_trailing_semicolon(subpath):
    """clickhouse_standalone.sql must not end with ';' (clickhouse-connect rejects it)."""
    sql = load_sql(subpath, "clickhouse_standalone")
    assert not sql.rstrip().endswith(";"), (
        f"benchmarks/queries/{subpath}/clickhouse_standalone.sql ends with ';' — "
        "clickhouse-connect rejects trailing semicolons as multi-statement queries"
    )


@pytest.mark.parametrize("mz_lag_s,ch_lag_s", [
    (0.1,  0.5),
    (2.0,  5.0),
    (0.01, 0.01),
    (30.0, 30.0),
])
def test_render_freshness_bars_no_index_error(mz_lag_s, ch_lag_s):
    """render_freshness_bars must not raise IndexError for any lag value."""
    render_freshness_bars(mz_lag_s, ch_lag_s)
