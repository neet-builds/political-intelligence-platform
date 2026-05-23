# PART 8 — END-TO-END PIPELINE DESIGN WAR ROOM

## How Pipeline Design Gets Asked in Interviews

Amarendra will say something like:
- "Design a pipeline for [business scenario]. Walk me through it end-to-end."
- "How would you build a data platform for [use case] from scratch?"
- "You inherit a broken pipeline. Redesign it."

He's watching: **Can you think systemically? Do you consider failure? Do you ask the right questions? Do you make pragmatic tradeoffs?**

The WORST thing you can do: jump into technology choices without understanding requirements.
The BEST thing you can do: ask 3-4 clarifying questions, then walk through a structured design.

---

## THE UNIVERSAL DESIGN FRAMEWORK (Memorize This)

Every pipeline design answer should follow this skeleton in ~15-20 minutes:

```
1. CLARIFY (2 min)        → Ask 3-5 questions about volume, latency, consumers, constraints
2. HIGH-LEVEL ARCH (2 min) → Source → Ingest → Bronze → Silver → Gold → Consumer
3. DEEP DIVE EACH LAYER (8 min) → Technology choices with justification
4. FAILURE MODES (3 min)   → What breaks, how you detect, how you recover
5. OBSERVABILITY (2 min)   → Metrics, alerts, SLAs
6. SCALABILITY (2 min)     → What happens at 10x, 100x volume
```

---

## DESIGN EXERCISE 1: Nike App Clickstream → Product Recommendations

### The Prompt:

> "Nike's mobile app generates clickstream events (views, searches, add-to-cart, purchases). Design a pipeline that processes these events and builds a daily user-product affinity table that the recommendation engine can query via API. ~500M events/day, growing 20% quarterly."


### Step 1: CLARIFY (say these out loud)

"Before I design, let me understand:
1. **Latency:** Does the recommendation engine need real-time affinity (last-click personalization) or is daily batch sufficient? → Assume daily batch for v1, with a path to near-real-time.
2. **Consumers:** Is the API serving the affinity table directly (low-latency key-value lookup) or going through an ML model first? → Assume API reads the affinity scores directly.
3. **Data shape:** What events do we have? Views, searches, add-to-cart, purchases, time-on-page? → All of the above.
4. **Scale:** 500M events/day = ~6K events/sec average, with likely 3-5x peaks during promotions. Event size ~500 bytes = ~250GB/day raw.
5. **Retention:** How much history feeds the affinity model? 30 days? 90 days? → Assume 90-day rolling window."

### Step 2: HIGH-LEVEL ARCHITECTURE

```
Nike App → Kafka/Kinesis → Auto Loader → Bronze (Delta)
                                              ↓
                                         Silver (Delta) ← cleaned, deduped, sessionized
                                              ↓
                                         Gold: user_product_affinity (Delta)
                                              ↓
                                         Serving Layer (Redis/DynamoDB) ← API reads from here
```

### Step 3: LAYER-BY-LAYER DEEP DIVE

**SOURCE → INGESTION:**
- App SDKs emit events to Kafka (or Kinesis on AWS)
- Topics partitioned by `user_id` hash (ensures ordering per user)
- Retention: 7 days on Kafka (replay buffer for failures)
- Schema: Avro/Protobuf with schema registry (prevents uncontrolled drift)

"I'd use Kafka over direct-to-S3 because: (a) decouples producers from consumers, (b) multiple consumers can subscribe (ML team, analytics team), (c) replay capability for reprocessing, (d) natural backpressure handling."

**BRONZE LAYER:**
```python
# Auto Loader (Structured Streaming from Kafka to Delta)
bronze = (
    spark.readStream
    .format("kafka")
    .option("subscribe", "nike-app-events")
    .option("kafka.bootstrap.servers", brokers)
    .option("maxOffsetsPerTrigger", 500000)  # Bound micro-batch size
    .load()
    .select(
        col("key").cast("string").alias("event_key"),
        from_json(col("value").cast("string"), event_schema).alias("data"),
        col("timestamp").alias("kafka_timestamp"),
        col("partition").alias("kafka_partition"),
        col("offset").alias("kafka_offset")
    )
    .select("data.*", "kafka_timestamp", "kafka_partition", "kafka_offset")
)

# Write to Bronze Delta
(bronze.writeStream
    .format("delta")
    .option("checkpointLocation", "s3://checkpoints/bronze_events/")
    .partitionBy("event_date")  # Derived from event_time
    .trigger(processingTime="2 minutes")  # Near real-time
    .toTable("bronze.app_events")
)
```

