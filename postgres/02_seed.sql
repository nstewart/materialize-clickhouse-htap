-- =============================================================================
-- Seed Data for Retail Kappa Architecture Demo
-- =============================================================================

-- -----------------------------------------------------------------------------
-- CUSTOMERS (10 rows, varied tiers)
-- -----------------------------------------------------------------------------
INSERT INTO customers (email, name, tier, created_at) VALUES
    ('alice.chen@example.com',    'Alice Chen',       'vip',      '2023-01-15 09:12:00+00'),
    ('bob.martinez@example.com',  'Bob Martinez',     'premium',  '2023-02-03 14:30:00+00'),
    ('carol.johnson@example.com', 'Carol Johnson',    'vip',      '2023-02-20 11:05:00+00'),
    ('david.kim@example.com',     'David Kim',        'standard', '2023-03-08 16:45:00+00'),
    ('emma.patel@example.com',    'Emma Patel',       'premium',  '2023-04-11 10:20:00+00'),
    ('frank.nguyen@example.com',  'Frank Nguyen',     'standard', '2023-05-22 08:55:00+00'),
    ('grace.okonkwo@example.com', 'Grace Okonkwo',    'vip',      '2023-06-14 13:40:00+00'),
    ('henry.walsh@example.com',   'Henry Walsh',      'standard', '2023-07-30 09:00:00+00'),
    ('isabella.russo@example.com','Isabella Russo',   'premium',  '2023-09-05 15:15:00+00'),
    ('james.taylor@example.com',  'James Taylor',     'standard', '2023-10-18 12:30:00+00');

-- -----------------------------------------------------------------------------
-- PRODUCTS (20 rows, 5 categories)
-- -----------------------------------------------------------------------------
INSERT INTO products (sku, name, category, price, cost, created_at) VALUES
    -- Electronics (4)
    ('ELEC-001', 'Wireless Noise-Cancelling Headphones', 'Electronics', 249.99, 112.00, '2022-11-01 00:00:00+00'),
    ('ELEC-002', 'USB-C Charging Hub (7-Port)',          'Electronics',  79.99,  32.50, '2022-11-01 00:00:00+00'),
    ('ELEC-003', 'Mechanical Keyboard (TKL)',            'Electronics', 139.99,  58.00, '2022-11-15 00:00:00+00'),
    ('ELEC-004', '27" 4K IPS Monitor',                  'Electronics', 449.99, 210.00, '2022-12-01 00:00:00+00'),

    -- Apparel (4)
    ('APPR-001', 'Merino Wool Crew-Neck Sweater',        'Apparel',      89.99,  28.00, '2022-11-01 00:00:00+00'),
    ('APPR-002', 'Slim-Fit Chino Pants',                 'Apparel',      64.99,  19.50, '2022-11-01 00:00:00+00'),
    ('APPR-003', 'Running Jacket (Waterproof)',          'Apparel',     119.99,  42.00, '2022-11-15 00:00:00+00'),
    ('APPR-004', 'Classic Canvas Sneakers',              'Apparel',      54.99,  16.00, '2022-12-01 00:00:00+00'),

    -- Home (4)
    ('HOME-001', 'Bamboo Cutting Board Set (3-Piece)',   'Home',         34.99,  11.00, '2022-11-01 00:00:00+00'),
    ('HOME-002', 'Ceramic Pour-Over Coffee Dripper',     'Home',         29.99,   9.50, '2022-11-01 00:00:00+00'),
    ('HOME-003', 'Linen Duvet Cover (Queen)',            'Home',         79.99,  28.00, '2022-11-15 00:00:00+00'),
    ('HOME-004', 'Cast Iron Skillet (12")',              'Home',         49.99,  18.00, '2022-12-01 00:00:00+00'),

    -- Sports (4)
    ('SPRT-001', 'Adjustable Dumbbell Set (5-50 lb)',    'Sports',      299.99, 140.00, '2022-11-01 00:00:00+00'),
    ('SPRT-002', 'Yoga Mat (6mm, Non-Slip)',             'Sports',       39.99,  12.00, '2022-11-01 00:00:00+00'),
    ('SPRT-003', 'Road Bike Helmet',                     'Sports',       89.99,  33.00, '2022-11-15 00:00:00+00'),
    ('SPRT-004', 'Resistance Band Kit (5 Levels)',       'Sports',       24.99,   7.50, '2022-12-01 00:00:00+00'),

    -- Food (4)
    ('FOOD-001', 'Cold-Brew Coffee Concentrate (32 oz)','Food',         18.99,   6.00, '2022-11-01 00:00:00+00'),
    ('FOOD-002', 'Organic Oat Granola (2 lb)',           'Food',         14.99,   4.50, '2022-11-01 00:00:00+00'),
    ('FOOD-003', 'Dark Chocolate Assortment (24-ct)',    'Food',         22.99,   8.00, '2022-11-15 00:00:00+00'),
    ('FOOD-004', 'Hot Sauce Variety Pack (6-ct)',        'Food',         19.99,   6.50, '2022-12-01 00:00:00+00');

