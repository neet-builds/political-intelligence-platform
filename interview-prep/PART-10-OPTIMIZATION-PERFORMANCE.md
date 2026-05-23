# PART 10 — OPTIMIZATION & PERFORMANCE DEEP DIVES

## Why Optimization Questions Are Inevitable

Every DE interview at the Lead level asks some variant of: "This is slow/expensive. Fix it." Amarendra will probe whether you:
1. **Diagnose before prescribing** — do you measure or just guess?
2. **Know the cost hierarchy** — what's expensive in distributed systems?
3. **Make tradeoffs explicitly** — speed vs cost vs complexity vs maintainability
4. **Think in layers** — storage, compute, network, application logic

---

## THE COST HIERARCHY IN SPARK (Memorize This)

From most expensive to least expensive operations:

```
1. SHUFFLE (wide transformation) — network + disk + serialization
2. DISK SPILL — partition too big for memory, writes to local disk
3. FULL TABLE SCAN — reading data you don't need
4. SERIALIZATION — Python UDF boundary crossing (JVM ↔ Python)
5. OBJECT STORAGE LISTING — millions of small files = slow listing
6. SORT — CPU intensive, can spill
7. BROADCAST — cheap per-query but uses driver memory
8. NARROW TRANSFORMATION — partition-local, minimal cost
```

**The optimization game:** push operations DOWN this list. Turn shuffles into broadcasts. Turn full scans into pruned scans. Turn UDFs into native functions.

---

## SECTION A: SPARK TUNING — The Complete Picture

### The 4 Knobs That Matter Most


#### Knob 1: `spark.sql.shuffle.partitions`

**Default:** 200
**What it controls:** How many partitions result from ANY shuffle (groupBy, join, distinct, repartition)

**The problem with 200:**
- 10GB shuffle → 200 partitions → 50MB each → fine
- 1TB shuffle → 200 partitions → 5GB each → OOM per task
- 100MB shuffle → 200 partitions → 500KB each → 200 tasks with huge overhead, mostly empty

**How to set it correctly:**
```
Optimal partitions = total_shuffle_data_size / target_partition_size
Target partition size = 128MB - 256MB
```

Example: 500GB shuffle → 500,000 MB / 200MB = 2,500 partitions

```python
# Set based on estimated shuffle size
spark.conf.set("spark.sql.shuffle.partitions", "2500")

# Or: let AQE handle it dynamically (preferred in Spark 3.2+)
spark.conf.set("spark.sql.adaptive.enabled", "true")
spark.conf.set("spark.sql.adaptive.coalescePartitions.enabled", "true")
spark.conf.set("spark.sql.adaptive.coalescePartitions.minPartitionSize", "64MB")
```

**Interview line:** "I don't hardcode shuffle partitions anymore unless AQE isn't available. AQE dynamically coalesces small partitions post-shuffle, so I set a high initial count (say 5000) and let AQE merge the small ones. Best of both worlds: enough parallelism for large shuffles, no overhead from empty partitions."

#### Knob 2: `spark.sql.autoBroadcastJoinThreshold`

**Default:** 10MB (10485760 bytes)
**What it controls:** Tables smaller than this are automatically broadcast to all executors (avoiding shuffle)

**Tuning guidance:**
```python
# Conservative production setting
spark.conf.set("spark.sql.autoBroadcastJoinThreshold", "100MB")  # 100MB

# Disable entirely (force sort-merge for predictable behavior)
spark.conf.set("spark.sql.autoBroadcastJoinThreshold", "-1")

# Aggressive (if you have memory headroom)
spark.conf.set("spark.sql.autoBroadcastJoinThreshold", "500MB")
```

**The danger:** "Setting this too high is a common mistake. If the optimizer ESTIMATES a table as 90MB but actual post-filter size is 2GB, it'll try to broadcast 2GB → driver OOM. With AQE, Spark uses ACTUAL runtime size for the decision, which is much safer. Without AQE, stick to conservative thresholds or use explicit `broadcast()` hints on known-small tables."

#### Knob 3: Executor Memory & Cores

