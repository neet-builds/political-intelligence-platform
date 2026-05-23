# PART 6 — DATABRICKS DEEP DIVE: Architecture, Production, Cost, Internals

## How This Section Works

You haven't used Databricks hands-on. That's fine. Amarendra is NOT going to ask you to navigate the UI. He'll ask **architectural reasoning** questions — "how would you design X on Databricks" or "what happens when Y goes wrong." This section gives you the depth to answer like someone who's been running Databricks in production for 2 years.

---

## SECTION A: DELTA LAKE INTERNALS — What You MUST Know Cold

### The Transaction Log (_delta_log/)

This is the single most important concept in Delta Lake. Everything else builds on it.

**What it is:** A directory of JSON files (numbered sequentially: `000000.json`, `000001.json`, ...) that records every operation on the table.

**What each commit file contains:**
- `add` actions: new Parquet files added to the table
- `remove` actions: files logically deleted (still on disk until VACUUM)
- `metadata`: schema changes, partition info
- `txn` actions: application-level transaction IDs (for idempotency)
- `protocol`: reader/writer version requirements


**How reads work:**
1. Reader lists `_delta_log/` directory
2. Reconstructs current table state by replaying all commit files (or reading latest checkpoint + subsequent commits)
3. Identifies which Parquet files are "active" (added but not removed)
4. Reads only those Parquet files
5. File-level pruning uses min/max stats from the commit entries

**How writes work (ACID guarantee):**
1. Writer reads current table version (e.g., version 42)
2. Writer computes new files to add/remove
3. Writer attempts to write commit file `000043.json` (optimistic concurrency)
4. If another writer already wrote `000043.json` → conflict! Delta checks if the conflict is resolvable (non-overlapping partitions = OK, same rows = fail)
5. If resolvable → retries with version 44. If not → throws `ConcurrentModificationException`

**Why this matters in interview:**
- It's HOW Delta achieves ACID on object storage (S3/GCS have no locking mechanism)
- It's WHY time travel works (old files aren't deleted until VACUUM)
- It's WHY MERGE is possible (read-modify-write with conflict detection)
- It's WHY you can't VACUUM too aggressively (breaks time travel / concurrent readers)

### Checkpoints (Every 10 commits)

"Every 10 commits, Delta writes a Parquet checkpoint file that contains the cumulative state. Instead of replaying 1000 JSON files, readers just read the latest checkpoint + subsequent commits. This is why Delta scales to tables with millions of commits."

**Interview line:** "The transaction log is what separates Delta from raw Parquet on S3. Without it, you have no ACID, no MERGE, no time travel, and no way to safely do concurrent writes."

---

### Time Travel — Production Uses

```sql
-- Read table as of a specific version
SELECT * FROM events VERSION AS OF 42;

-- Read table as of a timestamp
SELECT * FROM events TIMESTAMP AS OF '2024-06-15 08:00:00';

-- Restore to a previous version (UNDO a bad write)
RESTORE TABLE events TO VERSION AS OF 42;
```

**Production scenarios where time travel saves you:**
1. **Bad deployment:** merged incorrect logic, wrote bad data to gold. `RESTORE` to pre-deploy version, fix code, re-run.
2. **Debugging:** "data was wrong on Tuesday" → `SELECT * FROM gold_table TIMESTAMP AS OF '2024-06-11'` to see what the table looked like then.
3. **Audit:** regulatory requirement to reproduce historical state.
4. **Backfill validation:** compare current vs previous version to verify a backfill didn't corrupt existing data.

**The trap:** "How long does time travel work?"
**Answer:** "As long as the underlying Parquet files exist. `VACUUM` deletes files older than the retention period (default 7 days). After VACUUM, time travel to versions that reference those deleted files will fail. I set `delta.deletedFileRetentionDuration = '30 days'` on critical tables."

---

### MERGE Deep Dive — The Most Important Operation

**Why MERGE matters:** It's the foundation of incremental pipelines on Delta. It's the equivalent of your DBT `merge` strategy.

```sql
MERGE INTO silver.orders AS target
USING staging.new_orders AS source
ON target.order_id = source.order_id

WHEN MATCHED AND source.updated_at > target.updated_at THEN
    UPDATE SET *

WHEN NOT MATCHED THEN
    INSERT *

WHEN NOT MATCHED BY SOURCE AND target.order_date < current_date() - INTERVAL 90 DAYS THEN
    DELETE;  -- Clean up old unmatched rows (optional)
```

