# PART 13 — FINAL REVISION HANDBOOK

## How to Use This Document

This is your **final revision handbook**. Not a study guide — a structured recall doc.

**Read it once Sunday/Monday. Re-read your weakest 3 sections Tuesday morning.**

Each section answers four questions:
1. What's the concept (crisp summary)
2. What is Amarendra evaluating
3. What gets probed (and how to crush the probes)
4. Where candidates fail vs how strong candidates answer

The last two sections give you:
- **Behavioral STAR answers** for 10 likely questions
- **Project deep-dive answers** based on your GCP/DBT/BigQuery background

---

## INDEX

1. SQL
2. Spark Fundamentals
3. Spark Optimizations
4. PySpark Transformations
5. Databricks
6. Delta Lake
7. Streaming & Checkpointing
8. End-to-End Data Pipelines
9. Python for Data Engineering
10. Debugging & Analytical Thinking
11. System Design / Architecture
12. Communication & Interview Strategy
13. **Behavioral Questions (10 with STAR)**
14. **Project Deep-Dive Questions**

---


## SECTION 1: SQL

### Key Concepts
- **Window functions** — ROW_NUMBER (unique), RANK (gaps on ties), DENSE_RANK (no gaps); LAG/LEAD; OVER (PARTITION BY x ORDER BY y); ROWS = physical rows, RANGE = logical/date intervals
- **Joins** — INNER, LEFT, FULL OUTER, ANTI (NOT EXISTS), SEMI (EXISTS); self-joins for sequences
- **Aggregations** — GROUP BY collapses, window preserves rows; HAVING filters groups, WHERE filters rows; conditional aggregation `SUM(CASE WHEN ... THEN ... END)`
- **CTEs** — Readability; some engines materialize (BigQuery), some inline (Postgres)
- **Dedup** — ROW_NUMBER + filter rn=1 with explicit tiebreaker
- **Date logic** — DATE_TRUNC, INTERVAL arithmetic; **never** wrap partition columns in functions (kills pruning)
- **SCD Type 2** — Hash tracked columns, expire old (`valid_to`, `is_current=FALSE`), insert new with `valid_from`

### What Interviewers Evaluate
- Do you clarify before coding (units vs revenue, fiscal vs calendar)
- Do you handle edge cases (NULLs, ties, gaps)
- Do you think about scale (5B rows behavior)
- Can you narrate while writing

### Common Probes & Comebacks
- **"Why DENSE_RANK over ROW_NUMBER?"** → Ties: ROW_NUMBER picks one arbitrarily, DENSE_RANK shows both. Use case-driven.
- **"What if natural key has NULLs?"** → PARTITION BY treats NULLs as same group. Filter or `COALESCE(key, 'UNKNOWN')` first.
- **"Will UNION dedup hurt at scale?"** → UNION sorts entire combined set. UNION ALL is essentially free. Default to UNION ALL.
- **"How would you optimize this on 5B rows?"** → Partition pruning, predicate pushdown, no functions on partition cols, materialize gold tables, AQE skew handling.
- **"What about NOT IN with NULLs?"** → Returns ZERO rows if subquery has any NULL. Use `LEFT JOIN ... WHERE ... IS NULL` or `NOT EXISTS`.


### Candidate Mistakes
1. Diving into code before clarifying scope
2. `EXTRACT(YEAR FROM date) = 2024` — kills partition pruning. Use range: `date >= '2024-01-01' AND date < '2025-01-01'`
3. UNION when UNION ALL is correct
4. No tiebreaker in dedup → non-deterministic results
5. Forgetting `NULLIF(denom, 0)` for division — silent failures or errors

### Weak vs Strong Answer
- ❌ "I'd use ROW_NUMBER OVER PARTITION BY user_id ORDER BY event_time DESC and filter rn=1."
- ✅ "First — what defines 'duplicate' here? Same (user_id, event_id) exact match, or within a time window? Assuming the former, ROW_NUMBER OVER (PARTITION BY user_id, event_id ORDER BY event_time DESC, source_priority) — adding source_priority as tiebreaker for determinism. Filter rn=1. At Nike scale, I'd Z-ORDER the silver table on the merge key first to make subsequent reads fast."

### Tradeoffs & Production
- **DISTINCT vs ROW_NUMBER dedup** — DISTINCT loses ability to pick "best" version
- **Materializing gold tables** — Faster reads but staleness; daily vs near-real-time depends on consumer SLA
- **Approximate aggregation** — `APPROX_COUNT_DISTINCT` 10× faster on billions, ~2% error; ALWAYS ask if exact required

---

## SECTION 2: SPARK FUNDAMENTALS

### Key Concepts
- **Driver vs Executor** — Driver plans/coordinates/broadcasts; executors compute partitions, hold cached data, shuffle
- **Lazy evaluation** — Transformations build DAG; only actions trigger execution
- **Narrow vs Wide** — Narrow = partition-local (filter, select, withColumn); Wide = shuffle (join, groupBy, distinct)
- **DAG → Stages → Tasks** — Stage boundary at shuffles; task = one partition × one stage
- **Shuffle** — Serialize → local disk → network → deserialize. THE primary cost
- **Catalyst** — Predicate pushdown, column pruning, join reordering. Cannot fix skew or know your data
- **AQE (3.2+)** — Runtime: coalesce small partitions, switch join strategy, handle skew
- **Tungsten** — Off-heap, codegen, columnar — under the hood

### What Interviewers Evaluate
- Do you understand what Spark is DOING, not just syntax
- Can you reason about slowness without running it
- Do you know where costs actually live (shuffle, not "more nodes")


### Common Probes & Comebacks
- **"Why is shuffle expensive?"** → Network + serialization + local disk. Linear in data size, often dominates wall time.
- **"How does Spark choose join strategy?"** → Catalyst checks `autoBroadcastJoinThreshold` (10MB default). Below = broadcast hash. Above = sort-merge. AQE may switch at runtime based on actual size.
- **"Stage vs task?"** → Stage = sequence of narrow transformations between shuffles. Task = unit of work for ONE partition within a stage. Tasks per stage = partitions.
- **"Why lazy evaluation?"** → Lets Catalyst optimize the WHOLE pipeline before execution — push filters down, prune columns, reorder joins.
- **"Driver OOM — causes?"** → `collect()`, `toPandas()`, broadcasting too-large table, too many tasks. Fix: avoid collect, raise driver memory, lower autoBroadcastJoinThreshold.

### Candidate Mistakes
1. Confusing partitions with files (decoupled — runtime vs storage)
2. Treating "more cluster" as the universal fix
3. Ignoring AQE — manually tuning shuffle partitions when AQE handles it
4. Not catching `collect()` accidentally added during debugging

### Weak vs Strong
- ❌ "Spark is faster because it's in-memory."
- ✅ "Spark is faster than MapReduce because Catalyst optimizes the full DAG before execution, narrow transformations chain in-memory without intermediate writes, and shuffle only happens at wide-transformation boundaries. The 'in-memory' framing is partially true but misleading — Spark spills to disk all the time when partitions don't fit."

### Tradeoffs
- **More partitions** = more parallelism but more task overhead
- **Fewer partitions** = lower overhead but stragglers from skew
- **Broadcast join** = no shuffle but driver memory pressure
- **Sort-merge** = predictable but two big shuffles

---


## SECTION 3: SPARK OPTIMIZATIONS