```python
# Typical production cluster config
spark.conf.set("spark.executor.memory", "8g")       # Heap memory
spark.conf.set("spark.executor.memoryOverhead", "2g") # Off-heap (Python, shuffles)
spark.conf.set("spark.executor.cores", "4")           # Tasks per executor

# Driver (for orchestration, broadcast collect)
spark.conf.set("spark.driver.memory", "4g")
```

**The formula for sizing:**
- **Executor memory:** largest expected partition × 2-3x (for overhead + intermediate state)
- **Executor cores:** 4-5 cores is optimal. More = too much memory contention per executor.
- **Number of executors:** total_data / (partition_size × cores per executor)

**Interview line:** "I size executors so that each TASK (one partition) fits comfortably in memory. If my target partition is 200MB and each executor has 4 cores, I need executor memory to handle 4 × 200MB = 800MB of active data plus overhead — so 4-8GB per executor is typical. I'd rather have more small executors than fewer large ones for fault tolerance."

#### Knob 4: AQE (Adaptive Query Execution)

```python
spark.conf.set("spark.sql.adaptive.enabled", "true")  # Master switch
spark.conf.set("spark.sql.adaptive.coalescePartitions.enabled", "true")   # Merge small partitions
spark.conf.set("spark.sql.adaptive.skewJoin.enabled", "true")             # Split skewed partitions
spark.conf.set("spark.sql.adaptive.localShuffleReader.enabled", "true")   # Avoid network if data is local
```

**What AQE does at runtime:**
1. **After each shuffle:** examines actual partition sizes (not estimates)
2. **Coalesces small partitions:** if 200 partitions but most are 1MB, merges them to target size
3. **Splits skewed partitions:** if one partition is 10GB and others are 100MB, splits the big one
4. **Converts join strategy:** if a table is small at runtime (after filters), switches to broadcast

**Why this is the #1 recommendation in every optimization answer:** "AQE makes runtime decisions based on ACTUAL data, not optimizer estimates. Estimates are often wrong (especially after complex filter chains). AQE is almost always better than static tuning."

---

### SECTION B: JOIN OPTIMIZATION — The Deep Dive

#### The 5 Join Strategies (Know When Each Fires)

| Strategy | Conditions | Shuffle Required? | Best For |
|----------|-----------|-------------------|----------|
| **Broadcast Hash** | One side < threshold | No (broadcast only) | Fact + small dim |
| **Shuffle Hash** | One side fits in executor memory post-shuffle | Yes (one-sided) | Medium tables |
| **Sort-Merge** | Default for large-large | Yes (both sides) | Large + large |
| **Broadcast Nested Loop** | Non-equi join with small side | No shuffle but O(n×m) | Cross join, range join |
| **Cartesian** | No join condition | No shuffle but O(n×m) | Avoid at all costs |

#### Optimization: Converting Sort-Merge to Broadcast

**Scenario:** Joining `orders` (1B rows) with `products` (2M rows). Default: sort-merge (shuffles both). But `products` is only ~400MB — perfectly broadcastable.

```python
# Option 1: Explicit hint (guaranteed)
from pyspark.sql.functions import broadcast
orders.join(broadcast(products), "product_id")

# Option 2: Raise threshold (implicit)
spark.conf.set("spark.sql.autoBroadcastJoinThreshold", "500MB")

# Option 3: Let AQE decide at runtime (safest)
# AQE sees actual size after filters and broadcasts if small enough
```

**Savings:** Sort-merge on 1B + 2M rows shuffles ~200GB (orders side) + 400MB (products side). Broadcast eliminates the 200GB shuffle entirely. Job time: maybe 10x faster.

#### Optimization: Bucketed Joins (Pre-Shuffled Data)

**What it is:** Pre-partition and pre-sort data at WRITE time so READS avoid shuffle.

