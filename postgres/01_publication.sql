-- REPLICA IDENTITY FULL is required by Materialize CDC:
-- it includes the full before/after row in the WAL for UPDATE and DELETE,
-- allowing Materialize to correctly retract and re-emit changed rows.
ALTER TABLE customers   REPLICA IDENTITY FULL;
ALTER TABLE products    REPLICA IDENTITY FULL;
ALTER TABLE orders      REPLICA IDENTITY FULL;
ALTER TABLE order_items REPLICA IDENTITY FULL;
ALTER TABLE inventory   REPLICA IDENTITY FULL;

-- Logical replication publication covering all tables
CREATE PUBLICATION materialize_pub FOR ALL TABLES;
