# PART 5 — PySpark/Spark PRODUCTION MASTERY

## How Amarendra Will Probe Your Spark Knowledge

He won't ask "What is RDD vs DataFrame?" He'll ask:
- "Your daily job went from 20 min to 4 hours. Walk me through debugging it."
- "Write me a PySpark pipeline that deduplicates and incrementally loads. Now I'll break it."
- "Why is this code slow?" (shows you a snippet)
- "What happens under the hood when you do X?"

He's testing: **Do you understand what Spark is DOING, not just what you're TELLING it to do?**

---

## SECTION A: SPARK EXECUTION MODEL — WHAT REALLY HAPPENS

### The Mental Model You Must Have

When you write PySpark code, here's what ACTUALLY happens:

```
Your Code (Python) 
    → Logical Plan (unoptimized AST)
    → Catalyst Optimizer → Optimized Logical Plan
    → Physical Plan (actual execution strategy)
    → DAG of Stages (split at shuffle boundaries)
    → Tasks (one per partition per stage)
    → Executors run tasks in parallel
```

**Why this matters in interview:** When Amarendra asks "why is this slow?", the answer is ALWAYS somewhere in this chain. You need to reason at the right level.


### Key Concepts That Trip Candidates:

**1. Stage Boundaries = Shuffles**
Every wide transformation (join, groupBy, repartition, distinct) creates a NEW stage. Between stages, data is serialized, written to disk, transferred over network, deserialized. This is the #1 cost in Spark.

**2. Partition Count ≠ Parallelism**
- Default shuffle partitions: 200 (`spark.sql.shuffle.partitions`)
- If you have 200 partitions but only 10 executor cores → only 10 tasks run concurrently → 20 waves
- If you have 10 partitions but 100 cores → 90 cores idle
- **Senior insight:** "I tune `spark.sql.shuffle.partitions` based on data size. Rule of thumb: target 128MB–256MB per partition after shuffle. For a 50GB shuffle, that's ~200–400 partitions."

**3. Driver vs Executor Responsibilities**
- **Driver:** plans execution, coordinates, collects results, broadcasts small data
- **Executor:** processes partitions, stores cached data, shuffles
- **OOM on Driver:** you called `collect()`, `toPandas()`, or broadcast is too large
- **OOM on Executor:** single partition too large (skew), or too much cached data

