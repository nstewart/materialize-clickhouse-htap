-- =============================================================================
-- Layer 1: Sources
-- CDC stream from Postgres logical replication
-- Runs on source_cluster
-- =============================================================================

-- FOR ALL TABLES mirrors every table in the publication.
-- Tables are accessible as: customers, products, orders, order_items, inventory
CREATE SOURCE retail_source
  IN CLUSTER source_cluster
  FROM POSTGRES CONNECTION pg_connection (PUBLICATION 'materialize_pub')
  FOR ALL TABLES;
