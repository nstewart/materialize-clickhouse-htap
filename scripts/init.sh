#!/usr/bin/env bash
set -e

# =============================================================================
# HTAP Pipeline Initializer
# Postgres → Materialize → Redpanda → ClickHouse
# =============================================================================

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

NETWORK="materialize-clickhouse-htap_htap-net"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

log_info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
log_ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
log_wait()    { echo -e "${YELLOW}[WAIT]${RESET}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
log_header()  { echo -e "\n${BOLD}${CYAN}=== $* ===${RESET}"; }

# =============================================================================
# Service readiness helpers
# =============================================================================

wait_for_postgres() {
    log_wait "Waiting for Postgres to be ready..."
    local retries=30
    until docker compose exec -T postgres pg_isready -U postgres -d retail -q 2>/dev/null; do
        retries=$((retries - 1))
        if [[ $retries -le 0 ]]; then
            log_error "Postgres did not become ready in time."
            exit 1
        fi
        log_wait "  Postgres not ready yet — retrying in 2s (${retries} attempts left)..."
        sleep 2
    done
    log_ok "Postgres is ready."
}

wait_for_materialize() {
    log_wait "Waiting for Materialize to be ready..."
    local retries=40
    until docker run --rm --network "$NETWORK" -i postgres:15 \
        psql "postgres://materialize@materialize:6875/materialize" \
        -c "SELECT 1;" -q --no-align -t 2>/dev/null | grep -q "^1$"; do
        retries=$((retries - 1))
        if [[ $retries -le 0 ]]; then
            log_error "Materialize did not become ready in time."
            exit 1
        fi
        log_wait "  Materialize not ready yet — retrying in 3s (${retries} attempts left)..."
        sleep 3
    done
    log_ok "Materialize is ready."
}

wait_for_redpanda() {
    log_wait "Waiting for Redpanda to be ready..."
    local retries=30
    until docker compose exec -T redpanda rpk cluster health 2>/dev/null | grep -q "Healthy.*true"; do
        retries=$((retries - 1))
        if [[ $retries -le 0 ]]; then
            log_error "Redpanda did not become ready in time."
            exit 1
        fi
        log_wait "  Redpanda not ready yet — retrying in 2s (${retries} attempts left)..."
        sleep 2
    done
    log_ok "Redpanda is ready."
}

wait_for_debezium() {
    log_wait "Waiting for Debezium Connect to be ready..."
    local retries=40
    until curl -sf http://localhost:8084/connectors >/dev/null 2>&1; do
        retries=$((retries - 1))
        if [[ $retries -le 0 ]]; then
            log_error "Debezium Connect did not become ready in time."
            exit 1
        fi
        log_wait "  Debezium not ready yet — retrying in 3s (${retries} attempts left)..."
        sleep 3
    done
    log_ok "Debezium Connect is ready."
}

register_debezium_connector() {
    log_info "Registering Debezium Postgres connector..."

    # Delete existing connector if present so we always start from a clean snapshot.
    if curl -sf http://localhost:8084/connectors/postgres-retail-connector >/dev/null 2>&1; then
        log_wait "  Existing connector found — deleting..."
        curl -sf -X DELETE http://localhost:8084/connectors/postgres-retail-connector >/dev/null
        sleep 3
    fi

    local response exit_code
    response=$(curl -sf -X POST http://localhost:8084/connectors \
        -H "Content-Type: application/json" \
        -d @"$SCRIPT_DIR/debezium_connector.json" 2>&1)
    exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        log_error "Failed to register Debezium connector: $response"
        exit 1
    fi
    log_ok "Debezium connector registered. Snapshot will run in the background."
}

wait_for_clickhouse() {
    log_wait "Waiting for ClickHouse to be ready..."
    local retries=30
    until docker compose exec -T clickhouse clickhouse-client \
        --query "SELECT 1" 2>/dev/null | grep -q "^1$"; do
        retries=$((retries - 1))
        if [[ $retries -le 0 ]]; then
            log_error "ClickHouse did not become ready in time."
            exit 1
        fi
        log_wait "  ClickHouse not ready yet — retrying in 2s (${retries} attempts left)..."
        sleep 2
    done
    log_ok "ClickHouse is ready."
}

# =============================================================================
# Teardown helpers — idempotent reset of each system's state
# Called before applying SQL so init.sh is safe to re-run without docker down.
# All DROP commands use IF EXISTS and errors are suppressed (objects may not
# exist on a first-time run).
# =============================================================================

teardown_postgres() {
    log_info "Resetting Postgres schema..."
    docker compose exec -T postgres psql -U postgres -d retail \
        -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" \
        -c "DROP PUBLICATION IF EXISTS materialize_pub;" \
        2>/dev/null || true
    log_ok "Postgres schema reset."
}

teardown_materialize() {
    log_info "Resetting Materialize objects..."
    docker run --rm --network "$NETWORK" -i postgres:15 \
        psql "postgres://materialize@materialize:6875/materialize" -q \
        -c "DROP SCHEMA IF EXISTS public CASCADE;" \
        -c "CREATE SCHEMA IF NOT EXISTS public;" \
        -c "DROP CLUSTER IF EXISTS source_cluster CASCADE;" \
        -c "DROP CLUSTER IF EXISTS transform_sink_cluster CASCADE;" \
        -c "DROP CONNECTION IF EXISTS pg_connection CASCADE;" \
        -c "DROP CONNECTION IF EXISTS redpanda_conn CASCADE;" \
        -c "DROP SECRET IF EXISTS pg_password CASCADE;" \
        2>/dev/null || true
    log_ok "Materialize objects reset."
}

teardown_clickhouse() {
    log_info "Resetting ClickHouse database..."
    docker compose exec -T clickhouse clickhouse-client \
        --query "DROP DATABASE IF EXISTS retail" 2>/dev/null || true
    log_ok "ClickHouse database reset."
}

run_mz_sql() {
    local label="$1"
    local file="$2"
    log_info "Running $label..."
    docker run --rm --network "$NETWORK" -i postgres:15 \
        psql "postgres://materialize@materialize:6875/materialize" \
        -v ON_ERROR_STOP=1 -f /dev/stdin < "$file"
    log_ok "$label applied."
}

run_pg_sql() {
    local label="$1"
    local file="$2"
    log_info "Running $label..."
    docker compose exec -T postgres psql -U postgres -d retail \
        -v ON_ERROR_STOP=1 < "$file"
    log_ok "$label applied."
}

run_ch_sql() {
    local label="$1"
    local file="$2"
    log_info "Running $label..."
    docker compose exec -T clickhouse clickhouse-client \
        --multiquery \
        --multiline < "$file"
    log_ok "$label applied."
}

# =============================================================================
# Main pipeline
# =============================================================================

cd "$PROJECT_DIR"

echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         HTAP Pipeline — Initialization                       ║"
echo "║  Postgres → Materialize → Redpanda → ClickHouse             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${RESET}"

# ── Step 1: Postgres ──────────────────────────────────────────────────────────
log_header "Step 1 of 4: PostgreSQL"

wait_for_postgres
teardown_postgres

run_pg_sql "postgres/00_schema.sql   (schema)"     postgres/00_schema.sql
run_pg_sql "postgres/01_publication.sql (pub)"     postgres/01_publication.sql
run_pg_sql "postgres/02_seed.sql    (seed data)"   postgres/02_seed.sql

# ── Step 2: Materialize + Redpanda ───────────────────────────────────────────
log_header "Step 2 of 4: Materialize + Redpanda"

wait_for_materialize
teardown_materialize
wait_for_redpanda

run_mz_sql "materialize/00_connection.sql (connection)" materialize/00_connection.sql
run_mz_sql "materialize/01_sources.sql    (sources)"    materialize/01_sources.sql

log_wait "Pausing 15s for Materialize sources to begin hydrating..."
sleep 15

run_mz_sql "materialize/02_data_products.sql (data products)" materialize/02_data_products.sql
run_mz_sql "materialize/03_serving.sql       (serving layer)"  materialize/03_serving.sql

# ── Step 3: Redpanda (already ready) ─────────────────────────────────────────
log_header "Step 3 of 4: Redpanda"
log_ok "Redpanda already confirmed healthy."

# ── Step 4: ClickHouse ────────────────────────────────────────────────────────
log_header "Step 4 of 5: ClickHouse"

wait_for_clickhouse
teardown_clickhouse

run_ch_sql "clickhouse/00_tables.sql              (tables)"               clickhouse/00_tables.sql
run_ch_sql "clickhouse/01_kafka_consumers.sql     (kafka consumers)"      clickhouse/01_kafka_consumers.sql
run_ch_sql "clickhouse/02_raw_tables.sql           (raw tables)"          clickhouse/02_raw_tables.sql
run_ch_sql "clickhouse/03_optimized_tables.sql     (optimized tables)"    clickhouse/03_optimized_tables.sql
run_ch_sql "clickhouse/04_optimized_consumers.sql  (optimized consumers)" clickhouse/04_optimized_consumers.sql
run_ch_sql "clickhouse/05_mz_analytical_sinks.sql  (mz analytical sinks)" clickhouse/05_mz_analytical_sinks.sql

# ── Step 5: Debezium ──────────────────────────────────────────────────────────
# Register AFTER ClickHouse consumers are live so the snapshot is captured
# from offset 0 — ClickHouse Kafka engine starts reading at 'earliest'.
log_header "Step 5 of 5: Debezium"

wait_for_debezium
register_debezium_connector

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                   Pipeline initialized!                      ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  ✓ PostgreSQL      — schema, publication, seed data loaded   ║"
echo "║  ✓ Materialize     — connection, sources, views running      ║"
echo "║  ✓ Redpanda        — broker healthy                          ║"
echo "║  ✓ ClickHouse      — tables, Kafka consumers, raw tables     ║"
echo "║  ✓ Debezium        — connector registered, snapshot running  ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Note: Debezium snapshot runs async. opt_* tables populate   ║"
echo "║  within ~2 min. Run 'make bench' after snapshot completes.   ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Run: python scripts/demo.py   to see the pipeline live      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${RESET}"
