# E-commerce-Performance-RFM
# E-Commerce Performance & RFM Dashboard

An analytical layer on top of a standard e-commerce schema that scores every
customer on **Recency, Frequency, and Monetary (RFM)** value and assigns
them to a business-readable segment — Champion, Loyal Customer, At Risk,
Hibernating, Lost, and so on.

This isn't a mockup: every file here runs. The seed data was generated
programmatically from six customer archetypes, loaded into a real SQLite
database, and the analysis query was executed against it — the sample
output in this project is the actual query result.

---

## Files

| File | Purpose |
|---|---|
| `01_schema.sql` | Table definitions: `Users`, `Products`, `Orders`, `Order_Items` |
| `02_seed_data.sql` | 90 users, 56 products, 454 orders, 1,149 order lines — generated data |
| `03_rfm_analysis.sql` | **The deliverable.** CTEs + window functions + CASE + subquery → RFM scoring & segmentation |
| `generate_seed_data.py` | Script that produced the seed data (reproducible, `seed=42`) |
| `rfm_output_sample.csv` | Full output of `03_rfm_analysis.sql` run against the seed data (89 scored customers) |

Standard SQL (SQLite dialect used for portability — `julianday()` for date
math and `NTILE()` window function). Swap `julianday('2026-08-19')` for
`CURRENT_DATE` and the query runs unmodified on Postgres/MySQL 8+/SQL
Server.

---

## Schema

```
Users          (user_id PK, signup_date, country)
Products       (product_id PK, category, cost)
Orders         (order_id PK, user_id FK, order_date, total_amount, status)
Order_Items    (order_item_id PK, order_id FK, product_id FK, quantity, price)
```

`Orders.status` is one of `completed`, `cancelled`, `refunded`. This matters
more than it looks: RFM is calculated **only on completed orders**. A
customer whose last three orders were refunded shouldn't score as
"recently active" — that's a data quality trap the query explicitly
avoids by filtering `WHERE status = 'completed'` before any scoring happens.

---

## How the query works

`03_rfm_analysis.sql` is a single query built from six CTEs, each doing one
job:

1. **`completed_orders`** — the trusted-revenue base (excludes cancelled/refunded).
2. **`purchase_sequence`** — uses `ROW_NUMBER()` to number each customer's
   orders chronologically, and `LAG()` to pull the previous order's date
   onto the same row, so the gap between consecutive purchases can be
   computed directly (`julianday(order_date) - julianday(LAG(...))`).
3. **`repeat_purchase_stats`** — aggregates that into `avg_days_between_orders`
   per customer, a concrete measure of purchase cadence used to distinguish,
   e.g., a Loyal Customer who buys every 3 weeks from one who buys every 3 months.
4. **`store_avg`** — a scalar subquery computing the store-wide average
   order value once.
5. **`user_rfm_with_benchmark`** — cross-joins each customer's own average
   order value against that store-wide subquery result, labeling them
   Above/Below/At Average.
6. **`rfm_scored`** — the actual R/F/M scoring, via `NTILE(5)`:
   - **Recency**: ordered `DESC` by days-since-last-order, so the
     longest-absent customers land in tile 1 and the most recent land in tile 5.
   - **Frequency** and **Monetary**: ordered `ASC`, so low activity/spend
     lands in tile 1 and high activity/spend in tile 5.
   - Quintiles (not fixed thresholds like ">10 orders = high") are used
     deliberately — they auto-adjust to the actual shape of the customer
     base instead of needing to be re-tuned every time the store's typical
     order volume changes.
7. **`final`** — a `CASE` statement maps the three 1–5 scores to a single
   `RFM_Score` string (e.g. `'545'`) and to a `Customer_Segment` label,
   following the standard RFM heuristic:

| Segment | R | F | M | What it means |
|---|---|---|---|---|
| **Champion** | ≥4 | ≥4 | ≥4 | Bought recently, often, and spends the most. Protect and reward these. |
| **Loyal Customer** | ≥3 | ≥4 | ≥3 | Regular, dependable spenders — not quite top-tier recency/spend but consistent. |
| **New Customer** | ≥4 | ≤2 | any | Recent buyer, not enough order history yet to know if they'll stick. |
| **Needs Attention** | =3 | 2–3 | 2–3 | Mid-pack across the board — trending neither up nor down. |
| **At Risk** | ≤2 | ≥3 | ≥3 | Used to be valuable, haven't ordered in a while — highest-value retention target. |
| **Hibernating** | ≤3 | ≤3 | ≤3 | Low engagement generally, but not yet the worst case. |
| **Lost** | ≤2 | ≤2 | ≤2 | Bottom of all three dimensions — cheapest to write off, hardest to win back. |

---

## Sample result (from the actual run)

Segment distribution across the 89 customers with at least one completed order:

| Segment | Customers |
|---|---|
| Champion | 21 |
| Lost | 19 |
| At Risk | 13 |
| New Customer | 11 |
| Loyal Customer | 10 |
| Needs Attention | 7 |
| Hibernating | 5 |
| Others | 3 |

Top row from the output (`rfm_output_sample.csv`):

```
User_ID=6  RFM_Score=555  Segment=Champion
  recency_days=15  frequency=15  monetary=$2,614.02
  avg_order_value=$174.27 (Above Average)  total_orders=15
```

The **At Risk** segment (13 customers, R≤2 but F/M≥3) is the one worth
watching most closely on a real dashboard — these are customers who
historically spent well and often, but have gone quiet. That's exactly the
list a re-engagement email campaign should target first, since they've
already proven willingness to spend, unlike Hibernating/Lost customers who
were never that valuable to begin with.

---

## Running it yourself

```bash
sqlite3 store.db < 01_schema.sql
sqlite3 store.db < 02_seed_data.sql
sqlite3 store.db < 03_rfm_analysis.sql
```

Or in Python:

```python
import sqlite3
conn = sqlite3.connect("store.db")
cur = conn.cursor()
for f in ["01_schema.sql", "02_seed_data.sql"]:
    cur.executescript(open(f).read())
cur.execute(open("03_rfm_analysis.sql").read())
rows = cur.fetchall()
```

To regenerate the seed data with a different population, edit the
`archetypes` dict in `generate_seed_data.py` (counts, order-frequency
ranges, recency ranges) and re-run it.
