-- =====================================================================
-- ICT371 Advanced Database  |  Question 1: Pharmacy Stock and Daily Sales
-- DBMS: PostgreSQL 14+   |  Scheduler: pg_cron extension
-- Run the whole file in psql / pgAdmin Query Tool. It is re-runnable.
-- =====================================================================

-- ---------------------------------------------------------------------
-- (a) Database and seed data
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS daily_sales CASCADE;
DROP TABLE IF EXISTS stock_audit CASCADE;
DROP TABLE IF EXISTS sales       CASCADE;
DROP TABLE IF EXISTS medicines   CASCADE;

CREATE TABLE medicines (
    medicine_id   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    medicine_name VARCHAR(100)  NOT NULL UNIQUE,
    unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INT           NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    medicine_id INT           NOT NULL REFERENCES medicines(medicine_id),
    quantity    INT           NOT NULL CHECK (quantity > 0),
    unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on     DATE          NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE stock_audit (
    audit_id    INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    medicine_id INT       NOT NULL REFERENCES medicines(medicine_id),
    old_qty     INT       NOT NULL,
    new_qty     INT       NOT NULL,
    changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE daily_sales (
    sales_date   DATE PRIMARY KEY,
    total_qty    INT           NOT NULL DEFAULT 0,
    total_amount NUMERIC(12,2) NOT NULL DEFAULT 0
);

-- Medicines are seeded now; the sales are loaded later through pr_record_sale.
INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Paracetamol 500mg', 2.50, 100),
    ('Amoxicillin 250mg', 8.00,  30),
    ('Ibuprofen 400mg',   4.00,  20),
    ('ORS Sachet',        1.50,  15);

-- ---------------------------------------------------------------------
-- (b) Function: fn_sale_value
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INT, p_quantity INT)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_price NUMERIC(10,2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: % (must be a positive number)', p_quantity;
    END IF;

    SELECT unit_price INTO v_price
    FROM medicines
    WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    RETURN ROUND(v_price * p_quantity, 2);
END;
$$;

-- ---------------------------------------------------------------------
-- (d) Trigger: audit stock changes (created BEFORE sales are loaded)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_stock_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO stock_audit (medicine_id, old_qty, new_qty, changed_at)
    VALUES (NEW.medicine_id, OLD.stock_qty, NEW.stock_qty, now());
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_stock_audit ON medicines;
CREATE TRIGGER trg_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)   -- only when stock really changes
EXECUTE FUNCTION trg_fn_stock_audit();

-- ---------------------------------------------------------------------
-- (c) Procedure: pr_record_sale
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INT,
    p_quantity    INT,
    p_sold_on     DATE DEFAULT CURRENT_DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
    v_stock INT;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: % (must be positive)', p_quantity;
    END IF;
    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale date must not be NULL';
    END IF;

    -- Lock the medicine row so concurrent sales cannot oversell
    SELECT unit_price, stock_qty INTO v_price, v_stock
    FROM medicines
    WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock for medicine %: requested %, available %',
                        p_medicine_id, p_quantity, v_stock;
    END IF;

    -- Store the CURRENT price in the sale row
    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

    -- Deduct stock exactly once
    UPDATE medicines
    SET stock_qty = stock_qty - p_quantity
    WHERE medicine_id = p_medicine_id;
END;
$$;

-- Six valid sales loaded through the procedure
CALL pr_record_sale(1, 10, CURRENT_DATE - 1);
CALL pr_record_sale(1,  5, CURRENT_DATE - 1);
CALL pr_record_sale(2,  4, CURRENT_DATE - 1);
CALL pr_record_sale(3,  6, CURRENT_DATE);
CALL pr_record_sale(4,  7, CURRENT_DATE);
CALL pr_record_sale(2,  3, CURRENT_DATE);

SELECT * FROM sales ORDER BY sale_id;
SELECT * FROM medicines ORDER BY medicine_id;
SELECT * FROM stock_audit ORDER BY audit_id;

-- Test the function
SELECT fn_sale_value(1, 4) AS value_of_4_paracetamol;   -- 10.00

-- Invalid operations (expected to fail, tables stay unchanged)
DO $$
BEGIN
    CALL pr_record_sale(2, 9999, CURRENT_DATE);   -- more than the stock
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM;
END $$;
DO $$
BEGIN
    PERFORM fn_sale_value(99, 1);                 -- unknown medicine
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM;
END $$;
DO $$
BEGIN
    PERFORM fn_sale_value(1, 0);                  -- invalid quantity
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Expected error: %', SQLERRM;
END $$;

-- ---------------------------------------------------------------------
-- (e) View: v_low_stock
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_id, medicine_name, unit_price, stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

SELECT * FROM v_low_stock;                 -- ORS Sachet (8 left)
CALL pr_record_sale(3, 5, CURRENT_DATE);   -- Ibuprofen 14 -> 9
SELECT * FROM v_low_stock;                 -- now Ibuprofen appears as well

-- ---------------------------------------------------------------------
-- (f) Index: one medicine's sales in a sold_on date range
-- Justification: the query has an equality on medicine_id and a range on
-- sold_on. A composite index (medicine_id, sold_on) lets PostgreSQL jump to
-- the medicine's entries and scan only the requested date range, in order,
-- instead of reading the whole sales table.
-- ---------------------------------------------------------------------
CREATE INDEX idx_sales_medicine_sold_on ON sales (medicine_id, sold_on);
ANALYZE sales;

SET enable_seqscan = off;   -- sales is tiny; this forces the planner to show the index
EXPLAIN
SELECT sale_id, quantity, unit_price, sold_on
FROM sales
WHERE medicine_id = 1
  AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- ---------------------------------------------------------------------
-- (g) Scheduled job
-- pr_refresh_sales is idempotent: it REPLACES the row for the day
-- (INSERT ... ON CONFLICT DO UPDATE with recomputed totals, never "+=").
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day must not be NULL';
    END IF;

    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT p_day,
           COALESCE(SUM(quantity), 0),
           COALESCE(SUM(quantity * unit_price), 0)
    FROM sales
    WHERE sold_on = p_day
    ON CONFLICT (sales_date) DO UPDATE
        SET total_qty    = EXCLUDED.total_qty,
            total_amount = EXCLUDED.total_amount;
END;
$$;

-- Run twice to prove there is no duplication / double counting
CALL pr_refresh_sales(CURRENT_DATE - 1);
CALL pr_refresh_sales(CURRENT_DATE - 1);
SELECT * FROM daily_sales;

-- pg_cron must be in shared_preload_libraries (postgresql.conf) and the
-- extension created in the database named by cron.database_name.
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- Every day at 00:15, for the previous day
SELECT cron.schedule(
    'pharmacy_refresh_sales',
    '15 0 * * *',
    $job$CALL pr_refresh_sales(CURRENT_DATE - 1)$job$
);

SELECT jobid, jobname, schedule, command FROM cron.job;