-- -----------------------------------------------------------------------------
-- ORDERS (50 rows, spread across customers, varied statuses)
-- -----------------------------------------------------------------------------
INSERT INTO orders (customer_id, status, created_at, updated_at) VALUES
    -- Alice (customer 1) — VIP, heavy buyer
    (1, 'delivered',  '2024-01-05 10:00:00+00', '2024-01-08 14:00:00+00'),
    (1, 'delivered',  '2024-02-14 09:30:00+00', '2024-02-17 11:00:00+00'),
    (1, 'delivered',  '2024-03-22 15:45:00+00', '2024-03-25 10:30:00+00'),
    (1, 'shipped',    '2024-04-10 08:20:00+00', '2024-04-11 09:00:00+00'),
    (1, 'pending',    '2024-04-20 12:00:00+00', '2024-04-20 12:00:00+00'),

    -- Bob (customer 2) — Premium
    (2, 'delivered',  '2024-01-12 11:00:00+00', '2024-01-15 16:00:00+00'),
    (2, 'delivered',  '2024-02-28 14:15:00+00', '2024-03-02 09:45:00+00'),
    (2, 'shipped',    '2024-04-18 10:00:00+00', '2024-04-19 08:30:00+00'),
    (2, 'cancelled',  '2024-04-05 09:00:00+00', '2024-04-05 10:15:00+00'),

    -- Carol (customer 3) — VIP
    (3, 'delivered',  '2024-01-20 13:00:00+00', '2024-01-23 15:00:00+00'),
    (3, 'delivered',  '2024-02-08 10:30:00+00', '2024-02-11 12:00:00+00'),
    (3, 'delivered',  '2024-03-15 09:00:00+00', '2024-03-18 14:00:00+00'),
    (3, 'processing', '2024-04-19 16:00:00+00', '2024-04-19 16:30:00+00'),

    -- David (customer 4) — Standard
    (4, 'delivered',  '2024-01-30 08:45:00+00', '2024-02-02 10:00:00+00'),
    (4, 'delivered',  '2024-03-05 14:00:00+00', '2024-03-08 11:30:00+00'),
    (4, 'pending',    '2024-04-21 09:15:00+00', '2024-04-21 09:15:00+00'),

    -- Emma (customer 5) — Premium
    (5, 'delivered',  '2024-01-08 10:15:00+00', '2024-01-11 13:00:00+00'),
    (5, 'delivered',  '2024-02-19 15:30:00+00', '2024-02-22 10:00:00+00'),
    (5, 'shipped',    '2024-04-15 11:00:00+00', '2024-04-16 08:45:00+00'),
    (5, 'processing', '2024-04-22 14:00:00+00', '2024-04-22 14:30:00+00'),

    -- Frank (customer 6) — Standard
    (6, 'delivered',  '2024-01-25 12:00:00+00', '2024-01-28 14:00:00+00'),
    (6, 'delivered',  '2024-03-10 09:30:00+00', '2024-03-13 11:00:00+00'),
    (6, 'cancelled',  '2024-04-01 10:00:00+00', '2024-04-01 11:00:00+00'),

    -- Grace (customer 7) — VIP
    (7, 'delivered',  '2024-01-03 09:00:00+00', '2024-01-06 13:00:00+00'),
    (7, 'delivered',  '2024-02-10 14:45:00+00', '2024-02-13 10:30:00+00'),
    (7, 'delivered',  '2024-03-01 11:30:00+00', '2024-03-04 15:00:00+00'),
    (7, 'delivered',  '2024-03-28 08:00:00+00', '2024-03-31 10:00:00+00'),
    (7, 'shipped',    '2024-04-17 13:15:00+00', '2024-04-18 09:00:00+00'),
    (7, 'pending',    '2024-04-23 10:30:00+00', '2024-04-23 10:30:00+00'),

    -- Henry (customer 8) — Standard
    (8, 'delivered',  '2024-02-05 10:00:00+00', '2024-02-08 12:00:00+00'),
    (8, 'delivered',  '2024-03-20 15:00:00+00', '2024-03-23 11:30:00+00'),
    (8, 'pending',    '2024-04-22 08:30:00+00', '2024-04-22 08:30:00+00'),

    -- Isabella (customer 9) — Premium
    (9, 'delivered',  '2024-01-17 11:45:00+00', '2024-01-20 14:00:00+00'),
    (9, 'delivered',  '2024-02-25 09:15:00+00', '2024-02-28 10:30:00+00'),
    (9, 'delivered',  '2024-03-12 14:30:00+00', '2024-03-15 16:00:00+00'),
    (9, 'shipped',    '2024-04-16 10:45:00+00', '2024-04-17 08:15:00+00'),
    (9, 'processing', '2024-04-21 15:00:00+00', '2024-04-21 15:30:00+00'),

    -- James (customer 10) — Standard
    (10, 'delivered', '2024-01-22 13:30:00+00', '2024-01-25 11:00:00+00'),
    (10, 'delivered', '2024-02-16 10:00:00+00', '2024-02-19 14:00:00+00'),
    (10, 'delivered', '2024-03-25 09:45:00+00', '2024-03-28 12:00:00+00'),
    (10, 'cancelled', '2024-04-08 11:00:00+00', '2024-04-08 12:30:00+00'),
    (10, 'pending',   '2024-04-23 14:00:00+00', '2024-04-23 14:00:00+00'),

    -- Extra orders to round out to 50 (mixed customers)
    (1, 'delivered',  '2024-04-02 10:00:00+00', '2024-04-05 13:00:00+00'),
    (3, 'delivered',  '2024-04-06 14:00:00+00', '2024-04-09 11:00:00+00'),
    (5, 'delivered',  '2024-04-01 09:00:00+00', '2024-04-04 15:00:00+00'),
    (7, 'delivered',  '2024-04-12 11:00:00+00', '2024-04-15 10:00:00+00'),
    (9, 'delivered',  '2024-04-03 13:30:00+00', '2024-04-06 14:00:00+00'),
    (2, 'delivered',  '2024-03-18 10:00:00+00', '2024-03-21 12:00:00+00'),
    (4, 'shipped',    '2024-04-20 09:00:00+00', '2024-04-21 08:30:00+00'),
    (6, 'processing', '2024-04-23 15:00:00+00', '2024-04-23 15:15:00+00');