### Key Concepts
- **Broadcast join** — `broadcast(small_df)`; default threshold 10MB, raise to 100-500MB on healthy clusters
- **Salting** — Random suffix on heavy key, replicate other side N×; trade dim replication for parallelism
- **Repartition vs coalesce** — Repartition = shuffle, even sizes, bidirectional. Coalesce = no shuffle, only shrinks
- **AQE skew handling** — `spark.sql.adaptive.skewJoin.enabled=true`; auto-splits skewed partitions
- **Cache** — `df.cache()` for reused DataFrames; ALWAYS `.unpersist()` when done
- **Photon** — Vectorized C++ engine; aggregation/join wins; higher DBU rate but lower wall time = often net cheaper
- **File size target** — 128MB-1GB per Parquet/Delta file; OPTIMIZE compacts
- **Z-ORDER / Liquid Clustering** — Co-locate by access columns for file pruning
- **Cost hierarchy** — Shuffle > disk spill > full scan > Python UDF serialization > sort > broadcast > narrow

### What Interviewers Evaluate
- Do you diagnose before prescribing
- Do you know the cost hierarchy
- Can you read Spark UI

### Common Probes & Comebacks
- **"Job suddenly 5× slower — debug it"** → Data change, not code change. Check: input size spike, new skew, broadcast threshold crossing, small-file accumulation.
- **"How do you decide partition count?"** → Target 128-256MB per partition. Total shuffle / 200MB. With AQE on, set high (~5000) and let coalesce merge.
- **"When does broadcast hurt?"** → Driver OOM if "small" table grows; fixed broadcast survives schema/data changes badly. AQE runtime decision is safer.
- **"Skew — how do you fix it?"** → Detect: one task 10× longer in Spark UI. Fix order: AQE → null-key filter → broadcast small side → salt heavy key → isolate hot key.
- **"Repartition or coalesce before write?"** → Coalesce if shrinking and uneven sizes OK. Repartition if balanced files needed OR `partitionBy` column.
- **"Why not just cache everything?"** → Cache eats memory needed for shuffles → causes spill → slows everything. Cache only if reused 2+ times AND fits.

### Candidate Mistakes
1. Defaulting to "increase memory" without finding root cause
2. Manual `repartition` tuning when AQE handles it
3. Caching too aggressively — fills memory, causes spills
4. Forgetting `.unpersist()`


### Weak vs Strong
- ❌ "I'd repartition to 200 partitions and increase memory to 16GB."
- ✅ "First I'd open Spark UI to find the longest stage. If one task is 10× longer than others, that's skew — I'd enable AQE skew handling or salt the key. If all tasks are slow, it's volume — I'd check shuffle write size and look for unnecessary wide transformations. I'd avoid blindly bumping memory; usually the fix is reducing data, not adding compute."

### Tradeoffs
- **Salting cost** = N× replication of other side; severe skew justifies it
- **Z-ORDER cost** = OPTIMIZE rewrites files; nightly maintenance window
- **Photon cost** = Higher DBU rate offset by faster runtime; net cheaper for aggregation-heavy

---

## SECTION 4: PYSPARK TRANSFORMATIONS

### Key Concepts
- **Transformations** — `select`, `withColumn`, `filter`, `groupBy`, `join`, `union`, `distinct`, `repartition`, `coalesce`
- **Actions** — `count`, `collect`, `show`, `write`, `toPandas` (driver pulls)
- **Window** — `from pyspark.sql.window import Window`; `Window.partitionBy(...).orderBy(...)`
- **UDF performance** — Native > pandas_udf (Arrow vectorized) > row-at-a-time UDF (slow). Avoid Python UDFs unless necessary
- **MERGE pattern** — `DeltaTable.forPath(spark, path).alias("t").merge(updates.alias("s"), "t.id = s.id").whenMatchedUpdateAll().whenNotMatchedInsertAll().execute()`
- **Streaming pattern** — `readStream`, `withWatermark`, `writeStream` with checkpoint location

### What Interviewers Evaluate
- Can you write idiomatic PySpark
- Do you know which patterns trigger shuffles
- Do you understand the JVM ↔ Python boundary cost

### Common Probes & Comebacks
- **"What does collect() do and when is it dangerous?"** → Pulls all rows to driver. Dangerous when result set is large — driver OOM. Use `take(n)` or write to storage and read summary.
- **"Pandas UDF vs row UDF?"** → Pandas UDF batches rows via Arrow, ~10-100× faster. Row UDF serializes per-row across JVM ↔ Python. Native Spark functions stay in JVM — fastest of all.
- **"How do you write idempotent merges?"** → MERGE with natural key; `WHEN MATCHED AND s.updated_at > t.updated_at THEN UPDATE` ensures re-running doesn't double-apply.
- **"Why is `df.count()` slow?"** → Triggers full DAG execution. If df has expensive transformations upstream, count is as expensive as the full pipeline.
- **"Difference between persist() and cache()?"** → `cache()` = `persist(MEMORY_AND_DISK)`. `persist()` lets you specify storage level (e.g., `MEMORY_AND_DISK_SER` for serialized = less memory, more CPU).


### Candidate Mistakes
1. Using row-level Python UDFs when native functions exist
2. Calling `collect()` to "check" intermediate results — triggers full DAG and risks OOM
3. Chaining `count()` calls — each one runs the full DAG
4. Not understanding that `withColumn` adds a project, not a side effect

### Weak vs Strong
- ❌ "I'd write a UDF to clean the email."
- ✅ "Native first: `lower(trim(col('email')))`. If logic is too complex for native, pandas_udf with Arrow batching. Row UDF only as last resort — the JVM ↔ Python serialization cost dominates at scale."

### Tradeoffs
- **`withColumn` chains** — Each one adds a project; many of them slow plan generation. Sometimes a single `select(*)` is cleaner
- **Multiple aggregations** — Combine into one `agg(...)` call; multiple `collect()` calls = multiple full DAG runs

---

## SECTION 5: DATABRICKS

### Key Concepts
- **Cluster types** — Job cluster (ephemeral, cheap, prod), All-purpose (interactive, expensive), SQL Warehouse (BI, auto-scale)
- **Workflows** — Native orchestration; tasks with dependencies, retries, alerting
- **Unity Catalog** — Governance layer; table/column ACLs, automated lineage, cross-workspace metastore
- **Auto Loader** — Incremental file ingestion with checkpoint, schema evolution, rescue column
- **DLT (Delta Live Tables)** — Declarative pipelines with `EXPECT` constraints; auto-managed
- **Photon** — Vectorized C++ engine; enable for aggregation-heavy workloads
- **DBU** — Databricks Unit; pricing differs by workload type (jobs cheaper than all-purpose)

### What Interviewers Evaluate
- Even without hands-on, do you reason about Databricks correctly
- Can you bridge from your GCP/DBT experience
- Do you understand cost levers

### Common Probes & Comebacks
- **"Job cluster vs all-purpose?"** → Job = ephemeral, terminates after run, ~50% cheaper DBUs. All-purpose = interactive, expensive. Production rule: jobs use job clusters always.
- **"How do you cut Databricks cost?"** → (1) Auto-terminate all-purpose at 15min, (2) Move prod to job clusters, (3) Spot workers for fault-tolerant batch, (4) Photon for aggregation, (5) OPTIMIZE for small file problem, (6) Right-size based on actual utilization.


- **"DLT vs custom Spark?"** → DLT for declarative pipelines with quality gates and auto-managed compute. Custom for complex control flow, fine-grained config, integration with non-Databricks systems. Bridge: DLT is to Databricks what DBT is to BigQuery.
- **"Workflows vs Airflow?"** → Workflows for pure-Databricks DAGs, native integration. Airflow for cross-system orchestration (S3 → Databricks → Snowflake → BI tool refresh).
- **"How does Unity Catalog change governance?"** → Single metastore across workspaces, table/column ACLs, automated lineage, masking. Replaces ad-hoc IAM.
- **"How do you handle dev/staging/prod?"** → Three Unity Catalog catalogs. Service principal for prod. Asset Bundles for deployment.

### Candidate Mistakes
1. Claiming heavy Databricks experience when you don't have it (gets probed mercilessly)
2. Confusing DBU pricing with VM pricing — both are charged
3. Not knowing that all-purpose clusters left running are the #1 cost driver

