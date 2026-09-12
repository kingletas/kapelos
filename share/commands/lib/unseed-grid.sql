-- Removes every row seed-grid.sql added. Safe to run when there is nothing to remove.

DELETE FROM sales_order_grid WHERE entity_id BETWEEN 900000001 AND 999999999 AND increment_id LIKE 'PERFSEED-%';

ANALYZE TABLE sales_order_grid;

SELECT COUNT(*) AS grid_rows, SUM(increment_id LIKE 'PERFSEED-%') AS seeded FROM sales_order_grid;