Design decisions:
- **Partition by event_date:** 500M events/day ÷ ~500 bytes = ~250GB/day. One partition per day = ~250GB = reasonable.
- **Keep Kafka metadata:** offset + partition for debugging and replay tracking.
- **trigger(processingTime='2 min'):** processes micro-batches every 2 min. Balances latency vs cost.
- **No transformation at bronze:** raw is raw. If the source sends garbage, I want to see it.

**SILVER LAYER:**
```python
# Batch job (daily, processing last 2 days for late arrivals)
raw_events = spark.read.format("delta").table("bronze.app_events").filter(
    col("event_date") >= date_sub(current_date(), 2)
)

# Dedup: same event_id within 24 hours = duplicate (app retry)
dedup_window = Window.partitionBy("event_id").orderBy(col("event_time").desc())
deduped = (
    raw_events
    .withColumn("rn", row_number().over(dedup_window))
    .filter(col("rn") == 1)
    .drop("rn")
)

# Clean & validate
silver = (
    deduped
    .filter(col("user_id").isNotNull())  # Can't compute affinity without user_id
    .filter(col("event_type").isin(["view", "search", "add_to_cart", "purchase"]))
    .withColumn("event_time", to_timestamp("event_time"))
    .withColumn("product_id", trim(upper(col("product_id"))))  # Normalize
)

# MERGE into silver (idempotent)
DeltaTable.forName(spark, "silver.app_events").alias("t").merge(
    silver.alias("s"), "t.event_id = s.event_id"
).whenMatchedUpdateAll(
    condition="s.event_time > t.event_time"  # Update only if newer
).whenNotMatchedInsertAll().execute()
```

**GOLD LAYER — The Affinity Table:**
```python
# Compute user-product affinity scores (90-day rolling)
events_90d = spark.read.format("delta").table("silver.app_events").filter(
    col("event_date") >= date_sub(current_date(), 90)
)

# Weight by event type and recency
WEIGHTS = {"view": 1, "search": 2, "add_to_cart": 5, "purchase": 10}

affinity = (
    events_90d
    .withColumn("event_weight", 
        when(col("event_type") == "view", 1)
        .when(col("event_type") == "search", 2)
        .when(col("event_type") == "add_to_cart", 5)
        .when(col("event_type") == "purchase", 10)
    )
    # Recency decay: events today = 1.0x, 90 days ago = 0.1x (linear decay)
    .withColumn("days_ago", datediff(current_date(), col("event_date")))
    .withColumn("recency_factor", 1.0 - (col("days_ago") / 100.0))  # Linear decay
    .withColumn("weighted_score", col("event_weight") * col("recency_factor"))
    # Aggregate per user-product
    .groupBy("user_id", "product_id")
    .agg(
        _sum("weighted_score").alias("affinity_score"),
        count("*").alias("interaction_count"),
        max("event_date").alias("last_interaction"),
        collect_set("event_type").alias("interaction_types")
    )
    # Normalize: rank within user (top products get score 1.0)
    .withColumn("user_max_score", max("affinity_score").over(Window.partitionBy("user_id")))
    .withColumn("normalized_score", col("affinity_score") / col("user_max_score"))
    # Keep top 200 products per user (API doesn't need 10K products)
    .withColumn("rank", row_number().over(
        Window.partitionBy("user_id").orderBy(col("affinity_score").desc())
    ))
    .filter(col("rank") <= 200)
)

# Write gold table (full overwrite daily — deterministic)
affinity.write.format("delta").mode("overwrite").saveAsTable("gold.user_product_affinity")
```

**SERVING LAYER:**
```
Gold Delta Table → Daily export job → Redis / DynamoDB
API reads: GET /recommendations/{user_id} → Redis lookup → top 50 products by affinity_score
```

