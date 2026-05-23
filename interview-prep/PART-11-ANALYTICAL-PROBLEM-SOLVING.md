# PART 11 — ANALYTICAL PROBLEM SOLVING & SCENARIO ROUNDS

## What This Section Covers

The "analytical thinking" round at Nike isn't LeetCode. It's:
- "Here's a messy business problem. How do you think about it?"
- "Here's ambiguous data. What questions do you ask?"
- "Here's a tradeoff with no right answer. Walk me through your reasoning."
- "Here's a production decision. Justify it."

Amarendra is testing: **structured reasoning, communication clarity, and engineering judgment under ambiguity.**

---

## THE ANALYTICAL ANSWER FRAMEWORK

For any ambiguous/analytical question, use this structure:

```
1. RESTATE & CLARIFY    — "Let me make sure I understand the problem..."
2. DECOMPOSE           — Break into sub-problems (max 3-4)
3. PRIORITIZE          — "The highest-impact sub-problem is X because..."
4. REASON THROUGH      — Walk through logic, name assumptions
5. QUANTIFY            — Use numbers wherever possible
6. ACKNOWLEDGE TRADEOFFS — "The downside of this approach is..."
7. RECOMMEND           — Clear recommendation with rationale
```

---

## SCENARIO 1: The Ambiguous Data Quality Problem

### The Prompt:

> "We have a Nike product catalog with 500K products. Three different internal systems have their own copy of this catalog: the e-commerce platform, the warehouse management system, and the marketing platform. They're all slightly different. The business wants 'one source of truth.' How do you approach this?"


### Your Answer:

**RESTATE:** "So we have 3 independent copies of product data that have diverged over time. The goal is to establish a single authoritative version that all systems can trust."

**CLARIFY (ask these):**
- "Which system is closest to 'ground truth'? Is there a system that product managers actively maintain?"
- "What types of differences? Missing products, conflicting attributes (price, category), or structural differences (different fields)?"
- "Does 'one source of truth' mean one database everyone reads from, or one system that publishes and others subscribe?"
- "What's the urgency? Is this causing customer-visible issues?"

**DECOMPOSE:**
1. **Discovery:** Quantify the divergence. How different are these catalogs?
2. **Authority:** Decide which system owns which attributes.
3. **Reconciliation:** Build the golden record.
4. **Distribution:** How do other systems consume it going forward?
5. **Prevention:** Stop divergence from re-occurring.

**REASON THROUGH:**

"Step 1 — I'd start with a data profiling exercise:
```sql
-- Join all three catalogs on product_id
-- Identify: matches, mismatches, missing
SELECT
    COALESCE(e.product_id, w.product_id, m.product_id) as product_id,
    CASE
        WHEN e.product_id IS NULL THEN 'missing_ecommerce'
        WHEN w.product_id IS NULL THEN 'missing_warehouse'
        WHEN m.product_id IS NULL THEN 'missing_marketing'
        WHEN e.price != w.price OR e.price != m.price THEN 'price_conflict'
        WHEN e.category != m.category THEN 'category_conflict'
        ELSE 'consistent'
    END as status
FROM ecommerce_products e
FULL OUTER JOIN warehouse_products w USING (product_id)
FULL OUTER JOIN marketing_products m USING (product_id);
```

If 90% are consistent and 10% have conflicts → this is a targeted reconciliation, not a rebuild. If 50% diverge → it's a deeper structural problem.

Step 2 — Define attribute ownership:
| Attribute | Owner System | Reason |
|-----------|-------------|--------|
| Price | E-commerce | Customer-facing, must be accurate for transactions |
| Inventory count | Warehouse | Physical reality |
| Marketing description | Marketing | They write the copy |
| Category/taxonomy | Product team (new master) | Cross-functional concern |

Step 3 — Build the golden record:
- Create a new master catalog in the data platform (Delta table)
- For each attribute: take from the owning system
- For conflicts: flag for human review with both values
- For missing: investigate — is the product retired? Was it never synced?

Step 4 — Going forward: master catalog publishes via CDC to all consumers. No system writes product data directly. Changes go through the master catalog API."

**TRADEOFFS:**
"The risk of a centralized master is: it becomes a bottleneck. If the marketing team needs to update a description, they now depend on the master catalog's release cycle. The tradeoff is: governance vs agility. I'd recommend eventual consistency — each system can have a local cache, but the master is authoritative. Changes propagate within minutes via CDC."

---

## SCENARIO 2: The Build vs Buy Decision

### The Prompt:

