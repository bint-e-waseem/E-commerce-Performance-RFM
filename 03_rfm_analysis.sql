-- ============================================================================
-- 03_rfm_analysis.sql
-- RFM (Recency, Frequency, Monetary) Scoring & Customer Segmentation
-- ============================================================================
-- Output: one row per user -> user_id, r/f/m scores, combined RFM_Score,
--         avg_order_value, comparison to the store-wide average order
--         value, and a plain-English Customer_Segment label.
--
-- Reference date: all "recency" is measured against 2026-08-19, the date
-- this analysis was run. In production you would swap this literal for
-- CURRENT_DATE / GETDATE() / etc, or better, parameterize it.
-- ============================================================================

WITH

-- ---------------------------------------------------------------------------
-- 1. Only completed orders count toward RFM. Cancelled/refunded orders are
--    real signals of dissatisfaction, not revenue, so they're excluded here
--    (they'd be their own metric -- e.g. cancellation rate -- elsewhere).
-- ---------------------------------------------------------------------------
completed_orders AS (
    SELECT
        order_id,
        user_id,
        order_date,
        total_amount
    FROM Orders
    WHERE status = 'completed'
),

-- ---------------------------------------------------------------------------
-- 2. WINDOW FUNCTIONS: track each customer's purchase sequence and the gap
--    between consecutive orders. ROW_NUMBER() numbers each order in the
--    customer's own timeline; LAG() looks back to the previous order date
--    on the same timeline so we can compute days-between-purchases.
--    This directly powers the "repeat purchase behavior" requirement and
--    also produces first_purchase_date / most_recent_purchase_date without
--    a second pass over the table.
-- ---------------------------------------------------------------------------
purchase_sequence AS (
    SELECT
        user_id,
        order_id,
        order_date,
        total_amount,
        ROW_NUMBER() OVER (PARTITION BY user_id ORDER BY order_date)              AS purchase_seq,
        LAG(order_date) OVER (PARTITION BY user_id ORDER BY order_date)           AS previous_order_date,
        julianday(order_date)
            - julianday(LAG(order_date) OVER (PARTITION BY user_id ORDER BY order_date))
                                                                                    AS days_since_last_order
    FROM completed_orders
),

repeat_purchase_stats AS (
    SELECT
        user_id,
        COUNT(*)                                   AS total_orders,
        MIN(order_date)                            AS first_purchase_date,
        MAX(order_date)                            AS last_purchase_date,
        -- average time between orders; NULL for one-time buyers
        ROUND(AVG(days_since_last_order), 1)       AS avg_days_between_orders
    FROM purchase_sequence
    GROUP BY user_id
),

-- ---------------------------------------------------------------------------
-- 3. Core R / F / M base metrics per user.
-- ---------------------------------------------------------------------------
user_rfm_base AS (
    SELECT
        co.user_id,
        CAST(julianday('2026-08-19') - julianday(MAX(co.order_date)) AS INTEGER) AS recency_days,
        COUNT(co.order_id)                                                       AS frequency,
        SUM(co.total_amount)                                                     AS monetary,
        ROUND(AVG(co.total_amount), 2)                                           AS avg_order_value
    FROM completed_orders co
    GROUP BY co.user_id
),

-- ---------------------------------------------------------------------------
-- 4. SUBQUERY: compare each user's average order value to the store-wide
--    average order value (a scalar subquery, recomputed once and reused
--    for every row via the CROSS JOIN below).
-- ---------------------------------------------------------------------------
store_avg AS (
    SELECT ROUND(AVG(total_amount), 2) AS store_avg_order_value
    FROM completed_orders
),

user_rfm_with_benchmark AS (
    SELECT
        b.*,
        s.store_avg_order_value,
        ROUND(b.avg_order_value - s.store_avg_order_value, 2) AS aov_vs_store_avg,
        CASE
            WHEN b.avg_order_value > s.store_avg_order_value THEN 'Above Average'
            WHEN b.avg_order_value < s.store_avg_order_value THEN 'Below Average'
            ELSE 'At Average'
        END AS aov_benchmark
    FROM user_rfm_base b
    CROSS JOIN store_avg s
),

-- ---------------------------------------------------------------------------
-- 5. Score each dimension 1-5 using NTILE, a clean, standard way to bucket
--    a continuous population into quintiles without hard-coded thresholds
--    that would need re-tuning every time the data changes.
--      - Recency: FEWER days since last order = BETTER, so we order
--        DESCENDING by recency_days -> the "worst" (largest gap) bucket
--        lands in tile 1, "best" (smallest gap, most recent) in tile 5.
--      - Frequency & Monetary: MORE is better, so ascending order puts the
--        lowest values in tile 1 and highest in tile 5, same convention.
-- ---------------------------------------------------------------------------
rfm_scored AS (
    SELECT
        w.*,
        NTILE(5) OVER (ORDER BY w.recency_days DESC) AS r_score,
        NTILE(5) OVER (ORDER BY w.frequency   ASC)   AS f_score,
        NTILE(5) OVER (ORDER BY w.monetary    ASC)   AS m_score
    FROM user_rfm_with_benchmark w
),

-- ---------------------------------------------------------------------------
-- 6. CASE STATEMENTS: combine R/F/M into a single RFM_Score string (the
--    conventional "RFM cell", e.g. '545') and translate the score
--    combination into a business-readable Customer_Segment.
--    Segment logic follows the widely-used RFM heuristic:
--      Champions        : bought recently, often, and spend the most
--      Loyal Customers   : buy regularly and semi-recently, solid spenders
--      New Customers     : very recent, but not enough history yet
--      Needs Attention   : mid-pack across the board, trending down
--      At Risk           : used to buy often/well, but haven't lately
--      Hibernating       : low engagement across the board, cheap to
--                          re-activate but easy to lose for good
--      Lost              : worst recency, frequency AND monetary
-- ---------------------------------------------------------------------------
final AS (
    SELECT
        rs.user_id                                                     AS User_ID,
        u.country,
        rs.recency_days,
        rs.frequency,
        rs.monetary,
        rs.avg_order_value,
        rs.store_avg_order_value,
        rs.aov_vs_store_avg,
        rs.aov_benchmark,
        rp.total_orders,
        rp.avg_days_between_orders,
        rs.r_score,
        rs.f_score,
        rs.m_score,
        (rs.r_score || rs.f_score || rs.m_score)                       AS RFM_Score,
        (rs.r_score + rs.f_score + rs.m_score)                         AS RFM_Total,
        CASE
            WHEN rs.r_score >= 4 AND rs.f_score >= 4 AND rs.m_score >= 4
                THEN 'Champion'
            WHEN rs.r_score >= 3 AND rs.f_score >= 4 AND rs.m_score >= 3
                THEN 'Loyal Customer'
            WHEN rs.r_score >= 4 AND rs.f_score <= 2
                THEN 'New Customer'
            WHEN rs.r_score = 3 AND rs.f_score BETWEEN 2 AND 3 AND rs.m_score BETWEEN 2 AND 3
                THEN 'Needs Attention'
            WHEN rs.r_score <= 2 AND rs.f_score >= 3 AND rs.m_score >= 3
                THEN 'At Risk'
            WHEN rs.r_score <= 2 AND rs.f_score <= 2 AND rs.m_score <= 2
                THEN 'Lost'
            WHEN rs.r_score <= 3 AND rs.f_score <= 3 AND rs.m_score <= 3
                THEN 'Hibernating'
            ELSE 'Others'
        END AS Customer_Segment
    FROM rfm_scored rs
    JOIN Users u ON u.user_id = rs.user_id
    LEFT JOIN repeat_purchase_stats rp ON rp.user_id = rs.user_id
)

SELECT
    User_ID,
    RFM_Score,
    Customer_Segment,
    r_score               AS R,
    f_score                AS F,
    m_score                AS M,
    recency_days,
    frequency,
    monetary,
    avg_order_value,
    aov_benchmark,
    total_orders,
    avg_days_between_orders,
    country
FROM final
ORDER BY RFM_Total DESC, monetary DESC;
