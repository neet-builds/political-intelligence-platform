# PART 4 — SQL DEEP INTERVIEW GRILLING

## How Interviewers Think About SQL Rounds

Amarendra will NOT give you a textbook SQL question. He'll give you a **business problem** and watch:
1. Do you clarify edge cases BEFORE writing?
2. Do you think about performance WHILE writing?
3. Can you handle follow-ups that break your first solution?
4. Do you know WHY your solution works, not just THAT it works?

The interview pattern is: **Easy question → you solve it → they add complexity → they ask about scale → they ask what breaks.**

---

## EXERCISE 1: Revenue Attribution with Overlapping Windows

### The Setup (as interviewer would say it):

> "We have a Nike ecommerce platform. Users see multiple ads before purchasing. I need to attribute revenue to ad campaigns. A user can be influenced by multiple campaigns within a 7-day attribution window before purchase. Give each campaign proportional credit based on recency — most recent touchpoint gets more credit."

**Table: `ad_impressions`**
```
user_id | campaign_id | impression_time
```

**Table: `purchases`**
```
user_id | purchase_id | purchase_time | revenue
```

### Step 1: Clarify (SAY THIS OUT LOUD)

"Before I write — let me clarify:
- Attribution window is 7 days BEFORE purchase only?
- If a user has 3 impressions in 7 days, the most recent gets highest weight — is it linear decay, or do you want a specific formula?
- One purchase can credit multiple campaigns, and one campaign can be credited by multiple purchases?
- Do we want campaign-level aggregation or per-purchase breakdown?"

**Why this matters:** Weak candidates dive into code. Strong candidates scope the problem. Amarendra is watching your engineering instinct here.

### Step 2: The Solution (Recency-weighted linear attribution)

```sql
WITH purchase_attributions AS (
    SELECT
        p.purchase_id,
        p.user_id,
        p.revenue,
        ai.campaign_id,
        ai.impression_time,
        p.purchase_time,
        -- Recency rank: 1 = most recent impression before purchase
        ROW_NUMBER() OVER (
            PARTITION BY p.purchase_id
            ORDER BY ai.impression_time DESC
        ) AS recency_rank,
        -- Total impressions in window for this purchase
        COUNT(*) OVER (PARTITION BY p.purchase_id) AS total_touchpoints
    FROM purchases p
    INNER JOIN ad_impressions ai
        ON p.user_id = ai.user_id
        AND ai.impression_time BETWEEN p.purchase_time - INTERVAL '7' DAY
                                    AND p.purchase_time
),
weighted AS (
    SELECT
        *,
        -- Linear weight: most recent gets highest weight
        -- recency_rank=1 gets weight=total_touchpoints, rank=2 gets total-1, etc.
        (total_touchpoints - recency_rank + 1) AS raw_weight,
        -- Sum of weights for normalization: n*(n+1)/2
        (total_touchpoints * (total_touchpoints + 1)) / 2.0 AS weight_sum
    FROM purchase_attributions
)
SELECT
    campaign_id,
    SUM(revenue * raw_weight / weight_sum) AS attributed_revenue,
    COUNT(DISTINCT purchase_id) AS purchases_influenced,
    COUNT(DISTINCT user_id) AS users_reached
FROM weighted
GROUP BY campaign_id
ORDER BY attributed_revenue DESC;
```

### Step 3: The Follow-Up Probes (Amarendra will ask these)

**Probe 1:** "What happens if a user has 500 ad impressions in 7 days? Does your query blow up?"

**Strong answer:** "The join becomes a fan-out — 500 rows per purchase. At scale with millions of purchases, this explodes. I'd cap impressions per user-purchase to top N (say 10 most recent) using a CTE with ROW_NUMBER before the join. This bounds the explosion while keeping attribution meaningful."

```sql
-- Add this CTE before the join:
recent_impressions AS (
    SELECT *, ROW_NUMBER() OVER (
        PARTITION BY user_id ORDER BY impression_time DESC
    ) AS global_rank
    FROM ad_impressions
    WHERE global_rank <= 50  -- safety cap per user
)
```

**Probe 2:** "This query runs on 2 billion impression rows and 50 million purchases. It's slow. What do you do?"

