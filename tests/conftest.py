"""
Pytest configuration and shared fixtures for the Kappa architecture integration tests.
"""
import time
import pytest
import psycopg2
import clickhouse_connect


# ---------------------------------------------------------------------------
# Connection fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def pg_conn():
    """psycopg2 connection to Postgres (autocommit=True)."""
    conn = psycopg2.connect(
        host="localhost",
        port=5432,
        dbname="retail",
        user="postgres",
        password="postgres",
    )
    conn.autocommit = True
    yield conn
    conn.close()


@pytest.fixture(scope="session")
def mz_conn():
    """psycopg2 connection to Materialize (autocommit=True)."""
    conn = psycopg2.connect(
        host="localhost",
        port=6875,
        dbname="materialize",
        user="materialize",
    )
    conn.autocommit = True
    yield conn
    conn.close()


@pytest.fixture(scope="session")
def ch_client():
    """clickhouse_connect client for ClickHouse."""
    client = clickhouse_connect.get_client(
        host="localhost",
        port=8123,
        database="retail",
    )
    yield client
    client.close()


# ---------------------------------------------------------------------------
# Cursor fixtures (function-scoped so each test gets a fresh cursor)
# ---------------------------------------------------------------------------

@pytest.fixture
def pg_cursor(pg_conn):
    """Cursor from pg_conn."""
    cur = pg_conn.cursor()
    yield cur
    cur.close()


@pytest.fixture
def mz_cursor(mz_conn):
    """Cursor from mz_conn."""
    cur = mz_conn.cursor()
    yield cur
    cur.close()


# ---------------------------------------------------------------------------
# Helper utilities
# ---------------------------------------------------------------------------

def wait_for_condition(fn, timeout=30, interval=1):
    """
    Poll fn() until it returns True or timeout seconds elapse.

    Parameters
    ----------
    fn       : callable – should return a truthy value when the condition is met
    timeout  : int      – max seconds to wait (default 30)
    interval : int/float – seconds between polls (default 1)

    Raises
    ------
    TimeoutError if the condition is not met within *timeout* seconds.
    """
    deadline = time.time() + timeout
    while True:
        if fn():
            return
        if time.time() >= deadline:
            raise TimeoutError(
                f"Condition not met within {timeout}s"
            )
        time.sleep(interval)
