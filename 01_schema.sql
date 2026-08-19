-- ============================================================================
-- E-COMMERCE PERFORMANCE & RFM DASHBOARD
-- 01_schema.sql — Core transactional schema
-- ============================================================================
-- Design notes:
--   * Orders.status distinguishes completed transactions from cancelled/
--     refunded ones. RFM should only ever be calculated on completed
--     revenue — including cancelled orders would overstate a churned
--     customer's recency and inflate monetary value.
--   * Order_Items is kept even though Orders.total_amount already stores
--     the order total, because real-world order tables usually carry a
--     denormalized total for fast reporting while the line-item table
--     supports product/category-level analysis (margin, best-sellers, etc).
-- ============================================================================

DROP TABLE IF EXISTS Order_Items;
DROP TABLE IF EXISTS Orders;
DROP TABLE IF EXISTS Products;
DROP TABLE IF EXISTS Users;

CREATE TABLE Users (
    user_id       INTEGER PRIMARY KEY,
    signup_date   DATE NOT NULL,
    country       TEXT NOT NULL
);

CREATE TABLE Products (
    product_id    INTEGER PRIMARY KEY,
    category      TEXT NOT NULL,
    cost          DECIMAL(10,2) NOT NULL
);

CREATE TABLE Orders (
    order_id      INTEGER PRIMARY KEY,
    user_id       INTEGER NOT NULL,
    order_date    DATE NOT NULL,
    total_amount  DECIMAL(10,2) NOT NULL,
    status        TEXT NOT NULL CHECK (status IN ('completed', 'cancelled', 'refunded')),
    FOREIGN KEY (user_id) REFERENCES Users(user_id)
);

CREATE TABLE Order_Items (
    order_item_id INTEGER PRIMARY KEY,
    order_id      INTEGER NOT NULL,
    product_id    INTEGER NOT NULL,
    quantity      INTEGER NOT NULL,
    price         DECIMAL(10,2) NOT NULL,
    FOREIGN KEY (order_id) REFERENCES Orders(order_id),
    FOREIGN KEY (product_id) REFERENCES Products(product_id)
);

CREATE INDEX idx_orders_user_id     ON Orders(user_id);
CREATE INDEX idx_orders_status      ON Orders(status);
CREATE INDEX idx_orders_date        ON Orders(order_date);
CREATE INDEX idx_order_items_order  ON Order_Items(order_id);
CREATE INDEX idx_order_items_prod   ON Order_Items(product_id);