**Strong answer:**
1. "First — the interval join is the killer. It's a range join, not equi-join, so it can't use hash join. In Spark this becomes a broadcast nested loop or cartesian.
2. Solution: **Pre-filter impressions to only the 7 days before each purchase** by first collecting purchase dates per user, then filtering impressions to those windows. Or partition both tables by `user_id` and `date` and let the engine prune.
3. In BigQuery specifically: I'd partition `ad_impressions` by `DATE(impression_time)` and cluster by `user_id`. The range condition on `impression_time` would leverage partition pruning.
4. In Spark/Databricks: I'd rewrite this as a window self-join on user_id with a range frame, or use a bucketed join on user_id so the shuffle only happens once."

**Probe 3:** "A stakeholder says 'some purchases show zero attribution — no ad impressions in the window.' Is that a bug?"

**Strong answer:** "Not necessarily a bug — it means the user purchased without any tracked ad touchpoint in 7 days. Could be organic traffic, direct URL, or ad blocker. I'd use LEFT JOIN from purchases to preserve these, and add a category like 'organic/unattributed' in the output. The business question is: what % is unattributed? If it's 80%, the attribution window or tracking is broken. If it's 20%, it's expected organic."

---

## EXERCISE 2: Sessionization with Gap Detection

### The Setup:

> "Nike's mobile app sends clickstream events. Define a session as: events from the same user where the gap between consecutive events is less than 30 minutes. If gap > 30 min, it's a new session. Give me session-level metrics."

**Table: `app_events`**
```
user_id | event_time | event_type | page_name
```

### The Solution:

```sql
WITH event_gaps AS (
    SELECT
        user_id,
        event_time,
        event_type,
        page_name,
        LAG(event_time) OVER (
            PARTITION BY user_id ORDER BY event_time
        ) AS prev_event_time,
        CASE
            WHEN event_time - LAG(event_time) OVER (
                PARTITION BY user_id ORDER BY event_time
            ) > INTERVAL '30' MINUTE THEN 1
            WHEN LAG(event_time) OVER (
                PARTITION BY user_id ORDER BY event_time
            ) IS NULL THEN 1  -- first event = new session
            ELSE 0
        END AS is_new_session
    FROM app_events
),
sessions_numbered AS (
    SELECT
        *,
        SUM(is_new_session) OVER (
            PARTITION BY user_id ORDER BY event_time
            ROWS UNBOUNDED PRECEDING
        ) AS session_id
    FROM event_gaps
)
SELECT
    user_id,
    session_id,
    MIN(event_time) AS session_start,
    MAX(event_time) AS session_end,
    COUNT(*) AS event_count,
    COUNT(DISTINCT page_name) AS unique_pages,
    EXTRACT(EPOCH FROM MAX(event_time) - MIN(event_time)) / 60.0 AS duration_minutes,
    ARRAY_AGG(page_name ORDER BY event_time) AS page_path
FROM sessions_numbered
GROUP BY user_id, session_id;
```

### The Thought Process (say this during interview):

"I'm using the **gaps-and-islands** pattern. The trick is:
1. Use LAG to find the gap between consecutive events per user.
2. Flag any gap > 30 minutes as a new session boundary.
3. Use a running SUM of those flags to create a session counter.
4. Then aggregate per session."

### Follow-Up Probes:

**Probe 1:** "What if two events have the exact same timestamp?"

**Strong answer:** "LAG with ORDER BY event_time is non-deterministic when ties exist. The gap calculation would be 0, so they'd land in the same session — which is probably correct. But if I need deterministic ordering, I'd add a secondary sort key: `ORDER BY event_time, event_id` (if available) or `ORDER BY event_time, page_name` as a tiebreaker. In production, I'd ensure the source provides a monotonically increasing sequence ID."

**Probe 2:** "This works for batch. How would you do it in streaming?"

**Strong answer:** "In Structured Streaming, I can't use a global window function across all time. I'd use:
- **Session windows** (Spark 3.2+): `session_window(event_time, '30 minutes')` — Spark natively supports session window aggregation with watermarks.
- For older Spark: maintain state per user using `mapGroupsWithState` — track last event time, increment session counter when gap > 30 min, emit session metrics on timeout.
- Watermark is critical: `withWatermark('event_time', '1 hour')` to bound state. After 1 hour of no events from a user, close their session."