**What happens under the hood:**
1. Delta identifies which **files** in the target table MIGHT contain matching rows (using file-level stats — min/max on the merge key)
2. Only those files are read (file pruning)
3. For each matched row, a new file is written with the updated value
4. Old files are marked `remove` in the commit, new files marked `add`
5. This is a **copy-on-write** operation — even updating 1 row rewrites the entire file

**Performance implications:**
- If the merge key has poor data locality (random UUIDs), every file potentially contains a match → reads entire table
- **Z-ORDER on the merge key** dramatically improves this — co-locates similar keys in the same files, so fewer files need to be read
- MERGE on a well-Z-ordered table can be 10-50x faster than on an unordered one

**Follow-up probe:** "What if your source batch has duplicate keys?"

**Strong answer:** "Delta MERGE requires that the source has at most ONE match per target row (on the merge condition). If the source has duplicates on the merge key, the MERGE throws an error: 'multiple source rows matched.' Fix: deduplicate the source BEFORE the merge — ROW_NUMBER by merge key, keep latest. This is why I always dedup in the silver transform BEFORE the merge step."

---

### Change Data Feed (CDF) — CDC Made Easy

**What it is:** When enabled, Delta tracks row-level changes (insert/update/delete) and makes them queryable.

```sql
-- Enable on table
ALTER TABLE silver.customers SET TBLPROPERTIES (delta.enableChangeDataFeed = true);

-- Read changes between versions
SELECT * FROM table_changes('silver.customers', 5, 10);
-- Returns: _change_type (insert/update_preimage/update_postimage/delete), _commit_version, _commit_timestamp
```

**Production use cases:**
1. **Streaming downstream updates:** Gold layer subscribes to silver CDF — only processes changed rows, not full table scan
2. **Reverse ETL:** push only changed customer records to Salesforce
3. **Audit trail:** track who/what changed and when
4. **CDC propagation:** source DB → Bronze (raw CDC) → Silver (materialized via MERGE with CDF enabled) → Gold (reads CDF to incrementally update aggregates)

**Bridge to your GCP experience:** "This is like BigQuery's `INFORMATION_SCHEMA.TABLES` change history, but at row-level granularity. Or like Datastream's CDC output — but Delta generates it automatically from MERGE operations without a separate CDC tool."

---

## SECTION B: MEDALLION ARCHITECTURE — Deep Production Discussion

### Beyond the Basics

Amarendra won't ask "what is medallion?" He'll ask "how do you IMPLEMENT it, what decisions do you make, what goes wrong?"

**Bronze Layer — Design Decisions:**

| Decision | Options | My Recommendation & Why |
|----------|---------|-------------------------|
| Schema enforcement | Schema-on-read (accept anything) vs schema-on-write | Schema-on-read at bronze. Reason: I want to capture what the source ACTUALLY sent, including errors. Enforcement happens at silver. |
| Deduplication | Dedup at bronze vs pass-through | Pass-through (append-only). Dedup at silver. Bronze is a source-of-truth replica — dedup might hide data issues. |
| Partitioning | By ingestion date vs source event date | **Ingestion date** (`_ingested_date`). Source dates can be wrong/null. I always know when I received data. |
| Retention | Keep forever vs rolling window | Keep 90+ days minimum. Bronze is your recovery mechanism. If silver/gold corrupt, you replay from bronze. |
| Format | Raw (JSON/CSV as-is) vs converted Parquet/Delta | Convert to Delta at ingest. Raw files stay in a "raw" zone before bronze. Delta gives me ACID even at bronze level. |

**Silver Layer — Design Decisions:**