```python
# Write both tables bucketed by join key
orders.write \
    .bucketBy(256, "product_id") \
    .sortBy("product_id") \
    .format("parquet") \
    .saveAsTable("orders_bucketed")

products.write \
    .bucketBy(256, "product_id") \
    .sortBy("product_id") \
    .format("parquet") \
    .saveAsTable("products_bucketed")

# Join reads — NO SHUFFLE at join time (data already co-located)
spark.table("orders_bucketed").join(spark.table("products_bucketed"), "product_id")
```

**When to use:** "Same two tables are joined repeatedly (daily pipeline joins orders + products every day). The upfront cost of bucketed write pays off across every subsequent join. At Nike with daily product-order joins, this could save 30 minutes of shuffle per run."

**When NOT to use:** "Tables with very different join patterns (joined on different keys by different teams). Bucket count must match between both sides. And Delta Lake doesn't support bucketing natively — Databricks uses Z-ORDER + file pruning as the alternative."

---

### SECTION C: PARTITIONING STRATEGY — Production Decision Framework

#### When to Partition vs Z-Order vs Liquid Cluster

**Decision tree:**

```
Is the filter column low cardinality (< 1000 distinct values)?
├── YES → Is each partition > 1GB?
│   ├── YES → PARTITION BY that column ✓
│   └── NO → Don't partition (too many small files). Use Z-ORDER or Liquid Clustering.
└── NO (high cardinality like user_id, order_id)
    → Never partition by this. Use Z-ORDER or Liquid Clustering.
```

#### Partitioning Scenarios:

**Scenario 1:** "Table: 2B rows, 500GB. Accessed by `event_date` (daily). 3 years of data."
- Partition by `event_date` → 1095 partitions × ~450MB each → ✅ good size
- Z-ORDER by `user_id` within each partition → fast user-level lookups within a day

**Scenario 2:** "Table: 500M rows, 100GB. Accessed by `country_code` (200 values) AND `event_date`."
- Partition by `event_date` AND `country_code`? → 1095 × 200 = 219,000 partitions → ❌ too many, tiny files
- Better: partition by `event_date` only, Z-ORDER by `country_code`
- Or: Liquid Cluster by `(event_date, country_code)` — handles both access patterns

**Scenario 3:** "Table: 10M rows, 5GB. Small but queried 1000x/day by `product_id`."
- Don't partition (table is too small, partitions would be KB-sized)
- Z-ORDER by `product_id` → Delta file pruning handles it
- Or just leave unpartitioned — at 5GB, full scan is fast enough

#### The Over-Partitioning Problem

**Interviewer asks:** "Your table has 500K partitions. Is that a problem?"

**Strong answer:** "Yes, massively. Problems with too many partitions:
1. **File listing overhead:** S3 LIST operations are O(n) with partition count. 500K partitions with even 1 file each = 500K files to list on every read.
2. **Small files:** each partition might have only a few MB → massive read amplification (each file requires separate S3 GET).
3. **Metastore pressure:** Hive metastore or Unity Catalog tracks partition metadata. 500K entries strains it.
4. **OPTIMIZE becomes expensive:** needs to compact across all partitions.

Fix: repartition the table with fewer/different partition columns. Or migrate to Liquid Clustering which handles this automatically."

---

### SECTION D: COST OPTIMIZATION SCENARIOS

#### Scenario: "Your team's Databricks bill is $80K/month. Cut it to $50K without impacting SLAs."

**Your structured answer:**

"I'd approach this like performance optimization — measure first, then target the top cost drivers.

**Step 1: Measure (where is the money going?)**
```sql
-- Top 10 most expensive jobs in the last 30 days
SELECT
    j.job_name,
    j.job_id,
    COUNT(*) as run_count,
    AVG(r.execution_duration_ms) / 60000 as avg_minutes,
    SUM(u.usage_quantity) as total_dbus,
    SUM(u.usage_quantity) * 0.25 as estimated_cost_usd  -- approximate
FROM system.lakeflow.job_run_timeline r
JOIN system.lakeflow.jobs j USING (job_id)
JOIN system.billing.usage u ON r.run_id = u.usage_metadata.job_run_id
WHERE r.period_start_time >= current_date() - 30
GROUP BY 1, 2
ORDER BY total_dbus DESC
LIMIT 10;
```

