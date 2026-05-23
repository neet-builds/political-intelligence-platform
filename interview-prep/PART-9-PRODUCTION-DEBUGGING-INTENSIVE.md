# PART 9 — PRODUCTION DEBUGGING INTENSIVE

## Why Debugging Questions Dominate Modern DE Interviews

Amarendra has seen 100 candidates who can DESIGN a pipeline. He wants to know: **when it breaks at 2am, can you FIX it?**

Debugging questions test:
1. **Systematic thinking** — do you have a methodology, or do you thrash randomly?
2. **Production instinct** — do you stabilize first, investigate second?
3. **Root cause depth** — do you stop at "the job failed" or dig to "why NOW"?
4. **Communication** — can you explain your reasoning clearly under pressure?

---

## THE DEBUGGING FRAMEWORK (Use This Every Time)

```
1. STABILIZE (if impacting users)    → Can I restore service before investigating?
2. SCOPE                             → What exactly is wrong? Since when? What's the blast radius?
3. HYPOTHESIZE (top 3)               → Most likely causes given the symptoms
4. INVESTIGATE (cheapest check first) → Prove/disprove each hypothesis
5. ROOT CAUSE                        → Why did this happen NOW?
6. FIX + PREVENT                     → Fix the immediate issue + add guard for the future
```

Say this framework OUT LOUD when answering debugging questions. "Let me walk through my debugging process..." — this immediately signals senior thinking.

---

## SCENARIO 1: Pipeline Succeeded But Data Is Wrong

### The Setup:

> "Your daily pipeline that computes Nike store revenue completed successfully — no errors in logs. But the finance team says yesterday's total revenue is 30% lower than expected. It's Monday morning, they need accurate numbers for a board meeting at 2pm."


### Your Answer (structured walkthrough):

**STABILIZE:**
"First — is the board meeting consuming live data or a snapshot? If live dashboard, I can fix the data and it'll auto-refresh. If exported report, I need to regenerate it. Either way, I have until ~1pm to fix. I immediately acknowledge to finance: 'Investigating, ETA for resolution is 2 hours.'"

**SCOPE:**
"What exactly is wrong? Revenue is 30% low. Questions:
- Is it ALL stores or specific stores?
- Is it ALL product categories or specific ones?
- Is it a data completeness issue (missing rows) or a calculation issue (wrong numbers)?
- When did this start? Just yesterday, or has it been drifting?"

```sql
-- Quick diagnostic queries:

-- 1. Compare row counts: today vs last 7 days
SELECT event_date, COUNT(*) as txn_count, SUM(amount) as total_revenue
FROM gold.daily_store_revenue
WHERE event_date >= current_date - 7
GROUP BY event_date
ORDER BY event_date;

-- 2. Breakdown by store — which stores are low?
SELECT store_id, SUM(amount) as revenue,
    LAG(SUM(amount)) OVER (ORDER BY event_date) as prev_day_revenue
FROM gold.daily_store_revenue
WHERE event_date IN (current_date - 1, current_date - 2)
GROUP BY store_id, event_date
HAVING revenue < prev_day_revenue * 0.5;  -- Stores with >50% drop

-- 3. Check source layer — is bronze complete?
SELECT event_date, COUNT(*) as raw_count
FROM bronze.pos_transactions
WHERE event_date >= current_date - 3
GROUP BY event_date;
```

**HYPOTHESIZE (top 3 most likely):**

1. **Source data incomplete:** One or more stores didn't send data (POS system outage, network issue). Bronze would show fewer rows for yesterday.
2. **Filter bug in transformation:** A recent code change added or modified a filter that excludes valid transactions. Silver would show fewer rows than bronze.
3. **Join dropping rows:** A join in the pipeline changed from LEFT to INNER, or a dimension table is missing entries, causing transactions to fall out.

**INVESTIGATE (cheapest first):**

"I check bronze row count vs previous days. If bronze is low → source problem (not my pipeline's fault, but I need to flag it and re-ingest when source recovers).