### Weak vs Strong
- ❌ "I haven't used Databricks much."
- ✅ "I have limited hands-on Databricks but the conceptual model maps directly from my GCP + DBT work. BigQuery's distributed compute is what Databricks gives me with Spark and Delta on object storage. DBT's incremental models + tests map to DLT or to MERGE patterns in Spark SQL. Unity Catalog is what Data Catalog + IAM give me on GCP. I'd be ramping up on Databricks-specific operational nuances — cluster sizing, Photon decisions, Workflows orchestration — but the core concepts are familiar."

### Tradeoffs
- **DLT vs raw notebooks** — DLT auto-manages but constrains; raw gives flexibility at maintenance cost
- **Photon on or off** — Higher DBU rate; net cheaper for aggregation, neutral or worse for shuffle-light jobs
- **Serverless SQL Warehouse** — Auto-scales to zero; per-query minimum charge can hurt for ad-hoc workloads

---


## SECTION 6: DELTA LAKE

### Key Concepts
- **What it is** — Parquet + transaction log (`_delta_log/` JSON commits, periodic Parquet checkpoints)
- **What it gives** — ACID, time travel, MERGE, schema enforcement on object storage
- **MERGE** — Copy-on-write; rewrites entire files containing changed rows. Z-ORDER on merge key massively reduces files touched
- **Time travel** — `VERSION AS OF n` or `TIMESTAMP AS OF`. Limited by VACUUM retention (default 7 days)
- **OPTIMIZE** — Compacts small files; with `ZORDER BY (col)` co-locates data
- **VACUUM** — Cleans removed files; default 7-day retention. Don't go shorter or you break time travel
- **CDF (Change Data Feed)** — When enabled, tracks row-level changes; query with `table_changes()`
- **Liquid Clustering** — Replaces partition + Z-ORDER; incremental, evolving access patterns

### What Interviewers Evaluate
- Do you understand WHY Delta exists (ACID on object storage)
- Can you reason about MERGE performance
- Do you know operational maintenance (OPTIMIZE, VACUUM)

### Common Probes & Comebacks
- **"Why Delta over Parquet?"** → Parquet alone has no concurrent-safe writes, no upserts, no schema enforcement, no time travel. Delta adds ACID via the transaction log on top. For any production write workload, Delta wins.
- **"What's in `_delta_log/`?"** → Numbered JSON commit files (add/remove file actions, schema, txn IDs); periodic Parquet checkpoints every 10 commits. Reading the table = replay log to find current files.
- **"How does MERGE actually work?"** → File-level: identifies files that MIGHT contain matches via min/max stats, reads only those files, writes new files for changed rows, marks old files removed. Z-ORDER on merge key dramatically reduces files touched.
- **"What happens if VACUUM deletes files time travel needs?"** → Time travel to versions referencing those files fails. Set `delta.deletedFileRetentionDuration = '30 days'` on critical tables.
- **"When would you NOT use Delta?"** → Truly immutable append-only data with no read latency requirement (e.g., logs landing in raw zone). For everything in silver/gold, Delta is default.
- **"How do you handle concurrent merges?"** → Delta optimistic concurrency: one wins, other gets `ConcurrentModificationException`. Either lock externally OR design merges to non-overlapping partitions OR rely on idempotency to retry.


### Candidate Mistakes
1. Saying "Delta is fast Parquet" — misses ACID
2. Forgetting that MERGE is copy-on-write — rewrites whole files
3. Aggressive VACUUM that breaks time travel
4. Not knowing about Z-ORDER for merge performance

### Weak vs Strong
- ❌ "Delta is faster Parquet."
- ✅ "Delta is Parquet plus a transaction log that gives me ACID, time travel, MERGE, and schema enforcement on object storage. Without Delta, concurrent writers on S3/ADLS produce data corruption — Delta's optimistic concurrency makes that safe. The transaction log is what makes everything else possible."

### Tradeoffs
- **OPTIMIZE frequency** — More frequent = better read perf, more compute spent on maintenance
- **Time travel retention** — Longer = more storage, better recovery; shorter = cheaper but risky
- **Z-ORDER columns** — More columns = each less effective; cap at 4

---

## SECTION 7: STREAMING & CHECKPOINTING

### Key Concepts
- **Structured Streaming** — Micro-batch with exactly-once via checkpoints; Continuous mode is experimental
- **Watermark** — `withWatermark("event_time", "10 minutes")`; bounds state; data later than watermark is dropped
- **Checkpoint** — Stores Kafka offsets + state + commit metadata; recovery from last good
- **Trigger modes** — `processingTime("30s")` continuous, `availableNow=True` batch-like (process all then stop), default = micro-batch ASAP
- **Output modes** — append (only new), complete (full result), update (changed rows)
- **State management** — `mapGroupsWithState` / `flatMapGroupsWithState` for custom stateful logic; always set timeout

### What Interviewers Evaluate
- Do you understand exactly-once semantics
- Can you reason about state size and growth
- Do you know recovery from checkpoint corruption


### Common Probes & Comebacks
- **"Why watermark?"** → Without it, stateful operations (dedup, windowed aggregation) keep state forever → memory grows unbounded → OOM. Watermark tells Spark to evict state for events older than `max_event_time - watermark`.
- **"Exactly-once — how?"** → Checkpoint stores Kafka offsets + sink commits. On restart, resumes from last committed offset. Sink (Delta) is idempotent — duplicate write detected via commit version.
- **"Checkpoint corrupted — what now?"** → Worst case. Delete checkpoint, restart with `startingOffsets="earliest"` (or known good offset), accept duplicates, dedup downstream via Delta MERGE on natural key. Reprocess up to Kafka retention horizon.
- **"State growing unbounded — diagnose"** → (1) No watermark set, (2) watermark too generous, (3) stateful op on high-cardinality key without timeout. Check `query.lastProgress.stateOperators.numRowsTotal`.
- **"What's the cost of `availableNow=True`?"** → Cluster spins up, processes all available, terminates. Cheaper than continuous streaming. Use for batch-style hourly jobs that don't need sub-minute latency.
- **"When does streaming fall behind?"** → `processedRowsPerSecond < inputRowsPerSecond`. Scale executors, increase `maxOffsetsPerTrigger`, or check for skew.

### Candidate Mistakes
1. Forgetting watermark on stateful operations
2. Putting checkpoint on same volume as data (different lifecycles)
3. Not testing recovery from checkpoint loss
4. Treating exactly-once as automatic — sink must be idempotent

### Weak vs Strong
- ❌ "Streaming gives exactly-once automatically."
- ✅ "Exactly-once requires three things: replayable source (Kafka has offsets), checkpointed offsets in Spark, and idempotent sink (Delta via commit log). Lose any one and you get at-least-once at best. I always pair streaming with Delta sinks for that reason."

### Tradeoffs
- **Watermark length** — Longer = more late data captured, more state. Shorter = less memory, more drops
- **Checkpoint frequency** — More frequent = less reprocessing on failure but more S3 writes
- **Continuous vs availableNow** — Continuous = sub-second latency at always-on cost; availableNow = minutes latency at job-cluster cost


---

## SECTION 8: END-TO-END DATA PIPELINES

### Key Concepts
- **Medallion** — Bronze (raw, append-only), Silver (cleaned, deduped, conformed), Gold (business-aggregated)
- **Idempotency** — Re-running N times = same result; achieved via MERGE on natural key + watermark guard
- **Late data** — Batch: reprocess sliding window. Streaming: `withWatermark` + allowed lateness
- **Schema evolution** — Additive auto via `mergeSchema=true`; breaking gates via contract
- **Quality gates** — Row count assertions per layer, not-null on PKs, freshness checks, anomaly alerts
- **Backfill** — Separate code path; never mix backfill with regular incremental
- **Orchestration** — Workflows / Airflow / Composer; dependencies, retries, alerting