**Probe 3:** "The clickstream table has 10 billion rows. How do you make this query performant?"

**Strong answer:**
1. "Partition the table by `event_date` (extracted from event_time). Most analytics only needs recent data — date predicate prunes 90%+ of partitions.
2. The LAG window function requires sorting all events per user — if a single user has millions of events (bot?), that's a skew problem. I'd first filter obvious bots (users with >10K events/day), process them separately or cap.
3. In Spark: the `PARTITION BY user_id ORDER BY event_time` forces a sort within each partition. If user_id is skewed, one executor gets hammered. I'd repartition by user_id before this step so the sort is local, or use AQE to detect the skew.
4. Output: I'd materialize the sessions table (not compute on-the-fly for dashboards), partitioned by session_start_date."

---

## EXERCISE 3: SCD Type 2 — The Merge That Breaks

### The Setup:

> "Nike has a product catalog. Products change price, status, and category over time. We need a slowly changing dimension table that tracks history. Write the MERGE logic — and tell me what can go wrong."

**Source (daily snapshot from catalog API):**
```
product_id | product_name | price | category | status | snapshot_date
```

**Target (SCD2 dimension):**
```
product_sk (surrogate key) | product_id | product_name | price | category | status | valid_from | valid_to | is_current
```

### The Solution:

```sql
-- Step 1: Detect changes by comparing incoming snapshot vs current dim row
-- Step 2: Expire changed rows (set valid_to, is_current=false)
-- Step 3: Insert new versions of changed rows
-- Step 4: Insert brand new products

MERGE INTO dim_product AS target
USING (
    -- Incoming data with change detection
    SELECT
        s.product_id,
        s.product_name,
        s.price,
        s.category,
        s.status,
        s.snapshot_date,
        -- Hash tracked columns for change detection
        MD5(CONCAT(s.product_name, '|', CAST(s.price AS STRING), '|', s.category, '|', s.status)) AS source_hash,
        -- Current dim hash
        t.product_sk AS existing_sk,
        MD5(CONCAT(t.product_name, '|', CAST(t.price AS STRING), '|', t.category, '|', t.status)) AS target_hash
    FROM staging_products s
    LEFT JOIN dim_product t
        ON s.product_id = t.product_id AND t.is_current = TRUE
) AS source
ON target.product_sk = source.existing_sk

-- Case 1: Existing product changed — expire the old row
WHEN MATCHED
    AND source.source_hash != source.target_hash
    THEN UPDATE SET
        target.valid_to = source.snapshot_date,
        target.is_current = FALSE

-- Case 2: New products and new versions handled via INSERT after merge
;

-- Separate INSERT for new versions + new products
INSERT INTO dim_product (product_id, product_name, price, category, status, valid_from, valid_to, is_current)
SELECT
    s.product_id,
    s.product_name,
    s.price,
    s.category,
    s.status,
    s.snapshot_date AS valid_from,
    '9999-12-31' AS valid_to,
    TRUE AS is_current
FROM staging_products s
LEFT JOIN dim_product t
    ON s.product_id = t.product_id AND t.is_current = TRUE
WHERE t.product_id IS NULL  -- brand new product
   OR MD5(CONCAT(s.product_name, '|', CAST(s.price AS STRING), '|', s.category, '|', s.status))
      != MD5(CONCAT(t.product_name, '|', CAST(t.price AS STRING), '|', t.category, '|', t.status));  -- changed product
```

### Production Considerations (this is what separates strong from weak):

**1. The double-update problem:**
"If the source sends TWO changes for the same product_id in one batch, the MERGE fails or produces incorrect results. You get two 'current' rows. Fix: dedup the source batch first — keep only the latest snapshot per product_id."

**2. Late-arriving corrections:**
"What if the source retroactively corrects yesterday's price? My SCD2 might have already expired the old row. I need a policy: either allow out-of-order inserts (complex — insert between existing valid_from/valid_to ranges) or treat corrections as new change events (simpler — the history shows the correction as a new version)."