-- -----------------------------------------------------------------------------
-- ORDER ITEMS (~150 rows, 2-5 items per order)
-- -----------------------------------------------------------------------------

-- Order 1 (Alice, delivered) — 3 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (1, 1, 1, 249.99),  -- Headphones
    (1, 2, 1,  79.99),  -- USB Hub
    (1, 9, 2,  34.99);  -- Cutting Board Set

-- Order 2 (Alice, delivered) — 4 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (2,  4, 1, 449.99),  -- 4K Monitor
    (2,  3, 1, 139.99),  -- Keyboard
    (2, 17, 3,  18.99),  -- Cold-Brew
    (2, 18, 2,  14.99);  -- Granola

-- Order 3 (Alice, delivered) — 2 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (3,  5, 1,  89.99),  -- Sweater
    (3, 12, 1,  49.99);  -- Cast Iron Skillet

-- Order 4 (Alice, shipped) — 3 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (4,  6, 2,  64.99),  -- Chinos
    (4, 19, 4,  22.99),  -- Dark Chocolate
    (4, 20, 2,  19.99);  -- Hot Sauce

-- Order 5 (Alice, pending) — 2 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (5, 13, 1, 299.99),  -- Dumbbells
    (5, 14, 1,  39.99);  -- Yoga Mat