**Step 2: Categorize and fix (top to bottom)**

| Category | Typical % of Bill | Optimization |
|----------|------------------|--------------|
| Interactive clusters always on | 20-40% | Auto-terminate 15min. Move dev work to serverless SQL warehouse. |
| Over-provisioned job clusters | 15-25% | Right-size: profile peak memory/CPU utilization per job. Most use <50% of provisioned resources. |
| On-demand instances | 10-20% | Switch fault-tolerant batch jobs to SPOT instances (60-70% savings) |
| Redundant computation | 10-15% | Cache intermediate results that multiple jobs read. Materialize shared CTEs. |
| Inefficient queries (full scans) | 5-10% | Add partition pruning, Z-ORDER, column pruning. Reduce scan volume. |
| Retry storms | 5-10% | Fix root causes instead of retrying expensive jobs 3x |

**Step 3: Quick wins (implement this week)**
1. All-purpose clusters → auto-terminate 15 min (saves ~$15K/month alone if teams leave clusters running)
2. Largest 3 jobs: switch from on-demand to spot workers (saves ~$10K)
3. Enable Photon on top 5 aggregation-heavy jobs (fewer DBUs for same work, net savings)

**Step 4: Medium-term (next sprint)**
4. Profile and right-size the top 10 jobs (reduce worker count or memory)
5. Add `availableNow` trigger to streaming jobs that don't need sub-minute latency (cluster terminates between runs)
6. Implement shared compute pools for similar-sized jobs (reuse warm clusters)"

---

#### Scenario: "Streaming job costs $25K/month. Business only needs 15-minute freshness, not real-time."

**Answer:** "If the SLA is 15 minutes, I don't need a continuous streaming cluster. I'd switch from:
```python
# BEFORE: always-on streaming ($25K/month)
.trigger(processingTime='30 seconds')  # Cluster runs 24/7
```
to:
```python
# AFTER: scheduled micro-batch ($5K/month)
.trigger(availableNow=True)  # Process all available data, then stop
```
Schedule this via Databricks Workflow every 10 minutes. Cluster spins up, processes 10 min of data, shuts down. Only paying for ~15 min of compute per hour instead of 60 min. **Savings: 75%.**"

---

### SECTION E: DATA SKEW OPTIMIZATION — The Complete Playbook

#### Detecting Skew Quantitatively

```python
from pyspark.sql.functions import count, col, percentile_approx

# Step 1: Check key distribution
distribution = (
    df.groupBy("join_key")
    .count()
    .agg(
        percentile_approx("count", 0.5).alias("median"),
        percentile_approx("count", 0.9).alias("p90"),
        percentile_approx("count", 0.99).alias("p99"),
        max("count").alias("max_count")
    )
)
distribution.show()
# If max/median > 100 → severe skew
# If p99/median > 10 → moderate skew

# Step 2: Identify the hot keys
hot_keys = (
    df.groupBy("join_key")
    .count()
    .orderBy(col("count").desc())
    .limit(20)
)
hot_keys.show()
```

#### Fix 1: AQE Skew Handling (Lowest Effort)

```python
spark.conf.set("spark.sql.adaptive.enabled", "true")
spark.conf.set("spark.sql.adaptive.skewJoin.enabled", "true")
# A partition is considered skewed if:
# size > skewedPartitionFactor × median partition size AND
# size > skewedPartitionThresholdInBytes
spark.conf.set("spark.sql.adaptive.skewJoin.skewedPartitionFactor", "5")
spark.conf.set("spark.sql.adaptive.skewJoin.skewedPartitionThresholdInBytes", "256MB")
```

**When AQE handles it well:** moderate skew (top key is 10-50x the median). AQE splits the skewed partition and duplicates the other side's matching data.

**When AQE isn't enough:** extreme skew (one key is 1000x the median) or when the join is the foundation of a larger DAG and you need predictable performance.

#### Fix 2: Isolate and Broadcast Hot Keys