If bronze is normal but silver/gold is low → my pipeline logic introduced the loss. I'd diff row counts at each layer:"

```sql
-- Layer-by-layer reconciliation
SELECT 'bronze' as layer, COUNT(*) FROM bronze.pos_transactions WHERE event_date = '2024-06-16'
UNION ALL
SELECT 'silver', COUNT(*) FROM silver.transactions WHERE event_date = '2024-06-16'
UNION ALL
SELECT 'gold', COUNT(*) FROM gold.daily_store_revenue WHERE event_date = '2024-06-16';
```

"If bronze=1M, silver=700K → 300K rows lost at the silver transformation. I'd check:
- Dedup logic: did it over-deduplicate? (common with timezone bugs causing same-day events to span two dates)
- NOT NULL filter: are we dropping rows where a new source started sending NULLs in a required field?
- Schema change: did source add a new `transaction_type` value that our CASE statement doesn't handle (falls to NULL, gets filtered)?"

**ROOT CAUSE (example resolution):**

"Found it: the POS system deployed a new software version Saturday night that changed the `payment_type` field from 'CREDIT_CARD' to 'CC'. Our silver layer has a CASE statement that maps payment types — the new value 'CC' falls through to NULL, and we have a `WHERE payment_type IS NOT NULL` filter downstream. 30% of transactions are credit card → 30% revenue loss. Bronze has all the data — it's the mapping that's broken."

**FIX + PREVENT:**

"Immediate fix:
1. Add 'CC' → 'CREDIT_CARD' mapping to the transform logic
2. Rerun silver + gold for yesterday
3. Verify revenue numbers match expected
4. Notify finance by 11am