**3. Hash collisions:**
"MD5 can collide. In practice with product attributes, the probability is negligible. But if the interviewer pushes: use SHA-256, or better — compare columns directly instead of hashing (more verbose but zero collision risk)."

**4. Surrogate key generation:**
"In Spark/Databricks: use `monotonically_increasing_id()` or a UUID. In BigQuery: use `GENERATE_UUID()`. The surrogate key must NEVER be reused — it's the join key for fact tables."

### Follow-Up Probes:

**Probe 1:** "How would you backfill this if the dim table is wrong for the last 30 days?"

**Strong answer:** "Delta time travel. I'd `RESTORE TABLE dim_product TO VERSION AS OF <30_days_ago_version>`, then replay the staging loads for those 30 days in order. If that's not possible, I'd reconstruct from source snapshots: for each day in the 30-day window, replay the SCD2 logic sequentially. This is why I keep raw snapshots in bronze — they're the recovery mechanism."

**Probe 2:** "DBT has snapshots. How do they compare?"

**Strong answer (leverage your experience):** "DBT `snapshot` does exactly this — it uses `check` strategy (hash comparison) or `timestamp` strategy, automatically manages `valid_from`/`valid_to`/`dbt_valid_from`/`dbt_valid_to`. Under the hood it compiles to a MERGE. The advantage is it's declarative — I define what to track and DBT handles the SCD2 mechanics. The limitation is it requires source data to be available at snapshot time — if source is gone, you can't rebuild. That's why in production I snapshot daily AND keep raw source in bronze."

---

## EXERCISE 4: Funnel Analysis with Strict Ordering

### The Setup:

> "Nike wants to understand the purchase funnel: Homepage → Product Page → Add to Cart → Checkout → Purchase. For each step, tell me the conversion rate and median time between steps. Only count events in strict sequential order (no skipping steps)."

### The Solution:

```sql
WITH funnel_steps AS (
    -- Map event types to funnel positions
    SELECT
        user_id,
        event_time,
        CASE event_type
            WHEN 'homepage_view' THEN 1
            WHEN 'product_view' THEN 2
            WHEN 'add_to_cart' THEN 3
            WHEN 'checkout_start' THEN 4
            WHEN 'purchase_complete' THEN 5
        END AS step_number
    FROM app_events
    WHERE event_type IN ('homepage_view', 'product_view', 'add_to_cart', 'checkout_start', 'purchase_complete')
      AND event_date >= CURRENT_DATE - INTERVAL '30' DAY
),
strict_funnel AS (
    -- For each user, find the FIRST occurrence of each step
    -- that happens AFTER the previous step
    SELECT
        user_id,
        step_number,
        event_time,
        LAG(event_time) OVER (PARTITION BY user_id ORDER BY step_number, event_time) AS prev_step_time,
        LAG(step_number) OVER (PARTITION BY user_id ORDER BY step_number, event_time) AS prev_step_number
    FROM (
        -- First occurrence of each step per user (for strict ordering)
        SELECT user_id, step_number, event_time,
            ROW_NUMBER() OVER (PARTITION BY user_id, step_number ORDER BY event_time) AS rn
        FROM funnel_steps
    ) t WHERE rn = 1
),
valid_progressions AS (
    -- Only keep steps where previous step was exactly step_number - 1
    SELECT *
    FROM strict_funnel
    WHERE prev_step_number = step_number - 1
       OR step_number = 1  -- first step has no predecessor
)
SELECT
    step_number,
    CASE step_number
        WHEN 1 THEN 'Homepage'
        WHEN 2 THEN 'Product View'
        WHEN 3 THEN 'Add to Cart'
        WHEN 4 THEN 'Checkout'
        WHEN 5 THEN 'Purchase'
    END AS step_name,
    COUNT(DISTINCT user_id) AS users_at_step,
    ROUND(
        COUNT(DISTINCT user_id) * 100.0 /
        FIRST_VALUE(COUNT(DISTINCT user_id)) OVER (ORDER BY step_number),
        2
    ) AS conversion_from_top,
    ROUND(
        COUNT(DISTINCT user_id) * 100.0 /
        LAG(COUNT(DISTINCT user_id)) OVER (ORDER BY step_number),
        2
    ) AS step_conversion_rate,
    PERCENTILE_CONT(0.5) WITHIN GROUP (
        ORDER BY EXTRACT(EPOCH FROM event_time - prev_step_time)
    ) / 60.0 AS median_minutes_from_prev_step
FROM valid_progressions
GROUP BY step_number
ORDER BY step_number;
```