```python
# Identify hot keys (e.g., top 100 by frequency)
hot_key_set = set(
    df.groupBy("join_key").count()
    .orderBy(col("count").desc())
    .limit(100)
    .select("join_key")
    .rdd.flatMap(lambda x: x)
    .collect()
)

# Broadcast the hot key set for filtering
hot_keys_bc = spark.sparkContext.broadcast(hot_key_set)

# Split into hot and cold paths
from pyspark.sql.functions import udf
is_hot = udf(lambda k: k in hot_keys_bc.value, BooleanType())

fact_hot = fact.filter(is_hot(col("join_key")))
fact_cold = fact.filter(~is_hot(col("join_key")))

# Hot path: broadcast the dim rows for hot keys only (tiny)
dim_hot = dim.filter(col("join_key").isin(list(hot_key_set)))
joined_hot = fact_hot.join(broadcast(dim_hot), "join_key")

# Cold path: normal sort-merge (no skew)
joined_cold = fact_cold.join(dim, "join_key")

# Union
result = joined_hot.unionByName(joined_cold)
```

#### Fix 3: Salting (Most General)

```python
SALT_BUCKETS = 50  # Degree of parallelization for hot keys

# Salt the fact table
fact_salted = fact.withColumn(
    "salt", (rand() * SALT_BUCKETS).cast("int")
).withColumn(
    "salted_key", concat_ws("_", col("join_key"), col("salt"))
)

# Explode the dimension (replicate each row SALT_BUCKETS times)
from pyspark.sql.functions import explode, array, lit
dim_exploded = dim.withColumn(
    "salt", explode(array([lit(i) for i in range(SALT_BUCKETS)]))
).withColumn(
    "salted_key", concat_ws("_", col("join_key"), col("salt"))
)

# Join on salted key — hot key is now distributed across 50 partitions
joined = fact_salted.join(dim_exploded, "salted_key")

# Drop salt columns
result = joined.drop("salt", "salted_key")
```

**Cost of salting:** Dimension is replicated 50x. If dim is 1GB, that's 50GB of shuffle for the dim side. But if the alternative is one executor processing 500GB of skewed data for 4 hours, the 50GB replication is a bargain.

**When to use which fix:**

| Skew Severity | Approach | Reason |
|---------------|----------|--------|
| Mild (max/median < 50) | AQE | Zero code change, handles automatically |
| Moderate (50-500x) | Isolate hot keys + broadcast | Targeted, no dim replication |
| Severe (500x+) or unknown hot keys | Salting | Most general, handles any distribution |
| NULL key is the hot key | Filter NULLs, process separately | NULLs don't join anyway (unless full outer) |

---

### SECTION F: QUERY PLAN ANALYSIS (How to Read .explain())

**This is what separates mid from senior in interviews. If Amarendra shows you a query plan, you should be able to read it.**

```python
df.explain(True)  # Shows all 4 plans: Parsed, Analyzed, Optimized, Physical
df.explain("cost")  # Shows estimated costs
df.explain("formatted")  # Pretty-printed physical plan
```

#### What to Look for in a Physical Plan:

```
== Physical Plan ==
*(5) SortMergeJoin [customer_id#10], [customer_id#20], Inner
:- *(2) Sort [customer_id#10 ASC], false, 0
:  +- Exchange hashpartitioning(customer_id#10, 200)      ← SHUFFLE (expensive!)
:     +- *(1) Filter isnotnull(customer_id#10)
:        +- *(1) ColumnarToRow
:           +- FileScan parquet [customer_id#10,amount#11]  ← Only 2 columns read (good!)
:              PushedFilters: [IsNotNull(customer_id)]       ← Predicate pushed to scan (good!)
+- *(4) Sort [customer_id#20 ASC], false, 0
   +- Exchange hashpartitioning(customer_id#20, 200)       ← ANOTHER SHUFFLE
      +- *(3) FileScan parquet [customer_id#20,name#21]
```