-- Order 6 (Bob, delivered) — 3 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (6,  1, 1, 249.99),  -- Headphones
    (6, 15, 1,  89.99),  -- Bike Helmet
    (6, 16, 2,  24.99);  -- Resistance Bands

-- Order 7 (Bob, delivered) — 4 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (7,  7, 1, 119.99),  -- Running Jacket
    (7,  8, 1,  54.99),  -- Sneakers
    (7, 10, 1,  29.99),  -- Pour-Over
    (7, 17, 2,  18.99);  -- Cold-Brew

-- Order 8 (Bob, shipped) — 2 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (8,  4, 1, 449.99),  -- Monitor
    (8,  2, 2,  79.99);  -- USB Hub

-- Order 9 (Bob, cancelled) — 3 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (9, 11, 1,  79.99),  -- Duvet Cover
    (9, 18, 3,  14.99),  -- Granola
    (9, 19, 2,  22.99);  -- Dark Chocolate

-- Order 10 (Carol, delivered) — 5 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (10,  3, 1, 139.99),  -- Keyboard
    (10,  1, 1, 249.99),  -- Headphones
    (10,  9, 1,  34.99),  -- Cutting Board
    (10, 14, 2,  39.99),  -- Yoga Mat
    (10, 20, 3,  19.99);  -- Hot Sauce

-- Order 11 (Carol, delivered) — 3 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (11,  5, 2,  89.99),  -- Sweater
    (11,  6, 1,  64.99),  -- Chinos
    (11, 12, 1,  49.99);  -- Cast Iron

-- Order 12 (Carol, delivered) — 4 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (12, 13, 1, 299.99),  -- Dumbbells
    (12, 15, 1,  89.99),  -- Helmet
    (12, 17, 4,  18.99),  -- Cold-Brew
    (12, 19, 3,  22.99);  -- Dark Chocolate

-- Order 13 (Carol, processing) — 2 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (13,  4, 1, 449.99),  -- Monitor
    (13,  2, 1,  79.99);  -- USB Hub

-- Order 14 (David, delivered) — 3 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (14,  7, 1, 119.99),  -- Running Jacket
    (14, 16, 1,  24.99),  -- Resistance Bands
    (14, 18, 2,  14.99);  -- Granola

-- Order 15 (David, delivered) — 2 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (15, 10, 2,  29.99),  -- Pour-Over
    (15, 11, 1,  79.99);  -- Duvet Cover

-- Order 16 (David, pending) — 2 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (16,  8, 2,  54.99),  -- Sneakers
    (16, 20, 3,  19.99);  -- Hot Sauce

-- Order 17 (Emma, delivered) — 4 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (17,  1, 1, 249.99),  -- Headphones
    (17,  3, 1, 139.99),  -- Keyboard
    (17,  9, 2,  34.99),  -- Cutting Board
    (17, 17, 2,  18.99);  -- Cold-Brew

-- Order 18 (Emma, delivered) — 3 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (18,  5, 1,  89.99),  -- Sweater
    (18,  7, 1, 119.99),  -- Running Jacket
    (18, 14, 1,  39.99);  -- Yoga Mat

-- Order 19 (Emma, shipped) — 3 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (19, 13, 1, 299.99),  -- Dumbbells
    (19, 15, 1,  89.99),  -- Helmet
    (19, 16, 3,  24.99);  -- Resistance Bands

-- Order 20 (Emma, processing) — 2 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (20,  4, 1, 449.99),  -- Monitor
    (20,  2, 2,  79.99);  -- USB Hub

-- Order 21 (Frank, delivered) — 3 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (21, 18, 3,  14.99),  -- Granola
    (21, 19, 2,  22.99),  -- Dark Chocolate
    (21, 20, 2,  19.99);  -- Hot Sauce

-- Order 22 (Frank, delivered) — 2 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (22, 10, 1,  29.99),  -- Pour-Over
    (22, 12, 1,  49.99);  -- Cast Iron