| Decision | Options | My Recommendation & Why |
|----------|---------|-------------------------|
| Dedup strategy | Latest-wins vs first-wins vs merge | Latest-wins for most event data. Full MERGE for dimensions with update semantics. |
| Schema | Strict enforcement | Yes — `mergeSchema = false` at silver. Schema drift should FAIL and alert, not silently pass. |
| Grain | Same as source vs pre-aggregated | Same as source — one row per business event. Aggregation happens at gold. |
| Joins | Denormalize into wide tables? | Partial denormalization. Frequently co-queried dimensions get joined into silver. Don't over-join — creates coupling. |
| Partitioning | By business date | Yes — `event_date` or `transaction_date`. This is what downstream queries filter on. |
| Quality gates | What checks? | Not-null on PKs, uniqueness on natural keys, freshness (max event_time within expected range), referential integrity spot-checks. |

**Gold Layer — Design Decisions:**

| Decision | Options | My Recommendation & Why |
|----------|---------|-------------------------|
| Grain | Pre-aggregated vs flexible | Aggregated for known use cases. One gold table per business KPI domain (revenue, engagement, inventory). |
| Refresh | Incremental vs full rebuild | Incremental using CDF from silver. Full rebuild weekly as reconciliation. |
| Access pattern | Who reads this? | BI tools (SQL Warehouse), ML feature stores, APIs. Optimize for the consumer's query pattern. |
| SLA | How fresh? | Defined per table: real-time gold (streaming from silver), daily gold (batch), weekly (aggregates). |


### The Scenarios That Break Medallion Architecture

**Scenario:** "Bronze is fine, silver is fine, but gold shows incorrect revenue numbers."

**Your debugging walkthrough:**
1. "First I check: is this a completeness issue (missing data) or a correctness issue (wrong calculations)?
2. Compare gold row count vs expected (based on silver). If gold has fewer rows, the aggregation or filter lost data.
3. Sample 10 known transactions from silver, trace them through the gold aggregation logic manually.
4. Common causes: (a) a join in gold is filtering out rows with NULL foreign keys (inner join should be left), (b) a SUM is double-counting because the silver table has unexpected duplicate keys, (c) a timezone issue in date filtering causes boundary records to land in wrong day's aggregate.
5. Time travel: compare today's gold vs yesterday's gold to see when the discrepancy appeared."

**Scenario:** "A source system goes down for 3 days. When it comes back, it sends 3 days of backfill data at once. Does your pipeline handle this?"

**Your answer:**
"If my pipeline is designed correctly — yes. Here's how:
1. Bronze: append-only, so 3 days of data just lands as 3 days of ingest. No issue.
2. Silver: my incremental MERGE processes based on a watermark (e.g., `WHERE event_date >= current_date - 7`). The 3 days of backfill fall within the window, so they get merged. If the backfill exceeds my window (e.g., 7 days late), I'd need a separate backfill job or widen the window.
3. Gold: if gold reads from silver via CDF, it picks up the newly merged rows automatically. If gold runs a date-partitioned full rebuild per day, I'd re-trigger the affected 3 days.

The key design principle: **pipelines should handle late data within a defined window without special intervention. Beyond that window, a documented backfill procedure exists.**"

---

## SECTION C: DATABRICKS PERFORMANCE OPTIMIZATION — Deep Scenarios

### OPTIMIZE + Z-ORDER — When, Why, How

**What OPTIMIZE does:**
- Compacts small files into larger ones (target: ~1GB per file)
- Reduces metadata overhead (fewer files = faster listing)
- Optionally Z-Orders data within files

**What Z-ORDER does:**
- Co-locates data with similar values in the Z-ordered columns into the same files
- Uses space-filling curves to map multi-dimensional data into 1D file layout
- Enables file-skipping: queries filtering on Z-ordered columns skip entire files

**When to Z-ORDER:**
- Columns frequently used in WHERE clauses or JOIN conditions
- High-cardinality columns where partitioning would create too many small partitions
- 1-4 columns max (effectiveness decreases with more columns)
- Run OPTIMIZE nightly on tables receiving daily batch loads

**When NOT to Z-ORDER:**
- Table is already partitioned by the most common filter → partitioning handles pruning
- Column has 2-3 distinct values (use partition instead)
- Table is tiny (< 1GB) — overhead not worth it
- Table is append-only streaming sink with Structured Streaming (use `optimizeWrite` instead)

```sql
-- Standard OPTIMIZE with Z-ORDER
OPTIMIZE silver.events ZORDER BY (user_id, product_id);

-- With file size target
OPTIMIZE silver.events ZORDER BY (user_id) WHERE event_date >= '2024-06-01';
-- ^ Only optimize recent partitions (saves compute on historical data)
```

