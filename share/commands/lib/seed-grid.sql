-- Fills sales_order_grid with rows the admin grid can be timed against, all inside one
-- tagged, reversible range: entity_id 900000001 upwards, increment_id 'PERFSEED-%'.
-- seq_1_to_N is MariaDB's SEQUENCE engine, which is what Kapelos runs.

SET SESSION sql_mode = '';
SET SESSION unique_checks = 0;
SET SESSION foreign_key_checks = 0;

INSERT INTO sales_order_grid (
    entity_id, status, store_id, store_name, customer_id,
    base_grand_total, base_total_paid, grand_total, total_paid,
    increment_id, base_currency_code, order_currency_code,
    shipping_name, billing_name, created_at, updated_at,
    billing_address, shipping_address, shipping_information,
    customer_email, customer_group, subtotal, shipping_and_handling,
    customer_name, payment_method, total_refunded
)
SELECT
    900000000 + seq,
    ELT(1 + (seq % 5), 'complete', 'processing', 'pending', 'canceled', 'holded'),
    1,
    'Default Store View',
    1 + (seq % 100000),
    ROUND(15 + (seq % 40000) / 100, 4),
    ROUND(15 + (seq % 40000) / 100, 4),
    ROUND(15 + (seq % 40000) / 100, 4),
    ROUND(15 + (seq % 40000) / 100, 4),
    CONCAT('PERFSEED-', seq),
    'USD',
    'USD',
    CONCAT('Seed Ship ', seq),
    CONCAT('Seed Bill ', seq),
    TIMESTAMP('2023-01-01') + INTERVAL (seq % 1095) DAY + INTERVAL (seq % 86400) SECOND,
    TIMESTAMP('2023-01-02') + INTERVAL (seq % 1095) DAY,
    CONCAT(seq, ' Seed St, Testville, MO, 63000'),
    CONCAT(seq, ' Seed St, Testville, MO, 63000'),
    'Flat Rate - Fixed',
    CONCAT('seed', seq, '@example.test'),
    'General',
    ROUND(10 + (seq % 30000) / 100, 4),
    ROUND(5 + (seq % 900) / 100, 4),
    CONCAT('Seed Customer ', seq),
    ELT(1 + (seq % 3), 'checkmo', 'banktransfer', 'free'),
    0.0000
FROM seq_1_to_COUNT;

ANALYZE TABLE sales_order_grid;

SELECT COUNT(*) AS grid_rows, SUM(increment_id LIKE 'PERFSEED-%') AS seeded FROM sales_order_grid;