**4. Catalyst Optimizer — What It Does For You (and Doesn't)**
- ✅ Predicate pushdown (filters pushed to scan)
- ✅ Column pruning (only reads needed columns)
- ✅ Join reordering (sometimes)
- ✅ Constant folding
- ❌ Cannot fix data skew
- ❌ Cannot know your data distribution
- ❌ Cannot optimize Python UDFs (black box)

---

## SECTION B: PYSPARK CODING EXERCISES — INTERVIEW GRADE

### EXERCISE 1: Incremental Load with Deduplication

**Interviewer says:** "Write a PySpark job that reads new data from a landing zone, deduplicates against existing data, and merges into a Delta table. Handle late-arriving records."

```python
from pyspark.sql import SparkSession
from pyspark.sql.functions import (
    col, row_number, current_timestamp, lit, md5, concat_ws
)
from pyspark.sql.window import Window
from delta.tables import DeltaTable

spark = SparkSession.builder.appName("incremental_load").getOrCreate()

# --- CONFIG ---
LANDING_PATH = "s3://raw/events/landing/"
TARGET_PATH = "s3://silver/events/"
WATERMARK_DAYS = 7  # reprocess window for late data

# --- STEP 1: Read new data (Auto Loader in production, read for interview) ---
new_data = (
    spark.read.format("parquet")
    .load(LANDING_PATH)
    .filter(col("event_date") >= date_sub(current_date(), WATERMARK_DAYS))
)

# --- STEP 2: Deduplicate within the batch ---
# Business rule: keep latest record per (user_id, event_id)
dedup_window = Window.partitionBy("user_id", "event_id").orderBy(col("event_time").desc())

deduped = (
    new_data
    .withColumn("rn", row_number().over(dedup_window))
    .filter(col("rn") == 1)
    .drop("rn")
    # Add audit columns
    .withColumn("_ingested_at", current_timestamp())
    .withColumn("_row_hash", md5(concat_ws("|",
        col("user_id"), col("event_id"), col("event_time"),
        col("event_type"), col("payload")
    )))
)

# --- STEP 3: MERGE into target (upsert) ---
if DeltaTable.isDeltaTable(spark, TARGET_PATH):
    target = DeltaTable.forPath(spark, TARGET_PATH)

    target.alias("t").merge(
        deduped.alias("s"),
        """
        t.user_id = s.user_id
        AND t.event_id = s.event_id
        """
    ).whenMatchedUpdate(
        condition="s.event_time > t.event_time",  # Only update if newer
        set={
            "event_time": "s.event_time",
            "event_type": "s.event_type",
            "payload": "s.payload",
            "_ingested_at": "s._ingested_at",
            "_row_hash": "s._row_hash"
        }
    ).whenNotMatchedInsertAll().execute()
else:
    # First run — create the table
    deduped.write.format("delta").partitionBy("event_date").save(TARGET_PATH)

# --- STEP 4: Post-merge quality check ---
target_count = spark.read.format("delta").load(TARGET_PATH).count()
source_count = deduped.count()
print(f"Merged {source_count} records. Target now has {target_count} total.")
```


### Follow-Up Probes (Amarendra will ask these):

**Probe 1:** "What if `event_id` is not globally unique — same event_id can exist for different event_types?"

**Strong answer:** "Then my merge key is wrong. I'd add `event_type` to the merge condition: `t.user_id = s.user_id AND t.event_id = s.event_id AND t.event_type = s.event_type`. Or better — I'd define the natural key explicitly in my schema documentation and validate it with a uniqueness assertion before the merge."

**Probe 2:** "This job runs every hour. What if it overlaps with itself?"

**Strong answer:** "Two concurrent merges on the same Delta table will conflict — Delta's optimistic concurrency will fail one with a `ConcurrentAppendException`. Fixes:
1. Lock: use a external lock (e.g., DynamoDB lock for S3, or Databricks job concurrency=1 setting)
2. Idempotency: if both runs are idempotent (same merge logic), the retry is safe
3. Architecture: design so each run processes a non-overlapping partition (e.g., run for hour H only processes data from hour H)"

**Probe 3:** "You're deduplicating with ROW_NUMBER. What's the performance characteristic?"

**Strong answer:** "ROW_NUMBER over (PARTITION BY user_id, event_id ORDER BY event_time DESC) forces a shuffle on (user_id, event_id) and a sort on event_time within each partition. Cost: one shuffle + one sort. If user_id is skewed (one user has millions of events), that single partition will be huge and create a straggler task. Mitigation: if I know skew exists, I'd filter out the heavy hitter, process separately, union back. Or if I only need the latest, an aggregate approach might be cheaper: `groupBy('user_id', 'event_id').agg(max_struct('event_time', struct('*')))` — but that's trickier to express for all columns."

---

### EXERCISE 2: Handling Data Skew in a Join

**Interviewer says:** "You're joining a 2B-row fact table with a 50M-row dimension table on `customer_id`. One customer has 40% of all transactions. The job takes 6 hours. Fix it."

**The Thought Process (say this out loud):**

"This is a classic skew problem. One partition in the join gets 40% of the data while others get tiny amounts. The sort-merge join shuffles both sides by customer_id — one executor gets crushed.

Let me walk through options in order of complexity:"

**Option 1: Broadcast the dimension (if it fits)**
```python
from pyspark.sql.functions import broadcast

# 50M rows * ~200 bytes/row = ~10GB. Too big for broadcast (default 10MB, safe up to ~1GB)
# BUT — do I need all 50M dim rows? Probably not.
# Filter dim to only customers present in fact:
active_dim = dim.join(
    fact.select("customer_id").distinct(),
    "customer_id"
)
# If active_dim is now ~1M rows (~200MB), broadcast is viable:
result = fact.join(broadcast(active_dim), "customer_id", "left")
```

**Option 2: Isolate the hot key**
```python
HOT_CUSTOMER = "CUST_0001"  # the 40% customer

# Split fact into hot and cold
fact_hot = fact.filter(col("customer_id") == HOT_CUSTOMER)
fact_cold = fact.filter(col("customer_id") != HOT_CUSTOMER)

# Hot path: broadcast the single dim row (trivial size)
dim_hot = dim.filter(col("customer_id") == HOT_CUSTOMER)
joined_hot = fact_hot.join(broadcast(dim_hot), "customer_id", "left")

# Cold path: normal sort-merge (no skew now)
joined_cold = fact_cold.join(dim, "customer_id", "left")

# Union
result = joined_hot.unionByName(joined_cold)
```

**Option 3: Salting (most general solution)**
```python
import random
from pyspark.sql.functions import lit, concat, col, explode, array

SALT_BUCKETS = 20

# Salt the fact table: append random suffix to join key
fact_salted = fact.withColumn(
    "salted_key",
    concat(col("customer_id"), lit("_"), (rand() * SALT_BUCKETS).cast("int"))
)

# Explode the dimension: replicate each row N times with each salt suffix
dim_exploded = dim.withColumn(
    "salted_key",
    explode(array([concat(col("customer_id"), lit(f"_{i}")) for i in range(SALT_BUCKETS)]))
)

# Join on salted key — even the hot customer is now spread across 20 partitions
result = fact_salted.join(dim_exploded, "salted_key", "left").drop("salted_key")
```

**Option 4: AQE (let Spark handle it — Spark 3.2+)**
```python
spark.conf.set("spark.sql.adaptive.enabled", "true")
spark.conf.set("spark.sql.adaptive.skewJoin.enabled", "true")
spark.conf.set("spark.sql.adaptive.skewJoin.skewedPartitionFactor", "5")
spark.conf.set("spark.sql.adaptive.skewJoin.skewedPartitionThresholdInBytes", "256MB")

# AQE will detect the skewed partition at runtime and split it
result = fact.join(dim, "customer_id", "left")
```


### Follow-Up Probes:

**Probe:** "When would salting HURT performance?"

**Strong answer:** "Salting has a cost: the dimension side is replicated N times. If the dim is 10GB and I use 20 buckets, I'm now shuffling 200GB of dim data. That's often worth it if the skew is severe (40% = 800M rows on one executor). But if the skew is mild (e.g., top key is only 5% of data), AQE handles it fine and salting is overkill. Also — salting breaks predicate pushdown on the original key. After the join, any downstream filter on `customer_id` won't benefit from the salted partitioning. I'd repartition by `customer_id` after the join if downstream needs it."

**Probe:** "You isolated the hot key. But what if there are 500 hot keys, not one?"

**Strong answer:** "Then I'd compute a frequency distribution: `fact.groupBy('customer_id').count()`. Define 'hot' as any key above the 99th percentile of counts. Filter fact and dim by that set. The hot path gets broadcast-joined (because the dim subset for 500 keys is tiny). The cold path gets sort-merge. This generalizes cleanly."

---

### EXERCISE 3: Window Functions in PySpark — Production Pattern

**Interviewer says:** "For each Nike product, compute the 7-day rolling average of daily sales, and flag any day where sales drop more than 30% from the rolling average."

```python
from pyspark.sql.functions import (
    col, avg, sum as _sum, when, lag, abs as _abs, datediff
)
from pyspark.sql.window import Window

# Assume: daily_sales DataFrame with columns: product_id, sale_date, daily_revenue

# Step 1: Define window — 7 preceding days (not rows!)
# IMPORTANT: Spark window RANGE requires numeric ordering, not date.
# Convert date to numeric for range-based window:
daily_sales = daily_sales.withColumn("date_num", datediff(col("sale_date"), lit("2020-01-01")))

rolling_window = (
    Window.partitionBy("product_id")
    .orderBy("date_num")
    .rangeBetween(-6, 0)  # current day + 6 preceding = 7-day window
)

# Step 2: Compute rolling average
with_rolling = daily_sales.withColumn(
    "rolling_7d_avg", avg("daily_revenue").over(rolling_window)
)

# Step 3: Flag anomalies
anomalies = with_rolling.withColumn(
    "pct_deviation",
    (col("daily_revenue") - col("rolling_7d_avg")) / col("rolling_7d_avg") * 100
).withColumn(
    "is_anomaly",
    when(col("pct_deviation") < -30, True).otherwise(False)
)

# Step 4: Production output — only anomalies with context
alerts = anomalies.filter(col("is_anomaly")).select(
    "product_id", "sale_date", "daily_revenue",
    "rolling_7d_avg", "pct_deviation"
)
```

### The Critical Interview Distinction: ROWS vs RANGE

**If interviewer asks:** "Why `rangeBetween` and not `rowsBetween`?"

**Strong answer:** "`rowsBetween(-6, 0)` counts 6 physical rows before the current row regardless of date gaps. If a product has no sales on Saturday and Sunday, Monday's 'rolling 7-day' would actually span 9 calendar days (because it skips the gap). `rangeBetween(-6, 0)` on a numeric date column gives a TRUE 7-calendar-day window — it only includes rows whose date_num is within 6 units of the current row, even if there are gap days with no rows. This is the correct behavior for time-based rolling metrics."

**Follow-up trap:** "But what about products with sparse sales — only 2 days in the last 7 days?"

**Strong answer:** "The avg will be computed over only 2 data points, which might be misleading. I'd add a `COUNT` over the same window: `count('daily_revenue').over(rolling_window)` and only flag anomalies where the count >= 5 (minimum data points for a meaningful average). Otherwise the alert is noise."

---

### EXERCISE 4: Complex Aggregation with Multiple Granularities

**Interviewer says:** "Build a PySpark transformation that computes: per product per week — total revenue, unique buyers, repeat buyer rate, and week-over-week growth percentage."

```python
from pyspark.sql.functions import (
    col, countDistinct, sum as _sum, weekofyear, year,
    lag, round as _round, when
)
from pyspark.sql.window import Window

# Source: transactions (user_id, product_id, txn_date, amount)

# Step 1: Weekly aggregation
weekly_metrics = (
    transactions
    .withColumn("week", weekofyear("txn_date"))
    .withColumn("yr", year("txn_date"))
    .groupBy("product_id", "yr", "week")
    .agg(
        _sum("amount").alias("weekly_revenue"),
        countDistinct("user_id").alias("unique_buyers"),
        # Repeat buyers: users with > 1 transaction this week for this product
        countDistinct(
            when(col("txn_count") > 1, col("user_id"))
        ).alias("repeat_buyers")  # This needs a sub-aggregation — see below
    )
)

# CORRECTION: Repeat buyers requires a two-step aggregation
# Step 1a: Count transactions per user per product per week
user_week_counts = (
    transactions
    .withColumn("week", weekofyear("txn_date"))
    .withColumn("yr", year("txn_date"))
    .groupBy("product_id", "yr", "week", "user_id")
    .agg(count("*").alias("txn_count"))
)

# Step 1b: Aggregate to product-week level
weekly_metrics = (
    user_week_counts
    .groupBy("product_id", "yr", "week")
    .agg(
        _sum("txn_count").alias("total_transactions"),  # proxy for revenue if no amount
        countDistinct("user_id").alias("unique_buyers"),
        countDistinct(when(col("txn_count") > 1, col("user_id"))).alias("repeat_buyers")
    )
    .withColumn(
        "repeat_rate",
        _round(col("repeat_buyers") / col("unique_buyers") * 100, 2)
    )
)

# Step 2: Week-over-week growth
wow_window = Window.partitionBy("product_id").orderBy("yr", "week")

final = weekly_metrics.withColumn(
    "prev_week_revenue",
    lag("total_transactions").over(wow_window)
).withColumn(
    "wow_growth_pct",
    _round(
        (col("total_transactions") - col("prev_week_revenue"))
        / col("prev_week_revenue") * 100,
        2
    )
)
```

### Production Considerations:

**Interviewer probe:** "This runs on 3 years of transaction data. What's expensive?"

**Strong answer:**
1. "The `groupBy('product_id', 'yr', 'week', 'user_id')` shuffles all 3 years of data by that composite key. If I only need the last 12 weeks for the dashboard, I should filter BEFORE the groupBy — saves ~90% of shuffle volume.
2. The `countDistinct` after `groupBy` is fine because we're already at user-week granularity — it's just a count.
3. The window function `lag` over `(product_id)` ordered by `(yr, week)` is a narrow operation AFTER the groupBy — the expensive part was already done. This is cheap.
4. If product_id has extreme cardinality (millions of products), the shuffle in step 1 might create too many output partitions. I'd set shuffle partitions based on data size, not default 200."

---

## SECTION C: SPARK DEBUGGING — THE REAL INTERVIEW SCENARIOS

### SCENARIO 1: "This Code is Slow — Why?"

**Interviewer shows you:**
```python
# "This takes 3 hours. Why?"
result = (
    spark.read.parquet("s3://data/events/")  # 500GB, ~2B rows
    .filter(col("country") == "US")
    .join(spark.read.parquet("s3://data/users/"), "user_id")  # 100M rows
    .groupBy("user_id")
    .agg(countDistinct("event_id").alias("event_count"))
    .filter(col("event_count") > 100)
    .orderBy(col("event_count").desc())
    .limit(1000)
)
result.show()
```

**Your debugging walkthrough (say this):**

"Let me trace the execution:
1. **Reading 500GB without partition pruning** — no date filter, reading entire history. If data is partitioned by event_date, we're wasting huge IO.
2. **Filter on 'country' after full scan** — if the parquet files have min/max stats on 'country' column, Spark can skip files. But if country isn't sorted/clustered, it reads everything and filters in memory.
3. **Join with 100M user table** — this is a sort-merge join (both sides large). The 500GB side shuffles by user_id. But WAIT — should this be a broadcast? 100M rows × ~500 bytes = ~50GB. Too big. But after the country='US' filter, how big is the events side? Maybe the filter reduces it to 100GB. Still sort-merge.
4. **groupBy('user_id')** — ANOTHER shuffle on user_id. But wait — we just shuffled by user_id for the join. If AQE is off, this is redundant shuffle. With AQE on, Spark might coalesce.
5. **countDistinct** — expensive because it needs to see all event_ids per user.
6. **orderBy + limit** — global sort of all users, just to take top 1000. Wasteful.

**My fixes in priority order:**


```python
# OPTIMIZED VERSION
result = (
    spark.read.parquet("s3://data/events/")
    .filter(
        (col("country") == "US") &
        (col("event_date") >= "2024-01-01")  # FIX 1: Add date filter for partition pruning
    )
    .select("user_id", "event_id")  # FIX 2: Column pruning — only what we need
    .join(
        broadcast(spark.read.parquet("s3://data/users/").select("user_id")),  # FIX 3: Broadcast + prune
        "user_id"
    )
    .groupBy("user_id")
    .agg(countDistinct("event_id").alias("event_count"))
    .filter(col("event_count") > 100)  # FIX 4: This is fine — filters AFTER agg
    .orderBy(col("event_count").desc())
    .limit(1000)
)
```

**Fixes explained:**
1. **Date filter** — prunes 90% of partitions at scan time. 500GB → 50GB.
2. **Column pruning** — parquet is columnar. Reading 2 columns instead of 50 = massive IO reduction.
3. **Broadcast join** — users table with only user_id column is ~800MB (100M × 8 bytes). Broadcastable. Eliminates the biggest shuffle.
4. **If users table is only for filtering (inner join = only users who exist)** — maybe we don't even need the join. If the goal is just 'events from known users', a semi-join or `WHERE user_id IN (...)` with broadcast is cleaner.

**Impact:** 3 hours → probably 5-10 minutes."

---

### SCENARIO 2: "The Job Ran Fine Yesterday, Now It OOMs"

**Interviewer says:** "Same code, same cluster, worked for 6 months. Today: OOM on executors. What happened?"

**Your systematic answer:**

"When something that worked before breaks, it's almost always a **data change**, not a code change. My checklist:

1. **Data volume spike:** Did upstream send 10x today's batch? Check input file count and size.
   ```python
   # Quick check:
   spark.read.parquet(input_path).groupBy("event_date").count().orderBy("event_date").show(30)
   ```

2. **Skew emergence:** A new customer or campaign launched, concentrating data on one key. Check distribution:
   ```python
   df.groupBy("join_key").count().orderBy(col("count").desc()).show(20)
   ```
   If the top key is 100x the median, that's your OOM.

3. **Schema change upstream:** New columns added (wider rows = more memory per partition). A STRUCT or ARRAY column might have exploded in size.
   ```python
   df.printSchema()  # Check for unexpected nested types
   df.select([avg(length(col(c).cast("string"))).alias(c) for c in df.columns]).show()
   ```

4. **Broadcast threshold crossed:** If a table grew from 9MB to 11MB, and auto-broadcast threshold is 10MB, it WAS being broadcast (no shuffle) and NOW it's sort-merge join (shuffle). The join pattern changed without your code changing.

5. **Small file explosion:** If OPTIMIZE hasn't run and files accumulated (1000s of small files), the file listing and per-file overhead can exhaust driver memory.

**Recovery playbook:**
- Immediate fix: increase executor memory OR reduce shuffle partitions (more, smaller tasks)
- Root cause: add monitoring on input data profile (size, key distribution, schema)
- Prevention: alerting on data volume anomalies BEFORE the job runs"

---

### SCENARIO 3: "Explain What Happens When You Call .join()"

**This tests deep understanding. Interviewer says:** "Walk me through exactly what happens at the cluster level when this executes."

```python
orders.join(customers, "customer_id", "inner")
```

**Your answer (narrate the full story):**

"Okay, let me trace this end-to-end:

**Planning phase (Driver):**
1. Catalyst optimizer sees a join. It checks the sizes of both sides.
2. If `customers` is below `spark.sql.autoBroadcastJoinThreshold` (10MB default), it chooses **BroadcastHashJoin**. Otherwise, **SortMergeJoin**.

**Broadcast Hash Join path (small dimension):**
1. Driver collects the entire `customers` DataFrame to itself.
2. Driver broadcasts it to every executor.
3. Each executor builds a hash table from `customers` in memory.
4. Each executor scans its local partitions of `orders`, probes the hash table.
5. One stage, no shuffle on the `orders` side. Very fast.

**Sort-Merge Join path (both large):**
1. **Shuffle phase:** Both `orders` and `customers` are repartitioned (shuffled) by `customer_id`. Each partition of the output is a hash bucket of customer_ids.
2. **Sort phase:** Within each partition, both sides are sorted by `customer_id`.
3. **Merge phase:** Each task iterates through both sorted streams simultaneously, matching keys.
4. Two stages (one per shuffle), then the merge stage.

**The cost breakdown:**
- Shuffle writes: serialized data written to local disk on each executor
- Shuffle reads: data pulled across the network to the target partitions
- Sort: CPU + possible spill to disk if partition > executor memory
- Network: proportional to data size × replication factor

**What I watch for:**
- In Spark UI: shuffle read/write sizes. If shuffle write is 200GB, that's the bottleneck.
- Sort spill: if 'Spill (Disk)' in the Stages tab is non-zero, partitions are too big for memory."

---

## SECTION D: ADVANCED PYSPARK PATTERNS

### Pattern 1: Efficient Multiple Aggregations

**Bad (multiple passes):**
```python
total_rev = df.agg(_sum("revenue")).collect()[0][0]
avg_rev = df.agg(avg("revenue")).collect()[0][0]
count = df.count()
```

**Good (single pass):**
```python
from pyspark.sql.functions import sum as _sum, avg, count, countDistinct, percentile_approx

metrics = df.agg(
    _sum("revenue").alias("total_revenue"),
    avg("revenue").alias("avg_revenue"),
    count("*").alias("total_rows"),
    countDistinct("user_id").alias("unique_users"),
    percentile_approx("revenue", 0.5).alias("median_revenue")
).collect()[0]
```

**Why:** Each action triggers the full DAG. Three `collect()` calls = three full table scans. One aggregation with multiple expressions = one scan.

### Pattern 2: Avoiding Python UDFs (Performance Critical)

**Bad (Python UDF — data serialized to Python, processed row-by-row):**
```python
@udf(StringType())
def clean_email(email):
    if email:
        return email.strip().lower()
    return None

df = df.withColumn("clean_email", clean_email(col("email")))
```

**Good (native Spark functions — stays in JVM, vectorized):**
```python
from pyspark.sql.functions import lower, trim

df = df.withColumn("clean_email", lower(trim(col("email"))))
```

**When you MUST use UDF (complex business logic):**
```python
# Use pandas_udf (vectorized) instead of row-by-row UDF
from pyspark.sql.functions import pandas_udf
import pandas as pd

@pandas_udf(StringType())
def complex_parse(series: pd.Series) -> pd.Series:
    # Operates on batches (Arrow), not row-by-row
    return series.str.extract(r'(\w+@\w+\.\w+)')

df = df.withColumn("parsed_email", complex_parse(col("raw_text")))
```

**Senior insight:** "Pandas UDFs use Apache Arrow for zero-copy transfer between JVM and Python. They're 10-100x faster than row-at-a-time UDFs. But native Spark functions are still faster because they never leave the JVM. I use native first, pandas_udf second, row UDF as last resort."

### Pattern 3: Checkpoint vs Cache vs Persist

```python
# CACHE: keeps in memory (or spills to disk). Lost on executor failure.
df.cache()  # equivalent to persist(StorageLevel.MEMORY_AND_DISK)

# PERSIST: explicit control over storage level
from pyspark import StorageLevel
df.persist(StorageLevel.MEMORY_AND_DISK_SER)  # serialized = less memory, more CPU

# CHECKPOINT: writes to HDFS/S3. Breaks DAG lineage. Survives executor failure.
spark.sparkContext.setCheckpointDir("s3://checkpoints/")
df.checkpoint()  # materializes and truncates DAG
```

**When to use each:**
- **Cache:** DataFrame reused 2-3 times in same job, fits in memory. Always `.unpersist()` when done.
- **Checkpoint:** DAG is extremely long/complex (100+ stages). Spark recomputes from scratch on failure without checkpoint — expensive for long lineages. Also useful for iterative algorithms (ML training loops).
- **Neither:** used once → don't cache. Too big for memory → don't cache unless spill is acceptable.

**Interview trap:** "What happens if you cache but don't have enough memory?"

**Answer:** "It spills to disk. With `MEMORY_AND_DISK`, partitions that don't fit are written to local disk. With `MEMORY_ONLY`, they're simply not cached — recomputed on next access. Spill to disk is usually fine but adds IO latency. The real danger is caching too much and leaving no memory for shuffles/tasks — then EVERYTHING spills and the whole job slows down. Monitor the Storage tab in Spark UI."

---

## SECTION E: THE "BRIDGE FROM GCP" TALKING POINTS

### When Amarendra asks about Spark and you've done it in BigQuery:

**Partitioning:**
"In BigQuery I partition by date and cluster by user_id — that's analogous to Delta `PARTITION BY (event_date)` with `ZORDER BY (user_id)`. Same goal: minimize IO at read time through file/partition pruning."

**Incremental models:**
"My DBT incremental models use `is_incremental()` with a `merge_strategy` — that compiles to a BigQuery MERGE statement. The exact same pattern in Databricks is a Delta `MERGE INTO` using PySpark's `DeltaTable.merge()`. The logic is identical: identify new/changed rows, merge them in, handle the match conditions."

**Serverless compute:**
"Cloud Functions are my equivalent of Databricks serverless jobs or AWS Lambda — short-lived, event-triggered compute. The mental model is the same: stateless, idempotent, triggered by an event (file landing, schedule, API call). The difference is scale ceiling — Lambda/Cloud Functions cap at 15min/~10GB memory, while a Databricks job can run for hours on a cluster."

**Orchestration:**
"My DBT runs are orchestrated via Cloud Composer (managed Airflow) or Cloud Workflows. Same pattern applies to Databricks Workflows or Airflow-on-Databricks. I define DAG dependencies, retries, alerts, and parameterize by execution_date."

**Data Quality:**
"DBT tests (`not_null`, `unique`, `accepted_values`, custom SQL tests) map directly to DLT expectations (`EXPECT`, `EXPECT OR DROP`, `EXPECT OR FAIL`) or Great Expectations running as a task in a Databricks workflow. Same philosophy: assert invariants between pipeline stages."

---

## SECTION F: THE SPARK PERFORMANCE CHEAT SHEET

### If interviewer asks "How do you tune a Spark job?" — give this ordered checklist:

1. **Reduce data early** — filter rows, prune columns at scan time
2. **Avoid shuffles** — broadcast small tables, avoid unnecessary groupBys
3. **Handle skew** — AQE first, salt if needed
4. **Right-size partitions** — target 128-256MB per partition post-shuffle
5. **Avoid Python UDFs** — native functions > pandas_udf > row UDF
6. **Cache wisely** — only if reused AND fits
7. **File format** — Parquet/Delta with proper compression (snappy for speed, zstd for size)
8. **Cluster sizing** — enough executors for parallelism, enough memory for largest partition
9. **AQE on** — coalesces small partitions, flips join types, handles skew
10. **Photon** — if on Databricks, enable for aggregation-heavy workloads

### The numbers to quote:

| Metric | Target | Danger Zone |
|--------|--------|-------------|
| Partition size post-shuffle | 128-256 MB | > 1GB (spill) or < 10MB (overhead) |
| Shuffle partitions | Based on data: `total_shuffle_data / 200MB` | Default 200 for 100GB+ data is too few |
| Task duration | 10s - 2min | > 5min (possible skew) or < 1s (too many tasks) |
| Shuffle spill | 0 (ideal) | Any spill = partitions too big for memory |
| Broadcast threshold | 10MB default, tune to 100-500MB | > 1GB risky for driver OOM |
| Executor memory utilization | 60-80% | > 90% (OOM risk) or < 30% (wasteful) |