"I'd export to Redis because: (a) single-digit millisecond reads, (b) key-value by user_id is perfect for `HGETALL`, (c) TTL handles stale user cleanup automatically. DynamoDB is the alternative if we need persistence and auto-scaling without managing Redis clusters."

### Step 4: FAILURE MODES

| Failure | Detection | Impact | Recovery |
|---------|-----------|--------|----------|
| Kafka consumer lag > 30 min | Consumer lag monitoring | Stale bronze | Auto-scale consumers or increase maxOffsetsPerTrigger |
| Bronze streaming job dies | Checkpoint + heartbeat alert | No new bronze data | Restart from checkpoint (exactly-once) |
| Silver merge fails (schema drift) | Job failure alert | Silver stale | Fix schema, restart. Bronze has all raw data. |
| Gold job OOM (90-day data grew) | Executor OOM in logs | Gold not refreshed | Increase cluster size or partition the computation by user_id range |
| Redis export fails | Redis health check + data freshness alert | API serves stale recommendations | Retry export. API reads from yesterday's data (degraded, not broken) |
| Duplicate events from app | Silver dedup catches it | None (handled by design) | N/A |
| Late-arriving events (>2 days) | Monitor bronze event_time vs ingest time | Missing from silver | Widen silver reprocessing window to 7 days (trade cost for completeness) |

### Step 5: OBSERVABILITY

```
Pipeline metrics to track:
1. Bronze: events/sec throughput, consumer lag, file count per partition
2. Silver: row count per day (should be ~stable), dedup rate, null rate on key fields
3. Gold: user count with affinity scores, avg products per user, computation time
4. Serving: Redis cache hit rate, p99 API latency, freshness (hours since last load)
5. End-to-end: event_time to API-available latency (SLA: < 24 hours for daily batch)

Alerting:
- Consumer lag > 30 min → PagerDuty
- Silver row count drops > 20% day-over-day → Slack warning
- Gold job takes > 2x normal duration → Slack warning
- Redis freshness > 36 hours → PagerDuty (API serving very stale data)
```

### Step 6: SCALABILITY (10x growth)

"At 5B events/day (10x):
1. **Bronze:** streaming scales horizontally. More Kafka partitions, more Spark executors. No architectural change.
2. **Silver:** MERGE on 5B events gets expensive. I'd partition the merge by user_id ranges (A-M, N-Z) and run in parallel. Or switch to a streaming silver (process events as they arrive, no daily merge).
3. **Gold:** 90-day window on 5B/day = 450B events to scan. At this scale, I'd pre-aggregate daily affinity deltas in silver (not raw events), then gold just sums the daily deltas. Reduces computation from 450B rows to 450 days × users.
4. **Serving:** Redis scales with more shards. Or move to a dedicated feature store (Feast, Tecton) that handles versioning and serving."

---

## DESIGN EXERCISE 2: Multi-Store Inventory Reconciliation

### The Prompt:

> "Nike has 200 retail stores plus an online warehouse. Each store sends inventory snapshots every 15 minutes. Design a pipeline that detects discrepancies between physical inventory counts and the system-of-record, generates alerts for significant mismatches, and produces daily reconciliation reports."

### Step 1: CLARIFY

"Key questions:
1. **Volume:** 200 stores × ~50K SKUs × 96 snapshots/day = ~960M records/day. Each record ~200 bytes = ~180GB/day.
2. **System of Record:** Where is the 'expected' inventory? An ERP system with real-time transactions? → Assume ERP publishes inventory_transactions (sales, returns, transfers, adjustments) as a CDC stream.
3. **Discrepancy threshold:** What's 'significant'? → Assume: any single SKU discrepancy > 5 units OR any discrepancy on high-value items (>$200).
4. **Alert latency:** How fast do we need to detect? → Near-real-time for high-value, daily batch for routine reporting.
5. **Output consumers:** Store managers (dashboard), loss prevention team (alerts), finance (daily report)."


### Step 2: Architecture