**What I'd say in an interview:**
"I see a SortMergeJoin — both sides are shuffled by customer_id (two `Exchange hashpartitioning` operators). This means both tables are large. The good news: predicate pushdown is happening (`PushedFilters: IsNotNull`), and column pruning is working (only reading needed columns). The bad news: if the customer dimension table is small (< 100MB), this should be a BroadcastHashJoin instead. I'd check: why isn't it broadcasting? Probably the optimizer overestimated the dim table size. Fix: add explicit `broadcast()` hint or raise the threshold."

#### Key operators to recognize:

| Operator | Meaning | Cost |
|----------|---------|------|
| `Exchange hashpartitioning` | Shuffle | HIGH — network + disk |
| `BroadcastExchange` | Broadcast | LOW — no shuffle on fact side |
| `Sort` | Sort within partition | MEDIUM — CPU, can spill |
| `SortMergeJoin` | Both sides shuffled + sorted | HIGH |
| `BroadcastHashJoin` | Small side broadcast | LOW |
| `FileScan` | Reading from storage | Check: how many files, which columns |
| `Filter` | Row filter | LOW (but check if pushed to scan) |
| `Project` | Column selection | LOW |
| `HashAggregate` | Group by aggregation | MEDIUM — requires shuffle |
| `TakeOrderedAndProject` | LIMIT with ORDER BY | Can be expensive if sorting entire dataset |

---

### SECTION G: STORAGE OPTIMIZATION

#### File Size Optimization

**Problem:** Too many small files kills read performance. Too few large files kills write parallelism.

**Target:** 128MB - 1GB per file for Delta/Parquet.

**How small files accumulate:**
- Streaming writes (each micro-batch creates files per partition)
- Frequent MERGE operations (each merge rewrites affected files)
- Over-partitioning (each partition gets tiny files)
- Failed/killed jobs leaving partial writes

**Solutions:**
```sql
-- Compact files (run nightly)
OPTIMIZE silver.events;

-- Compact only recent partitions (cheaper)
OPTIMIZE silver.events WHERE event_date >= current_date() - 7;

-- Auto-compaction on write (Databricks)
ALTER TABLE silver.events SET TBLPROPERTIES (
    'delta.autoOptimize.optimizeWrite' = 'true',   -- Coalesce small files on write
    'delta.autoOptimize.autoCompact' = 'true'       -- Trigger compaction when too many small files
);
```

**`optimizeWrite` vs `autoCompact`:**
- `optimizeWrite`: at WRITE time, coalesces output files to target size. Adds slight write latency.
- `autoCompact`: AFTER write completes, triggers a background compaction if file count is too high. Async.
- "For streaming pipelines, I enable both. For batch pipelines that already produce well-sized files via `repartition()` before write, neither is needed."

#### Compression Choices

| Codec | Speed | Ratio | When to Use |
|-------|-------|-------|-------------|
| **Snappy** | Fastest | ~2x | Default for Spark. Best for shuffle-heavy workloads where decompression speed matters. |
| **ZSTD** | Medium | ~3-4x | Storage-optimized. Best for cold data / archival. Slower decompress but much smaller. |
| **LZ4** | Very fast | ~2x | Similar to snappy. Good for hot data with fast read requirements. |
| **Gzip** | Slow | ~3x | Avoid in Spark. Non-splittable in most contexts. Legacy only. |

```python
# Set compression for Delta writes
spark.conf.set("spark.sql.parquet.compression.codec", "zstd")
# Or per-table:
df.write.option("compression", "zstd").format("delta").save(path)
```

**Interview line:** "I use snappy for hot silver/gold tables where query speed matters, and zstd for cold bronze/archive tables where storage cost dominates. The 50% extra compression from zstd saves significant S3 costs on multi-TB tables."

---

### SECTION H: REAL-TIME OPTIMIZATION SCENARIO

**Interviewer asks:** "Walk me through how you'd optimize this end-to-end pipeline. Current runtime: 4 hours. Target: 45 minutes."