> "The team is debating whether to build a custom data quality framework in-house or adopt Great Expectations / Monte Carlo / Soda. You have 4 weeks of engineering time available. What do you recommend?"

### Your Answer:

**DECOMPOSE the decision:**

| Factor | Build In-House | Adopt Tool |
|--------|---------------|------------|
| **Time to value** | 4 weeks for MVP, months for maturity | 1-2 weeks for initial setup |
| **Customization** | Unlimited | Limited to tool's model |
| **Maintenance burden** | Ongoing — you own the bugs | Vendor maintains |
| **Integration depth** | Perfect fit with your stack | May have gaps (e.g., Delta-specific features) |
| **Team expertise** | Learning curve = zero (you built it) | Learning curve for team |
| **Cost** | Engineering time | License fee ($20-100K/year for enterprise) |
| **Maturity** | Starts at v0.1 | Already battle-tested |

**MY REASONING:**

"With only 4 weeks, I cannot build something competitive with Great Expectations' maturity. But the question is: do we NEED that maturity?

Let me quantify our needs:
- How many tables? → 50 tables in silver/gold
- What checks? → Not null, uniqueness, freshness, row count deltas, referential integrity
- Where does it run? → In Databricks after each pipeline stage
- Who configures rules? → Engineers (not business users)

If our needs are: simple assertions (not-null, range, uniqueness) running inside Spark jobs → I can build this in 1 week as a lightweight Python library. No external dependency.

If our needs are: anomaly detection, automated profiling, business-user-configurable rules, Slack integration, dashboard → adopt Great Expectations or Soda.

**MY RECOMMENDATION:**

'Start with lightweight custom assertions (1 week build), plan to adopt a mature tool in Q3.'