```
Store POS Systems → Kafka (inventory_snapshots) → Bronze (Delta)
ERP System → CDC Stream (Debezium) → Kafka (inventory_transactions) → Bronze (Delta)

Bronze inventory_snapshots + Bronze inventory_transactions
        ↓
Silver: physical_inventory (latest snapshot per store-SKU)
Silver: expected_inventory (computed from transactions)
        ↓
Gold: inventory_discrepancies (physical - expected, with severity)
        ↓
Alert Engine (real-time high-severity) + Dashboard (Looker/PowerBI) + Daily Report (email)
```

### Step 3: The Hard Parts (this is what Amarendra probes)

**Computing Expected Inventory:**
```sql
-- Expected inventory per store-SKU = opening balance + sum of transactions
-- Transactions: sales(-), returns(+), transfers(+/-), adjustments(+/-), receipts(+)

WITH daily_movements AS (
    SELECT
        store_id,
        product_id,
        SUM(CASE txn_type
            WHEN 'sale' THEN -quantity
            WHEN 'return' THEN +quantity
            WHEN 'receipt' THEN +quantity
            WHEN 'transfer_in' THEN +quantity
            WHEN 'transfer_out' THEN -quantity
            WHEN 'adjustment' THEN quantity  -- signed
        END) AS net_movement,
        txn_date
    FROM silver.inventory_transactions
    GROUP BY store_id, product_id, txn_date
),
running_inventory AS (
    SELECT
        store_id,
        product_id,
        txn_date,
        SUM(net_movement) OVER (
            PARTITION BY store_id, product_id
            ORDER BY txn_date
            ROWS UNBOUNDED PRECEDING
        ) + opening_balance AS expected_quantity
    FROM daily_movements
    JOIN dim_opening_balances USING (store_id, product_id)
)
SELECT * FROM running_inventory;
```

**Discrepancy Detection:**
```python
# Join physical (from snapshots) with expected (from transactions)
physical = spark.read.table("silver.physical_inventory")  # Latest snapshot per store-SKU
expected = spark.read.table("silver.expected_inventory")  # Computed from txns

discrepancies = (
    physical.alias("p")
    .join(expected.alias("e"), ["store_id", "product_id"], "full_outer")
    .withColumn("discrepancy", 
        coalesce(col("p.physical_qty"), lit(0)) - coalesce(col("e.expected_qty"), lit(0))
    )
    .withColumn("abs_discrepancy", abs(col("discrepancy")))
    .withColumn("severity",
        when(
            (col("abs_discrepancy") > 5) | 
            ((col("abs_discrepancy") > 0) & (col("unit_price") > 200)),
            "HIGH"
        ).when(col("abs_discrepancy") > 2, "MEDIUM")
        .when(col("abs_discrepancy") > 0, "LOW")
        .otherwise("NONE")
    )
    .filter(col("severity") != "NONE")
)
```

### Step 4: FAILURE MODES (unique to this scenario)

**Clock skew between stores:**
"Store A reports inventory at 14:03 but the transaction for a sale at 14:01 hasn't arrived yet. Physical shows 10, expected shows 11 (because the sale transaction is in-flight). Solution: add a **grace period** — only compare physical snapshots with transactions up to (snapshot_time - 5 minutes). This accounts for propagation delay."

**Store goes offline:**
"If a store stops sending snapshots, last known inventory goes stale. Detection: monitor `MAX(snapshot_time)` per store. If > 30 minutes stale, alert ops. Don't generate false discrepancy alerts — mark as 'stale data, no reconciliation possible.'"

**Transaction replay (ERP resends):**
"If ERP resends transactions on recovery, we'd double-count movements. Solution: idempotency on `transaction_id` — dedup in silver. Same as the app event dedup pattern."

### Follow-Up Probes Amarendra Would Ask:

**Probe:** "What if a store consistently shows discrepancies on the same products?"

**Answer:** "That's a pattern detection problem. I'd add a gold layer that tracks discrepancy TRENDS: per store-product, rolling 7-day average discrepancy. If it's consistently > 2 units, flag for loss prevention review (potential theft, damaged goods not recorded, or systematic POS error). This is a simple `AVG() OVER (PARTITION BY store_id, product_id ORDER BY recon_date ROWS 6 PRECEDING)` on the discrepancy table."

**Probe:** "How do you handle the initial opening balance? What if it's wrong?"