Prevention:
1. Add a validation rule: if any unknown payment_type values appear in >1% of transactions, fail the pipeline (don't silently filter)
2. Add a row-count comparison between bronze and silver — alert if delta > 5%
3. Add to the data contract with the POS team: schema changes require 1-week notice"

### What Makes This Answer Strong:

- Stabilized first (acknowledged stakeholder, set ETA)
- Quantified the problem before hypothesizing
- Used cheap diagnostic queries before deep investigation
- Named 3 hypotheses in order of likelihood
- Found a root cause that's realistic and specific
- Fixed immediately AND added prevention

---

## SCENARIO 2: Spark Job Suddenly Running 10x Slower

### The Setup:

> "Your nightly Spark job that processes Nike's order data typically finishes in 45 minutes. Last night it ran for 7 hours and barely completed before the downstream dashboard SLA. No code changes were deployed. What happened?"

### Your Answer:

**SCOPE:**
"No code changes means the change is in the DATA or the ENVIRONMENT. Let me check both."

**HYPOTHESIS 1: Data volume spike**
```python
# Check input data size vs historical
spark.read.table("bronze.orders") \
    .filter(col("order_date") == "2024-06-16") \
    .count()
# Compare to: SELECT order_date, count(*) FROM bronze.orders GROUP BY 1 ORDER BY 1 DESC LIMIT 10
```
"If yesterday was a major sale (Nike Air Max Day, Black Friday), volume might have 5-10x'd. A job designed for 10M records might struggle with 100M."

**HYPOTHESIS 2: Data skew emerged**
"Even if total volume is normal, a new distribution pattern could cause skew. Example: a viral product gets 50% of all orders, concentrating data on one partition."
```python
# Check distribution of join key
spark.read.table("bronze.orders") \
    .filter(col("order_date") == "2024-06-16") \
    .groupBy("product_id").count() \
    .orderBy(col("count").desc()) \
    .show(20)
# If top product_id has 10x the count of the next → skew
```

**HYPOTHESIS 3: Small file explosion in source data**
"If upstream stopped running OPTIMIZE, or if a streaming job wrote thousands of tiny files, the file listing and read overhead kills performance."
```sql
DESCRIBE DETAIL bronze.orders;
-- Check: numFiles, sizeInBytes. If numFiles went from 500 to 50,000 → small file problem.
```

**HYPOTHESIS 4: Cluster resource contention**
"If another team's job was running on shared resources (same cluster pool, same S3 prefix), it could starve our job. Check Spark UI: were executors killed/preempted? Was shuffle write to disk (memory pressure from co-tenants)?"

**HYPOTHESIS 5: Broadcast threshold crossed**
"A dimension table that was 9MB (auto-broadcast) grew to 11MB (sort-merge join now). The join strategy silently changed without code changes."
```python
# Check dimension table sizes
for dim in ["dim_products", "dim_stores", "dim_customers"]:
    size = spark.read.table(dim).count()
    print(f"{dim}: {size} rows")
```

**INVESTIGATION PATH:**

"I'd open the Spark UI for last night's run and compare stage durations with a healthy run from the previous night.

1. Find the longest stage. Is it the same stage that was previously fast?
2. Within that stage: are all tasks similar duration (volume problem) or is one task 100x longer (skew)?
3. Check Shuffle Read/Write: massive increase suggests data volume or join strategy change.
4. Check Spill: any disk spill means partitions don't fit in memory anymore.

Most likely resolution for 'sudden, no code change': **either volume spike from a sale event, or small file accumulation that finally crossed a tipping point.** The fix: for volume → scale cluster or add AQE. For small files → run OPTIMIZE and schedule it nightly."

---

## SCENARIO 3: Incremental Pipeline Producing Duplicates

### The Setup:

> "Your incremental pipeline runs every hour, loading new transactions into a Delta table. Users report seeing duplicate transactions in reports. The pipeline uses MERGE on `transaction_id`. How is this possible?"

### Your Answer:

**SCOPE:**
"Duplicates despite MERGE means either: (a) the dedup logic has a gap, or (b) truly different records look like duplicates to the user but aren't to the pipeline."

**SYSTEMATIC INVESTIGATION:**

"Let me trace the duplicate path:

**Check 1: Are they actual duplicates (same transaction_id)?**
```sql
SELECT transaction_id, COUNT(*) as cnt
FROM silver.transactions
GROUP BY transaction_id
HAVING cnt > 1
ORDER BY cnt DESC
LIMIT 20;
```
If this returns results → MERGE didn't dedup. Why?

**Check 2: Is the MERGE condition matching correctly?**

Possible bugs:
1. **Case sensitivity:** source sends 'TXN-001' and 'txn-001' — these are different strings. MERGE sees them as different keys.
2. **Leading/trailing whitespace:** 'TXN-001' vs 'TXN-001 ' — invisible but different.
3. **Source system generating different transaction_ids for the same logical transaction:** e.g., a retry creates a new UUID. The transaction is semantically the same but has a different ID.
4. **Race condition:** two hourly runs overlap. Both read the same source records. First run MERGEs them in. Second run also has them (because it read source before first run committed). Second MERGE should be a no-op (WHEN MATCHED → no change), but if the match condition is wrong...

**Check 3: Is the source sending duplicates across batches?**
```sql
-- Check: same transaction_id appearing in multiple ingestion batches
SELECT transaction_id, COUNT(DISTINCT _batch_id) as batch_count
FROM bronze.transactions
GROUP BY transaction_id
HAVING batch_count > 1
LIMIT 20;
```
If yes → source has at-least-once delivery. My MERGE should handle this (matched → update). But if the `WHEN MATCHED` condition prevents the update (e.g., `AND s.updated_at > t.updated_at` and they're equal)... the existing row stays AND the new row doesn't match 'WHEN NOT MATCHED' either — so nothing happens. But wait — if the merge condition is wrong..."

**ROOT CAUSE SCENARIOS (pick the most likely):**

**Most common cause:** "The pipeline partitions by `event_date`. MERGE only targets partitions present in the source batch (`MERGE INTO target USING source ON target.txn_id = source.txn_id`). But if the source sends a transaction with `event_date = June 14` in the June 16 batch (late arrival), AND the merge only scans the June 16 partition of the target... it won't FIND the existing June 14 row → inserts as new → duplicate!"

**Fix:** "Either: (a) MERGE without partition filter (scans more data but correct), (b) Include `event_date` in the merge condition AND ensure late-arriving data targets the correct partition, or (c) Dedup the ENTIRE table periodically as a safety net:
```sql
-- Periodic dedup safety net (weekly)
MERGE INTO silver.transactions AS t
USING (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY transaction_id ORDER BY _ingested_at DESC) as rn
    FROM silver.transactions
) AS s
ON t.transaction_id = s.transaction_id AND s.rn > 1
WHEN MATCHED AND s.rn > 1 THEN DELETE;
```"

**PREVENT:**
"Add a uniqueness assertion that runs after every merge:
```python
dupe_count = spark.sql('''
    SELECT COUNT(*) - COUNT(DISTINCT transaction_id) as dupe_count
    FROM silver.transactions
    WHERE event_date >= current_date - 7
''').collect()[0]['dupe_count']

if dupe_count > 0:
    raise DataQualityError(f'{dupe_count} duplicates detected post-merge')
```"

---

## SCENARIO 4: Streaming Job Checkpoint Corruption

### The Setup:

> "Your Structured Streaming job that processes Kafka events into a silver Delta table stopped last night. When you restart it, it throws: `StreamingQueryException: Error reading checkpoint`. The checkpoint directory exists but seems corrupted. You have 12 hours of unprocessed data in Kafka (retention is 24 hours). How do you recover?"

### Your Answer:

**STABILIZE:**
"Clock is ticking — Kafka retention is 24 hours, and 12 hours have passed. I have 12 hours to recover before data is permanently lost. Priority: get data flowing again, even if imperfect."

**RECOVERY OPTIONS (ordered by speed):**

**Option 1: Start from a checkpoint backup (fastest — if it exists)**
"If I have periodic checkpoint backups (which I should): restore the latest good checkpoint, restart. The job resumes from that offset and reprocesses some data. Since my sink is idempotent (Delta MERGE or append with dedup), reprocessing is safe."

**Option 2: Start fresh from Kafka's earliest available offset**
```python
# Delete corrupted checkpoint
# dbutils.fs.rm(checkpoint_path, recurse=True)

# Restart with explicit starting offsets
query = (
    spark.readStream
    .format("kafka")
    .option("startingOffsets", "earliest")  # Read everything available in Kafka
    .option("subscribe", "events-topic")
    .load()
    # ... transforms ...
    .writeStream
    .format("delta")
    .option("checkpointLocation", new_checkpoint_path)  # NEW checkpoint location
    .trigger(availableNow=True)  # Process all available, then stop
    .start()
)
```
"This reprocesses ALL data in Kafka (24 hours). Potential duplicates for the 12 hours that were already processed before the crash. Since I'm writing to Delta with append mode, I'll have duplicates → I need a dedup step after."

**Option 3: Start from specific known-good offsets**
"If I logged the last committed offsets externally (e.g., in a metadata table), I can specify exact starting offsets:"
```python
.option("startingOffsets", json.dumps({
    "events-topic": {"0": 15234567, "1": 14523456, "2": 13987654}
}))
```

**POST-RECOVERY:**
"After the stream catches up:
1. Run a dedup job on the silver table for the affected time window
2. Validate row counts against Kafka topic lag (should be zero)
3. Set up the new checkpoint for ongoing streaming

**PREVENTION:**
1. Back up checkpoints every N commits to a separate S3 location
2. Monitor checkpoint size — growing unboundedly means state leak
3. Alert on streaming query failure within 5 minutes (don't wait 12 hours to notice)
4. Set `minPartitions` on Kafka source to balance partition assignment
5. Keep Kafka retention at 72 hours minimum for replay safety margin"

---

## SCENARIO 5: Data Freshness SLA Breach

### The Setup:

> "Your gold table has a freshness SLA of 6 hours (data should be no older than 6 hours from source event time). The monitoring system just fired: gold table's most recent data is 10 hours old. The pipeline appears to be running. What's happening?"

### Your Answer:

**SCOPE:**
"Pipeline is RUNNING but data isn't fresh. This is different from 'pipeline failed' — it's more subtle. Something in the chain is blocked or slow."

**CHECK EACH LAYER (upstream to downstream):**

```
Source → Kafka → Bronze (streaming) → Silver (batch every 2h) → Gold (batch after silver)
```

**Check 1: Is the SOURCE emitting events?**
```bash
# Check Kafka consumer lag and latest offsets
kafka-consumer-groups.sh --describe --group my-consumer-group
# If latest offset == committed offset for all partitions → no new data from source
# If latest offset >> committed offset → consumer is lagging (processing is slow)
```

**Check 2: Is Bronze streaming running?**
```python
# Check streaming query status
for query in spark.streams.active:
    print(query.name, query.lastProgress)
    # Look at: inputRowsPerSecond, processedRowsPerSecond, processedRowsPerSecond < inputRowsPerSecond = falling behind
```
"If `processedRowsPerSecond < inputRowsPerSecond` consistently, the streaming job can't keep up. It's processing data slower than it arrives → latency grows linearly."

**Check 3: Is Silver batch running on schedule?**
"Silver runs every 2 hours. Did the last run complete? Or did it start and get stuck (waiting for cluster resources, OOM, retry loop)?"
```python
# Check Databricks Workflows run history
# Is there a run in 'RUNNING' state for >4 hours? That's hung.
# Is there a run that failed and exhausted retries? Not rescheduled?
```

**Check 4: Is the issue a date boundary/timezone bug?**
"Classic: gold filters on `event_date = current_date()`. If the timezone is wrong (UTC vs IST for Nike India), current_date() might be 'tomorrow' relative to the data. The query returns zero rows for 'today' because today's data has yesterday's date in UTC."

**MOST LIKELY ROOT CAUSES (for 'running but stale'):**

1. **Silver batch job is hung** — waiting for cluster, deadlocked, or in a retry loop. FIX: kill and restart.
2. **Bronze streaming fell behind** — volume spike overwhelmed processing capacity. FIX: scale out executors.
3. **Source stopped emitting** — upstream system is down. FIX: escalate to source team, nothing I can do until they recover.
4. **Dependency deadlock** — silver job waits for a completed bronze run signal that never comes because the signaling mechanism broke.

**FIX PLAYBOOK:**
"Once I identify the blocked layer: restart/fix that specific job. Then:
- If bronze was behind: after catching up, trigger silver immediately (don't wait for next schedule)
- If silver was stuck: after fix, trigger gold immediately
- Goal: chain-trigger downstream jobs to clear the stale data ASAP
- Notify stakeholders with realistic ETA: 'Freshness will be restored in ~2 hours after silver catches up'"

---

## SCENARIO 6: Revenue Numbers Don't Match Between Systems

### The Setup:

> "The revenue number in the analytics dashboard shows $4.2M for yesterday, but the finance system shows $4.5M. Both claim to be correct. Find the discrepancy."

### Your Answer:

"This is my favorite type of debugging because it's never a bug — it's a DEFINITION mismatch. Let me investigate systematically."

**STEP 1: Define what each system counts as 'revenue'**

| Question | Analytics Dashboard | Finance System |
|----------|-------------------|----------------|
| What's included? | Completed orders | Invoiced transactions |
| When is it counted? | When order status = 'completed' | When payment is captured |
| Returns included? | Subtracted immediately | Subtracted at refund processing (30-day delay) |
| Taxes included? | Excluded (net revenue) | Included (gross revenue) |
| Currency conversion? | At time of order | At daily closing rate |
| B2B orders? | Excluded | Included |

"The $300K difference ($4.5M - $4.2M) is likely a combination of:
1. **Timing difference:** orders completed yesterday but payment captured today (or vice versa)
2. **Scope difference:** finance includes B2B wholesale orders, analytics only counts D2C
3. **Returns:** analytics subtracted yesterday's returns, finance hasn't processed them yet
4. **Taxes:** if finance reports gross and analytics reports net, the tax amount is the difference"

**STEP 2: Reconcile quantitatively**
```sql
-- Analytics system revenue breakdown
SELECT
    SUM(CASE WHEN channel = 'D2C' THEN net_amount ELSE 0 END) as analytics_d2c,
    SUM(CASE WHEN channel = 'B2B' THEN net_amount ELSE 0 END) as analytics_b2b,
    SUM(tax_amount) as total_tax,
    SUM(CASE WHEN order_status = 'returned' THEN net_amount ELSE 0 END) as returns_deducted
FROM gold.daily_revenue
WHERE revenue_date = '2024-06-16';
```

"If `analytics_d2c + analytics_b2b + total_tax - returns_deducted ≈ $4.5M` → the systems agree, they're just reporting different slices."

**STEP 3: Document the reconciliation**

"The real fix isn't technical — it's organizational. I'd create a `reconciliation` gold table that shows both numbers side-by-side with the explained differences. Finance and analytics should agree on a shared metric definition. This is the data governance conversation."

**Senior insight:** "In production, I've never seen two systems agree perfectly. The goal is: (a) understand WHY they differ, (b) ensure the difference is explainable and bounded, (c) have an automated reconciliation that alerts when the unexplained difference exceeds a threshold (e.g., >1%)."

---

## SCENARIO 7: Silent Schema Drift Causing Downstream Failures

### The Setup:

> "A downstream ML team reports that their feature pipeline broke this morning. They read from your silver table `silver.user_events`. You haven't made any changes. Their error: `AnalysisException: cannot resolve 'device_type' given input columns: [user_id, event_time, event_name, device_info]`"

### Your Answer:

**IMMEDIATE DIAGNOSIS:**
"The column `device_type` no longer exists in my table. It was probably renamed or restructured. Let me check what changed."

```sql
-- Check current schema
DESCRIBE TABLE silver.user_events;

-- Check schema history via Delta
DESCRIBE HISTORY silver.user_events LIMIT 20;
-- Look for 'SET TBLPROPERTIES', 'WRITE' with schema change, etc.
```

"Found it: version 157 (6 hours ago), the 'WRITE' operation had `userMetadata: mergeSchema=true`. The upstream source changed `device_type` (a string) to `device_info` (a struct containing `{type, os, browser, model}`). My pipeline has `mergeSchema=true` on the bronze-to-silver write, which auto-evolved the schema."

**ROOT CAUSE:**
"The upstream API team changed their event schema without notice. My pipeline auto-evolved because `mergeSchema=true` — it added `device_info` as a new column. But it DIDN'T remove `device_type` — old data still has it, new data only has `device_info`. The ML team's code references the old column name, which now only exists in historical data."

**WAIT — let me verify:**
```sql
-- Check if device_type exists in any form
SELECT device_type, device_info FROM silver.user_events LIMIT 10;
-- If device_type is NULL for new records → it's been deprecated upstream
```

**FIX (layered):**

1. **Immediate (unblock ML team):** Create a view that maps old to new:
```sql
CREATE OR REPLACE VIEW silver.user_events_v2 AS
SELECT *,
    COALESCE(device_type, device_info.type) AS device_type_compat
FROM silver.user_events;
```

2. **Short-term:** Add a backwards-compatible alias column:
```python
# In the silver transform, always output device_type for backward compat
.withColumn("device_type", coalesce(col("device_type"), col("device_info.type")))
```

3. **Long-term:** 
   - Turn OFF `mergeSchema=true` on silver writes. Schema changes should FAIL and alert, not silently evolve.
   - Implement a schema contract: upstream must register changes in a schema registry
   - Add a breaking-change detection step (like Part 7's SchemaEvolutionHandler) between bronze and silver
   - The ML team should pin to a specific table version or use a stable view, not reference physical tables directly

**PREVENT:**
- Schema contracts between teams
- `mergeSchema=false` on silver (fail on schema mismatch → human review)
- Automated schema diff alerts when any column is added/removed/renamed
- Downstream consumers should use views (abstraction layer), not physical tables

---

## THE DEBUGGING COMMUNICATION TEMPLATE

When Amarendra gives you a debugging scenario, structure your answer like this (takes ~3-4 minutes):

```
"Here's how I'd approach this:

FIRST — [stabilize/scope]: Let me understand what's broken and who's affected...
  [30 seconds]

MY TOP 3 HYPOTHESES:
1. [most likely] — because [reasoning]
2. [second most likely] — because [reasoning]
3. [less likely but high impact] — because [reasoning]

HOW I'D INVESTIGATE:
- [cheapest/fastest check that eliminates hypothesis 1 or 2]
- [specific query or command I'd run]
- [what the result tells me]

ASSUMING I FIND [X]:
- Immediate fix: [action]
- Root cause: [why this happened NOW]
- Prevention: [what I'd add to prevent recurrence]
"
```

This template:
- Shows structured thinking (not random thrashing)
- Demonstrates prioritization (hypotheses ranked)
- Shows cost-awareness (cheapest check first)
- Ends with prevention (senior mindset)

---

## QUICK-FIRE DEBUGGING SCENARIOS (Practice These Out Loud)

### Q: "Your Databricks cluster starts with 10 nodes but auto-scales to maximum (50) every day. Why?"

**Answer:** "Auto-scaling means tasks need more parallelism. Check: (a) input data growing? (b) shuffle partitions misconfigured (too many small partitions → too many tasks → needs more executors)? (c) cache eviction causing recomputation? (d) executor memory too low → tasks failing and retrying → more executors needed to compensate. I'd check the Spark UI ganglia/metrics: if CPU utilization per executor is <20%, we have too many executors doing too little — the real fix is better partition sizing or fixing a skew, not more nodes."

### Q: "A Delta MERGE that used to take 5 minutes now takes 2 hours. Table is 500GB."

**Answer:** "Three suspects: (1) Z-ORDER degraded — haven't run OPTIMIZE recently, so file pruning during merge is poor. MERGE needs to scan more files. (2) Source batch grew — more rows to match means more probe operations. (3) Small files: if the table has 100K tiny files, listing overhead alone is huge. Fix order: check `DESCRIBE DETAIL` for file count, run `OPTIMIZE ZORDER BY (merge_key)`, re-run MERGE. Expected improvement: 10-50x."

### Q: "Your streaming job's event_time watermark is advancing but processed_rows is zero."

**Answer:** "Watermark advancing + zero rows = the data IS arriving but being FILTERED out before it reaches the processing logic. Check: (a) filter condition too restrictive, (b) deserialization failure dropping all rows (check `numInputRows` vs `numProcessedRows` in query progress), (c) data format changed so JSON parsing returns NULL for all fields → filter on NOT NULL drops everything. Check the rescued data column if using Auto Loader."

### Q: "Pipeline passes all quality checks, no errors, but users say 'something feels off' in the dashboard."

**Answer:** "This is the hardest type — no obvious signal. My approach: (a) Ask WHICH metric feels off. Get specific. (b) Check for silent filtering: compare record counts week-over-week. A 5% gradual decline is hard to notice per-day but clear over a week. (c) Check for subtle timezone bugs: maybe a deployment shifted timezone from UTC to local, causing 8 hours of data to show on the wrong day. (d) Check dimension table freshness: if a product mapping table is stale, new products show as 'Unknown' and don't aggregate correctly. (e) Run a statistical anomaly detection on key metrics for the past 30 days — look for the inflection point."