### What Interviewers Evaluate
- Can you design end-to-end without missing key concerns (failure, observability, cost)
- Do you ask clarifying questions before designing
- Do you anticipate scale and operational reality

### The Universal Design Framework (Memorize)
1. **Clarify** (2 min) — volume, latency, consumers, constraints
2. **High-level arch** (2 min) — Source → Ingest → Bronze → Silver → Gold → Consumer
3. **Layer deep dive** (8 min) — tech choice + justification per layer
4. **Failure modes** (3 min) — what breaks, how detected, how recovered
5. **Observability** (2 min) — metrics, alerts, SLAs
6. **Scalability** (2 min) — what happens at 10×

### Common Probes & Comebacks
- **"Walk me through a pipeline you built"** → STAR. 90 seconds. Quantify. End with what you'd do differently.
- **"How do you ensure idempotency?"** → Three layers: (1) input dedup on natural key + timestamp, (2) deterministic transformations (no `current_timestamp()` baked in), (3) output via MERGE not INSERT. Track `batch_id` in metadata table.
- **"How do you handle schema drift?"** → Three categories: additive (auto via mergeSchema), type widening (Delta supports in newer versions), breaking (versioned table + contract change with downstream). Always alert on schema diff.
- **"Late-arriving data — strategy?"** → Quantify late distribution first (% arriving after 1d, 3d, 7d). Pick reprocessing window where cost-vs-completeness balances. Beyond window: separate backfill path.


- **"How do you backfill 30 days of data?"** → Time travel restore if Delta + recent. Else separate backfill job, idempotent, processes one day at a time, validates row counts post-each-day. Never block regular incremental on backfill.
- **"Pipeline succeeded but data is wrong — debug"** → Stabilize → row counts per layer → find lossy stage → identify root cause (timezone, schema drift, source change, join inflation) → fix + add quality gate.
- **"What's idempotent processing?"** → Same input + same code = same output, regardless of how many times run. Failures + retries don't corrupt state. Critical for Airflow/Workflows retries.

### Candidate Mistakes
1. Designing without asking clarifying questions
2. Forgetting failure modes and observability
3. Missing the late-data discussion
4. Not separating backfill from regular path

### Weak vs Strong
- ❌ "I'd use Airflow to orchestrate Spark jobs writing to Delta."
- ✅ "Before I design, let me clarify: latency requirement, data volume, consumer access pattern, compliance constraints. Assuming daily batch with BI consumption: Auto Loader → Bronze Delta → daily Silver MERGE with 7-day reprocessing window for late data → Gold aggregations refreshed via CDF from silver. Workflows for orchestration. Failure modes: schema drift (alert + manual review), source outage (backfill on recovery), merge concurrency (job concurrency=1)."

### Tradeoffs
- **Batch vs streaming** — Streaming = lower latency, higher cost, more complexity. Default to batch unless SLA requires real-time
- **Reprocessing window** — Wider = more late data captured but more compute every run
- **Quality gate strictness** — Strict = fewer downstream surprises but more pipeline failures from minor issues

---


## SECTION 9: PYTHON FOR DATA ENGINEERING

### Key Concepts
- **Idempotent ETL structure** — Config (dataclass), Extract class, Transform class (pure functions), Load class with delete-then-insert
- **Retry pattern** — `tenacity` library with exponential backoff; not custom retry loops
- **Logging** — Structured (level, timestamp, logger name); not `print()`
- **Generators** — `yield` for memory-efficient streaming over large files
- **Async / aiohttp** — For IO-bound work (API calls); not for CPU-bound
- **Type hints + dataclasses** — Documentation as code; testability
- **Context managers** — `with` for resource cleanup (DB, file, session)
- **Decorators** — Cross-cutting concerns (logging, retry, validation)

### What Interviewers Evaluate
- Do you write production Python or scripting Python
- Do you handle errors / retries / observability properly
- Do you know when to use async vs threading vs multiprocessing

### Common Probes & Comebacks
- **"How do you make ETL reusable?"** → Config-driven (YAML or dataclass). Separate Extract/Transform/Load classes. Pure functions for transforms (testable). Decorator for logging/retry. Schema-validated input.
- **"How do you handle API rate limits?"** → Token bucket rate limiter; respect `Retry-After` on 429s; safety margin (80% of limit); circuit breaker after N consecutive failures.
- **"Async vs threading vs multiprocessing?"** → Async for IO-bound (API calls, DB queries) at high concurrency. Threading for IO-bound when library doesn't support async. Multiprocessing for CPU-bound (parsing, hashing). For PySpark workloads, parallelism is already handled — don't add.
- **"How do you handle schema drift in Python?"** → Schema validator at ingest boundary. Three categories (additive, type-widening, breaking). Fail loud on breaking; alert and continue on additive.
- **"Memory-efficient processing of 50GB JSON?"** → Generator chain: `stream_jsonl()` yields records; `batch_records()` groups; process and write each batch. Constant memory regardless of file size.
- **"How do you test PySpark transformations?"** → Pure transform functions take and return DataFrames. Unit tests with small DataFrames in pytest. No Spark cluster needed for logic tests. Integration tests on staging with real data sample.


### Candidate Mistakes
1. `print()` instead of structured logging
2. Custom retry loops instead of `tenacity`
3. Loading entire files into memory when generators would work
4. Mixing extract/transform/load in one function — untestable
5. Not type-hinting — interviewers notice

### Weak vs Strong
- ❌ "I'd write a Python script that reads from API, transforms, and writes to BigQuery."
- ✅ "Production ETL has structure: a Config dataclass for parameters, an Extractor class with retry-decorated paginated fetches, a Transformer class with pure functions and validation, and a Loader class with idempotent writes (delete-then-insert by execution_date). Wrapped in a context manager for centralized error handling — different exception types map to different alert severities. Logging is structured. Tests are pytest with type-hinted interfaces."

### Tradeoffs
- **Async overhead** — Worth it for >100 concurrent IO ops; for <10, simpler synchronous is fine
- **Strict validation** — More confidence in downstream but more pipeline failures
- **Generators vs lists** — Generators win on memory but lose if you need random access

---

## SECTION 10: DEBUGGING & ANALYTICAL THINKING

### The Framework (Memorize)
1. **STABILIZE** — Acknowledge to stakeholder, set ETA. Restore service if possible.
2. **SCOPE** — What exactly is wrong? Since when? Blast radius?
3. **HYPOTHESIZE (top 3)** — Most likely causes given symptoms
4. **INVESTIGATE (cheapest first)** — Prove/disprove each
5. **ROOT CAUSE** — Why did this happen NOW?
6. **FIX + PREVENT** — Immediate fix + guard against recurrence

### What Interviewers Evaluate
- Do you have a methodology or thrash randomly
- Do you stabilize before investigating
- Do you go beyond "the job failed" to "why now"
- Do you end with prevention


### Common Debug Scenarios & Approach

**"Pipeline succeeded but data is wrong"**
→ Layer-by-layer row count comparison. Find the lossy stage. Common causes: timezone bug, source schema drift adding nulls, silent dedup over-aggression, join inflation. Fix + add row count alert.

**"Spark job 5× slower than yesterday"**
→ Data change, not code. Check input volume, key distribution, broadcast threshold crossings, small file accumulation. Open Spark UI: longest stage, longest task, shuffle size.

**"Streaming job state growing unbounded"**
→ Missing watermark, watermark too generous, or stateful op without timeout. Check `query.lastProgress.stateOperators.numRowsTotal`.

**"Duplicates after CDC retry"**
→ Source resends events on recovery. MERGE on natural key with `WHEN MATCHED AND s.updated_at > t.updated_at` handles this. If duplicates persist, dedup window logic is wrong (e.g., partition pruning excluding the existing row).