**Answer:** "Opening balance error compounds — every subsequent expected quantity is wrong. I'd periodically 'reset' using a physical count (annual inventory audit). When a manual adjustment comes through the ERP, that's effectively a reset point. The system should allow 'set absolute quantity' transactions that reset the running total."

---

## DESIGN EXERCISE 3: Real-Time Fraud Detection Pipeline

### The Prompt:

> "Nike's e-commerce platform processes payments. Design a pipeline that scores transactions for fraud in real-time (< 2 seconds from payment initiation to score), can block suspicious transactions, and learns from confirmed fraud/non-fraud over time."

### Step 1: CLARIFY

"1. **Latency requirement:** < 2 seconds end-to-end means the scoring must be synchronous in the payment flow, not async.
2. **Volume:** ~10K transactions/sec peak (during launches), ~2K avg.
3. **Blocking:** Can we reject transactions in real-time, or only flag for review? → Assume: high-confidence fraud gets auto-blocked, medium goes to review queue.
4. **Features:** What signals are available? → User history, device info, shipping address, payment method, velocity (how many txns in last hour), geolocation mismatch.
5. **ML model:** Is there an existing model, or am I building the feature pipeline? → Assume: ML team maintains the model. I build the feature pipeline and serving infrastructure."

### Step 2: Architecture (Real-Time is Different)

```
Payment Service → Kafka (payment_events) → Feature Computation (Flink/Structured Streaming)
                                                    ↓
                                           Feature Store (online: Redis)
                                                    ↓
Payment Service → [Sync API call] → Scoring Service → reads features from Redis
                                         ↓               → calls ML model
                                    score + decision → back to Payment Service

Feedback Loop:
Confirmed fraud/non-fraud → Kafka → Training Pipeline (batch, daily) → Model retrain → Deploy
```

### Step 3: Why This Design

**Sync vs Async scoring:**
"The <2s requirement means scoring MUST be in the payment request path. The payment service calls the scoring service synchronously. The scoring service must have pre-computed features available (can't query a data lake in real-time)."

**Feature computation (two paths):**
1. **Real-time features:** velocity (txns in last 1h/24h per user), session behavior (pages viewed), device change — computed via Structured Streaming, stored in Redis with TTL.
2. **Batch features:** user lifetime value, historical fraud rate, address history — computed daily in Spark, stored in feature store.

```python
# Real-time feature computation (Structured Streaming)
txn_stream = (
    spark.readStream.format("kafka")
    .option("subscribe", "payment_events")
    .load()
    .select(from_json(col("value").cast("string"), txn_schema).alias("t"))
    .select("t.*")
)

# Velocity features: count transactions per user in sliding windows
velocity_features = (
    txn_stream
    .withWatermark("txn_time", "10 minutes")
    .groupBy(
        col("user_id"),
        window("txn_time", "1 hour", "5 minutes")  # 1-hour sliding window, 5-min slide
    )
    .agg(
        count("*").alias("txn_count_1h"),
        sum("amount").alias("total_amount_1h"),
        countDistinct("payment_method_id").alias("unique_methods_1h"),
        countDistinct("shipping_address_hash").alias("unique_addresses_1h")
    )
)

# Write to Redis (online feature store)
(velocity_features.writeStream
    .foreachBatch(write_features_to_redis)
    .trigger(processingTime="30 seconds")
    .start()
)
```

**Why Redis for serving:**
"Scoring service needs features in < 50ms (out of 2s budget). Redis gives single-digit ms lookups by user_id. Structure: `HASH user:{user_id} txn_count_1h 15 total_amount_1h 2500.00 ...`"

### Step 4: THE HARD PARTS

**Cold-start problem:**
"New user with no history — all features are zero/null. The model needs to handle this gracefully. Feature pipeline outputs defaults: `txn_count_1h = 0, is_new_user = true`. Model should weigh device/IP signals more heavily for new users."

**Feature freshness:**
"If the streaming job lags (consumer lag), features in Redis are stale. The scoring service checks feature timestamp. If features are > 5 minutes stale, it falls back to a conservative model (higher suspicion threshold) or uses only real-time request features (device, IP, amount)."

