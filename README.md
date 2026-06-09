# 🛒 Grocery Inventory Analysis

An end-to-end data analytics portfolio project covering the full analyst stack —
data preparation in Python, feature engineering in PostgreSQL, and an interactive
dashboard published on Tableau Public.

> 📊 **[View Live Dashboard →](https://public.tableau.com/views/GroceryInventoryAnalysis_17808873066200/Dashboard1?:language=en-US&:sid=&:redirect=auth&:display_count=n&:origin=viz_share_link)**
> 
> 💻 **Dataset:** [Grocery Inventory and Sales — Kaggle](https://www.kaggle.com/datasets/salahuddinahmedshuvo/grocery-inventory-and-sales-dataset)

---

## 📌 Project Overview

Grocery retailers face constant pressure to balance stock availability against
carrying costs. This project simulates a real-world inventory analytics pipeline
that answers four core business questions:

1. **Which products are at risk of stockout and how urgent is each?**
2. **Which products drive the most revenue and deserve the most attention?**
3. **How old is our inventory and where is stock aging fastest?**
4. **Which suppliers are unreliable and how much business damage do they cause?**

---
---

## 📦 Dataset

| Attribute | Value |
|---|---|
| Source | Kaggle — Grocery Inventory and Sales Dataset |
| Records | 990 products |
| Raw columns | 16 |
| Categories | 7 (Fruits & Vegetables, Dairy, Grains & Pulses, Seafood, Oils & Fats, Beverages, Bakery) |
| Unique suppliers | 350 |
| Price range | $0.20 – $98.43 |
| Date range | Feb 2024 – Feb 2025 |
| Reference date | 2025-03-01 (used for stock age calculations) |
| Status values | Active (332), Backordered (325), Discontinued (333) |

---

## 🐍 Stage 1 — Python

**File:** `/grocery_cleaning.ipynb`

The notebook handles all data preparation before PostgreSQL ingestion:

| Step | Action |
|---|---|
| Load | Pull dataset from Kaggle using `kagglehub` |
| Inspect | Check dtypes, sample rows, unique values |
| Clean | Standardize column names to `snake_case` |
| Fix types | Strip `$` from `unit_price`, parse date columns |
| Export | Save as `grocery_dataset.csv` with `index=False` |

**Libraries:** `pandas`, `numpy`, `kagglehub`

**Key decision — `index=False` on export:**
Prevents an unnamed index column being written to the CSV,
which would cause a column count mismatch when loading into PostgreSQL.

---

## 🗄️ Stage 2 — PostgreSQL

**File:** `sql/grocery_postgresql.sql`

All feature engineering is done entirely in SQL — no Python post-processing
after the raw CSV is loaded. Five views build on each other in a layered architecture:

```
grocery_raw  (16 columns)
    └── v_enriched
          ├── v_abc_segmentation
          ├── v_reorder_priority
          ├── v_supplier_risk
          └── v_summary_kpis
```

---

### v_enriched
Base feature engineering layer. Computes all derived columns from raw data.

| New column | Formula | Purpose |
|---|---|---|
| `inventory_value` | `stock_quantity × unit_price` | Capital tied up per product |
| `revenue_potential` | `sales_volume × unit_price` | Expected monthly revenue |
| `daily_sales_rate` | `sales_volume / 30` | Average units sold per day |
| `days_of_stock_remaining` | `stock_quantity / daily_sales_rate` | Days until stockout |
| `stock_gap` | `reorder_level − stock_quantity` | How far below reorder threshold |
| `is_understocked` | `1 if stock_quantity < reorder_level` | Binary reorder flag |
| `reorder_qty_gap` | `reorder_quantity − sales_volume` | Over/under-set reorder quantity |
| `stock_age_days` | `'2024-12-01' − date_received` | Days sitting in warehouse |
| `stock_age_category` | Fresh / Normal / Aging / Old Stock | Age tier for visual grouping |

---

### v_abc_segmentation
Ranks all **Active** products by `revenue_potential` and assigns ABC tiers
using a cumulative revenue window function:

```sql
SUM(revenue_potential) OVER (
    ORDER BY revenue_potential DESC
    ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
)
```

| Tier | Cumulative revenue share | Meaning |
|---|---|---|
| A | 0 – 20% | Highest value, fewest items — monitor closely |
| B | 20 – 50% | Mid-value — standard monitoring |
| C | 50 – 100% | Low individual value — lowest priority |

---

### v_reorder_priority
Filters Active understocked items and scores each by urgency using
**min-max normalization** across three weighted signals:

```
urgency_score = (normalized stock_gap    × 0.50)
              + (normalized sales_volume × 0.30)
              + (normalized unit_price   × 0.20)
```

| Weight | Signal | Rationale |
|---|---|---|
| 50% | Stock gap | How critically understocked the item is |
| 30% | Sales volume | Fast-moving items run out sooner |
| 20% | Unit price | Higher-value stockouts cost more |

Output: `urgency_score` (0–1) + `urgency_band` (High / Medium / Low)

---

### v_supplier_risk
Aggregates per-supplier health metrics and produces two complementary scores:

**`risk_score` (0–100) — reliability**
```sql
risk_score = (backorder_rate_pct × 0.6) + (discontinue_rate_pct × 0.4)
```
Answers: *"How unreliable is this supplier?"*
Backorder rate weighted higher (60%) because it directly impacts current sales.

**`impact_score` (0–270) — business damage**
```sql
impact_score = risk_score × LOG(total_products + 1)
```
Answers: *"How much damage does this supplier cause?"*
`LOG()` scales by volume so a supplier with 500 products scores higher than
one with 5 products at the same failure rate — without letting volume
completely dominate the score.

| Score | risk_tier | impact_tier |
|---|---|---|
| risk ≥ 60 | High Risk | — |
| risk ≥ 30 | Medium Risk | — |
| impact ≥ 150 | — | High Impact |
| impact ≥ 75 | — | Medium Impact |

---

### v_summary_kpis
Single-row snapshot used to feed Tableau KPI cards directly.

| KPI | Value |
|---|---|
| Total Products | 990 |
| Active Items | 332 |
| Backordered Items | 325 |
| Discontinued Items | 333 |
| Urgent Reorders | 140 |
| Unique Suppliers | 350 |

*(Fill in Total Inventory Value, Revenue at Risk, Avg Stock Age from your pgAdmin output)*

---

### SQL Techniques Used

| Technique | Where |
|---|---|
| Window functions `SUM() OVER()` | `v_abc_segmentation` — cumulative revenue ranking |
| CTEs `WITH ... AS` | All views — multi-step transformations |
| Min-max normalization | `v_reorder_priority` — urgency scoring |
| `COALESCE` / `NULLIF` | Safe division and null handling throughout |
| `LOG()` scaling | Volume-weighted impact score in `v_supplier_risk` |
| `CASE WHEN` tiering | ABC tiers, urgency bands, risk tiers, stock age |
| `LEFT JOIN USING` | Joining ABC tiers into reorder priority |
| `CROSS JOIN` stats CTE | Min/max normalization constants |
| `::NUMERIC` casting | Fix `ROUND(double precision)` PostgreSQL type constraint |

---

## 📊 Stage 3 — Tableau Public

**[View Dashboard →](https://public.tableau.com/views/GroceryInventoryAnalysis_17808873066200/Dashboard1?:language=en-US&:sid=&:redirect=auth&:display_count=n&:origin=viz_share_link)**
The dashboard has 3 pages, each answering a specific business question:

---

## 📁 Repository Structure

```
grocery-inventory-analysis/
├── README.md
├── grocery_cleaning.ipynb     ← data prep pipeline
├── grocery_postgresql.sql     ← schema + 5 views
└── grocery_dataset.csv        ← cleaned export from notebook
```

---

## 👤 Author

**Hazel Pernanda Putra**
---
*End-to-end grocery inventory analytics — Python · PostgreSQL · Tableau Public*