**"Cost spiked 3×"**
→ System.billing.usage; identify top jobs. Likely culprits: all-purpose cluster left running, retry storms, full-table scans (missing partition pruning), missing OPTIMIZE causing read amplification.

**"Late data showing up days late"**
→ Quantify the distribution. Update reprocessing window to cover legitimate cases. Beyond window: separate backfill flow + forensic table for very-late data.

### Candidate Mistakes
1. Jumping to a fix without scoping the problem
2. Not asking about blast radius
3. Stopping at "the job failed" instead of digging to root cause
4. Forgetting prevention step
5. Saying "I'd add more memory" without diagnosis

### Weak vs Strong
- ❌ "I'd check the logs and restart the job."
- ✅ "First — what's the impact? If users are blocked, I'd stabilize first (rollback via Delta time travel if it's a recent bad write). Then scope: what's wrong (data wrong vs job failed), since when, what's the blast radius. Then I'd hypothesize top 3 — for data wrong without job failure: silent filter dropping rows, schema drift, source change, or join inflation. Investigate cheapest first: layer-by-layer row counts. Once root cause is found, fix + add a quality gate so it can't recur silently."

---


## SECTION 11: SYSTEM DESIGN / ARCHITECTURE

### Key Concepts
- **Always clarify first** — volume, latency, consumers, compliance
- **Standard architecture** — Source → Ingest → Bronze → Silver → Gold → Consumer
- **Tech choices need justification** — Why Kafka not direct-to-S3, why batch not streaming, why Delta not Parquet
- **Failure modes upfront** — Don't bolt on; design with failure in mind
- **Observability per layer** — Row counts, freshness, quality assertions, cost
- **Cost as first-class concern** — Senior engineers don't ignore cost

### What Interviewers Evaluate
- Can you systematize ambiguous problems
- Do you make tradeoffs explicit
- Do you anticipate scale
- Can you justify every tech choice

### Common Probes
- **"Why X over Y?"** → Prepare to justify any choice. Don't have an answer? Say so and explain how you'd evaluate.
- **"What breaks at 10× scale?"** → Always something. Identify likely first failure point (usually merge step on silver, or driver memory on broadcast, or shuffle volume on aggregation). Have a mitigation.
- **"How do you ensure data quality across this pipeline?"** → Per-layer assertions. Not-null on PKs. Row count delta alerts. Anomaly detection on key metrics. Schema contracts at boundaries.
- **"What's the cost of this?"** → Quantify. Cluster sizing × runtime × DBU rate × frequency. Add storage. Compare to alternatives.
- **"How would you migrate from existing system to this?"** → Strangler pattern: dual-write to new system, validate, gradually cut readers over, decommission old.

### Candidate Mistakes
1. Diving into tech choices before clarifying requirements
2. Not addressing failure modes
3. Missing observability discussion entirely
4. Ignoring cost completely
5. Over-engineering — designing for problems you don't have

### Weak vs Strong
- ❌ "I'd use Kafka, Spark, Delta Lake, and Airflow."
- ✅ "Before tech, let me understand: 500M events/day means ~6K/sec average with 5× peaks. Daily batch is sufficient unless dashboard latency requires real-time — which one? If batch: Auto Loader → bronze → daily silver MERGE with 7-day reprocessing window → gold aggregations. Workflows for orchestration. Failure modes: source outage (backfill on recovery), schema drift (alert), volume spike (auto-scaling cluster). Cost: ~$X/month at this volume; here's how that scales at 10×."


### Tradeoffs to Articulate
- **Batch vs streaming** — Cost and complexity vs latency
- **Strict schema vs flexible** — Quality vs velocity
- **Centralized vs federated data** — Consistency vs team autonomy
- **Build vs buy** — Customization vs maintenance burden

---

## SECTION 12: COMMUNICATION & INTERVIEW STRATEGY

### The 5 Senior Reflexes
1. **Tradeoffs, not absolutes** — "It depends on..." is a senior phrase
2. **Always name failure modes** — For every design, what breaks
3. **Quantify** — "2B rows, 400GB Parquet, 1.5GB/partition," not "big table"
4. **Always mention observability** — Row counts, freshness, alerts
5. **Bridge from what you know** — "I haven't done X in Databricks but..."

### The Universal Answer Skeleton
```
1. Clarify     — "So you're asking about X in Y context, right?"
2. Short answer — "The default move is A."
3. Why          — "Because B and C."
4. When breaks  — "It falls apart when D, then I'd switch to E."
5. Production   — "I'd also care about F — observability/cost/recovery."
```

### Communication Don'ts
- Don't ramble; structured > comprehensive
- Don't say "I don't know" without a follow-up
- Don't bluff — gets caught fast under probing
- Don't use jargon you can't explain when challenged
- Don't badmouth previous employers


### What Amarendra Is Silently Grading
| Axis | Weak | Strong |
|---|---|---|
| Clarity | Rambles | Clarifies → structured answer |
| Depth | Stops at definitions | Goes to failure modes + tradeoffs |
| Production | "It works" | "It works, here's how it fails, how I monitor" |
| Quantification | "Big table" | "2B rows, 400GB, 1.5GB/partition" |
| Self-awareness | Bluffs | "I haven't done X, here's how I'd reason about Y" |
| Curiosity | Robotic | Asks clarifying questions, shows interest |

### Recovery Phrases When Stuck
1. "Let me think for a second on this..."
2. "To make sure I'm answering the right thing — are you asking about X or Y context?"
3. "I haven't done that exact thing, but here's how I'd reason about it from..."
4. "Let me walk through my approach systematically..."
5. "That's interesting — let me think about the tradeoffs..."

---

## SECTION 13: BEHAVIORAL QUESTIONS

For each: STAR answer + why strong + what's being evaluated.

---

### Q1: "Tell me about a challenging stakeholder situation you handled."

**Situation:** A product manager needed real-time member tier updates for a marketing campaign, but our existing pipeline was daily batch.

**Task:** I needed to deliver the latency requirement without rebuilding the entire pipeline.

**Action:** Instead of immediately saying "we need streaming" (3-month build), I dug into what they actually needed. The campaign personalized email subject lines based on tier — they didn't need true real-time, they needed within 30 minutes. I proposed a tiered solution: existing daily batch for non-urgent tier flags, plus a 15-minute scheduled job using `availableNow=True` that processed only tier-changed members from a CDF feed. Quantified the cost difference: $2K/month vs the $25K/month a streaming pipeline would have cost.


**Result:** PM accepted the proposal. Delivered in 2 weeks. Campaign launched on time. 12× cost savings vs the alternative.

**Why this answer is strong:** Shows you don't blindly accept requirements; you dig into the underlying need. Quantifies tradeoffs in dollars. Demonstrates engineering judgment over engineering enthusiasm.

**What's being evaluated:** Stakeholder management, ability to negotiate scope, cost-awareness.

---

### Q2: "Walk me through a production incident you handled."

**Situation:** Our analytics gold table started showing ~5% revenue undercount on a Monday morning. Pipeline hadn't failed — no alerts.

**Task:** Find root cause and restore data integrity before the 2pm executive review.

**Action:** First I stabilized: acknowledged to the analytics lead, set ETA. Pulled row counts per pipeline layer — bronze was correct, silver was 5% short. Profiled the silver job. Found the dedup logic used `updated_at` from source, but a source system patch had changed timezone handling, pushing some rows out of the dedup window. Time-traveled silver back to Friday's version, fixed the timezone normalization, backfilled the affected days. Added a row-count delta alert between bronze and silver.

**Result:** Reports were corrected by EOD. The new alert caught two similar issues in the next quarter. Mean time to detection on data quality issues went from days to hours.

**Why this answer is strong:** Specific, quantified, shows debugging instinct, mentions Delta time travel naturally, ends with a SYSTEMIC improvement (not just a fix).