-- Order 23 (Frank, cancelled) — 3 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (23,  6, 1,  64.99),  -- Chinos
    (23,  8, 1,  54.99),  -- Sneakers
    (23, 11, 1,  79.99);  -- Duvet Cover

-- Order 24 (Grace, delivered) — 5 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (24,  1, 1, 249.99),  -- Headphones
    (24,  4, 1, 449.99),  -- Monitor
    (24,  3, 1, 139.99),  -- Keyboard
    (24, 13, 1, 299.99),  -- Dumbbells
    (24, 17, 4,  18.99);  -- Cold-Brew

-- Order 25 (Grace, delivered) — 4 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (25,  5, 2,  89.99),  -- Sweater
    (25,  7, 1, 119.99),  -- Running Jacket
    (25,  9, 1,  34.99),  -- Cutting Board
    (25, 15, 1,  89.99);  -- Helmet

-- Order 26 (Grace, delivered) — 3 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (26, 11, 1,  79.99),  -- Duvet Cover
    (26, 14, 2,  39.99),  -- Yoga Mat
    (26, 16, 2,  24.99);  -- Resistance Bands

-- Order 27 (Grace, delivered) — 3 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (27,  6, 1,  64.99),  -- Chinos
    (27,  8, 2,  54.99),  -- Sneakers
    (27, 20, 4,  19.99);  -- Hot Sauce

-- Order 28 (Grace, shipped) — 2 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (28,  2, 2,  79.99),  -- USB Hub
    (28, 19, 3,  22.99);  -- Dark Chocolate

-- Order 29 (Grace, pending) — 2 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (29, 10, 1,  29.99),  -- Pour-Over
    (29, 18, 2,  14.99);  -- Granola

-- Order 30 (Henry, delivered) — 3 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (30, 12, 1,  49.99),  -- Cast Iron
    (30, 17, 2,  18.99),  -- Cold-Brew
    (30, 18, 2,  14.99);  -- Granola

-- Order 31 (Henry, delivered) — 3 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (31, 14, 1,  39.99),  -- Yoga Mat
    (31, 16, 2,  24.99),  -- Resistance Bands
    (31, 20, 2,  19.99);  -- Hot Sauce

-- Order 32 (Henry, pending) — 2 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (32,  7, 1, 119.99),  -- Running Jacket
    (32, 15, 1,  89.99);  -- Helmet

-- Order 33 (Isabella, delivered) — 4 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (33,  1, 1, 249.99),  -- Headphones
    (33,  5, 1,  89.99),  -- Sweater
    (33, 10, 2,  29.99),  -- Pour-Over
    (33, 19, 2,  22.99);  -- Dark Chocolate

-- Order 34 (Isabella, delivered) — 3 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (34,  4, 1, 449.99),  -- Monitor
    (34,  3, 1, 139.99),  -- Keyboard
    (34, 13, 1, 299.99);  -- Dumbbells

-- Order 35 (Isabella, delivered) — 3 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (35,  6, 2,  64.99),  -- Chinos
    (35,  9, 1,  34.99),  -- Cutting Board
    (35, 11, 1,  79.99);  -- Duvet Cover

-- Order 36 (Isabella, shipped) — 2 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (36,  7, 1, 119.99),  -- Running Jacket
    (36, 14, 2,  39.99);  -- Yoga Mat

-- Order 37 (Isabella, processing) — 3 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (37,  2, 1,  79.99),  -- USB Hub
    (37, 17, 3,  18.99),  -- Cold-Brew
    (37, 20, 2,  19.99);  -- Hot Sauce

-- Order 38 (James, delivered) — 3 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (38, 12, 1,  49.99),  -- Cast Iron
    (38, 18, 2,  14.99),  -- Granola
    (38, 16, 1,  24.99);  -- Resistance Bands

-- Order 39 (James, delivered) — 4 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (39,  8, 1,  54.99),  -- Sneakers
    (39, 15, 1,  89.99),  -- Helmet
    (39, 19, 3,  22.99),  -- Dark Chocolate
    (39, 10, 1,  29.99);  -- Pour-Over