### The Trap (interviewer will try this):

**Probe:** "What if a user goes: Homepage → Product → Homepage → Add to Cart? Does that break your strict ordering?"

**Strong answer:** "Good catch. My first-occurrence logic takes the FIRST product_view per user. But the user went back to homepage before adding to cart — the 'add_to_cart' event happened after a non-sequential event. Depends on the business definition:
- **Strict linear:** each step must happen after the previous with no steps in between → much harder, requires sequence pattern matching (MATCH_RECOGNIZE in Oracle/Snowflake, or stateful processing in Spark).
- **First occurrence per step:** my current approach — simpler, answers 'did the user ever complete each step in order.'
- **Most common interpretation:** the second one. But I'd clarify with the stakeholder."

---

## EXERCISE 5: Detecting Duplicate Payments (Production-Critical)

### The Setup:

> "Nike's payment system occasionally double-charges customers. Write a query to find potential duplicate payments — same user, same amount, within 5 minutes. But be careful about false positives: a user might legitimately buy two items of the same price."

### The Solution:

```sql
WITH potential_dupes AS (
    SELECT
        p1.payment_id AS payment_id_1,
        p2.payment_id AS payment_id_2,
        p1.user_id,
        p1.amount,
        p1.payment_time AS time_1,
        p2.payment_time AS time_2,
        p1.order_id AS order_id_1,
        p2.order_id AS order_id_2,
        p1.payment_method AS method_1,
        p2.payment_method AS method_2,
        EXTRACT(EPOCH FROM p2.payment_time - p1.payment_time) AS gap_seconds
    FROM payments p1
    INNER JOIN payments p2
        ON p1.user_id = p2.user_id
        AND p1.amount = p2.amount
        AND p1.payment_id < p2.payment_id  -- avoid self-join and dedup pairs
        AND p2.payment_time BETWEEN p1.payment_time AND p1.payment_time + INTERVAL '5' MINUTE
)
SELECT
    *,
    CASE
        -- High confidence duplicate: same order_id, same method
        WHEN order_id_1 = order_id_2 AND method_1 = method_2 THEN 'HIGH'
        -- Medium: same method, different order (could be retry creating new order)
        WHEN method_1 = method_2 AND order_id_1 != order_id_2 THEN 'MEDIUM'
        -- Low: different method (user might have intentionally paid twice)
        ELSE 'LOW'
    END AS duplicate_confidence
FROM potential_dupes
ORDER BY duplicate_confidence, time_1 DESC;
```

### Production Considerations:

**1. Self-join performance:** "Self-join on payments is O(n²) worst case per user. In production, I'd:
- Partition by user_id and payment_date
- Pre-filter to only today's payments (real-time dedup)
- Or use a window function approach: LAG within partition to find consecutive same-amount payments within 5 min — avoids the join entirely."

**Window alternative (lighter):**
```sql
SELECT *,
    LAG(payment_time) OVER (PARTITION BY user_id, amount ORDER BY payment_time) AS prev_same_amount_time,
    payment_time - LAG(payment_time) OVER (PARTITION BY user_id, amount ORDER BY payment_time) AS gap
FROM payments
HAVING gap < INTERVAL '5' MINUTE;
```

**2. False positive handling:** "I'd NEVER auto-refund based on this query. Output goes to a review queue with confidence scores. HIGH confidence gets auto-flagged for immediate CS review; LOW confidence gets batched for weekly audit."

**3. Real-time prevention vs batch detection:** "This query is batch detection — finds dupes after the fact. For prevention, I'd implement an idempotency key at the payment gateway level — same (user_id, order_id, amount, idempotency_key) within 5 min is rejected at write time. Much better than catching it after."

---

## SQL OPTIMIZATION: THE DEEP PATTERNS

### Pattern: Predicate Pushdown Awareness