**Model deployment without downtime:**
"Blue-green deployment of the ML model. Two model versions running. Traffic gradually shifts from old to new (canary). If new model increases false positives beyond threshold, auto-rollback."

### Follow-Up Probes:

**Probe:** "How do you handle the feedback loop? How does the system learn?"

**Answer:** "Two feedback signals: (a) chargebacks arrive 30-90 days later (confirmed fraud), (b) manual review decisions (human labels fraudulent/legitimate). These feed into a labeling pipeline: `gold.labeled_transactions` with `(txn_id, label, label_source, label_time)`. The ML team retrains weekly on this labeled data. My responsibility: ensure the labeled data is joined with the features-at-scoring-time (point-in-time correct features, not current features — otherwise it's data leakage)."

**Probe:** "What's data leakage in this context and how do you prevent it?"

**Answer:** "Data leakage = training the model on features computed AFTER the transaction happened. Example: if I use 'user was blocked yesterday' as a feature when scoring today's transaction — but that feature wasn't available at scoring time yesterday. Prevention: I snapshot features at scoring time (log them alongside the score) and use THOSE for training, not re-computed features. This is called a 'feature log' or 'training dataset join' pattern."

---

## DESIGN EXERCISE 4: CDC-Based Data Warehouse Sync

### The Prompt:

> "Nike's order management system (OMS) is on PostgreSQL. We need to replicate it to the data warehouse (Databricks/Delta Lake) in near-real-time for analytics. 50 tables, 500M rows in the largest table (order_items), 10K transactions/sec peak on the source DB. Design this."

### Step 1: CLARIFY

"1. **Latency:** 'Near-real-time' = minutes, not seconds? → Assume: 5-minute freshness SLA.
2. **Initial load:** Are tables already empty in DW, or do I need a full historical backfill? → Need full initial load + ongoing CDC.
3. **Schema changes:** How often? → Monthly releases may add columns.
4. **Soft deletes:** Does the source use soft deletes (is_deleted flag) or hard deletes? → Mix. Some tables hard-delete.
5. **Access patterns:** What queries run against the DW tables? → Join-heavy analytics across orders, customers, products."

### Step 2: Architecture

```
PostgreSQL → Debezium (CDC connector) → Kafka → Structured Streaming → Bronze (Delta, raw CDC events)
                                                                              ↓
                                                                         Silver (Delta, materialized tables)
                                                                              ↓
                                                                         Gold (analytics-ready)
```

### Step 3: Why Debezium + Kafka (Not Direct Queries)

"I would NOT query the production database directly because:
1. **Load isolation:** analytical queries compete with production OLTP workload. CDC extracts changes with minimal source impact (reads WAL/binlog).
2. **Real-time:** polling-based extraction has inherent latency. WAL-based CDC captures changes as they happen.
3. **Delete capture:** `SELECT *` can't detect hard deletes. CDC captures DELETE events from the WAL.
4. **Ordering guarantee:** Kafka preserves per-key ordering, so I can replay changes in the correct sequence."

### Step 3b: The CDC Event Structure

```json
// Debezium CDC event for an UPDATE
{
  "before": {"order_id": 123, "status": "pending", "amount": 99.99},
  "after": {"order_id": 123, "status": "shipped", "amount": 99.99},
  "op": "u",  // c=create, u=update, d=delete, r=read(snapshot)
  "ts_ms": 1718400000000,
  "source": {"table": "orders", "lsn": "0/1234ABC"}
}
```

### Step 3c: Bronze Layer (Raw CDC)

```python
# Stream CDC events from Kafka to Bronze (one table per source table)
for table_name in SOURCE_TABLES:
    (spark.readStream
        .format("kafka")
        .option("subscribe", f"dbserver1.public.{table_name}")
        .load()
        .select(
            from_json(col("value").cast("string"), cdc_schema).alias("cdc"),
            col("timestamp").alias("kafka_ts")
        )
        .select(
            col("cdc.op").alias("operation"),
            col("cdc.before").alias("before_state"),
            col("cdc.after").alias("after_state"),
            col("cdc.ts_ms").alias("source_ts_ms"),
            col("kafka_ts"),
            lit(table_name).alias("source_table")
        )
        .writeStream
        .format("delta")
        .option("checkpointLocation", f"s3://checkpoints/cdc_bronze/{table_name}/")
        .trigger(processingTime="1 minute")
        .toTable(f"bronze.cdc_{table_name}")
    )
```

