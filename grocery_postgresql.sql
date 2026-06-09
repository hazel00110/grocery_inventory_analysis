-- RAW TABLE

DROP TABLE IF EXISTS grocery_raw CASCADE;

CREATE TABLE grocery_raw (
    product_id              VARCHAR(20),
    product_name            VARCHAR(100),
    category                VARCHAR(50),
    supplier_id             VARCHAR(20),
    supplier_name           VARCHAR(100),
    stock_quantity          INTEGER,
    reorder_level           INTEGER,
    reorder_quantity        INTEGER,
    unit_price              NUMERIC(10,2),
    date_received           DATE,
    last_order_date         DATE,
    expiration_date         DATE,
    warehouse_location      VARCHAR(150),
    sales_volume            INTEGER,
    inventory_turnover_rate INTEGER,
    status                  VARCHAR(20)
);


-- 1. VIEW: v_enriched

CREATE OR REPLACE VIEW v_enriched AS
SELECT
    product_id,
    product_name,
    category,
    supplier_id,
    supplier_name,
    stock_quantity,
    reorder_level,
    reorder_quantity,
    unit_price,
    date_received,
    last_order_date,
    expiration_date,
    warehouse_location,
    sales_volume,
    inventory_turnover_rate,
    status,

--  Financial metrics
    ROUND(stock_quantity * unit_price, 2)                           AS inventory_value,
    ROUND(sales_volume   * unit_price, 2)                           AS revenue_potential,

-- Sales velocity
    ROUND(sales_volume / 30.0, 4)                                   AS daily_sales_rate,

    CASE
        WHEN sales_volume > 0
        THEN ROUND(stock_quantity / (sales_volume / 30.0), 1)
        ELSE NULL
    END                                                             AS days_of_stock_remaining,

--  Stock health
    reorder_level - stock_quantity                                  AS stock_gap,

    CASE
        WHEN stock_quantity < reorder_level THEN 1
        ELSE 0
    END                                                             AS is_understocked,

    reorder_quantity - sales_volume                                 AS reorder_qty_gap,

--  Stock age (days since received, as of 2025-03-01)
    ('2025-03-01'::DATE - date_received)::INTEGER                   AS stock_age_days,

    CASE
        WHEN ('2025-03-01'::DATE - date_received) <= 30
            THEN 'Fresh (0-30d)'
        WHEN ('2025-03-01'::DATE - date_received) <= 90
            THEN 'Normal (31-90d)'
        WHEN ('2025-03-01'::DATE - date_received) <= 180
            THEN 'Aging (91-180d)'
        ELSE
            'Old Stock (180d+)'
    END                                                             AS stock_age_category

FROM grocery_raw;