-- Order 40 (James, delivered) — 3 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (40,  5, 1,  89.99),  -- Sweater
    (40,  6, 1,  64.99),  -- Chinos
    (40, 11, 1,  79.99);  -- Duvet Cover

-- Order 41 (James, cancelled) — 2 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (41, 13, 1, 299.99),  -- Dumbbells
    (41, 20, 2,  19.99);  -- Hot Sauce

-- Order 42 (James, pending) — 2 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (42,  9, 2,  34.99),  -- Cutting Board
    (42, 17, 3,  18.99);  -- Cold-Brew

-- Order 43 (Alice, extra delivered) — 3 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (43,  3, 1, 139.99),  -- Keyboard
    (43, 14, 1,  39.99),  -- Yoga Mat
    (43, 18, 2,  14.99);  -- Granola

-- Order 44 (Carol, extra delivered) — 4 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (44,  1, 1, 249.99),  -- Headphones
    (44,  7, 1, 119.99),  -- Running Jacket
    (44, 10, 2,  29.99),  -- Pour-Over
    (44, 16, 2,  24.99);  -- Resistance Bands

-- Order 45 (Emma, extra delivered) — 3 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (45,  4, 1, 449.99),  -- Monitor
    (45, 12, 1,  49.99),  -- Cast Iron
    (45, 19, 4,  22.99);  -- Dark Chocolate

-- Order 46 (Grace, extra delivered) — 4 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (46,  5, 2,  89.99),  -- Sweater
    (46,  6, 1,  64.99),  -- Chinos
    (46,  8, 1,  54.99),  -- Sneakers
    (46, 15, 1,  89.99);  -- Helmet

-- Order 47 (Isabella, extra delivered) — 3 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (47,  2, 2,  79.99),  -- USB Hub
    (47, 13, 1, 299.99),  -- Dumbbells
    (47, 20, 3,  19.99);  -- Hot Sauce

-- Order 48 (Bob, extra delivered) — 2 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (48, 11, 1,  79.99),  -- Duvet Cover
    (48, 17, 4,  18.99);  -- Cold-Brew

-- Order 49 (David, shipped) — 3 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (49,  9, 1,  34.99),  -- Cutting Board
    (49, 18, 2,  14.99),  -- Granola
    (49, 14, 1,  39.99);  -- Yoga Mat

-- Order 50 (Frank, processing) — 2 items
INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
    (50, 16, 2,  24.99),  -- Resistance Bands
    (50, 19, 3,  22.99);  -- Dark Chocolate