### Step 3d: Silver Layer (Materialized Current State)

```python
# For each table: apply CDC events to materialize current state
def materialize_table(table_name: str, primary_key: str):
    """Apply CDC events to produce current-state table in silver."""
    
    # Read new CDC events since last run
    cdc_events = (
        spark.read.table(f"bronze.cdc_{table_name}")
        .filter(col("source_ts_ms") > get_last_processed_ts(table_name))
    )
    
    # Dedup: if multiple changes to same PK in one batch, keep latest
    latest_per_key = (
        cdc_events
        .withColumn("rn", row_number().over(
            Window.partitionBy(primary_key).orderBy(col("source_ts_ms").desc())
        ))
        .filter(col("rn") == 1)
        .drop("rn")
    )
    
    # Apply to silver via MERGE
    silver = DeltaTable.forName(spark, f"silver.{table_name}")
    
    silver.alias("t").merge(
        latest_per_key.alias("s"),
        f"t.{primary_key} = s.after_state.{primary_key}"
    ).whenMatchedUpdate(
        condition="s.operation = 'u'",
        set={"*": "s.after_state.*", "_cdc_ts": "s.source_ts_ms"}
    ).whenMatchedDelete(
        condition="s.operation = 'd'"
    ).whenNotMatchedInsert(
        condition="s.operation IN ('c', 'r')",
        values={"*": "s.after_state.*", "_cdc_ts": "s.source_ts_ms"}
    ).execute()
    
    update_last_processed_ts(table_name, max_ts)
```

### Step 4: FAILURE MODES

**Debezium connector dies:**
"Kafka Connect monitors connector health. If it dies, events accumulate in PG's WAL (won't be truncated until consumer catches up). PG WAL disk usage alert at 80% → restart connector. On restart, Debezium resumes from its stored LSN (log sequence number) — no data loss."

**Out-of-order CDC events:**
"Kafka guarantees per-partition ordering. If I partition by primary key, events for the same row are always in order. If I partition by table, events for DIFFERENT rows might interleave, but that's fine — they're independent."

**Initial load + CDC overlap:**
"During initial snapshot, Debezium first dumps all existing rows (op='r'), then switches to streaming changes. During the overlap, a row might get snapshot'd AND then a CDC update arrives. The MERGE handles this naturally — the update overwrites the snapshot version."

---

## THE DESIGN ANTI-PATTERNS (What NOT to do)

### Anti-Pattern 1: "I'd just schedule a SELECT * query on the source DB every hour"

**Why it's bad:** Puts load on production DB, can't detect deletes, grows linearly with table size (even if nothing changed), creates consistency issues (mid-batch updates).

**What to say instead:** "CDC captures only changes, isolates source from analytical load, detects deletes, and scales with change velocity not table size."

### Anti-Pattern 2: "I'd use Lambda architecture — batch for accuracy, stream for speed"

**Why it's risky:** Two codepaths computing the same thing = maintenance nightmare, divergence bugs. Modern approach: **Kappa architecture** — one streaming pipeline with Delta/lakehouse handling both real-time and historical.

**What to say instead:** "I'd use a single pipeline with Structured Streaming writing to Delta. For batch analytics, I query the same Delta table at a point-in-time. One codebase, one truth."

### Anti-Pattern 3: "I'd put all 50 tables in one big pipeline"

**Why it's bad:** One table's failure blocks all 50. One table's schema drift crashes everything. No independent retry.

**What to say instead:** "Each source table gets its own independent streaming job with its own checkpoint. They can fail/retry independently. Shared infrastructure (Kafka, cluster pools), independent execution."

### Anti-Pattern 4: "Let me handle all edge cases in the design"

**Why it's bad in interviews:** You'll spend 30 minutes on one layer and never finish. The interviewer wants to see you IDENTIFY edge cases, not solve them all.

**What to say instead:** "Here are the edge cases I'd address in implementation: [list 3-4]. For now, let me continue with the full design and we can deep-dive any of these."