**Production pattern:** "I OPTIMIZE nightly as the last step after my batch pipeline. Only on the partitions that were written today (`WHERE event_date = current_date`). Historical partitions are already optimized from previous runs."

### Liquid Clustering — The Modern Replacement

**What it is:** Replaces both PARTITION BY and ZORDER. Data is incrementally re-clustered on write.

**When to use Liquid Clustering over traditional partitioning + Z-ORDER:**
1. Access patterns evolve (today queries filter by `region`, next month by `product_category`)
2. High-cardinality cluster columns that would create too many partitions
3. Tables with frequent writes that would make Z-ORDER maintenance expensive
4. Simplicity — one knob instead of two (partition + zorder)

```sql
-- Create table with liquid clustering
CREATE TABLE silver.events (
    event_id STRING,
    user_id STRING,
    event_date DATE,
    event_type STRING
) USING DELTA
CLUSTER BY (user_id, event_date);

-- Change clustering columns without rewriting data
ALTER TABLE silver.events CLUSTER BY (event_type, event_date);
```

**Trade-off vs traditional:** "Liquid clustering is incremental — it optimizes data progressively as new data arrives, rather than requiring a scheduled OPTIMIZE. But for very large tables with stable access patterns, traditional partitioning + Z-ORDER gives more predictable file pruning because the layout is guaranteed. I'd use liquid clustering for newer tables and keep traditional for mature, stable schemas."

---

### Auto Loader — Deep Production Discussion

**What it is:** Databricks' file ingestion framework. Incrementally processes new files from cloud storage.

