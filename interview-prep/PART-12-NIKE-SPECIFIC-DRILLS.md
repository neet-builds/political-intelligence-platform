# PART 12 — NIKE-SPECIFIC INTERVIEW DRILLS

## What Nike Actually Cares About (From Real Interview Research)

Based on Glassdoor, [dataford.io](https://dataford.io/interview-guides/nike/data-engineer), [interviewquery.com](https://www.interviewquery.com/interview-guides/nike-data-engineer), [datalemur.com](https://datalemur.com/blog/nike-sql-interview-questions), and Nike's actual ITC job postings — here are the **confirmed question patterns** for Nike Data Engineer interviews. *(Content rephrased for compliance with licensing restrictions.)*

### Confirmed SQL Question Patterns:
1. **Top-N per group** — "top 5 selling products per category"
2. **Dedup without primary key**
3. **Return rate calculations** — Nike's classic
4. **Cohort/retention queries** — "users who bought X but haven't returned in 6 months"
5. **Month-over-month growth**
6. **UNION vs UNION ALL** explanation
7. **JOIN type explanations** (LEFT vs INNER)
8. **Query optimization on millions of rows**

### Nike's Real Data Domains (Weave These Into Answers):
- **SNKRS app** — sneaker drops, raffles, high-heat launches (60-second events)
- **Nike App / Nike Run Club / Nike Training Club** — member engagement
- **Marketplace vs Nike Direct** — wholesale partners vs Nike.com/App
- **Consumer Product & Innovation (CP&I)** — *your team's domain per the JD*
- **Demand sensing** — Nike compressed forecasting from 6 months to 30 minutes using AI
- **Member tiers** — REGULAR, ELITE, X (loyalty program)
- **Returns** — apparel/footwear has 20-40% return rates online
- **1500+ retail stores** globally — inventory distribution complexity
- **Move to Zero** — sustainability reporting
- **Reseller economy** — StockX/GOAT, bot detection on drops
- **Athlete data** — Nike Run Club workouts, Apple Watch integration

### Nike-Specific Vocabulary to Use:
- "Nike Direct" = Nike.com + Nike App (D2C)
- "Marketplace" = wholesale partners (Foot Locker, etc.)
- "Style-color code" = Nike's SKU format (e.g., "DD1391-100")
- "Drop" or "launch" = product release event
- "High-heat" = limited-edition with massive demand
- "Bot mitigation" = preventing scripted purchases on drops

### Nike's Fiscal Year Quirk (Important!):
**Nike's fiscal year ends May 31.** When the interviewer says "last quarter" or "Q3," ALWAYS clarify whether they mean fiscal or calendar. This signals you've done your research.


---

## SECTION A: NIKE SQL DRILLS (8 Questions)

### Q1: Top 5 Selling Products Per Category Last Quarter

**Confirmed asked at Nike.** "Find the top 5 selling products per category for the last quarter."

**Nike framing:** "Nike sells across Footwear, Apparel, Equipment, Accessories — each with subcategories (Running, Basketball, Lifestyle). For Q3 FY24, find the top 5 by units sold within each subcategory."

**Tables:**
```
products: product_id, name, category, subcategory, gender, retail_price
sales: sale_id, product_id, sale_date, units, channel
```

**Solution:**
```sql
WITH quarterly_sales AS (
    SELECT
        p.subcategory,
        s.product_id,
        p.name,
        SUM(s.units) AS total_units,
        SUM(s.units * p.retail_price) AS total_revenue
    FROM sales s
    JOIN products p ON s.product_id = p.product_id
    WHERE s.sale_date >= '2024-09-01' AND s.sale_date < '2024-12-01'
    GROUP BY p.subcategory, s.product_id, p.name
),
ranked AS (
    SELECT *,
        DENSE_RANK() OVER (PARTITION BY subcategory ORDER BY total_units DESC) AS rank
    FROM quarterly_sales
)
SELECT subcategory, product_id, name, total_units, total_revenue
FROM ranked
WHERE rank <= 5
ORDER BY subcategory, rank;
```

**Why DENSE_RANK over ROW_NUMBER:** "If two products tie at #5, ROW_NUMBER picks one arbitrarily. DENSE_RANK includes both. Nike business teams want ties shown — losing a tied bestseller in the report would be questioned."

**Probes Amarendra would ask:**
- *"What if a product is in multiple subcategories?"* → "Then I clarify the grain. If sales rolls up by product_id only, joining with products inflates rows. I'd dedupe products to one canonical subcategory or aggregate sales by product_id first."
- *"What's 'last quarter' — fiscal or calendar?"* → **Critical Nike-specific answer:** "Nike's fiscal year ends May 31, so fiscal Q3 = Dec-Feb. Always confirms with the interviewer."
- *"Top 5 by UNITS or REVENUE?"* → "They tell different stories. Units = mass appeal. Revenue = high-margin/premium. I'd compute both since I already have the data."


---

### Q2: Calculate Return Rate Per Product (Nike's #1 SQL Question)

**Confirmed asked at Nike.** "Given Orders and Returns tables, calculate the return rate for each product."

**Why this is Nike-classic:** Returns are a massive operational pain in footwear/apparel. SNKRS has different return rules than Nike.com (some limited drops are non-returnable). Return rate is a core KPI for product quality, sizing accuracy, and fit feedback.

**Tables:**
```
orders: order_id, product_id, customer_id, order_date, units, amount
returns: return_id, order_id, return_date, units_returned, reason_code
```

**Solution:**
```sql
SELECT
    o.product_id,
    SUM(o.units) AS units_sold,
    COALESCE(SUM(r.units_returned), 0) AS units_returned,
    ROUND(
        COALESCE(SUM(r.units_returned), 0) * 100.0 / NULLIF(SUM(o.units), 0),
        2
    ) AS return_rate_pct,
    COUNT(DISTINCT o.order_id) AS order_count,
    COUNT(DISTINCT r.return_id) AS return_count
FROM orders o
LEFT JOIN returns r ON o.order_id = r.order_id
WHERE o.order_date >= CURRENT_DATE - INTERVAL '90' DAY
GROUP BY o.product_id
HAVING SUM(o.units) >= 50  -- Filter low-volume noise
ORDER BY return_rate_pct DESC;
```

**Senior touches:**
- **LEFT JOIN, not INNER:** "Inner join would only show products WITH returns. I want 0% return rate visible too — that's a positive signal."
- **NULLIF for division:** "Defensive — if zero units sold (data quality issue), division by zero would error. NULLIF returns NULL safely."
- **HAVING units >= 50:** "Low-volume products distort rates. One return on 2 units = 50% — meaningless. Filter noise."

**Probes:**
- *"What if a return crosses date boundaries — order in Q1, return in Q2?"* → "Depends on the question. By ORDER date attributes returns to when sold (good for product quality). By RETURN date attributes to operations period (good for warehouse capacity). I'd ask which view they want."
- *"How would you flag anomalously high return rates?"* → "Compare to category benchmark. Flag where `return_rate > 1.5x category_avg` AND `units_sold > 100`. This filters noise and surfaces real product issues — likely sizing problems."
- *"What's a Nike-specific reason_code we'd see?"* → "Common ones: 'TOO_LARGE' / 'TOO_SMALL' (sizing), 'COLOR_DIFFERENT' (rendering vs reality), 'QUALITY' (defect), 'CHANGED_MIND' (just doesn't want it). Sizing issues are Nike's biggest return driver."


---

### Q3: SNKRS Drop Buyers Who Haven't Returned in 6 Months (Cohort Retention)

**Confirmed pattern at Nike.** "Identify users who purchased a specific item but haven't returned [as customers] in last 6 months."

**Nike framing:** "Members who bought the Air Jordan 1 'Lost & Found' drop. Find those who haven't placed any order in the 6 months since."

**Tables:**
```
members: member_id, signup_date, tier
orders: order_id, member_id, product_id, order_date
products: product_id, name, drop_id
```

**Solution:**
```sql
WITH drop_buyers AS (
    SELECT DISTINCT
        o.member_id,
        MIN(o.order_date) AS drop_purchase_date
    FROM orders o
    JOIN products p ON o.product_id = p.product_id
    WHERE p.drop_id = 'AJ1-LOST-FOUND-2023'
    GROUP BY o.member_id
),
last_activity AS (
    SELECT member_id, MAX(order_date) AS last_order_date
    FROM orders
    GROUP BY member_id
)
SELECT
    db.member_id,
    db.drop_purchase_date,
    la.last_order_date,
    DATEDIFF(CURRENT_DATE, la.last_order_date) AS days_dormant,
    m.tier
FROM drop_buyers db
JOIN last_activity la ON db.member_id = la.member_id
JOIN members m ON db.member_id = m.member_id
WHERE la.last_order_date < CURRENT_DATE - INTERVAL '6' MONTH
ORDER BY days_dormant DESC;
```

**Probes:**
- *"Why is this useful for Nike?"* → "Churn detection on high-value members. SNKRS drop buyers are highly engaged at purchase moment but often go dormant. This list feeds re-engagement: 'we miss you, here's early access to next drop.'"
- *"What if their LAST order WAS the drop — they bought once and never came back?"* → "My query handles that. `last_order_date == drop_purchase_date`, both fall outside the 6-month window. They're in the result, with `days_dormant` ≈ 180."
- *"How would you A/B test the win-back campaign?"* → "Random 50/50 split of this dormant cohort. Treatment gets the email/push; control gets nothing. Measure orders-within-30-days post-campaign. Significance testing on conversion rate."


---

### Q4: Month-over-Month Sales Growth by Region (Confirmed asked at Nike)

**Nike framing:** "Compute MoM growth for Nike Direct (Nike.com + Nike App) revenue, broken down by region: NA, EMEA, APAC, China."

**Tables:** `orders: order_id, order_date, channel, region, amount`

```sql
WITH monthly_sales AS (
    SELECT
        region,
        DATE_TRUNC('month', order_date) AS sales_month,
        SUM(amount) AS monthly_revenue
    FROM orders
    WHERE channel IN ('NIKE_COM', 'NIKE_APP')  -- Nike Direct only
      AND order_date >= '2023-01-01'
    GROUP BY region, sales_month
)
SELECT
    region,
    sales_month,
    monthly_revenue,
    LAG(monthly_revenue) OVER (PARTITION BY region ORDER BY sales_month) AS prev_month,
    ROUND(
        (monthly_revenue - LAG(monthly_revenue) OVER (PARTITION BY region ORDER BY sales_month))
        * 100.0 / NULLIF(LAG(monthly_revenue) OVER (PARTITION BY region ORDER BY sales_month), 0),
        2
    ) AS mom_growth_pct,
    LAG(monthly_revenue, 12) OVER (PARTITION BY region ORDER BY sales_month) AS yoy_prev,
    ROUND(
        (monthly_revenue - LAG(monthly_revenue, 12) OVER (PARTITION BY region ORDER BY sales_month))
        * 100.0 / NULLIF(LAG(monthly_revenue, 12) OVER (PARTITION BY region ORDER BY sales_month), 0),
        2
    ) AS yoy_growth_pct
FROM monthly_sales
ORDER BY region, sales_month;
```

**Senior touches:**
- Computes BOTH MoM AND YoY in one pass
- `LAG(col, 12)` for YoY — same window, just offset by 12

**Probes:**
- *"China showed -28% YoY in Q3 FY26 (real Nike news). Would your query catch this?"* → "Yes — `yoy_growth_pct` for China rows would show negative values. I'd build an alert on `yoy_growth_pct < -15%` for any region+month combination, surfacing material business risk."
- *"April 2024 was a major Nike App relaunch. How separate launch effect from genuine growth?"* → "MoM April vs March is contaminated by the launch. YoY April 2024 vs April 2023 controls for seasonal/launch effects. For cleanest signal, compare YoY in months WITHOUT the launch event in either year."
- *"What about currency conversion?"* → "If `amount` is in local currency, MoM still works (each region is internally consistent). For global rollup, convert to USD using daily exchange rates. EMEA in EUR vs APAC in JPY can't be summed without conversion."


---

### Q5: Deduplicate Without a Primary Key (Confirmed asked at Nike)

**Nike framing:** "The `product_attributes` table from a legacy SAP integration has duplicate rows due to merge errors. No primary key. Same `style_color_code` can appear with same OR different attribute values. Dedupe."

```sql
-- Source: product_id, style_color_code, color_name, size_run, material, last_updated, source_system

WITH ranked AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY style_color_code  -- Nike's natural key
            ORDER BY
                last_updated DESC,         -- Most recent wins
                CASE source_system           -- Authoritative source first
                    WHEN 'SAP_PRIMARY' THEN 1
                    WHEN 'PIM' THEN 2
                    WHEN 'LEGACY_BPCS' THEN 3
                END
        ) AS rn
    FROM product_attributes
)
SELECT * EXCEPT (rn) FROM ranked WHERE rn = 1;
```

**The TRAP probe (very common):** *"What if 'duplicate' means same style_color_code with DIFFERENT attribute values?"*

**Strong answer:** "That's a data quality question, not a dedup question. If style 'DD1391-100' has two rows with different colors, they're not duplicates — they're conflicting source-of-truth. I would:
1. **Surface the conflicts first:** which style_color_codes have multiple distinct attribute combinations?
2. **Investigate:** is one source authoritative? Is `last_updated` reliable across systems?
3. **Apply rules transparently:** take latest, or from authoritative source, or flag for human review.
4. **Never silently pick one** — that's how data lies travel downstream and break trust."

```sql
-- Surface conflicts BEFORE deduping (the senior move):
SELECT style_color_code, COUNT(DISTINCT (color_name, size_run, material)) AS variants
FROM product_attributes
GROUP BY style_color_code
HAVING variants > 1
ORDER BY variants DESC;
```

**Bridge to your DBT experience:** "In DBT I'd use the `unique` test on style_color_code. If it fails, I see the failures in `dbt test` output and investigate before they enter production. This is the equivalent in raw SQL — surface failures first, dedupe second."


---

### Q6: Average Monthly Sales Per Product (Confirmed asked at Nike)

**Confirmed phrasing:** "Find the average sales amount in USD per product on a monthly basis using last year's data."

```sql
SELECT
    p.style_color_code,
    p.name,
    DATE_TRUNC('month', s.sale_date) AS sale_month,
    AVG(s.sale_amount_usd) AS avg_transaction_value,
    SUM(s.sale_amount_usd) AS total_revenue,
    COUNT(*) AS transaction_count,
    SUM(s.units) AS total_units
FROM sales s
JOIN products p ON s.product_id = p.product_id
WHERE s.sale_date >= CURRENT_DATE - INTERVAL '1' YEAR
GROUP BY p.style_color_code, p.name, DATE_TRUNC('month', s.sale_date)
ORDER BY p.style_color_code, sale_month;
```

**The trap probe:** *"Average of WHAT exactly?"*

**Strong answer:** "Two interpretations and they differ massively:
1. **AVG(sale_amount)** = average transaction value — useful for pricing/discount analysis
2. **SUM(sale_amount) / num_business_days** = average daily sales — useful for demand planning
3. **SUM(sale_amount) / num_distinct_customers** = revenue per customer — useful for cohort analysis

I'd compute all three since I'm already scanning the data, but I'd ask the interviewer which interpretation they want as the headline metric. Asking is the senior move."

---

### Q7: UNION vs UNION ALL — The Production Trap (Confirmed asked at Nike)

**Setup:** "Combine sales from Nike.com and SNKRS into one analytics view."

```sql
-- Which is correct?
SELECT order_id, member_id, amount, 'NIKE_COM' AS source FROM nike_com_orders
UNION
SELECT order_id, member_id, amount, 'SNKRS' AS source FROM snkrs_orders;
```

**Strong answer:** "`UNION` deduplicates — runs an expensive sort+distinct over the combined set. `UNION ALL` doesn't.

In this specific case: `order_id` should be unique per source (different ID-spaces), AND I'm tagging `source` differently for each side. So there are NO actual duplicates — they're disjoint by design. **UNION here is wasteful: same correctness, worse performance.** UNION ALL is correct.

**When to use UNION:**
- Combining customer lists from CRM + e-commerce where the same customer might be in both
- Small sets where sort cost is negligible
- Data integration where you EXPECT overlap

**When to use UNION ALL (my default in production):**
- Sources are disjoint by design
- Volume is large
- You want explicit dedup with ROW_NUMBER for control over which row wins

**Senior insight:** I default to UNION ALL. Explicit dedup with ROW_NUMBER + tiebreaker is more debuggable than UNION's implicit dedup. With UNION, you can't tell WHICH duplicate was kept — the engine picks arbitrarily."

**Probe:** *"At Nike scale, what's the cost difference?"* → "UNION on 1B orders requires sorting all 1B rows. That's a massive shuffle + sort — could turn a 5-min job into 1 hour. UNION ALL is essentially free (just stitches partitions). For pipelines that run nightly, this difference compounds into real DBU costs."


---

### Q8: Optimize a Slow Query on Millions of Rows (Confirmed asked at Nike)

**Setup:** "This Nike App analytics query takes 45 minutes on the orders table (5B rows). Make it faster."

```sql
-- Slow original
SELECT
    member_id,
    COUNT(*) AS order_count,
    SUM(amount) AS lifetime_value
FROM orders
WHERE EXTRACT(YEAR FROM order_date) = 2024
  AND UPPER(channel) = 'NIKE_APP'
GROUP BY member_id
ORDER BY lifetime_value DESC
LIMIT 100;
```

**Diagnosis (say this systematically):** "Three problems I see:

1. **`EXTRACT(YEAR FROM order_date) = 2024`** — function on the column prevents partition pruning. If `order_date` is the partition column (which it should be for 5B rows), the engine reads ALL partitions then filters in memory.

2. **`UPPER(channel) = 'NIKE_APP'`** — same issue. Function on column kills file pruning even if channel is a Z-Order or cluster column.

3. **`ORDER BY ... LIMIT 100`** — global sort then limit. Most engines optimize this to top-K, but worth verifying in `.explain()`.

**Optimized:**
```sql
SELECT
    member_id,
    COUNT(*) AS order_count,
    SUM(amount) AS lifetime_value
FROM orders
WHERE order_date >= '2024-01-01' AND order_date < '2025-01-01'
  AND channel = 'NIKE_APP'  -- Direct comparison, prunable
GROUP BY member_id
ORDER BY lifetime_value DESC
LIMIT 100;
```

**Further optimizations at Nike scale:**
- **Skew on member_id?** Top 1% of members (Elite tier, sneakerheads) drive 30%+ of orders. Enable AQE skew handling: `spark.sql.adaptive.skewJoin.enabled=true`.
- **Z-Order:** Run `OPTIMIZE orders ZORDER BY (member_id, channel)` weekly so file pruning works on these access columns.
- **Materialize:** If this query runs frequently, build a `gold.member_ltv_2024` table refreshed daily. Analytics queries hit the gold table — sub-second responses.
- **Approximate counts:** If exact precision isn't required, `APPROX_COUNT_DISTINCT(member_id)` is 10x faster on billions of rows.

**Expected improvement:** 45 min → under 2 min with these changes.

---

## SECTION B: NIKE PYSPARK DRILLS (6 Questions)

### Q1: Process SNKRS Drop Traffic Logs

**Setup:** "On Air Jordan drop days, SNKRS gets 100M+ requests in the first hour. Build a PySpark job that processes access logs, computes per-second request rates, identifies bot patterns, outputs a clean event stream for analytics."

```python
from pyspark.sql.functions import (
    col, count, window, when, broadcast,
    countDistinct, hour, minute
)

# Read raw access logs (5TB for one drop day)
logs = spark.read.format("parquet").load("s3://snkrs-logs/2024-11-09/")

# 1. Per-second request rate by endpoint
per_second = (
    logs
    .groupBy(window("request_time", "1 second"), "endpoint")
    .agg(count("*").alias("rps"))
    .filter(col("rps") > 1000)  # Anomaly threshold
)
```


```python
# 2. Bot detection: high requests/sec from single IP, low UA diversity
bot_candidates = (
    logs
    .groupBy(window("request_time", "10 seconds"), "ip_address")
    .agg(
        count("*").alias("requests_10s"),
        countDistinct("user_agent").alias("ua_diversity"),
        countDistinct("session_id").alias("session_count"),
        countDistinct("member_id").alias("member_count")
    )
    .filter(
        (col("requests_10s") > 100) |  # Volume anomaly
        ((col("requests_10s") > 50) & (col("ua_diversity") < 2)) |  # Headless bot
        ((col("session_count") > 10) & (col("member_count") < 3))   # Session farming
    )
)

# 3. Clean event stream (legitimate users only)
bot_ips = bot_candidates.select("ip_address").distinct()
clean_events = (
    logs
    .join(broadcast(bot_ips), "ip_address", "left_anti")  # Exclude bots
    .filter(col("response_code") == 200)
)

clean_events.write.format("delta").mode("overwrite") \
    .partitionBy("event_hour") \
    .save("s3://gold/snkrs_clean_events/")
```

**Probes:**
- *"Why broadcast the bot IPs?"* → "Bot list is small (likely <10K IPs even on a heavy drop). Broadcast eliminates shuffle on the 5TB log table — turns a sort-merge into a hash lookup per row."
- *"Why `left_anti` instead of NOT IN?"* → "`left_anti` is the SQL `WHERE NOT EXISTS` equivalent. Cleaner than `~col('ip').isin(bot_list)`, which would require collecting bot list to driver — defeats the broadcast benefit."
- *"What if bot list is huge (millions)?"* → "Broadcast OOMs the driver. I'd add a size guardrail: `if bot_ips.count() > 100K → switch to sort-merge join` with bot_ips as right side. Or use a Bloom filter for approximate exclusion."
- *"This is a Nike-specific signal — what other bot patterns matter?"* → "Add: (a) impossibly fast checkout time (<2 sec from add-to-cart to purchase), (b) repeated identical payment tokens across different members, (c) shipping addresses from known reseller hubs, (d) device fingerprints that match across multiple member accounts."

---

### Q2: Inventory Reconciliation Across 1500+ Stores

**Setup:** "Daily, you receive inventory snapshots from Nike's 1500+ stores globally and compare against SAP system inventory. 50M SKU-store combinations daily. Flag discrepancies."

```python
from pyspark.sql.functions import (
    col, abs as _abs, when, broadcast, coalesce, lit
)

# Physical inventory from store POS
physical = spark.read.format("delta").table("bronze.store_inventory_snapshot") \
    .filter(col("snapshot_date") == current_date()) \
    .select("store_id", "style_color_code", "size", "physical_qty")

# System of record from SAP
expected = spark.read.format("delta").table("bronze.sap_inventory") \
    .filter(col("as_of_date") == current_date()) \
    .select("store_id", "style_color_code", "size", "expected_qty")

# Store dim is small — broadcast
stores = spark.read.format("delta").table("dim.stores") \
    .select("store_id", "region", "country", "store_type", "is_flagship")

discrepancies = (
    physical.alias("p")
    .join(expected.alias("e"),
          ["store_id", "style_color_code", "size"],
          "full_outer")  # Capture both: missing physical AND missing expected
    .join(broadcast(stores), "store_id")
    .withColumn("physical_qty", coalesce(col("p.physical_qty"), lit(0)))
    .withColumn("expected_qty", coalesce(col("e.expected_qty"), lit(0)))
    .withColumn("variance", col("physical_qty") - col("expected_qty"))
    .withColumn("severity",
        when(_abs(col("variance")) > 10, "HIGH")
        .when(_abs(col("variance")) > 3, "MEDIUM")
        .when(_abs(col("variance")) > 0, "LOW")
        .otherwise("MATCH")
    )
    .filter(col("severity") != "MATCH")
)


discrepancies.write.format("delta").mode("overwrite") \
    .partitionBy("region", "severity") \
    .save("s3://gold/inventory_discrepancies/")
```

**Probes:**
- *"Why FULL OUTER JOIN?"* → "Inner misses cases where physical exists but SAP doesn't (theft/loss not yet recorded) AND vice versa (system shows stock but warehouse can't find it). Both are real discrepancies. Full outer captures both."
- *"Why partition by region first, then severity?"* → "Ops teams query by region (each region has its own ops team). Within region, they filter to HIGH severity. Partition order matches access pattern."
- *"What's the skew risk?"* → "Flagship stores (NYC, Shanghai, Tokyo) have 100x the SKU count of small franchise stores. The store_id distribution is heavily skewed. If the join shuffles by store_id, flagship stores create stragglers. Mitigation: AQE skew handling, or pre-aggregate physical/expected by store before the join."
- *"How would you reconcile a store with TIMING differences — physical inventory at 14:03 but a sale at 14:01 hasn't propagated?"* → "Add a grace period: only compare snapshots with transactions up to `snapshot_time - 5 min`. Accounts for propagation delay. Eliminates false positives from in-flight transactions."

---

### Q3: Real-Time Member Tier Calculation (Streaming)

**Setup:** "Nike Membership has tiers — REGULAR, ELITE, X (top 1%). Tier is based on rolling 12-month spend. Build a Structured Streaming job that updates tier in real-time as orders flow in."

```python
from pyspark.sql.functions import (
    col, sum as _sum, window, when, from_json
)

orders_stream = (
    spark.readStream.format("kafka")
    .option("kafka.bootstrap.servers", "kafka:9092")
    .option("subscribe", "nike-orders")
    .load()
    .select(from_json(col("value").cast("string"), order_schema).alias("o"))
    .select("o.*")
    .withWatermark("order_time", "24 hours")
)

# Rolling 12-month spend per member
member_spend = (
    orders_stream
    .groupBy("member_id", window("order_time", "365 days", "1 day"))
    .agg(
        _sum("amount").alias("rolling_12mo_spend"),
        _sum("units").alias("rolling_units")
    )
)

# Tier logic with Nike's actual thresholds (illustrative)
member_tier = member_spend.withColumn("tier",
    when(col("rolling_12mo_spend") >= 5000, "X")
    .when(col("rolling_12mo_spend") >= 1000, "ELITE")
    .otherwise("REGULAR")
)

def upsert_to_delta(batch_df, batch_id):
    batch_df.createOrReplaceTempView("staging")
    spark.sql("""
        MERGE INTO gold.member_tier T
        USING staging S ON T.member_id = S.member_id
        WHEN MATCHED AND T.tier != S.tier THEN UPDATE SET *
        WHEN NOT MATCHED THEN INSERT *
    """)
```


```python
query = (
    member_tier.writeStream
    .foreachBatch(upsert_to_delta)
    .option("checkpointLocation", "s3://checkpoints/member_tier/")
    .trigger(processingTime="5 minutes")
    .start()
)
```

**Probes:**
- *"365-day window in streaming = huge state. How big?"* → "Each member's window state is small (just a running sum), maybe 50 bytes. 350M Nike members × 50B = 17.5GB across executors. Manageable. Critical: have to keep state ONLY for active members, not all 350M historic. Watermark + state TTL handles this — members with no orders in 13 months drop out of state."
- *"What if a member crosses tier threshold mid-day?"* → "Promotion event: REGULAR → ELITE. Downstream consumers care (welcome email, badge update on app, SNKRS early access). I'd emit `tier_change_event` to a separate Kafka topic. The stream above maintains the LATEST tier; the change topic captures DELTAS for reactive systems."
- *"What about demotion?"* → "Tricky. If member spend drops below threshold, do we demote? Nike likely uses 'at least once during fiscal year' for tier qualification, not strictly rolling. I'd clarify the business rule. If demotion is allowed, my logic handles it. If 'sticky' tier (qualified once = elite for 12 months), I'd add: `WHEN MATCHED AND T.tier_locked_until > current_date() THEN keep T.tier`."

---

### Q4: Sneaker Reseller Detection (Behavioral Analytics)

**Setup:** "Nike is concerned about resellers — bots/people buying limited drops to resell on StockX/GOAT. Build a PySpark transform that flags suspicious member behavior over the last 30 days."

```python
from pyspark.sql.functions import (
    countDistinct, count, when, sum as _sum, datediff, lit
)

orders_30d = spark.read.format("delta").table("silver.orders") \
    .filter(col("order_date") >= current_date() - 30)

member_signals = (
    orders_30d
    .groupBy("member_id")
    .agg(
        count("*").alias("order_count"),
        countDistinct("shipping_address_hash").alias("ship_addr_count"),
        countDistinct("payment_method_id").alias("payment_methods"),
        countDistinct("device_fingerprint").alias("device_count"),
        countDistinct(when(col("is_limited_drop") == True, col("order_id")))
            .alias("drop_orders"),
        countDistinct(when(col("billing_zip") != col("shipping_zip"), col("order_id")))
            .alias("zip_mismatches"),
        _sum(when(col("size") == "12", 1).otherwise(0)).alias("size_12_orders"),
        # Common reseller pattern: resellers often buy size 9-12 (high-demand resale sizes)
    )
)

# Composite reseller score
suspicious = member_signals.withColumn("reseller_score",
    when(col("ship_addr_count") > 5, 30).otherwise(0)
    + when(col("payment_methods") > 3, 20).otherwise(0)
    + when(col("drop_orders") >= 3, 30).otherwise(0)
    + when(col("zip_mismatches") > 2, 20).otherwise(0)
    + when(col("device_count") > 4, 25).otherwise(0)
).filter(col("reseller_score") >= 50)

suspicious.write.format("delta").mode("overwrite") \
    .saveAsTable("gold.suspected_resellers")
```


**Why this is Nike-classic:**
- Reseller economy on StockX/GOAT is huge for Nike (limited drops = $$$)
- Air Jordan 1, Dunks, Travis Scott collabs are prime reseller targets
- Nike actively blocks confirmed resellers from SNKRS access
- Real feature engineering that mirrors actual fraud detection ML pipelines

**Probes:**
- *"False positives — gift-buyers ship to multiple addresses?"* → "True. Score is a SIGNAL not a verdict. High-score members go to fraud/trust team for human review, not auto-blocked. Thresholds tuned based on confirmed reseller examples vs false-positive rates from past reviews."
- *"How would you train an ML model on this?"* → "Treat human-confirmed reseller flags as labels. Features: the columns I computed + behavioral patterns over time. Model: XGBoost for tabular, imbalanced classes (smote or class weights). SHAP values for explainability — when blocking a member, we need to be able to justify the decision."
- *"What's the Nike-specific bias to avoid?"* → "Cultural communities buying for friends/family in Asia and the Middle East legitimately use multiple shipping addresses. The model must NOT learn 'shipping to certain countries = reseller.' I'd validate fairness across geographic and demographic segments before deployment."

---

### Q5: Joining Skewed Drop Day Data

**Setup:** "When Air Jordan 1 'Chicago' dropped, 40% of all SNKRS orders that day were for that single product. Your daily orders-with-product-details job is taking 8 hours instead of 30 minutes."

**Diagnosis (say this):** "Classic key skew on `product_id`. The sort-merge join shuffles both sides by product_id — one executor gets 40% of the data on the AJ1-Chicago partition. While 199 other executors finish in 5 minutes, this one takes 4 hours."

**Solution — Hot Key Isolation (best for known hot keys):**
```python
HOT_PRODUCT = "AJ1-CHI-2024"

# Split the fact table
orders_hot = orders.filter(col("product_id") == HOT_PRODUCT)
orders_cold = orders.filter(col("product_id") != HOT_PRODUCT)

# Hot path: broadcast the SINGLE matching product row (trivial size)
products_hot = products.filter(col("product_id") == HOT_PRODUCT)
joined_hot = orders_hot.join(broadcast(products_hot), "product_id")

# Cold path: normal sort-merge — no skew remaining
joined_cold = orders_cold.join(products, "product_id")

# Combine
result = joined_hot.unionByName(joined_cold)
```

**Nike-specific probe:** *"How would you predict skew BEFORE it happens?"*

**Strong answer:** "Nike publishes the drop calendar in advance. SNKRS team knows AJ1-Chicago is dropping on Saturday. I'd parameterize my pipeline:
```python
# Read drop calendar
drops_today = spark.read.table("ops.drop_calendar") \
    .filter(col("drop_date") == current_date()) \
    .select("product_id").rdd.flatMap(lambda x: x).collect()

if drops_today:
    # Hot-key isolation mode
    apply_hot_key_strategy(drops_today)
else:
    # Default: AQE skew handling
    spark.conf.set("spark.sql.adaptive.skewJoin.enabled", "true")
```

This is the senior move — anticipate the skew based on business calendar, not just react to it."


---

### Q6: Nike Run Club Engagement Score (Window Functions)

**Setup:** "For each Nike Run Club member, compute their engagement score: blend of weekly run frequency, total miles, app sessions, and store visits over a rolling 90 days."

```python
from pyspark.sql.functions import (
    col, sum as _sum, least, lit, when
)
from pyspark.sql.window import Window

daily_activity = spark.read.format("delta").table("silver.member_daily_activity") \
    .filter(col("activity_date") >= current_date() - 90)

# Rolling 90-day window
w_90d = (
    Window.partitionBy("member_id")
    .orderBy("activity_date")
    .rowsBetween(-89, 0)
)

engagement = (
    daily_activity
    .withColumn("rolling_runs", _sum("run_count").over(w_90d))
    .withColumn("rolling_miles", _sum("miles_run").over(w_90d))
    .withColumn("rolling_sessions", _sum("app_session_count").over(w_90d))
    .withColumn("rolling_store_visits", _sum("store_visit_count").over(w_90d))
    .filter(col("activity_date") == current_date() - 1)  # Latest snapshot
)

# Composite score (weighted blend, capped at 1.0)
engagement_scored = engagement.withColumn(
    "raw_score",
    (col("rolling_runs") / 50.0 * 0.30        # 50 runs in 90d = max
   + col("rolling_miles") / 200.0 * 0.30      # 200 miles = max
   + col("rolling_sessions") / 90.0 * 0.20    # ~daily app user = max
   + col("rolling_store_visits") / 5.0 * 0.20  # 5 visits = max
    ).cast("double")
).withColumn("engagement_score",
    least(col("raw_score"), lit(1.0))  # Cap at 1.0
)
```

**Probes:**
- *"Why window function instead of GROUP BY?"* → "Window keeps the daily granularity, then I filter to today. GROUP BY would collapse to one row per member. With window, I COULD output daily score history if needed without re-running. Also Spark can pipeline window+filter efficiently."
- *"Skew on member_id?"* → "Top 1% of members (Elite tier marathon runners) might have 100x the daily activity rows of average. AQE skew handling helps. Better: my source `daily_activity` is already pre-aggregated to one row per (member_id, day), so the window has at most 90 rows per member — bounded skew."
- *"How does this feed Nike Run Club's product?"* → "Score drives: (a) personalized challenge recommendations ('try a 5K this week'), (b) coaching content tier, (c) tier qualification for elite running community access, (d) marketing segmentation for product launches relevant to runners."


---

## SECTION C: NIKE PYTHON DRILLS (4 Questions)

### Q1: SNKRS Raffle Winner Selection

**Setup:** "SNKRS uses raffles for high-heat drops. Members enter; a random subset wins. Write a Python function that processes raffle entries, validates them, dedupes, and selects N winners with weighted probability based on member tier."

```python
from dataclasses import dataclass
import random
from typing import Optional

@dataclass
class RaffleEntry:
    member_id: str
    member_tier: str  # REGULAR, ELITE, X
    entry_time: str
    shipping_country: str
    payment_verified: bool

# Tier weights — Elite/X members get higher win probability
TIER_WEIGHTS = {"REGULAR": 1.0, "ELITE": 2.0, "X": 5.0}

def select_raffle_winners(
    entries: list[RaffleEntry],
    num_winners: int,
    eligible_countries: set[str],
    seed: Optional[int] = None
) -> list[RaffleEntry]:
    """
    Select raffle winners with tier-weighted probability.
    Idempotent: same seed → same winners. Auditable.
    """
    # Validate
    valid = [
        e for e in entries
        if e.payment_verified and e.shipping_country in eligible_countries
    ]

    # Dedupe by member_id (first entry wins per member)
    seen = set()
    unique = []
    for e in sorted(valid, key=lambda x: x.entry_time):
        if e.member_id not in seen:
            seen.add(e.member_id)
            unique.append(e)

    if len(unique) <= num_winners:
        return unique  # Not enough entries; everyone wins

    # Weighted random sampling without replacement
    rng = random.Random(seed)
    candidates = [(e, TIER_WEIGHTS.get(e.member_tier, 1.0)) for e in unique]
    winners = []

    for _ in range(num_winners):
        total_weight = sum(w for _, w in candidates)
        r = rng.uniform(0, total_weight)
        cumulative = 0
        for i, (entry, weight) in enumerate(candidates):
            cumulative += weight
            if r <= cumulative:
                winners.append(entry)
                candidates.pop(i)
                break

    return winners
```


**Probes:**
- *"Why deterministic seed?"* → "Auditability. If a member disputes the result, we re-run with the same seed and prove the outcome. Also for testing — same input always produces same output, making unit tests stable."
- *"Why first-entry wins on dedup, not random?"* → "Fairness. Two entries from the same member shouldn't penalize OR reward — first one counts. Also prevents bot scripts from flooding entries to increase win odds."
- *"How does this scale to 5M raffle entries?"* → "Single Python won't OOM (5M × 200 bytes = 1GB). For VERY large drops (10M+ entries), I'd partition by tier first, sample within each tier proportionally, then combine. Or move to PySpark with `Window.orderBy(rand(seed=...))` for distributed sampling."
- *"What's the production wrinkle?"* → "Anti-fraud must run BEFORE this. If a member is on the suspected reseller list (from PySpark Q4), exclude them at validation step. Add: `if e.member_id in known_resellers_set: skip`."

---

### Q2: Validate Nike Product Catalog API Response

**Setup:** "Nike's product catalog API occasionally returns inconsistent data. Build a Python validator with Nike-specific rules."

```python
# Reuse DataValidator from Part 7, with Nike-specific rules:

nike_product_rules = [
    # Style-color code: 6 alphanumeric, dash, 3 digits (e.g., "DD1391-100")
    ValidationRule("style_color_code", "regex",
                   {"pattern": r"^[A-Z0-9]{6}-[0-9]{3}$"}),
    ValidationRule("category", "enum", {
        "allowed_values": ["FOOTWEAR", "APPAREL", "EQUIPMENT", "ACCESSORIES"]
    }),
    ValidationRule("gender", "enum", {
        "allowed_values": ["MENS", "WOMENS", "UNISEX", "BOYS", "GIRLS", "INFANT"]
    }),
    ValidationRule("retail_price_usd", "range", {"min": 0.01, "max": 5000}),
    ValidationRule("launch_date", "not_null"),
    ValidationRule("brand", "enum", {
        "allowed_values": ["NIKE", "JORDAN", "CONVERSE", "NIKE_SB", "NIKELAB"]
    }),
    ValidationRule("size_run", "custom", {
        "func": lambda v: (
            isinstance(v, list) and len(v) > 0,
            "Must be non-empty size array"
        )
    }),
    # Nike-specific: Move to Zero sustainability score should be 0-100
    ValidationRule("sustainability_score", "range", {"min": 0, "max": 100}),
]

# Apply to incoming catalog data
validator = DataValidator(nike_product_rules)
result = validator.validate(catalog_response_records)

if result.error_rate > 0.02:  # >2% invalid = upstream issue
    raise DataQualityError(
        f"Catalog validation failed: {result.error_rate:.1%} invalid records. "
        f"Top violations: {summarize_violations(result.violations)}"
    )
```

**Probe:** *"What if Nike adds a new sub-brand (e.g., a new acquisition)?"* → "The ENUM rule fails on the new brand → pipeline alerts → I add the new value to the allowed list after confirming with the catalog team. This is the desired behavior — schema drift should be visible, not silent. The alternative (skip validation) means new categories silently pass through and break downstream consumers expecting the old taxonomy."


---

### Q3: Member LTV — Incremental Update Pattern

**Setup:** "Nike has 350M+ members globally. Recomputing LTV for every member daily is wasteful. Write an incremental update."

```python
from datetime import datetime
from google.cloud import bigquery  # Your GCP stack
import logging

logger = logging.getLogger(__name__)

def update_member_ltv_incremental(execution_date: str):
    """
    Incrementally update member LTV using yesterday's orders only.
    Idempotent for execution_date — safe to re-run.
    """
    client = bigquery.Client()

    # Step 1: Stage yesterday's activity
    stage_sql = f"""
    CREATE OR REPLACE TABLE `nike.staging.member_daily_activity_{execution_date}` AS
    SELECT
        member_id,
        SUM(net_amount_usd) AS daily_spend,
        SUM(units) AS daily_units,
        COUNT(*) AS daily_orders,
        MAX(order_time) AS last_order_time,
        DATE('{execution_date}') AS as_of_date
    FROM `nike.silver.orders`
    WHERE order_date = '{execution_date}'
      AND order_status = 'COMPLETED'
    GROUP BY member_id
    """
    client.query(stage_sql).result()

    # Step 2: MERGE — idempotent on (member_id, as_of_date)
    merge_sql = f"""
    MERGE `nike.gold.member_ltv` T
    USING `nike.staging.member_daily_activity_{execution_date}` S
    ON T.member_id = S.member_id

    WHEN MATCHED AND T.last_processed_date < S.as_of_date THEN UPDATE SET
        T.lifetime_spend = T.lifetime_spend + S.daily_spend,
        T.lifetime_units = T.lifetime_units + S.daily_units,
        T.lifetime_orders = T.lifetime_orders + S.daily_orders,
        T.last_order_date = S.as_of_date,
        T.last_processed_date = S.as_of_date,
        T.updated_at = CURRENT_TIMESTAMP()

    WHEN NOT MATCHED THEN INSERT (
        member_id, lifetime_spend, lifetime_units, lifetime_orders,
        first_order_date, last_order_date, last_processed_date, updated_at
    ) VALUES (
        S.member_id, S.daily_spend, S.daily_units, S.daily_orders,
        S.as_of_date, S.as_of_date, S.as_of_date, CURRENT_TIMESTAMP()
    )
    """
    job = client.query(merge_sql)
    job.result()
    logger.info(f"LTV updated. Rows affected: {job.num_dml_affected_rows}")
```

**The IDEMPOTENCY trap (key probe):**
*"What if execution_date runs twice? LTV would double-count, right?"*

**Strong answer:** "Without protection — yes. That's why I added `T.last_processed_date < S.as_of_date` to the MATCH condition. On the second run for the same date, `T.last_processed_date == S.as_of_date`, so the UPDATE is skipped. Idempotent.

The pattern: **the merge target tracks the last date it absorbed**. Subsequent merges only apply if they bring NEW dates. This is a watermark pattern at the row level."


---

### Q4: Sustainability API Enrichment (Move to Zero)

**Setup:** "Enrich 100K Nike products with carbon footprint data from an external sustainability API. Rate limit: 50 req/sec. Need to feed Move to Zero reporting."

```python
import asyncio
from typing import Optional

# Reuse ResilientAPIClient from Part 7

async def enrich_with_sustainability(product_ids: list[str]) -> list[dict]:
    """
    Fetch carbon footprint for Nike's Move to Zero reporting.
    Concurrent + rate-limited + retry-resilient.
    """
    async with ResilientAPIClient(
        base_url="https://sustainability-api.nike.internal",
        api_key=get_secret("sustainability_api_key"),
        max_rps=40  # 80% of 50 limit for safety margin
    ) as client:
        requests = [
            {"endpoint": f"products/{pid}/footprint", "params": {}}
            for pid in product_ids
        ]
        return await client.fetch_many(requests, concurrency=15)

# Usage in pipeline:
# enriched = asyncio.run(enrich_with_sustainability(product_ids))
```

**Why this is Nike-flavored:**
- **Move to Zero** is Nike's actual sustainability initiative
- Carbon footprint per product is a real data engineering problem at Nike
- Pulls from manufacturing systems (factories), materials database (cotton/polyester sources), logistics (shipping emissions)
- Output feeds: internal sustainability dashboards, consumer-facing "sustainability score" on Nike.com, regulatory reporting (EU CSRD)

**Probes:**
- *"Why 80% of rate limit?"* → "Safety margin. Rate limits are usually rolling-window not strict per-second. Bursting to 100% triggers 429s, which forces exponential backoff — net throughput is LOWER than just running at 80%. Also: if multiple instances of my service share the quota, this leaves headroom."
- *"What if the sustainability API is down for 6 hours?"* → "I wouldn't fail the entire pipeline. Use a circuit breaker pattern: after N consecutive failures, mark API as DOWN, write products with `sustainability_score = NULL` and a flag column `enrichment_status = 'API_DOWN_RETRY_LATER'`. A separate retry job picks them up later. Pipeline keeps moving — sustainability data backfills async."
- *"How do you handle the 100K products that don't change daily?"* → "Cache aggressively. Sustainability scores for a finished product change rarely (only when manufacturing process changes). I'd compute hash of product attributes, lookup cache, only re-fetch on cache miss or hash change. Reduces API calls from 100K daily to ~500 (only changed/new products)."


---

## SECTION D: NIKE-SPECIFIC DESIGN QUESTIONS

### D1: Real-Time Inventory for High-Heat Drops (Confirmed asked)

**Confirmed Nike interview question** (from Engineering Manager guide): "Walk me through how you would architect a real-time inventory check system for high-heat product launches."

Apply the framework from Part 8, with these **Nike-specific design decisions**:

**Hard Requirements:**
- 1M+ concurrent users in first 60 seconds of drop
- Inventory MUST be accurate (oversell = customer fury, undersell = revenue loss)
- Pre-allocated inventory by region (avoid global lock contention)
- Sub-100ms availability check latency
- Graceful degradation if any component fails

**Architecture:**
```
[Pre-Drop]
  Inventory Service → Allocates per-region inventory pools to Redis
                    → Each pool: { product_id, size, region, available_qty }

[During Drop]
  User → Nike App → API Gateway → Inventory Check (Redis DECRBY atomic)
                                ↓ (success)
                          Reserve in DynamoDB (90-second TTL)
                                ↓ (checkout completes)
                          Confirm reservation → Order created
                          (else: TTL expires → Redis quantity restored)

[Post-Drop]
  Reconciliation: Redis state ↔ DynamoDB orders ↔ SAP inventory
                  Discrepancies → Ops review (within 1 hour SLA)
```

**Key design moves:**
1. **Pre-allocate per region** — avoids contention on a single global counter
2. **Atomic DECRBY** — Redis primitive guarantees no oversells under race conditions
3. **TTL-based reservations** — abandoned carts auto-restore inventory after 90s
4. **Async order creation** — Redis is the gate; DB writes happen after
5. **Read replicas for browsing** — strong consistency only on the buy path

### D2: Demand Sensing Pipeline (Nike's Stated 30-Min Goal)

**Real Nike initiative:** Nike publicly aims to compress demand forecasting from 6 months to 30 minutes using AI.

**Inputs:**
- Historical sales (5+ years from data warehouse)
- Real-time POS feeds from 1500 stores (Kafka)
- Web/app behavior signals (early intent: search, wishlist, cart-add)
- External signals: weather, holidays, competitor launches, social sentiment
- Inventory positions globally (live)

**Output:** Per-SKU per-store demand forecast for next 4 weeks. Updated hourly.

**Architecture:**
```
Batch (nightly): historical patterns → train baseline model → S3
Stream (continuous): real-time signals → feature engineering → online feature store
Inference (hourly): baseline forecast × real-time multipliers → demand forecast
                  → publish to inventory planning system
                  → drive auto-replenishment orders to factories
```


---

## SECTION E: NIKE-SPECIFIC POWER PHRASES

Use these naturally to signal you've researched Nike. Each one earns credibility.

1. **"Nike's fiscal year ends May 31, so when you say 'last quarter,' I want to confirm whether that's calendar or fiscal."** *(Use on any time-bound SQL question.)*

2. **"For high-heat drops on SNKRS, I'd design for write-throughput first — read availability is secondary because it's a 60-second event."** *(Real-time inventory question.)*

3. **"Returns rate is a critical KPI for Nike's footwear/apparel — sizing inconsistencies drive returns and they're a big margin hit."** *(Any returns/quality question.)*

4. **"With 1500+ stores globally, store-level data has natural skew — flagship stores generate 100x revenue of secondary locations."** *(Skew or partitioning question.)*

5. **"Nike Direct (Nike.com + Nike App) and Marketplace (wholesale partners) have very different data shapes — I'd model them as separate facts before unifying at gold."** *(Data modeling question.)*

6. **"Nike Membership data is 350M+ members globally — for any per-member computation, incremental processing isn't optional, it's required."** *(LTV / member analytics question.)*

7. **"For Move to Zero sustainability reporting, I'd think about data lineage from raw materials through manufacturing through retail — full lifecycle tracking."** *(Data governance / lineage question.)*

8. **"Reseller economy is a real concern at Nike — bot detection on drops and account integrity is a first-class data problem, not an afterthought."** *(Fraud/security question.)*

9. **"China is a separate fiscal segment for Nike — data residency requirements may force regional pipeline isolation."** *(Architecture / multi-region question.)*

10. **"Nike's demand sensing initiative aims to compress forecasting from 6 months to 30 minutes — that's the kind of latency target that drives architectural decisions."** *(Streaming or ML/data question.)*

---

## SECTION F: QUESTIONS TO ASK AMARENDRA (Nike-Specific)

Add these to the questions in Part 11 — they show you understand Nike specifically:

1. *"How does the CP&I (Consumer Product & Innovation) data team's platform interact with the broader Nike Direct and Marketplace stacks?"*

2. *"What's this team's relationship to Nike's Demand Sensing initiative — are you contributing data or consuming it?"*

3. *"How mature is Nike's medallion architecture on Databricks? Are most CP&I tables on Delta Lake yet, or still in transition?"*

4. *"For high-heat drops on SNKRS, does CP&I own any of that real-time data infrastructure, or is it owned by a different team?"*

5. *"What's the team's biggest data engineering challenge right now — scale, governance, real-time, or developer velocity?"*

6. *"How does the team work with the AI/ML organization at Nike — particularly given the personalization and demand forecasting investments?"*

7. *"What does success in the first 90 days look like for someone in this role at Nike ITC?"*

---

## SECTION G: NIKE INTERVIEW DAY CHEAT SHEET

**One-page summary to glance at Tuesday morning:**

### SQL Quick Templates
```sql
-- Top N per group → DENSE_RANK() OVER (PARTITION BY x ORDER BY y DESC)
-- Dedup → ROW_NUMBER() OVER (PARTITION BY natural_key ORDER BY recency)
-- MoM growth → LAG(metric) OVER (PARTITION BY dim ORDER BY month)
-- Return rate → SUM(returned) / NULLIF(SUM(sold), 0) * 100
-- Cohort retention → date_diff between first action and most recent action
-- UNION ALL by default, UNION only when explicit dedup needed
```

### PySpark Quick Templates
```python
# Skew → broadcast(small_df) OR salt the join key OR AQE
# OOM → check collect/toPandas, broadcast size, partition skew
# Dedup → row_number() over Window.partitionBy(key).orderBy(time.desc())
# Incremental → MERGE INTO target USING source ON keys WHEN MATCHED ... WHEN NOT MATCHED
# Late data → withWatermark(event_time, "X hours")
```

### Nike-Specific Context to Drop In
- SNKRS / drops / high-heat / bot detection
- 1500+ stores / Nike Direct vs Marketplace
- 350M members / tier qualification
- Move to Zero sustainability
- Demand sensing 6mo → 30min goal
- Fiscal year ends May 31

You're prepped. Go close it Tuesday.
