-- =============================================================================
-- Layer 0: Clusters and Connections
-- =============================================================================

-- Clusters
-- Note: In production, use three clusters: source, transform, sink
CREATE CLUSTER source_cluster SIZE '50cc';
CREATE CLUSTER transform_sink_cluster SIZE '100cc';

-- Postgres credentials (Materialize requires secrets for passwords)
CREATE SECRET pg_password AS 'postgres';

-- Postgres connection
CREATE CONNECTION pg_connection TO POSTGRES (
    HOST 'postgres',
    PORT 5432,
    DATABASE 'retail',
    USER 'postgres',
    PASSWORD SECRET pg_password
);

-- Redpanda/Kafka connection (PLAINTEXT for local dev; use SSL in production)
CREATE CONNECTION redpanda_conn TO KAFKA (
    BROKER 'redpanda:9092',
    SECURITY PROTOCOL = 'PLAINTEXT'
);