**Why it's better than `spark.read.format("parquet").load(path)`:**
- **Exactly-once semantics** via checkpoint tracking
- **Handles millions of files** without listing overhead (uses cloud notification or incremental listing)
- **Schema inference and evolution** built in
- **Rescue column** for unparseable data (doesn't fail the whole batch)

```python
# Auto Loader in production
raw_stream = (
    spark.readStream
    .format("cloudFiles")
    .option("cloudFiles.format", "json")
    .option("cloudFiles.schemaLocation", "s3://schema/events/")
    .option("cloudFiles.inferColumnTypes", "true")
    .option("cloudFiles.schemaEvolutionMode", "addNewColumns")  # auto-add new fields
    .option("rescuedDataColumn", "_rescued")  # unparseable rows go here, not failure
    .load("s3://landing/events/")
)

# Write to bronze Delta
(raw_stream
    .writeStream
    .format("delta")
    .option("checkpointLocation", "s3://checkpoints/events_bronze/")
    .trigger(availableNow=True)  # Process all available then stop (batch-like)
    .outputMode("append")
    .toTable("bronze.events")
)
```

**Interview-critical details:**

**`trigger(availableNow=True)` vs `trigger(processingTime='5 minutes')`:**
- `availableNow`: process all new files, then stop. Used in scheduled batch jobs (Databricks Workflow runs every hour, processes whatever landed since last run).
- `processingTime`: continuous streaming, process every 5 minutes. Used for near-real-time.
- "I use `availableNow` for most pipelines because it's simpler to reason about (one execution = one complete batch) and cheaper (cluster terminates after)."

**`cloudFiles.useNotifications` (notification mode):**
- Uses S3 event notifications (SNS/SQS) to discover new files. O(1) per file.
- vs. Directory listing mode: lists the directory each trigger. O(n) with number of files.
- "For directories with millions of historical files, notification mode avoids the expensive listing."

---

## SECTION D: UNITY CATALOG — Governance That Gets Asked About

### What It Is (and Why Interviewers Care)

Unity Catalog is Databricks' answer to: "Who can access what data, and how do we track lineage?"

**The hierarchy:**
```
Metastore (one per region)
  └── Catalog (like a database server — prod, staging, dev)
      └── Schema (like a database — sales, marketing, raw)
          └── Table / View / Volume / Function
```

**Key capabilities:**
1. **Fine-grained access control:** table-level, column-level, row-level filtering
2. **Automatic lineage:** tracks which notebooks/jobs read/write which tables
3. **Data discovery:** search across all catalogs, schemas, tables with tags and descriptions
4. **Cross-workspace:** one metastore shared across multiple Databricks workspaces

**How to talk about it in interview:**

"Unity Catalog gives me the governance layer that was always missing from Hive Metastore. In my current stack, I have GCP's Data Catalog for discovery and IAM for access control — Unity Catalog consolidates both into a single pane. The lineage feature is particularly valuable: I can see that table X was built from tables Y and Z by job W, without manually documenting it. For a company like Nike with PII in customer data, the column-level masking and row-level filtering means I can let analysts query the same table but see different columns based on their role."

**Probe:** "How does access control work across environments?"

**Answer:** "I'd set up three catalogs: `dev`, `staging`, `prod`. Each catalog has the same schema structure. Data engineers have full access to dev, read access to staging, and restricted access to prod. Production jobs run with a service principal that has write access to prod. This mirrors the pattern I use with GCP IAM — separate projects for environments, service accounts for automation."

---

## SECTION E: DATABRICKS WORKFLOWS & ORCHESTRATION

### Databricks Workflows vs Airflow — The Decision

**Interviewer asks:** "Would you use Databricks Workflows or Airflow for orchestration?"

**Strong answer:** "It depends on the scope of orchestration.

**Databricks Workflows when:**
- DAG is purely Databricks tasks (notebooks, DLT pipelines, SQL queries)
- Team is small, don't want to manage Airflow infrastructure
- Need native integration with job clusters, Unity Catalog permissions, and retry logic
- Simple dependencies (linear or fan-out)

**Airflow when:**
- DAG spans multiple systems (S3 → Databricks → Snowflake → dbt → Looker refresh → Slack alert)
- Complex scheduling (sensors waiting for upstream, cross-DAG dependencies)
- Team already has Airflow expertise
- Need programmatic DAG generation (Airflow DAGs are Python code)

At Nike, if the team is pure Databricks stack, I'd start with Workflows for simplicity. If they integrate with external systems heavily, Airflow (or managed MWAA on AWS) is the right call."

### Task Dependencies and Error Handling

```yaml
# Conceptual Databricks Workflow YAML
tasks:
  - task_key: ingest_bronze
    notebook_task:
      notebook_path: /pipelines/bronze/ingest_events
    new_cluster: {spark_version: "13.3", node_type: "m5.xlarge", num_workers: 4}
    max_retries: 2
    retry_on_timeout: true

  - task_key: transform_silver
    depends_on: [{task_key: ingest_bronze}]
    notebook_task:
      notebook_path: /pipelines/silver/transform_events
    # Runs on same job cluster (cost efficient)

  - task_key: quality_check
    depends_on: [{task_key: transform_silver}]
    notebook_task:
      notebook_path: /pipelines/quality/check_silver_events
    # If this fails → don't proceed to gold

  - task_key: build_gold
    depends_on: [{task_key: quality_check}]
    notebook_task:
      notebook_path: /pipelines/gold/build_aggregates
```

**Production patterns:**
- **Job clusters, not all-purpose:** Each workflow uses an ephemeral job cluster that spins up and terminates. Cheaper.
- **Retry with backoff:** Set `max_retries: 2` for transient failures (S3 throttling, spot interruption).
- **Quality gates:** A dedicated quality-check task between silver and gold. If it fails, gold doesn't get corrupted data.
- **Alerting:** On-failure notifications to Slack/PagerDuty via workflow notification settings.

---

## SECTION F: COST OPTIMIZATION — The Senior Discussion

### How Databricks Costs Work

**The billing model:**
- You pay for **DBUs (Databricks Units)** × rate + cloud compute (EC2/GCS VMs)
- Different workload types have different DBU rates:
  - Jobs compute: ~$0.15-0.25/DBU
  - All-purpose (interactive): ~$0.40-0.55/DBU
  - SQL Warehouse: ~$0.22-0.35/DBU (serverless is more)
  - Photon: higher DBU rate but fewer DBUs consumed (net often cheaper)

**Where costs hide:**
1. **All-purpose clusters left running** — auto-terminate MUST be set (15-30 min)
2. **Over-provisioned job clusters** — 20 nodes for a job that uses 3
3. **Shuffle to disk on undersized clusters** — job takes 4x longer = 4x cost
4. **Storage costs from VACUUM not running** — old files accumulate forever
5. **Unity Catalog overhead** — not a major cost, but serverless SQL warehouses have high per-query minimum

### The Cost Optimization Playbook

**Interviewer asks:** "Cost went from $20K/month to $60K/month in 3 months. Diagnose and fix."

**Systematic answer:**

"I'd audit in this order:

**1. Identify top cost drivers (system tables):**
```sql
SELECT
    workspace_id,
    sku_name,
    usage_unit,
    SUM(usage_quantity) AS total_dbus,
    SUM(usage_quantity * list_price) AS estimated_cost
FROM system.billing.usage
WHERE usage_date >= current_date() - 90
GROUP BY 1, 2, 3
ORDER BY estimated_cost DESC;
```

**2. Find expensive jobs:**
```sql
SELECT
    job_id,
    job_name,
    COUNT(*) AS runs,
    AVG(duration_ms) / 60000 AS avg_minutes,
    SUM(total_dbus) AS total_dbus
FROM system.billing.usage
JOIN system.lakeflow.jobs USING (job_id)
WHERE usage_date >= current_date() - 30
GROUP BY 1, 2
ORDER BY total_dbus DESC
LIMIT 20;
```

**3. Common fixes by category:**

| Issue | Fix | Savings |
|-------|-----|---------|
| Interactive clusters always on | Auto-terminate 15min, move production to job clusters | 50-70% |
| Job clusters over-provisioned | Profile actual utilization, right-size | 30-50% |
| Spot instances not used | Enable spot for fault-tolerant batch jobs | 50-70% on compute |
| Photon not enabled | Enable for aggregation-heavy workloads | 20-40% fewer DBUs |
| OPTIMIZE not running | Small files → slow reads → long jobs → more DBUs | 10-30% |
| Redundant full-table scans | Add partition pruning, Z-ORDER for file skipping | 30-60% |
| Retry storms | Fix root cause instead of retrying expensive jobs | Variable |
| Dev workloads on prod-grade clusters | Smaller clusters for dev/test | 40-60% |

**4. Architecture-level savings:**
- **Serverless SQL Warehouses:** auto-scale to zero. Pay only for query time. Better than keeping a cluster warm for ad-hoc BI.
- **Delta caching:** enables local SSD caching of remote data. Speeds up repeated reads dramatically → less compute time → fewer DBUs.
- **`availableNow` trigger:** cluster exists only during execution. vs. continuous streaming cluster running 24/7."


---

## SECTION G: DELTA LIVE TABLES (DLT) — The Declarative Framework

### What It Is

DLT is Databricks' declarative pipeline framework. You define WHAT the data should look like, and DLT handles HOW (dependencies, retries, streaming vs batch, quality enforcement).

**The mental model for you:** "DLT is like if DBT and Structured Streaming had a baby inside Databricks. You define expectations (like dbt tests) and transformations (like dbt models), and the framework manages execution."

```python
import dlt
from pyspark.sql.functions import *

# Bronze: raw ingestion with quality expectations
@dlt.table(
    comment="Raw clickstream events from Nike app"
)
@dlt.expect_or_drop("valid_user_id", "user_id IS NOT NULL")
@dlt.expect("valid_timestamp", "event_time > '2020-01-01'")
def bronze_events():
    return (
        spark.readStream
        .format("cloudFiles")
        .option("cloudFiles.format", "json")
        .load("s3://landing/clickstream/")
    )

# Silver: cleaned and enriched
@dlt.table(comment="Cleaned events with user dimensions")
@dlt.expect_all_or_fail({
    "unique_event": "event_id IS NOT NULL",
    "valid_amount": "amount >= 0 OR amount IS NULL"
})
def silver_events():
    events = dlt.read_stream("bronze_events")
    users = dlt.read("dim_users")  # batch read for dimension
    return (
        events
        .withWatermark("event_time", "2 hours")
        .dropDuplicates(["event_id"])
        .join(users, "user_id", "left")
    )

# Gold: business aggregates
@dlt.table(comment="Daily product engagement metrics")
def gold_daily_engagement():
    return (
        dlt.read("silver_events")
        .groupBy("event_date", "product_id")
        .agg(
            countDistinct("user_id").alias("unique_visitors"),
            count("*").alias("total_events"),
            sum(when(col("event_type") == "purchase", col("amount"))).alias("revenue")
        )
    )
```

### DLT Expectations — The Quality Framework

| Expectation Type | Behavior | When to Use |
|-----------------|----------|-------------|
| `@dlt.expect("name", "condition")` | Records violation in metrics, row passes through | Monitoring-only (I want to see % of bad data without blocking) |
| `@dlt.expect_or_drop("name", "condition")` | Drops violating rows silently | Non-critical data quality (filter junk, keep pipeline running) |
| `@dlt.expect_or_fail("name", "condition")` | Fails the pipeline | Critical constraints (PII validation, PK uniqueness) — must fix before proceeding |

**Interview line:** "I layer expectations: soft expectations for monitoring on bronze, hard expectations (fail) for critical constraints on silver. This gives me visibility without blocking ingest, but enforces quality before data reaches gold."

### DLT vs Custom Spark Pipelines — When to Use Which

**DLT when:**
- Streaming + batch mixed pipelines
- Team wants declarative, low-boilerplate
- Quality gates are important (expectations are first-class)
- Auto-managed infrastructure (DLT manages its own clusters)
- You want automatic lineage and monitoring

**Custom PySpark when:**
- Complex control flow (conditional logic, loops, external API calls)
- Need fine-grained control over cluster configuration
- Unit testing individual transformations
- Integration with non-Databricks systems
- Team prefers explicit over declarative

**Bridge from DBT:** "DLT is Databricks' answer to DBT. The differences: DLT handles streaming natively, DLT expectations are runtime (not post-run tests), and DLT auto-manages compute. DBT gives you more portability (runs on BigQuery, Snowflake, Databricks) and a larger community ecosystem."

---

## SECTION H: STRUCTURED STREAMING ON DATABRICKS — Production Patterns

### The Core Pattern (Nike real-time clickstream)

```python
# Read from Kafka (or Kinesis, or Delta CDF)
events_stream = (
    spark.readStream
    .format("kafka")
    .option("kafka.bootstrap.servers", "broker:9092")
    .option("subscribe", "nike-app-events")
    .option("startingOffsets", "latest")
    .option("maxOffsetsPerTrigger", 100000)  # Bound batch size for cost control
    .load()
    .select(
        from_json(col("value").cast("string"), event_schema).alias("data"),
        col("timestamp").alias("kafka_timestamp")
    )
    .select("data.*", "kafka_timestamp")
)

# Transform with watermark (handles late data)
transformed = (
    events_stream
    .withWatermark("event_time", "4 hours")  # Accept data up to 4 hours late
    .dropDuplicates(["event_id"])  # Stateful dedup
    .withColumn("event_date", to_date("event_time"))
)

# Write to Delta (exactly-once via checkpoint)
query = (
    transformed
    .writeStream
    .format("delta")
    .outputMode("append")
    .option("checkpointLocation", "s3://checkpoints/silver_events/")
    .partitionBy("event_date")
    .trigger(processingTime="2 minutes")
    .toTable("silver.events")
)
```

### Watermarks — The Deep Explanation

**Interviewer asks:** "Explain watermarks. Why do you need them?"

**Strong answer:**
"A watermark tells Spark: 'assume no event will arrive more than X late. After X, you can discard state for that time window.'

Without a watermark, stateful operations (dedup, windowed aggregation) keep state FOREVER — memory grows unbounded → OOM.

With `withWatermark('event_time', '4 hours')`:
- Spark tracks the max event_time it has seen (say, 14:00)
- The watermark line is: max_event_time - 4 hours = 10:00
- Any state for events before 10:00 is eligible for cleanup
- Any NEW event arriving with event_time < 10:00 is dropped (it's 'too late')

**The tradeoff:** longer watermark = more late data captured, but more memory used for state. Shorter = less memory, but more late data dropped.

I'd quantify: check the actual late-arrival distribution. If 99% of late data arrives within 2 hours, a 4-hour watermark gives me a 2-hour buffer with 99.9% coverage."

### Exactly-Once Semantics

**How it works in Databricks:**
1. **Checkpoint** stores: source offsets (which Kafka offsets processed), sink commits (which files written), operator state (dedup hashes, window state)
2. On failure + restart: reads checkpoint, resumes from last committed offset, reprocesses the incomplete micro-batch
3. **Delta sink** provides idempotent writes: even if the same micro-batch is written twice, Delta's transaction log deduplicates at commit level

**What breaks exactly-once:**
- Writing to a non-transactional sink (e.g., REST API, non-Delta file system)
- Deleting or corrupting the checkpoint
- Source that doesn't support replay (most file sources DO support replay, Kafka supports replay via offset reset)

---

## SECTION I: SCENARIO-BASED DATABRICKS QUESTIONS

### Scenario 1: "Your MERGE is taking 2 hours on a 500GB table. It used to take 20 minutes."

**Your answer:**

"There are 4 likely causes:

1. **Source batch grew:** If the staging data went from 10K rows to 10M rows, the MERGE has to probe more target files. Check source count.

2. **Z-ORDER degraded:** If new data has been written since the last OPTIMIZE, files are no longer well-ordered. The MERGE now reads most of the table instead of a few files. Run OPTIMIZE with Z-ORDER on the merge key.

3. **Target table bloated with small files:** Thousands of tiny files from frequent writes without OPTIMIZE. File listing alone takes minutes. Run OPTIMIZE to compact.

4. **Data skew on merge key:** If one key value dominates (e.g., 'unknown' customer_id), one task handles disproportionate work. Profile the merge key distribution.

**My fix sequence:** check source size → check `DESCRIBE DETAIL table` for file count → check Z-ORDER freshness → profile key distribution → run OPTIMIZE → rerun."

### Scenario 2: "You need to migrate from Hive tables to Delta. 50 tables, 10TB total. Plan?"

**Your answer:**

"I'd do this in waves, not big-bang.

**Week 1: Assessment**
- Catalog all 50 tables: size, format, partitioning, access patterns, downstream consumers
- Prioritize: start with leaf tables (no downstream dependencies), smallest first

**Week 2-3: Migration (batch of 10 tables at a time)**
```sql
-- For each table:
CREATE TABLE delta_catalog.schema.table_name
USING DELTA
PARTITIONED BY (date_col)
AS SELECT * FROM hive_catalog.schema.table_name;

-- Validate counts match
-- Set up Z-ORDER based on access patterns
OPTIMIZE delta_catalog.schema.table_name ZORDER BY (key_col);
```

**Week 3-4: Cutover**
- Point readers to Delta tables (views help: `CREATE VIEW old_name AS SELECT * FROM new_name`)
- Dual-write for 1 week (write to both Hive and Delta), compare
- Cut over writers, remove Hive tables

**Key considerations:**
- Partition alignment: some Hive tables might have non-ideal partitioning. This is a chance to fix it.
- Unity Catalog: register Delta tables in Unity Catalog during migration for governance.
- Testing: downstream notebooks/dashboards must be tested against Delta tables before full cutover.
- Rollback: keep Hive tables for 2 weeks post-migration as safety net."

### Scenario 3: "Streaming job's state is growing unbounded. Memory usage up 10% weekly."

**Your answer:**

"Unbounded state means either (a) no watermark is set, or (b) the watermark is too generous, or (c) there's a dedup/aggregation over a high-cardinality key that never expires.

**Diagnosis:**
1. Check streaming query metrics: `query.lastProgress` → `stateOperators` → `numRowsTotal`, `customMetrics`. If numRowsTotal is only growing, state is never being evicted.
2. Check if watermark exists: `df.withWatermark(...)` — if missing, state is kept forever.
3. Check the stateful operations: `dropDuplicates`, `groupBy`, `flatMapGroupsWithState` — each holds state per key.

**Root cause scenarios:**
- **Missing watermark:** Add it. `withWatermark('event_time', '4 hours')` → state older than 4 hours gets purged.
- **Dedup on high-cardinality key:** `dropDuplicates(['event_id'])` keeps every event_id forever (because it needs to know if a future duplicate arrives). With watermark, Spark purges event_ids older than the watermark.
- **State that never closes:** a `mapGroupsWithState` that doesn't define a timeout. Add `GroupStateTimeout.EventTimeTimeout` with a timeout duration.

**Immediate mitigation while fixing:** Increase driver/executor memory. But this is a band-aid — the fix is proper watermark + timeout configuration."