**What's being evaluated:** Production maturity, debugging methodology, ability to prevent recurrence.

---


### Q3: "Tell me about a time you failed."

**Situation:** Early in my role, I was asked to build a campaign attribution pipeline. I was eager, and I jumped into building before understanding the business context.

**Task:** Deliver a working attribution model in 6 weeks.

**Action:** I built a sophisticated multi-touch attribution with weighted decay — technically impressive. When I showed it to the marketing team, they wanted simple last-click. I had over-engineered. We had to rebuild the simpler version, which delayed delivery by 2 weeks.

**Result:** Delivered eventually, but late. Bigger lesson: I now ALWAYS clarify what success looks like for the stakeholder before designing. I write a one-page design doc with the stakeholder before any code. Since then, I haven't had a "rebuild" situation.

**Why this answer is strong:** Real failure (not a humble-brag), shows learning, shows you've internalized the lesson with a concrete process change.

**What's being evaluated:** Self-awareness, ability to learn from failure, mature reflection.

---

### Q4: "Describe a time you disagreed with a teammate or technical decision."

**Situation:** My team lead proposed running all transformations as raw SQL scripts via cron jobs — no DBT, no orchestration tools, no testing framework.

**Task:** I believed this was wrong but I was junior and didn't have authority.

**Action:** Instead of arguing, I built a parallel proof-of-concept on the same data using DBT. Same SQL logic, but wrapped in `ref()` for lineage, with `not_null` and `unique` tests, and DBT's incremental models. Ran both pipelines for 2 weeks. The cron version failed 4 times with cryptic errors; the DBT version failed once and self-recovered with a clear error message. I presented the comparison: failure rate, debugging time per incident, lineage visibility.


**Result:** Lead adopted DBT. Pipeline reliability went from ~80% to 99% over the next quarter. Lead specifically thanked me for showing rather than telling.

**Why this answer is strong:** Disagreement handled productively. Show, don't tell. Quantified outcome. Preserves relationship with the lead.

**What's being evaluated:** Conflict resolution, technical influence without authority, data-driven argumentation.

---

### Q5: "Tell me about a time you had to take ownership beyond your role."

**Situation:** Our team's analytics dashboard had been broken for two weeks. Everyone said "it's the BI team's problem." But I noticed the issue traced back to a silent failure in our gold table's freshness.

**Task:** I wasn't formally responsible for downstream BI, but the data engineering chain was broken.

**Action:** I picked it up. Diagnosed: a Delta `OPTIMIZE` job was holding a write lock during the nightly merge window, causing the merge to silently retry past its SLA. I fixed the schedule (OPTIMIZE moved to a non-overlapping window), added a freshness alert on the gold table, and documented the incident in a runbook. Then I went to the BI team and walked them through what happened so they had context.

**Result:** Dashboard reliability returned. The freshness alert caught two similar issues later. The BI team started looping me in on cross-team incidents.

**Why this answer is strong:** Shows ownership without ego. Cross-team awareness. Ends with a process improvement and stronger relationships.

**What's being evaluated:** Initiative, ownership mindset, cross-team collaboration, systems thinking.

---


### Q6: "Tell me about debugging under pressure."

**Situation:** Right before a quarterly board meeting, the executive dashboard showed numbers that didn't match the finance team's reports. 90 minutes until the meeting.

**Task:** Identify the discrepancy and either fix it or explain it credibly.

**Action:** Skipped my usual deep diagnostic — went straight to reconciliation. Pulled both reports' totals, broke down by segment. Found the dashboard included a now-deprecated "Marketplace-Wholesale" channel that finance had removed from their reporting 2 months ago. The dashboard's filter logic still included it. I added the filter exclusion to the dashboard query, refreshed, validated against finance's number — matched within 0.01%.

**Result:** Dashboard fixed before the meeting. After the meeting, did a proper post-mortem: the channel taxonomy had changed but no one had updated downstream consumers. Built an alert: any new channel value triggers a notification to data engineering.

**Why this answer is strong:** Time-pressured pragmatism. Shows you can prioritize "fix it now" vs "do it right" appropriately. Follows up with a real systemic fix.

**What's being evaluated:** Performance under pressure, prioritization, post-incident discipline.

---

### Q7: "Tell me about handling ambiguity."

**Situation:** Leadership asked me to "improve our data quality." That was the entire ask.

**Task:** Translate vague directive into actionable, prioritized work.

**Action:** Spent the first week NOT building anything. Talked to 8 people: data engineers, analysts, product managers, the head of data. Asked each: "What's a recent data issue that hurt you?" Wrote up the issues, categorized them, and built a one-page proposal: 70% of pain came from three specific problems — schema drift breaking dashboards silently, late-arriving data showing as missing, and duplicate records from CDC retries. I proposed three concrete projects to address each.


**Result:** Leadership approved all three. Implemented over the next quarter. Quantifiable metric (data quality issues reported per week) dropped 60%.

**Why this answer is strong:** Shows you don't just execute on ambiguous asks — you scope them. Stakeholder interviews. Quantified problem definition. Quantified outcome.

**What's being evaluated:** Ability to scope ambiguous problems, stakeholder interviewing, prioritization.

---

### Q8: "Tell me about cross-team collaboration."

**Situation:** Our data engineering team needed to ingest data from a system owned by the application engineering team. They had no API; their position was "we'll build a CDC connector when we get to it."

**Task:** Get the data without waiting indefinitely.

**Action:** Instead of escalating, I proposed a partnership: I'd build the Debezium connector for their PostgreSQL setup, they'd review and own it. They got CDC capability they could reuse for other consumers; we got data immediately. Built it in 2 weeks, ran a 2-week shadow period, handed off ownership.

**Result:** Both teams won. The connector is now used by 3 other consumers. The app engineering lead and I started doing monthly syncs on cross-team data needs — preventing future blockers.

**Why this answer is strong:** Reframes a blocker as a partnership. Demonstrates you build relationships, not just technical solutions. Sustainable outcome (recurring sync).

**What's being evaluated:** Cross-functional influence, partnership mindset, long-term thinking.

---


### Q9: "Tell me about a prioritization conflict."

**Situation:** Two stakeholders both wanted my time the same week — marketing for a campaign analytics build, finance for a regulatory reporting fix. Both labeled "urgent."

**Task:** Decide who got my full attention.

**Action:** Asked each: "What's the consequence if this slips by 1 week?" Marketing: "Campaign launches with less precise targeting; revenue impact maybe ~$X." Finance: "Regulatory filing deadline; potential fines." Clear answer. Did finance's fix first. For marketing, proposed a partial approach — basic segmentation in 2 days that covered 80% of the use case, full version the following week.

**Result:** Finance fix delivered on time. Marketing accepted the partial approach; campaign performed well. Neither stakeholder felt deprioritized because I'd surfaced the tradeoff explicitly.

**Why this answer is strong:** Quantification, transparent tradeoff communication, partial-solution creativity.

**What's being evaluated:** Prioritization framework, stakeholder communication, ability to say no without burning bridges.

---

### Q10: "Tell me about mentoring or supporting a junior."

**Situation:** A new hire on the team was struggling with PySpark. They'd come from a pure SQL background and got overwhelmed by the mental model shift.

**Task:** Help them ramp without slowing my own work.

**Action:** Two things. First, paired with them for 2 hours a week for the first month — not solving their tickets, but watching them debug and asking guiding questions. Second, wrote a "GCP-to-Spark mental model" doc since I'd made that transition recently and remembered the gotchas. They could use it asynchronously.


**Result:** They ramped in ~6 weeks instead of the typical 3 months. The doc has been used by 3 subsequent hires. They've since told me the pairing approach is what made the difference — not the answers, but the questions I asked.

**Why this answer is strong:** Specific approach (paired debugging, async doc). Shows you understand teaching is about questions, not answers. Scaled impact (doc reused).