-- -----------------------------------------------------------------------------
-- INVENTORY (20 products × 3 warehouses = 60 rows)
-- Several items have quantity < 10 to trigger low-stock alerts.
-- -----------------------------------------------------------------------------
INSERT INTO inventory (product_id, warehouse_id, quantity, updated_at) VALUES
    -- ELEC-001 (Headphones)
    (1,  'east',    42, '2024-04-23 06:00:00+00'),
    (1,  'west',    18, '2024-04-23 06:00:00+00'),
    (1,  'central',  7, '2024-04-23 06:00:00+00'),  -- LOW STOCK

    -- ELEC-002 (USB Hub)
    (2,  'east',   120, '2024-04-23 06:00:00+00'),
    (2,  'west',    95, '2024-04-23 06:00:00+00'),
    (2,  'central', 83, '2024-04-23 06:00:00+00'),

    -- ELEC-003 (Keyboard)
    (3,  'east',    55, '2024-04-23 06:00:00+00'),
    (3,  'west',    31, '2024-04-23 06:00:00+00'),
    (3,  'central',  4, '2024-04-23 06:00:00+00'),  -- LOW STOCK

    -- ELEC-004 (4K Monitor)
    (4,  'east',    22, '2024-04-23 06:00:00+00'),
    (4,  'west',     9, '2024-04-23 06:00:00+00'),  -- LOW STOCK
    (4,  'central', 15, '2024-04-23 06:00:00+00'),

    -- APPR-001 (Sweater)
    (5,  'east',   200, '2024-04-23 06:00:00+00'),
    (5,  'west',   175, '2024-04-23 06:00:00+00'),
    (5,  'central',148, '2024-04-23 06:00:00+00'),

    -- APPR-002 (Chinos)
    (6,  'east',   310, '2024-04-23 06:00:00+00'),
    (6,  'west',   280, '2024-04-23 06:00:00+00'),
    (6,  'central',265, '2024-04-23 06:00:00+00'),

    -- APPR-003 (Running Jacket)
    (7,  'east',    88, '2024-04-23 06:00:00+00'),
    (7,  'west',    62, '2024-04-23 06:00:00+00'),
    (7,  'central',  5, '2024-04-23 06:00:00+00'),  -- LOW STOCK

    -- APPR-004 (Sneakers)
    (8,  'east',   190, '2024-04-23 06:00:00+00'),
    (8,  'west',   145, '2024-04-23 06:00:00+00'),
    (8,  'central',112, '2024-04-23 06:00:00+00'),

    -- HOME-001 (Cutting Board Set)
    (9,  'east',   250, '2024-04-23 06:00:00+00'),
    (9,  'west',   220, '2024-04-23 06:00:00+00'),
    (9,  'central',185, '2024-04-23 06:00:00+00'),

    -- HOME-002 (Pour-Over)
    (10, 'east',   160, '2024-04-23 06:00:00+00'),
    (10, 'west',   130, '2024-04-23 06:00:00+00'),
    (10, 'central', 98, '2024-04-23 06:00:00+00'),

    -- HOME-003 (Duvet Cover)
    (11, 'east',    75, '2024-04-23 06:00:00+00'),
    (11, 'west',    50, '2024-04-23 06:00:00+00'),
    (11, 'central',  3, '2024-04-23 06:00:00+00'),  -- LOW STOCK

    -- HOME-004 (Cast Iron Skillet)
    (12, 'east',   340, '2024-04-23 06:00:00+00'),
    (12, 'west',   295, '2024-04-23 06:00:00+00'),
    (12, 'central',210, '2024-04-23 06:00:00+00'),

    -- SPRT-001 (Dumbbells)
    (13, 'east',    30, '2024-04-23 06:00:00+00'),
    (13, 'west',    12, '2024-04-23 06:00:00+00'),
    (13, 'central',  6, '2024-04-23 06:00:00+00'),  -- LOW STOCK

    -- SPRT-002 (Yoga Mat)
    (14, 'east',   420, '2024-04-23 06:00:00+00'),
    (14, 'west',   390, '2024-04-23 06:00:00+00'),
    (14, 'central',350, '2024-04-23 06:00:00+00'),

    -- SPRT-003 (Bike Helmet)
    (15, 'east',    65, '2024-04-23 06:00:00+00'),
    (15, 'west',    48, '2024-04-23 06:00:00+00'),
    (15, 'central',  8, '2024-04-23 06:00:00+00'),  -- LOW STOCK

    -- SPRT-004 (Resistance Bands)
    (16, 'east',   500, '2024-04-23 06:00:00+00'),
    (16, 'west',   475, '2024-04-23 06:00:00+00'),
    (16, 'central',430, '2024-04-23 06:00:00+00'),

    -- FOOD-001 (Cold-Brew)
    (17, 'east',   280, '2024-04-23 06:00:00+00'),
    (17, 'west',   315, '2024-04-23 06:00:00+00'),
    (17, 'central',240, '2024-04-23 06:00:00+00'),

    -- FOOD-002 (Granola)
    (18, 'east',   195, '2024-04-23 06:00:00+00'),
    (18, 'west',   210, '2024-04-23 06:00:00+00'),
    (18, 'central',  1, '2024-04-23 06:00:00+00'),  -- LOW STOCK (critical)

    -- FOOD-003 (Dark Chocolate)
    (19, 'east',   375, '2024-04-23 06:00:00+00'),
    (19, 'west',   400, '2024-04-23 06:00:00+00'),
    (19, 'central',320, '2024-04-23 06:00:00+00'),

    -- FOOD-004 (Hot Sauce)
    (20, 'east',   440, '2024-04-23 06:00:00+00'),
    (20, 'west',   460, '2024-04-23 06:00:00+00'),
    (20, 'central',  0, '2024-04-23 06:00:00+00');  -- OUT OF STOCK