**Weak answer:** "I put WHERE clauses to filter data."

**Strong answer:** "I structure my query so predicates on partitioned/clustered columns appear as early as possible — ideally in the base scan, not after a CTE or subquery that might prevent pushdown. In Spark I verify with `.explain(true)` that `PushedFilters` shows my predicate. In BigQuery, I check the execution graph for 'Input bytes' — if it's reading the full table despite my date filter, the predicate didn't push down (common cause: wrapping the partition column in a function like `DATE(timestamp_col) = '2024-01-01'` instead of using range: `timestamp_col >= '2024-01-01' AND timestamp_col < '2024-01-02'`)."

### Pattern: JOIN ORDER matters

"In cost-based optimizers (Spark Catalyst, BigQuery), the optimizer usually picks optimal join order. But when it doesn't:
- Smaller table on the build side (right side of broadcast hash join)
- Filter BEFORE join — reduce both sides
- If I'm doing A JOIN B JOIN C, and B JOIN C produces a much smaller result than A JOIN B, I'd force that order with CTEs or hints"

### Pattern: COUNT(DISTINCT) at scale

**Weak:** `COUNT(DISTINCT user_id)` — fine for millions, slow for billions.

**Strong:** "At Nike scale, exact distinct counts on billions of rows are expensive. Options:
1. `APPROX_COUNT_DISTINCT(user_id)` — HyperLogLog, ~2% error, 10x faster
2. Pre-aggregate daily uniques, then combine with UNION + distinct (reduces from billions to millions)
3. Bitmap indexes if on a system that supports them
4. I'd clarify with the stakeholder: do they need exact or approximate? Most dashboards are fine with ~2% error."

---

## COMMON SQL INTERVIEW TRAPS

### Trap 1: NULL handling in NOT IN

```sql
-- This returns ZERO rows if any value in the subquery is NULL!
SELECT * FROM orders WHERE customer_id NOT IN (SELECT id FROM blacklist);

-- Safe version:
SELECT * FROM orders WHERE customer_id NOT IN (SELECT id FROM blacklist WHERE id IS NOT NULL);
-- Or better:
SELECT o.* FROM orders o LEFT JOIN blacklist b ON o.customer_id = b.id WHERE b.id IS NULL;
```

### Trap 2: GROUP BY with window functions

"Window functions execute AFTER GROUP BY and HAVING but BEFORE ORDER BY. If you need a window over grouped data, you must subquery or CTE — you can't window and group in the same SELECT level."

### Trap 3: BETWEEN is inclusive on both ends

"When filtering dates: `WHERE order_date BETWEEN '2024-01-01' AND '2024-01-31'` — this INCLUDES midnight of Jan 31. If order_date is a timestamp, you'll get all of Jan 31. If you want January only: `WHERE order_date >= '2024-01-01' AND order_date < '2024-02-01'`."

### Trap 4: Implicit type casting kills performance

"Joining a VARCHAR column to an INT column causes implicit cast on every row — bypasses indexes and partition pruning. In Spark it's even worse — it might silently succeed but produce wrong results if the cast fails on some rows. Always explicit: `CAST(col AS INT)` and handle parse failures."

### Trap 5: UNION vs UNION ALL

"UNION deduplicates (expensive sort + distinct). UNION ALL does not. In data pipelines, I almost always want UNION ALL — if I need dedup, I'll do it explicitly with ROW_NUMBER so I control which row survives."

---

## THE "HOW INTERVIEWERS GRADE SQL" RUBRIC

| Signal | Junior (reject) | Mid (maybe) | Senior (hire) |
|--------|-----------------|-------------|---------------|
| Approach | Starts writing immediately | Pauses briefly | Clarifies edge cases, states assumptions |
| Correctness | Syntax errors, wrong logic | Correct but brittle | Handles NULLs, ties, edge cases |
| Performance | Ignores scale | Mentions indexes | Discusses partition pruning, join strategy, predicate pushdown |
| Follow-ups | Gets stuck | Adjusts query | Explains WHY original breaks and offers alternatives |
| Communication | Silent coding | Narrates output | Narrates thought process, tradeoffs, alternatives |

**Your goal: sound like the right column on every row.**