```python
# The slow pipeline (pseudocode):
raw = spark.read.parquet("s3://data/events/")                    # 2TB, 5B rows
users = spark.read.parquet("s3://data/users/")                   # 500M rows
products = spark.read.parquet("s3://data/products/")             # 5M rows

# Step 1: Filter to last 7 days
recent = raw.filter(col("event_date") >= "2024-06-10")           # Still 300GB

# Step 2: Enrich with user data
enriched = recent.join(users, "user_id")                         # Sort-merge (both large)

# Step 3: Enrich with product data  
enriched2 = enriched.join(products, "product_id")                # Sort-merge again!

# Step 4: Aggregate
result = enriched2.groupBy("user_segment", "product_category", "event_date") \
    .agg(count("*"), countDistinct("user_id"), sum("amount"))

# Step 5: Write
result.write.format("delta").mode("overwrite").save("s3://gold/daily_metrics/")
```

**My optimization walkthrough:**

"I see 5 issues. Let me address them in order of impact:

**Issue 1: Full 2TB scan before filter** — Parquet files aren't partitioned by event_date (or the read doesn't leverage it). 
Fix: Ensure source is partitioned by event_date, or add partition filter BEFORE read.
```python
raw = spark.read.parquet("s3://data/events/event_date=2024-06-1*")  # Partition pruning
```
Impact: 2TB → 300GB scan. ~6x improvement on read alone.

**Issue 2: Sort-merge join with 500M user table** — users table is too big to broadcast, but do we need ALL 500M users? After the date filter, only a subset of users have events.
Fix: Filter users to only those present in recent events.
```python
active_user_ids = recent.select("user_id").distinct()  # Maybe 50M users in 7 days
active_users = users.join(broadcast(active_user_ids), "user_id")  # Filter users down
enriched = recent.join(active_users, "user_id")  # Now joining 300GB with a much smaller user set
```
Or better: if after filtering, users is < 500MB, broadcast it entirely.

**Issue 3: Products table should ALWAYS be broadcast** — 5M rows × 200 bytes = ~1GB. Broadcastable.
```python
enriched2 = enriched.join(broadcast(products), "product_id")  # No shuffle!
```
Impact: eliminates one full shuffle of 300GB+.

**Issue 4: Two shuffles for two joins** — both joins shuffle on different keys (user_id, then product_id).
Fix: If I must sort-merge users, I can chain the product join via broadcast to avoid a second shuffle. With broadcast products, only ONE shuffle total (for the user join).

**Issue 5: Column pruning** — am I reading all 100 columns from raw when I only need 6?
```python
recent = raw.select("user_id", "product_id", "event_date", "event_type", "amount", "event_time") \
    .filter(col("event_date") >= "2024-06-10")
```
Impact: Parquet is columnar — reading 6/100 columns = 94% less IO.

**Optimized pipeline:**
```python
# 1. Read with partition pruning + column pruning
recent = (spark.read.parquet("s3://data/events/")
    .select("user_id", "product_id", "event_date", "amount")
    .filter(col("event_date") >= "2024-06-10"))

# 2. Broadcast products (1GB, easily fits)
products_slim = spark.read.parquet("s3://data/products/") \
    .select("product_id", "product_category")
recent_with_product = recent.join(broadcast(products_slim), "product_id")

# 3. Join users — broadcast if possible after reducing
users_slim = spark.read.parquet("s3://data/users/") \
    .select("user_id", "user_segment")
# If 500M × 50 bytes = 25GB → too big to broadcast → sort-merge but ONLY on needed columns
enriched = recent_with_product.join(users_slim, "user_id")

# 4. Aggregate
result = enriched.groupBy("user_segment", "product_category", "event_date") \
    .agg(count("*").alias("events"), countDistinct("user_id").alias("users"), sum("amount").alias("revenue"))

# 5. Write (coalesce to reduce output files)
result.coalesce(10).write.format("delta").mode("overwrite").save("s3://gold/daily_metrics/")
```

**Expected improvement:**
- Partition pruning: 2TB → 300GB (6x read reduction)
- Column pruning: 300GB → ~30GB (reads only needed columns)
- Broadcast products: eliminates one 300GB shuffle
- Column pruning on users: 500M × 200B → 500M × 50B = 25GB shuffle instead of 100GB
- **Total: from 4 hours to ~30-45 minutes.**"