**What's being evaluated:** Mentorship, knowledge transfer, scalable contribution.

---

## SECTION 14: PROJECT DEEP-DIVE QUESTIONS

Based on your stack: SQL, Python, GCP (BigQuery, GCS, Cloud Functions, Cloud SQL, Apigee), DBT.

For each: likely follow-ups + strong answer + weak vs strong.

---

### Q1: "Walk me through the most complex DBT pipeline you've built."

**Strong opening (90 sec STAR):** "[Project name] for [business context]. ~30 DBT models across staging, intermediate, and marts. Sources: 3 transactional databases via Datastream, plus event data from Pub/Sub landing in BigQuery. The complexity was around incremental processing of late-arriving events — we had source systems that could send corrections up to 14 days late. Used DBT incremental models with `merge` strategy, partitioned by event_date, with a 14-day reprocessing window. Quality enforced via `not_null`, `unique`, and `accepted_values` tests. Pipeline runs hourly via Cloud Composer; full quality test suite passes before promoting silver to gold tables. Quantified: 2B events/day, runtime 35 min, cost ~$3K/month for transformations."

**Likely Follow-ups:**
- *"Why DBT over Spark?"* → BigQuery handled volume natively; DBT gave us SQL-first transformation with lineage and tests. Spark would have added operational complexity for no scale benefit at our volume. If we hit BigQuery's slot limits, that calculus might change.


- *"How did you handle late data?"* → 14-day reprocessing window in incremental models. `is_incremental()` filter looks back 14 days. MERGE re-applies correctly via `unique_key` and `merge_update_columns`. Beyond 14 days = manual backfill via `--full-refresh` on specific date range.
- *"What were your DBT tests?"* → `not_null` on PKs, `unique` on natural keys, `accepted_values` for enums (event_type, status), custom SQL tests for cross-table referential integrity, freshness tests on sources.
- *"How did you orchestrate?"* → Cloud Composer (managed Airflow). DAG: source freshness check → DBT run (staging → intermediate → marts) → DBT test → conditional promotion to gold. Failures alerted to Slack with dbt-specific context.

**Deeper probes:**
- *"What happens if a DBT test fails mid-run?"* → Configurable. We used `on-run-end` hooks and severity levels: `error` halts the run, `warn` continues but alerts. Critical PK tests = error. Anomaly detection on row counts = warn. Don't block production on every minor issue.
- *"How did you handle schema evolution?"* → DBT recompiles models when schema changes. For breaking changes (column drop, rename), used `materialization='incremental', on_schema_change='append_new_columns'` for additive, manual contract change for breaking.

**Weak vs Strong:**
- ❌ "I built DBT models that read from BigQuery."
- ✅ The 90-second answer above. Quantified, specific tradeoffs, articulated the late-data problem and how it was solved.

---

### Q2: "How did you handle Cloud Functions in your pipeline?"

**Strong answer:** "Cloud Functions served three roles. First, event-triggered ingestion: Pub/Sub messages from Apigee triggered a Cloud Function that wrote raw JSON to GCS landing zone with structured naming for downstream batch ingestion. Second, schema validation gates: when files landed in GCS, a Cloud Function validated against a registered schema and either moved to bronze or to a quarantine bucket with alerts. Third, lightweight API integrations — pulling from external SaaS APIs on a schedule via Cloud Scheduler triggers."


**Likely Follow-ups:**
- *"Why Cloud Functions over Cloud Run or a Spark job?"* → Cloud Functions for short-lived (<1 min), event-triggered, simple logic. Cloud Run for longer-running services with HTTP. Spark for transformations on data already in storage. Cloud Functions hit the sweet spot for ingestion glue: low cost when idle, scales to zero, fast cold starts for our use case.
- *"How did you handle Cloud Function failures?"* → Idempotent design: function is keyed on event_id from Pub/Sub. Re-delivery from Pub/Sub is safe — duplicate events overwrite the same GCS object. Dead-letter topic for messages that failed N retries; manual review queue.
- *"What's the cost of this approach?"* → Cloud Functions billed per invocation + duration. At our volume (~10M invocations/day), under $200/month. Spark cluster always-on for this would be 50× the cost.

**Deeper probes:**
- *"Limitations you hit?"* → 9-minute timeout per invocation. For longer work, broke into multiple functions chained via Pub/Sub. Memory cap (8GB at the time) limited single-event size — bigger payloads went to Cloud Run.
- *"How did you test Cloud Functions?"* → Unit tests on the handler function with mocked event input. Integration tests deployed to a dev project, sent test events through Pub/Sub, validated GCS outputs. CI/CD via Cloud Build.

**Bridge to Nike:** "On AWS this maps to Lambda + SNS/SQS or EventBridge. The mental model is identical: short, idempotent, event-triggered compute. The Nike JD mentions Lambda explicitly, and the patterns I've used translate directly."

---

### Q3: "How did Apigee fit into your data pipeline?"

**Strong answer:** "Apigee was our API gateway for both inbound (third parties calling our APIs) and outbound (our services calling external APIs). For data engineering specifically, three uses. First, inbound: event APIs that external partners called to send data — Apigee handled auth, rate limiting, and request/response logging, then forwarded to a Pub/Sub topic for ingestion. Second, outbound rate limiting: when we called external SaaS APIs (e.g., a marketing tool), Apigee enforced our quotas to prevent us from blowing through their rate limits. Third, audit logging: all API traffic went to a BigQuery sink for analytics on partner usage and our own service consumption."


**Likely Follow-ups:**
- *"Why Apigee specifically?"* → It was already in the org. For greenfield I'd evaluate: Kong, AWS API Gateway, custom. Apigee's strength is policy management and analytics — but it's expensive for high-volume use cases.
- *"How did you handle API schema versioning?"* → URL-based versioning (`/v1/events`, `/v2/events`) at the gateway. Apigee policy translated v1 requests to v2 schema for a deprecation period. This is API gateway 101 but worth showing you understand the lifecycle.
- *"How did you handle authentication?"* → API keys for partners (Apigee key management), OAuth 2.0 for first-party services. Apigee verified at the edge before forwarding.

**Deeper probes:**
- *"What were the limitations?"* → Apigee's analytics had ~minute-level lag for our volume; for true real-time we logged separately to Cloud Logging. Cost grew nonlinearly with traffic — we did a cost analysis at 10× scale and considered alternatives.
- *"How did this connect to your data lake?"* → Apigee → Pub/Sub → Cloud Function → GCS landing → DBT into BigQuery. Standard event-driven ingestion pattern.

**Bridge to Nike:** "API-first is in the JD. Apigee experience translates directly to AWS API Gateway or Kong. The patterns of policy enforcement, rate limiting, and audit logging are universal."

---

### Q4: "How did you ensure data quality across BigQuery + DBT?"

**Strong answer:** "Data quality at multiple layers. First, source freshness: DBT source tests verified that landing tables had recent data; failures alerted before downstream models ran. Second, schema validation: Cloud Functions at ingest validated against a registered JSON schema; bad records went to a quarantine table with alerts. Third, DBT tests at every model: `not_null` on PKs, `unique` on natural keys, `accepted_values` on enums, custom SQL for referential integrity. Fourth, anomaly detection on key business metrics: a separate DBT model that compared today's metric values against rolling averages and flagged 3-sigma deviations. Fifth, post-load reconciliation: row count parity between layers, alerting if delta > 5%."


**Likely Follow-ups:**
- *"How did you handle test failures?"* → Severity-driven. Critical (PK uniqueness, referential integrity) → halt the run. Warning (anomaly detection on volume) → continue with Slack alert. Documentation in the runbook on how to triage each.
- *"How did you balance test strictness vs pipeline reliability?"* → Started strict, observed false positive rate over 4 weeks, tuned thresholds. The goal was: every alert means a real action is needed. If 3 alerts in a row are false positives, the alert is broken.
- *"How did you communicate quality issues to stakeholders?"* → A quality dashboard in Looker showing test results per model, freshness per source, anomalies detected. Stakeholders could self-serve confidence checks before running their analyses.