-- 2. VIEW: v_abc_segmentation
-- A = top 20%  (highest value, fewest items)
-- B = next 30%
-- C = bottom 50% (lowest value, most i

CREATE OR REPLACE VIEW v_abc_segmentation AS
WITH revenue_ranked AS (
    SELECT
        product_id,
        product_name,
        category,
        supplier_name,
        status,
        stock_quantity,
        reorder_level,
        stock_gap,
        is_understocked,
        sales_volume,
        unit_price,
        inventory_value,
        revenue_potential,
        days_of_stock_remaining,
        inventory_turnover_rate,
        stock_age_days,
        stock_age_category,

        SUM(revenue_potential) OVER (
            ORDER BY revenue_potential DESC
            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
        )                                       AS cumulative_revenue,
        SUM(revenue_potential) OVER ()          AS total_revenue

    FROM v_enriched
    WHERE status = 'Active'
),
tiered AS (
    SELECT *,
        ROUND(cumulative_revenue / NULLIF(total_revenue, 0) * 100, 2) AS cumulative_pct,
        CASE
            WHEN cumulative_revenue / NULLIF(total_revenue, 0) <= 0.20 THEN 'A'
            WHEN cumulative_revenue / NULLIF(total_revenue, 0) <= 0.50 THEN 'B'
            ELSE 'C'
        END AS abc_tier
    FROM revenue_ranked
)
SELECT * FROM tiered
ORDER BY revenue_potential DESC;

-- 3. VIEW: v_reorder_priority
-- Active items below reorder level, scored by urgency.
-- Urgency score (0–1) weights three normalised signals:
-- 50% stock gap      — how far below reorder level
-- 30% sales volume   — how fast the item moves
-- 20% unit price     — financial impact of stockout

CREATE OR REPLACE VIEW v_reorder_priority AS
WITH understocked AS (
    SELECT
        e.product_id,
        e.product_name,
        e.category,
        e.supplier_name,
        e.stock_quantity,
        e.reorder_level,
        e.stock_gap,
        e.reorder_quantity,
        e.sales_volume,
        e.unit_price,
        e.revenue_potential,
        e.days_of_stock_remaining,
        e.stock_age_days,
        e.stock_age_category,
        COALESCE(a.abc_tier, 'N/A')             AS abc_tier
    FROM v_enriched e
    LEFT JOIN v_abc_segmentation a USING (product_id)
    WHERE e.status = 'Active'
      AND e.stock_quantity < e.reorder_level
),
stats AS (
    SELECT
        MAX(stock_gap)    AS max_gap,    MIN(stock_gap)    AS min_gap,
        MAX(sales_volume) AS max_sales,  MIN(sales_volume) AS min_sales,
        MAX(unit_price)   AS max_price,  MIN(unit_price)   AS min_price
    FROM understocked
),
scored AS (
    SELECT
        u.*,
        ROUND(
            CASE WHEN s.max_gap   > s.min_gap
                 THEN (u.stock_gap    - s.min_gap)   / (s.max_gap   - s.min_gap)
                 ELSE 0 END * 0.5
            +
            CASE WHEN s.max_sales > s.min_sales
                 THEN (u.sales_volume - s.min_sales) / (s.max_sales - s.min_sales)
                 ELSE 0 END * 0.3
            +
            CASE WHEN s.max_price > s.min_price
                 THEN (u.unit_price   - s.min_price) / (s.max_price - s.min_price)
                 ELSE 0 END * 0.2,
        4)                                          AS urgency_score,

        CASE
            WHEN ROUND(
                CASE WHEN s.max_gap   > s.min_gap
                     THEN (u.stock_gap    - s.min_gap)   / (s.max_gap   - s.min_gap)
                     ELSE 0 END * 0.5
                +
                CASE WHEN s.max_sales > s.min_sales
                     THEN (u.sales_volume - s.min_sales) / (s.max_sales - s.min_sales)
                     ELSE 0 END * 0.3
                +
                CASE WHEN s.max_price > s.min_price
                     THEN (u.unit_price   - s.min_price) / (s.max_price - s.min_price)
                     ELSE 0 END * 0.2,
            4) >= 0.7 THEN 'High'
            WHEN ROUND(
                CASE WHEN s.max_gap   > s.min_gap
                     THEN (u.stock_gap    - s.min_gap)   / (s.max_gap   - s.min_gap)
                     ELSE 0 END * 0.5
                +
                CASE WHEN s.max_sales > s.min_sales
                     THEN (u.sales_volume - s.min_sales) / (s.max_sales - s.min_sales)
                     ELSE 0 END * 0.3
                +
                CASE WHEN s.max_price > s.min_price
                     THEN (u.unit_price   - s.min_price) / (s.max_price - s.min_price)
                     ELSE 0 END * 0.2,
            4) >= 0.4 THEN 'Medium'
            ELSE 'Low'
        END                                         AS urgency_band

    FROM understocked u
    CROSS JOIN stats s
)
SELECT * FROM scored
ORDER BY urgency_score DESC;


-- 4. VIEW: v_supplier_risk
--    Per-supplier health metrics with TWO risk scores:
--    risk_score   — rate-based reliability score (0–100)
--                   answers: "how unreliable is this supplier?"
--                   60% backorder rate + 40% discontinuation rate
--
--    impact_score — volume-weighted business impact
--                   answers: "how much damage does this supplier cause?"
--                   risk_score × LOG(total_products + 1)
--                   a supplier with 500 products scores higher than
--                   one with 5 products at the same rate
--
--    Use risk_score   → to flag unreliable suppliers
--    Use impact_score → to prioritize which ones to fix first


CREATE OR REPLACE VIEW v_supplier_risk AS
WITH base AS (
    SELECT
        supplier_name,
        supplier_id,
        COUNT(product_id)                                                           AS total_products,
        SUM(CASE WHEN status = 'Active'       THEN 1 ELSE 0 END)                   AS active_count,
        SUM(CASE WHEN status = 'Backordered'  THEN 1 ELSE 0 END)                   AS backordered_count,
        SUM(CASE WHEN status = 'Discontinued' THEN 1 ELSE 0 END)                   AS discontinued_count,
        ROUND(AVG(sales_volume), 1)                                                 AS avg_sales_volume,
        ROUND(SUM(inventory_value), 2)                                              AS total_inventory_value,
        ROUND(AVG(stock_age_days), 1)                                               AS avg_stock_age_days,

        -- Backorder rate (% of products currently backordered)
        ROUND(
            SUM(CASE WHEN status = 'Backordered'  THEN 1 ELSE 0 END)
            * 100.0 / NULLIF(COUNT(product_id), 0), 1)                             AS backorder_rate_pct,

        -- Discontinuation rate (% of products discontinued)
        ROUND(
            SUM(CASE WHEN status = 'Discontinued' THEN 1 ELSE 0 END)
            * 100.0 / NULLIF(COUNT(product_id), 0), 1)                             AS discontinue_rate_pct

    FROM v_enriched
    GROUP BY supplier_name, supplier_id
),
scored AS (
    SELECT *,

        -- Risk score: pure rate-based reliability (0–100)
        -- High score = unreliable supplier regardless of size
        ROUND(
            backorder_rate_pct * 0.6
            + discontinue_rate_pct * 0.4,
        2)                                                                          AS risk_score,

        -- Impact score: volume-weighted business damage
        -- High score = unreliable AND affects many products
        -- LOG scales volume so 500-product suppliers don't
        -- completely overshadow 5-product suppliers
        ROUND(
            (backorder_rate_pct * 0.6 + discontinue_rate_pct * 0.4)
            * LOG(total_products + 1),
        2)                                                                          AS impact_score

    FROM base
)
SELECT *,
    -- Risk tier based on risk_score
    CASE
        WHEN risk_score >= 60 THEN 'High Risk'
        WHEN risk_score >= 30 THEN 'Medium Risk'
        ELSE 'Low Risk'
    END                                                                             AS risk_tier,

    -- Impact tier based on impact_score
    CASE
        WHEN impact_score >= 100 THEN 'High Impact'
        WHEN impact_score >= 50  THEN 'Medium Impact'
        ELSE 'Low Impact'
    END                                                                             AS impact_tier

FROM scored
ORDER BY impact_score DESC;


-- 5. VIEW: v_summary_kpis
--    Single-row snapshot for Tableau KPI cards

CREATE OR REPLACE VIEW v_summary_kpis AS
SELECT
    COUNT(*)                                                                AS total_products,
    SUM(CASE WHEN status = 'Active'       THEN 1 ELSE 0 END)               AS active_items,
    SUM(CASE WHEN status = 'Backordered'  THEN 1 ELSE 0 END)               AS backordered_items,
    SUM(CASE WHEN status = 'Discontinued' THEN 1 ELSE 0 END)               AS discontinued_items,
    SUM(CASE WHEN status = 'Active'
             AND stock_quantity < reorder_level THEN 1 ELSE 0 END)         AS urgent_reorders,
    ROUND(SUM(inventory_value), 2)                                          AS total_inventory_value,
    ROUND(SUM(CASE WHEN status = 'Active'
                    AND stock_quantity < reorder_level
                   THEN revenue_potential ELSE 0 END), 2)                  AS revenue_at_risk,
    ROUND(AVG(
        CASE WHEN days_of_stock_remaining IS NOT NULL
             THEN days_of_stock_remaining END), 1)                         AS avg_days_stock_remaining,
    ROUND(AVG(stock_age_days), 1)                                           AS avg_stock_age_days,
    SUM(CASE WHEN stock_age_category = 'Old Stock (180d+)' THEN 1 ELSE 0 END) AS old_stock_items,
    SUM(CASE WHEN stock_age_category = 'Aging (91-180d)'  THEN 1 ELSE 0 END) AS aging_items,
    COUNT(DISTINCT supplier_name)                                           AS unique_suppliers,
    ROUND(AVG(inventory_turnover_rate), 1)                                  AS avg_turnover_rate
FROM v_enriched;


-- VALIDATION

-- Row count check
SELECT 'grocery_raw'        AS view_name, COUNT(*) AS rows FROM grocery_raw
UNION ALL
SELECT 'v_enriched',                       COUNT(*) FROM v_enriched
UNION ALL
SELECT 'v_abc_segmentation',               COUNT(*) FROM v_abc_segmentation
UNION ALL
SELECT 'v_reorder_priority',               COUNT(*) FROM v_reorder_priority
UNION ALL
SELECT 'v_supplier_risk',                  COUNT(*) FROM v_supplier_risk;

-- KPI snapshot
SELECT * FROM v_summary_kpis;

-- Stock age distribution
SELECT stock_age_category, COUNT(*) AS products
FROM v_enriched
GROUP BY stock_age_category
ORDER BY MIN(stock_age_days);

-- Top 10 urgent reorders
SELECT product_name, category, abc_tier, urgency_score, urgency_band,
       stock_gap, stock_age_days, stock_age_category
FROM v_reorder_priority
LIMIT 10;

-- ABC tier distribution
SELECT abc_tier, COUNT(*) AS products,
       ROUND(AVG(revenue_potential), 2) AS avg_revenue,
       ROUND(AVG(stock_age_days), 1)    AS avg_stock_age
FROM v_abc_segmentation
GROUP BY abc_tier
ORDER BY abc_tier;

-- Top 10 riskiest suppliers
SELECT supplier_name, total_products, backorder_rate_pct,
       discontinue_rate_pct, avg_stock_age_days, risk_score
FROM v_supplier_risk
LIMIT 10;