Reasoning:
1. 4 weeks is too short to evaluate, integrate, and roll out a vendor tool properly
2. A simple custom validator (like Part 7's DataValidator) covers 80% of immediate needs
3. After 3 months of usage, we'll know WHICH features of a mature tool we actually need — that informs the vendor selection
4. This avoids premature lock-in to a tool that might not fit our Databricks + Delta stack optimally

The risk: we build something, then adopt a tool anyway (sunk cost). Mitigation: keep the custom solution thin — just assertions and alerts. Don't build a UI or complex configuration system."

---

## SCENARIO 3: The Prioritization Problem

### The Prompt:

> "You join the Nike data team. There are 15 open requests from different teams. You have capacity for 3 this quarter. How do you decide?"

### Your Answer:

**FRAMEWORK:** I'd score each request on 4 dimensions:

| Dimension | Weight | What It Means |
|-----------|--------|---------------|
| **Business impact** | 40% | Revenue impact, user impact, strategic alignment |
| **Urgency** | 25% | Deadline-driven? Regulatory? Blocking other teams? |
| **Engineering effort** | 20% | Can we do it in the quarter? Dependencies? Complexity? |
| **Technical debt reduction** | 15% | Does this fix underlying issues or add more duct tape? |

**PROCESS:**

1. **Categorize requests:**
   - Quick wins (< 1 week, high impact) → do these immediately regardless of formal prioritization
   - Strategic bets (high impact, high effort) → these are the real queue to prioritize
   - Nice-to-haves (low impact, any effort) → defer or decline

2. **Score the strategic bets:**
   - Meet with each requesting team (30 min). Understand: What's the business outcome? What happens if we DON'T do this? What's the deadline?
   - Score 1-5 on each dimension. Multiply by weight. Rank.

3. **Validate with leadership:**
   - Present top 5 ranked items to engineering director. Get alignment.
   - Make the tradeoffs VISIBLE: "We're choosing A, B, C. That means D, E are deferred. Here's why."

4. **Communicate the 'no':**
   - For deferred requests: give a realistic timeline AND offer a lightweight alternative. "We can't build the full feature, but here's a workaround that gets you 60% of the value."

**WHAT SEPARATES STRONG FROM WEAK ANSWERS HERE:**

- **Weak:** "I'd do whatever the most senior stakeholder asks."
- **Strong:** "I'd quantify impact, make tradeoffs explicit, get alignment, and communicate clearly — including saying no with alternatives."

---

## SCENARIO 4: The "Impossible" Requirement

### The Prompt:

> "A product manager says: 'I need real-time personalization — when a user lands on Nike.com, I want recommendations updated with their LAST action, within 1 second.' Your current pipeline is daily batch. What do you do?"

### Your Answer:

**DON'T immediately say 'impossible.' Don't immediately say 'yes.' DECOMPOSE.**

"Let me unpack what 'real-time' means here and find the actual requirement:

**Question 1:** Does 'last action' mean the action they took 1 second ago on THIS session, or the action from their last session (maybe yesterday)?
- If same session: I need sub-second event processing → real-time stream processing
- If last session: hourly or even daily batch might be fine

**Question 2:** How much does the recommendation ACTUALLY change based on one event?
- User viewed a shoe → recommendations shift from generic to shoe-heavy
- How different would yesterday's recommendations be vs today's? If 90% overlap → daily batch is good enough and we're over-engineering

**Question 3:** What's the cost tolerance?
- Real-time personalization (Kafka → Flink → Feature Store → API): $50K/month+ in infrastructure
- Near-real-time (15-min refresh): $10K/month
- Daily batch (current): $2K/month

**MY PROPOSAL (layered solution):**

```
Layer 1 (cheap, immediate): 
  Pre-computed daily recommendations based on 90-day history.
  Covers: returning users, cold-start personalization.
  Latency: stale by up to 24 hours. Covers 70% of value.

Layer 2 (moderate, 4-week build):
  Session-based boosting. When user views a product category,
  boost that category in their pre-computed recommendations in real-time.
  Implementation: JavaScript on the frontend re-ranks cached recommendations
  based on current session signals. No backend change needed.
  Covers: additional 20% of value.

Layer 3 (expensive, 3-month build):
  Full real-time feature pipeline (Kafka → streaming features → serving layer).
  Only justified if A/B test shows Layer 1+2 isn't enough.
  Covers: final 10% of value.
```

**COMMUNICATION:** 'I'd propose Layer 1+2 to the PM, which gets 90% of the value in 4 weeks at 1/5 the cost. Then we instrument and A/B test to prove whether Layer 3 is needed. If the 10% uplift justifies $50K/month ongoing cost, we build it. If not, we saved the company $600K/year.'

**WHY THIS ANSWER IS STRONG:**
- Didn't say no
- Didn't blindly agree
- Quantified the options
- Proposed an iterative approach with validation
- Made cost explicit
- Showed business thinking, not just engineering thinking"

---

## SCENARIO 5: The Data Modeling Decision

### The Prompt:

> "Nike has order data. An order can have multiple items. Each item can have multiple discounts applied. How would you model this for analytics? What are the tradeoffs between normalized vs denormalized?"

### Your Answer:

**NORMALIZED MODEL (3NF):**
```
orders:         order_id | user_id | order_date | total_amount | status
order_items:    item_id | order_id | product_id | quantity | unit_price | item_total
item_discounts: discount_id | item_id | discount_type | discount_amount | coupon_code
```

**DENORMALIZED MODEL (wide fact table):**
```
fact_order_items:
  order_id | user_id | order_date | product_id | quantity |
  unit_price | discount_type_1 | discount_amount_1 | discount_type_2 |
  discount_amount_2 | net_item_total | order_total | status
```

**STAR SCHEMA (middle ground — what I'd actually build):**
```
fact_order_items:
  order_item_sk | order_id | product_id | user_id | order_date_key |
  quantity | gross_amount | total_discount | net_amount

dim_order:    order_id | order_date | status | channel | store_id
dim_product:  product_id | name | category | subcategory | brand
dim_user:     user_id | segment | region | lifetime_value_tier
dim_date:     date_key | date | week | month | quarter | year | is_holiday

bridge_item_discounts:  (for multi-valued dimension)
  order_item_sk | discount_type | discount_amount | coupon_code
```

**TRADEOFF ANALYSIS:**

| Factor | Normalized | Star Schema | Fully Denormalized |
|--------|-----------|-------------|-------------------|
| Query simplicity | Complex (many joins) | Moderate (predictable joins) | Simple (single table) |
| Storage efficiency | Best (no redundancy) | Moderate | Worst (lots of repetition) |
| Write performance | Best (update one place) | Moderate | Worst (update many rows) |
| Read performance | Worst (many joins) | Good (few predictable joins) | Best (pre-joined) |
| Flexibility for new questions | Best | Good | Poor (must re-model for new dimensions) |
| Handling multi-value (discounts) | Natural (separate table) | Bridge table needed | Arrays or fixed columns |

**MY RECOMMENDATION:**

"For Nike's analytics use case, I'd go with a **star schema in gold** layer with a bridge table for discounts.

Reasoning:
1. Most analytics questions are about order items + product + time → star schema handles this with 2-3 joins that the engine optimizes well
2. The discount problem is a multi-valued dimension. Options: (a) bridge table (cleanest, any number of discounts), (b) array column in fact (works in Spark/BigQuery, harder in BI tools), (c) fixed columns (discount_1, discount_2... — ugly, breaks at N+1 discounts)
3. In Databricks/BigQuery, joins on surrogate keys in a star schema are extremely fast (broadcast the dims, scan the fact)
4. Silver layer stays normalized (source of truth). Gold layer is denormalized for the specific access pattern.

The key insight: **in lakehouse, you can have BOTH.** Silver is normalized and correct. Gold is denormalized and fast. They coexist."

---

## SCENARIO 6: Estimating Pipeline Scale

### The Prompt:

> "Nike launches in 5 new countries next year. Your pipeline currently handles US + EU (10 countries). What breaks at 15 countries? What about 50?"

### Your Answer:

**CURRENT STATE (quantify first):**
"Let me estimate current scale:
- 10 countries × avg 10M events/day/country = 100M events/day
- ~500 bytes/event = ~50GB/day ingestion
- Storage (1 year): ~18TB
- Peak throughput: ~5x during local peak hours = 500M events in a day during sales"

**AT 15 COUNTRIES (50% growth):**

"Linear growth in volume: 100M → 150M events/day. Most systems handle this without architecture changes.

What MIGHT break:
1. **Timezone complexity:** pipeline runs at midnight UTC. With more timezones, 'daily' means different things. Some countries' data for 'today' arrives in what's UTC 'tomorrow.' → Ensure pipeline uses event_time not processing_time for partitioning.
2. **Currency/locale:** new countries = new currencies. Aggregations that sum revenue need currency conversion. → Add a `dim_exchange_rates` table, convert to USD at source.
3. **Regulatory differences:** GDPR (EU) vs India's DPDP Act vs China's PIPL. Data residency requirements might prevent centralizing data. → May need regional data isolation.

Likely fine: cluster sizing, storage, network. 50% growth is well within scaling buffer."

**AT 50 COUNTRIES (5x growth):**

"500M events/day = ~250GB/day. Now things get interesting:

What LIKELY breaks:
1. **Cluster sizing:** jobs that fit in 45 minutes at 100M events might take 4 hours at 500M. Need to scale clusters OR make pipeline incremental (process only new data, not full-day recompute).
2. **Shuffle volume:** groupBy('country', 'product') shuffle grows 5x. May need to pre-aggregate per-country in parallel, then combine. Or partition data by region and run regional pipelines.
3. **Small file problem:** 5x more data writing to same table = 5x more files if partition strategy stays the same.
4. **Cost:** 5x data = potentially 5x compute cost. Need to optimize BEFORE scaling to avoid $100K+ monthly bills.
5. **Data residency:** at 50 countries, almost certainly need multi-region deployment. Some countries legally require data stays in-country (China, Russia, India partially).

Architecture evolution needed:
- **Regional pipelines:** run bronze/silver per-region (data stays local)
- **Global aggregation:** gold layer combines regional silvers (only aggregates cross borders, not raw PII)
- **Partition strategy:** add `region` as top-level partition to enable regional isolation
- **Cluster pools per region:** avoid cross-region data movement during processing"

---

## SCENARIO 7: The Ethical/Governance Question

### The Prompt:

> "A marketing analyst asks for access to raw customer event data including precise geolocation, browsing history, and purchase details to build customer segments. How do you handle this?"

### Your Answer:

"This is a data governance question disguised as an access request. I don't just grant or deny — I investigate the actual need and find the appropriate access level.

**MY PROCESS:**

1. **Understand the use case:** What segments are they building? Do they need INDIVIDUAL customer data or AGGREGATE patterns? Usually: they need aggregates.

2. **Apply least-privilege:** 
   - Can they achieve their goal with pre-built aggregated tables? (gold layer with user segments already computed)
   - If they need row-level data: can we provide it with PII masked/hashed?
   - If they truly need raw PII: what's the business justification, and who approves?

3. **Propose tiered access:**

| Access Level | What They See | Approval Needed |
|-------------|--------------|-----------------|
| Gold aggregates (segment_id, count, avg_revenue) | No PII | Self-service |
| Silver with hashed user_id (can analyze patterns but not identify individuals) | Pseudonymized | Manager approval |
| Silver with real user_id + geolocation | Full PII | Data protection officer + legal |
| Raw bronze with precise coordinates | Maximum PII | VP approval + audit log |

4. **Technical implementation:**
   - Unity Catalog column-level masking: `CREATE MASK` on sensitive columns
   - Row-level security: analyst only sees data for their approved regions
   - Audit trail: every query against PII tables is logged

5. **My recommendation to the analyst:** 'Let's start with the aggregated segment table. If that doesn't give you what you need, I can provide pseudonymized row-level data. We'll escalate to full PII only if there's a clear business justification that legal approves.'

**WHY THIS IS A STRONG ANSWER:**
- Doesn't blindly deny (blocks business value)
- Doesn't blindly approve (creates compliance risk)
- Proposes a pragmatic middle ground
- Shows awareness of governance (GDPR, Nike's reputation risk)
- Technical solution (masking, RBAC) not just policy"

---

## SCENARIO 8: Architecture Tradeoff — Batch vs Stream vs Hybrid

### The Prompt:

> "For Nike's inventory system: Should inventory levels be computed via batch (nightly recompute from transactions) or streaming (update in real-time as sales happen)? There's a $1M budget for the year."

### Your Answer:

**DECOMPOSE BY CONSUMER NEEDS:**

| Consumer | Freshness Requirement | Current Pain |
|----------|----------------------|--------------|
| Warehouse operations | Real-time | Workers picking items that don't exist |
| E-commerce (show stock) | Minutes | Selling items that are out of stock |
| Finance reporting | Daily | Reconciliation delays |
| Demand planning | Weekly | N/A, batch is fine |

"The answer isn't one-size-fits-all. Different consumers need different freshness."

**OPTION A: Pure Batch ($200K/year)**
- Recompute all inventory nightly from transaction sum
- Pro: simple, cheap, deterministic, easy to debug
- Con: warehouse is stale all day, e-commerce oversells

**OPTION B: Pure Streaming ($600K/year)**
- Every sale/return/receipt updates inventory in real-time
- Pro: always fresh, no overselling
- Con: complex (exactly-once is hard), expensive (24/7 cluster), harder to debug, state management

**OPTION C: Hybrid ($350K/year) — MY RECOMMENDATION:**
```
Streaming path (fast, approximate):
  Sales events → Structured Streaming → Redis (live inventory counter)
  Latency: seconds. Consumers: e-commerce, warehouse operations.
  
Batch path (slow, authoritative):
  All transactions → Nightly recompute → Delta gold table
  Latency: daily. Consumers: finance, demand planning.
  
Reconciliation:
  Every night, batch result corrects any drift in the streaming counter.
  Streaming counter resets to batch-computed value at midnight.
```

**WHY HYBRID:**
1. Streaming handles the real-time need (don't oversell) — but it's APPROXIMATE (might miss edge cases)
2. Batch is the source of truth (handles corrections, returns processed offline, adjustments)
3. Nightly reconciliation prevents drift from compounding over time
4. If streaming fails: e-commerce falls back to batch (stale by up to 24h but not infinite)
5. Cost: streaming cluster is sized for throughput not storage (small), batch is nightly (cheap)

**BUDGET ALLOCATION:**
- Streaming infrastructure (Kafka + Spark + Redis): $200K/year
- Batch pipeline (Databricks jobs nightly): $50K/year
- Monitoring/alerting/ops: $50K/year
- Engineering team time (2 engineers × 3 months build): $150K
- Total: ~$450K year 1, $300K/year ongoing → within $1M budget

**Under $1M with room for contingency.**"

---

## RAPID-FIRE ANALYTICAL QUESTIONS (30-Second Answers)

### Q: "How do you decide between Parquet and Delta?"

"Delta is always preferred when you need ACID (writes), time travel, or MERGE. Parquet is fine for immutable, append-only data that's never updated (raw file drops, ML training datasets). In practice: everything in my lakehouse is Delta. External data sources stay in Parquet until ingested."

### Q: "When would you choose Snowflake over Databricks?"

"Snowflake when: team is SQL-heavy, workload is BI/analytics-dominated, need zero-admin scaling, governance is priority. Databricks when: ML/DS workloads, need Spark for complex transforms, streaming requirements, want open formats (Delta/Parquet on YOUR storage). Both work — it's a team/workload fit question, not a pure technology question."

### Q: "How do you handle a situation where two teams need the same data in incompatible formats?"

"Build one authoritative source (gold table), then serve views or derived tables for each consumer. Never copy-paste a pipeline. If format is truly incompatible (one needs event-level, one needs daily aggregate), build TWO gold tables from the SAME silver source. Lineage connects them."

### Q: "What's your approach to testing data pipelines?"

"Layered: (1) Unit tests on transform logic with small test DataFrames — pytest, runs in seconds. (2) Contract tests on schema/data quality — dbt tests or DLT expectations, runs with each pipeline execution. (3) Integration tests in staging environment — full pipeline against sample data, validates end-to-end correctness. (4) Monitoring in production — row counts, freshness, anomaly detection. I shift quality LEFT but accept that production monitoring catches what tests can't anticipate."

### Q: "How do you onboard yourself to a new data codebase?"

"Day 1: read the data model (ER diagram or DBT docs). Day 2: read the DAG/orchestration (what runs when, what depends on what). Day 3: pick one end-to-end pipeline and trace it from source to dashboard. By Day 4 I can ask meaningful questions. I don't try to understand everything at once — I understand one slice deeply, then expand."

---

## FINAL SECTION: THE BEHAVIORAL + TECHNICAL HYBRID QUESTIONS

### Q: "Tell me about a time you disagreed with a technical decision and how you handled it."

**STAR (tailored to your GCP/DBT background):**

"**Situation:** On my previous team, the lead proposed building all pipeline transformations as raw SQL scripts scheduled via cron jobs — no orchestration, no testing, no lineage.

**Task:** I believed this would be unmaintainable at scale and create a debugging nightmare. But I was more junior and needed to influence without authority.

**Action:** Instead of just saying 'this is wrong,' I built a proof-of-concept with DBT on the same transformation logic:
- Same SQL, wrapped in DBT models with `ref()` for lineage
- Added 5 tests (not-null, uniqueness, freshness)
- Generated documentation automatically
- Showed the lineage graph: 'here's how all 30 models connect'
- Ran both approaches side by side for 2 weeks: my DBT pipeline broke once and self-recovered with clear error message. The raw SQL pipeline broke 4 times with cryptic cron failures.

**Result:** Team adopted DBT. Pipeline reliability went from ~80% to 99% over the next quarter. Debugging time per incident dropped from hours to minutes because lineage was visible. The lead appreciated that I showed rather than told."

### Q: "How do you handle technical debt in data pipelines?"

**Strong answer:** "I classify tech debt into three tiers:
1. **Critical (fix this sprint):** security vulnerabilities, data loss risk, incorrect business logic
2. **High (plan for next quarter):** scaling bottlenecks approaching limit, deprecated dependencies, missing tests on critical paths
3. **Low (backlog):** code style inconsistencies, suboptimal partitioning on non-critical tables

I track it visibly (tagged tickets), advocate for 20% of sprint capacity dedicated to debt reduction, and prioritize by blast radius: 'if this breaks, how many people are affected?'

The trap data teams fall into: only building new features and never reducing debt, until the pipeline is so fragile that every new feature causes two bugs. I prevent this by making debt visible to stakeholders: 'we can build Feature X in 2 weeks, or in 1 week if we first spend a week fixing the underlying data model. The 1-week investment saves us 3 weeks across the next 5 features.'"

---

## THE 10 POWER PHRASES FOR TUESDAY

Use these naturally throughout the interview. Each one signals senior thinking:

1. **"The tradeoff there is..."** (shows you see both sides)
2. **"In production, I'd also worry about..."** (shows operational maturity)
3. **"Let me quantify that..."** (shows you don't hand-wave)
4. **"The failure mode here is..."** (shows defensive thinking)
5. **"I've seen this pattern before — in my BigQuery/DBT work..."** (bridges experience)
6. **"The first thing I'd check is..."** (shows systematic debugging)
7. **"What's the SLA for this?"** (shows you think about contracts)
8. **"Is this a latency problem or a throughput problem?"** (shows you decompose correctly)
9. **"I'd instrument this before optimizing..."** (shows measurement-first thinking)
10. **"What would this look like at 10x scale?"** (shows you think ahead)

---

## CLOSING: YOUR TUESDAY GAMEPLAN CHECKLIST

Before you walk in:
- [ ] 2 STAR stories memorized (structure, not script)
- [ ] Know your GCP→Databricks bridge phrases cold
- [ ] Can write window function + dedup SQL in 3 minutes
- [ ] Can explain MERGE, Z-ORDER, watermark in 30 seconds each
- [ ] Can draw a medallion pipeline on a whiteboard in 60 seconds
- [ ] Have 3 questions for Amarendra ready
- [ ] Know the debugging framework (stabilize/scope/hypothesize/investigate/fix/prevent)
- [ ] Can explain one production incident from your career in STAR format

You're ready. Go get it.