**Deeper probes:**
- *"What's a quality issue you caught BEFORE it hit production?"* → A source schema change added a new event_type. Our `accepted_values` test failed in staging. Investigation showed the new event was legit; we updated the allowed list and added the new event to downstream aggregations. Without the test, would have silently skipped 8% of new event volume.
- *"What's a quality issue that slipped past your checks?"* → A timezone bug in a source system pushed event times by 8 hours. Tests didn't catch it because all the values were still "valid" event_times. Lesson: tests catch known-bad shapes, not unknown-unknowns. Added anomaly detection on event_time distribution as a result.

**Weak vs Strong:**
- ❌ "I added DBT tests."
- ✅ The five-layer answer above. Demonstrates you think of quality as a system, not a feature.

---


### Q5: "How did you optimize BigQuery costs?"

**Strong answer:** "Cost optimization in three areas. Storage: we used partitioned tables (by event_date) and clustered (by user_id, product_id) — reduced scan volumes 90%+ for typical queries. Long-term storage rates kicked in automatically for partitions >90 days untouched. Query: pushed filtering to the leftmost position; avoided `SELECT *` (column pruning); used `LIMIT` aggressively in dev. Reservations: moved from on-demand to flat-rate slot reservations once we hit predictable workload — saved ~40%. Plus DBT-specific: incremental models avoid full-table reads, materialized views for frequently-queried aggregations, and `dry_run` in CI to catch query cost regressions before deployment."

**Likely Follow-ups:**
- *"How did you know cost reductions worked?"* → BigQuery's `INFORMATION_SCHEMA.JOBS_BY_PROJECT` for per-query bytes scanned. Tracked monthly cost per project; established baselines, measured deltas after each optimization.
- *"What's the cost of clustering?"* → Slight write overhead, no read overhead. Effective when queries filter on cluster columns. Measured: typical analytics query went from 500GB scan to 20GB after clustering.
- *"Reserved slots vs on-demand — when do you choose?"* → On-demand if workload is bursty/unpredictable. Reservations when you have steady baseline. We hit ~70% utilization on reservations consistently — that's the sweet spot.

**Deeper probes:**
- *"What's a query optimization you're proud of?"* → A daily marketing attribution query that scanned 8TB → optimized to 200GB. Original used `EXTRACT(YEAR FROM date) = 2024` which killed partition pruning. Switched to range filter, added clustering on `customer_id`, result: 40× cheaper, 8× faster.
- *"What's a cost trap you hit?"* → A scheduled query without cost limits that joined two large tables; one developer changed a JOIN condition and the query went from $5/run to $500/run silently. Now we have alerts on per-query bytes-billed thresholds.

**Weak vs Strong:**
- ❌ "I added partitioning."
- ✅ The structured answer above. Demonstrates systematic thinking, measurement, and concrete wins.


---

### Q6: "Tell me about your incremental processing strategy."

**Strong answer:** "Incremental at three layers. Bronze: append-only, partitioned by ingestion date. Silver: incremental DBT models with `is_incremental()` macro, looking back 14 days for late data, MERGE on natural key. Gold: incremental aggregations using a surrogate timestamp on each row to compute deltas only. Backfill: separate code path that uses `--full-refresh` with date filters; never run as part of regular incremental.

The key idempotency primitive was a `last_processed_date` column on each silver row. Re-running for an already-processed date was a no-op via the merge condition. This made retries safe and let me handle late-arriving data cleanly."

**Likely Follow-ups:**
- *"What happens if a record updates AFTER your 14-day window?"* → Falls outside automatic reprocessing. Caught by a separate weekly reconciliation job that compares source vs silver counts; mismatches trigger backfill workflow with operator review.
- *"How did you avoid double-counting?"* → MERGE with `WHEN MATCHED AND s.updated_at > t.updated_at` ensured updates only when source was newer. For aggregations, used delta tables — each daily delta added/subtracted, never full recomputation.
- *"How did you handle deletes?"* → Source soft-deletes (boolean flag) flowed through normally. Source hard-deletes were detected via daily reconciliation: rows in silver but not in source = mark deleted. Slow but bounded.

**Deeper probes:**
- *"What if the source loses your watermark column?"* → Falls back to ingestion date as the watermark. Quality drops slightly (some legit late updates missed) but pipeline continues. Long-term fix: add the column back upstream or use Datastream-style CDC.
- *"How would you migrate from full-refresh to incremental?"* → Build incremental version in parallel. Run both for 2 weeks; reconcile counts. Cut over once parity confirmed. Keep full-refresh as a backstop for backfill.

**Weak vs Strong:**
- ❌ "I used DBT incremental models."
- ✅ The layered answer above. Show you understand the WHY behind each layer's strategy.


---

### Q7: "How did you monitor and alert on production pipelines?"

**Strong answer:** "Three layers of monitoring. First, infrastructure: Cloud Composer DAG run status, BigQuery slot utilization, Cloud Function error rates — all to Cloud Monitoring with PagerDuty for critical alerts. Second, data quality: DBT test results published to a `test_results` table, anomaly detection on row counts and key business metrics, Slack alerts for warnings and PagerDuty for errors. Third, business SLA: a freshness dashboard showing time-since-last-update per gold table, with explicit SLAs documented (e.g., 'daily revenue gold refreshed within 4 hours of midnight UTC'). Cost monitoring on BigQuery via daily reports + per-query alerting at $X threshold."

**Likely Follow-ups:**
- *"What's the alert fatigue trap?"* → Too many alerts → engineers ignore them → real issues missed. Tuned threshold and severity over 4 weeks. Goal: every alert means action needed. False positives = re-tune the alert.
- *"How do you handle alerts at 2am?"* → Critical only (data-blocking-business). Everything else waits for business hours. PagerDuty has business-hours-only and 24/7 routing rules.
- *"What's a metric you wish you'd monitored sooner?"* → Per-query bytes billed. We had project-level cost alerts but not per-query, and one bad query in a Looker dashboard ran our daily cost up 5× before we noticed. Added per-query threshold alerting after.

**Deeper probes:**
- *"How do you distinguish 'pipeline broken' from 'data legitimately weird'?"* → Anomaly detection compares to historical baseline. If today's metric is 3-sigma off, alert + manual review. Sometimes business legitimately did spike 5× (e.g., Black Friday) — runbook says "verify with marketing before assuming pipeline issue."
- *"What's your dashboarding philosophy?"* → One executive dashboard (high-level KPIs, freshness flags, alert summary). Per-team operational dashboards (DAG status, test results, cost). Don't duplicate; link.


**Weak vs Strong:**
- ❌ "I added Cloud Monitoring alerts."
- ✅ The layered answer above. Shows you understand monitoring as a system with severity tiers, alert tuning, and explicit SLAs.

---

## CLOSING: WALK-IN POSTURE

You're prepared. The volume of material you've covered is significant. Now the only thing standing between you and the offer is **execution under pressure**.

### Tuesday Morning Final Sequence (30 min)
1. Re-read Section 12 (Communication) — 5 min
2. Re-read Section 13 (Behavioral) — 10 min
3. Re-read Section 14 (Project Deep-Dive) — 10 min
4. Quiet 5 minutes. Don't cram. Confidence > knowledge today.

### The Mindset
- He's a peer, not a judge.
- Tradeoffs > certainty.
- Failure modes are your friend.
- Bridge from what you know — that's a strength.

### The Three Phrases to Have Ready
1. *"Let me clarify one thing first..."*
2. *"In my GCP/DBT work, I've solved the equivalent problem..."*
3. *"The tradeoff there is..."*

You've put in the work. Go close it.
