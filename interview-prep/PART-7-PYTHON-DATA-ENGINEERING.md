# PART 7 — PYTHON FOR DATA ENGINEERING: Production Patterns & Interview Exercises

## How Python Gets Tested in DE Interviews

Amarendra won't ask you LeetCode-style algorithm problems. He'll ask:
- "Write a Python script that handles X data processing scenario"
- "How would you structure a production ETL in Python?"
- "This code has a bug — find it" (shows you a data pipeline snippet)
- "How do you handle failures/retries/logging in Python pipelines?"

He's testing: **Can you write production-grade Python, not just scripting Python?**

---

## SECTION A: PRODUCTION PYTHON PATTERNS FOR DATA ENGINEERING

### Pattern 1: Idempotent ETL Job Structure

This is the template for ANY Python-based data pipeline:

```python
"""
Nike Product Inventory ETL
Extracts from REST API, transforms, loads to data warehouse.
Idempotent: safe to re-run for the same execution_date.
"""
import logging
import sys
from datetime import datetime, timedelta
from typing import Optional
from dataclasses import dataclass

import requests
from tenacity import retry, stop_after_attempt, wait_exponential

# --- CONFIGURATION (never hardcode) ---
@dataclass(frozen=True)
class Config:
    api_base_url: str
    api_key: str
    target_table: str
    batch_size: int = 1000
    max_retries: int = 3
    timeout_seconds: int = 30

# --- LOGGING (structured, not print statements) ---
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(name)s: %(message)s'
)
logger = logging.getLogger(__name__)


# --- EXTRACT (with retry, timeout, pagination) ---
class APIExtractor:
    def __init__(self, config: Config):
        self.config = config
        self.session = requests.Session()
        self.session.headers.update({
            "Authorization": f"Bearer {config.api_key}",
            "Content-Type": "application/json"
        })

    @retry(
        stop=stop_after_attempt(3),
        wait=wait_exponential(multiplier=1, min=2, max=30),
        reraise=True
    )
    def _fetch_page(self, endpoint: str, params: dict) -> dict:
        """Single API call with retry logic."""
        response = self.session.get(
            f"{self.config.api_base_url}/{endpoint}",
            params=params,
            timeout=self.config.timeout_seconds
        )
        response.raise_for_status()
        return response.json()

    def extract_all(self, execution_date: str) -> list[dict]:
        """Paginated extraction for a given date."""
        all_records = []
        offset = 0

        while True:
            logger.info(f"Fetching page at offset {offset} for date {execution_date}")
            data = self._fetch_page(
                "inventory/snapshots",
                params={
                    "date": execution_date,
                    "limit": self.config.batch_size,
                    "offset": offset
                }
            )

            records = data.get("items", [])
            if not records:
                break

            all_records.extend(records)
            offset += self.config.batch_size

            # Safety valve: prevent infinite loops from buggy APIs
            if offset > 1_000_000:
                logger.warning("Hit safety limit of 1M records. Stopping pagination.")
                break

        logger.info(f"Extracted {len(all_records)} records for {execution_date}")
        return all_records


# --- TRANSFORM (pure functions, testable) ---
class InventoryTransformer:
    """Transform raw API response to warehouse schema. Pure functions — no side effects."""

    REQUIRED_FIELDS = {"product_id", "store_id", "quantity", "snapshot_date"}

    def transform_batch(self, raw_records: list[dict]) -> list[dict]:
        """Transform and validate a batch of records."""
        transformed = []
        invalid_count = 0

        for record in raw_records:
            result = self._transform_single(record)
            if result is not None:
                transformed.append(result)
            else:
                invalid_count += 1

        if invalid_count > 0:
            invalid_pct = invalid_count / len(raw_records) * 100
            logger.warning(f"Dropped {invalid_count} invalid records ({invalid_pct:.1f}%)")

            # CIRCUIT BREAKER: if >10% invalid, something is wrong upstream
            if invalid_pct > 10:
                raise ValueError(
                    f"Too many invalid records: {invalid_pct:.1f}% "
                    f"exceeds 10% threshold. Aborting to prevent bad data in warehouse."
                )

        return transformed

    def _transform_single(self, record: dict) -> Optional[dict]:
        """Transform one record. Returns None if invalid."""
        # Validate required fields
        if not self.REQUIRED_FIELDS.issubset(record.keys()):
            return None

        # Null check on critical fields
        if any(record.get(f) is None for f in ("product_id", "store_id")):
            return None

        return {
            "product_id": str(record["product_id"]).strip(),
            "store_id": str(record["store_id"]).strip(),
            "quantity": max(0, int(record.get("quantity", 0))),  # Floor at 0
            "snapshot_date": record["snapshot_date"],
            "unit_cost": float(record.get("unit_cost", 0.0)),
            "total_value": float(record.get("quantity", 0)) * float(record.get("unit_cost", 0.0)),
            "category": record.get("category", "UNKNOWN").upper(),
            "_source": "inventory_api",
            "_loaded_at": datetime.utcnow().isoformat()
        }


# --- LOAD (idempotent write) ---
class WarehouseLoader:
    def __init__(self, config: Config):
        self.config = config

    def load(self, records: list[dict], execution_date: str):
        """
        Idempotent load: delete existing data for this date, then insert.
        This ensures re-runs produce the same result.
        """
        logger.info(f"Loading {len(records)} records for {execution_date}")

        # In production, this would be:
        # 1. DELETE FROM target WHERE snapshot_date = execution_date
        # 2. INSERT INTO target VALUES (...)
        # Or: MERGE INTO target USING staging ON (keys) ...
        # Or: COPY INTO with overwrite partition mode

        # Example with BigQuery client (your stack):
        # client.query(f"DELETE FROM {self.config.target_table} WHERE snapshot_date = '{execution_date}'")
        # client.insert_rows_json(self.config.target_table, records)

        logger.info(f"Successfully loaded {len(records)} records")


# --- ORCHESTRATION (the main entry point) ---
def run_pipeline(execution_date: str, config: Config):
    """
    Main pipeline entry point. Idempotent for a given execution_date.
    """
    logger.info(f"Starting inventory pipeline for {execution_date}")

    try:
        # Extract
        extractor = APIExtractor(config)
        raw_data = extractor.extract_all(execution_date)

        if not raw_data:
            logger.warning(f"No data extracted for {execution_date}. Exiting gracefully.")
            return {"status": "no_data", "records": 0}

        # Transform
        transformer = InventoryTransformer()
        clean_data = transformer.transform_batch(raw_data)

        # Load
        loader = WarehouseLoader(config)
        loader.load(clean_data, execution_date)

        result = {
            "status": "success",
            "extracted": len(raw_data),
            "loaded": len(clean_data),
            "dropped": len(raw_data) - len(clean_data)
        }
        logger.info(f"Pipeline complete: {result}")
        return result

    except requests.exceptions.HTTPError as e:
        logger.error(f"API error: {e.response.status_code} - {e.response.text}")
        raise
    except ValueError as e:
        logger.error(f"Data quality failure: {e}")
        raise
    except Exception as e:
        logger.error(f"Unexpected error: {type(e).__name__}: {e}")
        raise


if __name__ == "__main__":
    # Entry point when run from CLI or Airflow
    exec_date = sys.argv[1] if len(sys.argv) > 1 else (
        datetime.utcnow() - timedelta(days=1)
    ).strftime("%Y-%m-%d")

    config = Config(
        api_base_url="https://api.nike.internal/v2",
        api_key="from-secrets-manager",  # In reality: read from env/secrets
        target_table="warehouse.inventory.daily_snapshot"
    )

    run_pipeline(exec_date, config)
```

### Why This Structure Impresses Interviewers:

1. **Separation of concerns:** Extract/Transform/Load are independent classes — testable in isolation
2. **Retry with exponential backoff:** using `tenacity` (production standard, not custom retry loops)
3. **Circuit breaker:** if >10% records are invalid, STOP — don't silently load garbage
4. **Idempotency:** delete-then-insert for the execution_date means re-runs are safe
5. **Structured logging:** not `print()`. Includes timestamp, level, logger name
6. **Type hints:** shows you think about interfaces
7. **Config as dataclass:** immutable, typed, testable
8. **Safety valves:** pagination limit prevents infinite loops from buggy APIs
9. **Graceful handling of empty data:** doesn't fail, logs and exits

---

## SECTION B: PYTHON CODING EXERCISES — Interview Grade

### Exercise 1: Implement a Generic Data Validator

**Interviewer says:** "Write a Python class that validates a batch of records against a configurable schema with rules like not_null, type_check, range_check, regex_match. Return valid records and a summary of violations."

```python
from dataclasses import dataclass, field
from typing import Any, Callable
import re

@dataclass
class ValidationRule:
    column: str
    rule_type: str  # "not_null", "type_check", "range", "regex", "custom"
    params: dict = field(default_factory=dict)
    severity: str = "error"  # "error" = drop row, "warning" = keep but log

@dataclass
class ValidationResult:
    valid_records: list[dict]
    invalid_records: list[dict]
    violations: list[dict]  # {record_index, column, rule_type, value, message}

    @property
    def valid_count(self) -> int:
        return len(self.valid_records)

    @property
    def invalid_count(self) -> int:
        return len(self.invalid_records)

    @property
    def error_rate(self) -> float:
        total = self.valid_count + self.invalid_count
        return self.invalid_count / total if total > 0 else 0.0


class DataValidator:
    """Configurable data validator for pipeline quality gates."""

    def __init__(self, rules: list[ValidationRule]):
        self.rules = rules
        self._validators = {
            "not_null": self._check_not_null,
            "type_check": self._check_type,
            "range": self._check_range,
            "regex": self._check_regex,
            "enum": self._check_enum,
            "custom": self._check_custom,
        }

    def validate(self, records: list[dict]) -> ValidationResult:
        valid = []
        invalid = []
        all_violations = []

        for idx, record in enumerate(records):
            record_violations = self._validate_record(record, idx)
            error_violations = [v for v in record_violations if v["severity"] == "error"]

            if error_violations:
                invalid.append(record)
            else:
                valid.append(record)

            all_violations.extend(record_violations)

        return ValidationResult(
            valid_records=valid,
            invalid_records=invalid,
            violations=all_violations
        )

    def _validate_record(self, record: dict, idx: int) -> list[dict]:
        violations = []
        for rule in self.rules:
            value = record.get(rule.column)
            is_valid, message = self._validators[rule.rule_type](value, rule.params)

            if not is_valid:
                violations.append({
                    "record_index": idx,
                    "column": rule.column,
                    "rule_type": rule.rule_type,
                    "value": value,
                    "message": message,
                    "severity": rule.severity
                })
        return violations

    def _check_not_null(self, value: Any, params: dict) -> tuple[bool, str]:
        if value is None or (isinstance(value, str) and value.strip() == ""):
            return False, "Value is null or empty"
        return True, ""

    def _check_type(self, value: Any, params: dict) -> tuple[bool, str]:
        if value is None:
            return True, ""  # null check is separate rule
        expected = params["expected_type"]  # "int", "float", "str"
        type_map = {"int": int, "float": (int, float), "str": str}
        if not isinstance(value, type_map.get(expected, str)):
            # Try casting
            try:
                type_map_cast = {"int": int, "float": float, "str": str}
                type_map_cast[expected](value)
                return True, ""
            except (ValueError, TypeError):
                return False, f"Expected {expected}, got {type(value).__name__}: {value}"
        return True, ""

    def _check_range(self, value: Any, params: dict) -> tuple[bool, str]:
        if value is None:
            return True, ""
        min_val = params.get("min")
        max_val = params.get("max")
        try:
            num_val = float(value)
            if min_val is not None and num_val < min_val:
                return False, f"Value {value} below minimum {min_val}"
            if max_val is not None and num_val > max_val:
                return False, f"Value {value} above maximum {max_val}"
        except (ValueError, TypeError):
            return False, f"Cannot compare non-numeric value: {value}"
        return True, ""

    def _check_regex(self, value: Any, params: dict) -> tuple[bool, str]:
        if value is None:
            return True, ""
        pattern = params["pattern"]
        if not re.match(pattern, str(value)):
            return False, f"Value '{value}' does not match pattern '{pattern}'"
        return True, ""

    def _check_enum(self, value: Any, params: dict) -> tuple[bool, str]:
        if value is None:
            return True, ""
        allowed = params["allowed_values"]
        if value not in allowed:
            return False, f"Value '{value}' not in allowed: {allowed}"
        return True, ""

    def _check_custom(self, value: Any, params: dict) -> tuple[bool, str]:
        func: Callable = params["func"]
        return func(value)


# --- USAGE IN PIPELINE ---
rules = [
    ValidationRule("product_id", "not_null"),
    ValidationRule("product_id", "regex", {"pattern": r"^PRD-\d{6}$"}),
    ValidationRule("price", "not_null"),
    ValidationRule("price", "range", {"min": 0.01, "max": 50000}),
    ValidationRule("category", "enum", {"allowed_values": ["SHOES", "APPAREL", "EQUIPMENT"]}),
    ValidationRule("quantity", "type_check", {"expected_type": "int"}),
    ValidationRule("store_code", "not_null", severity="warning"),  # warn but don't drop
]

validator = DataValidator(rules)
result = validator.validate(raw_records)

if result.error_rate > 0.05:
    raise ValueError(f"Validation error rate {result.error_rate:.1%} exceeds 5% threshold")
```


### Follow-Up Probes:

**Probe:** "How would you test this?"

**Strong answer:**
```python
import pytest

def test_not_null_rejects_none():
    rules = [ValidationRule("name", "not_null")]
    validator = DataValidator(rules)
    result = validator.validate([{"name": None}, {"name": "Alice"}])
    assert result.valid_count == 1
    assert result.invalid_count == 1

def test_range_check_boundaries():
    rules = [ValidationRule("price", "range", {"min": 0, "max": 100})]
    validator = DataValidator(rules)
    result = validator.validate([
        {"price": -1},    # invalid
        {"price": 0},     # valid (inclusive)
        {"price": 100},   # valid (inclusive)
        {"price": 101},   # invalid
    ])
    assert result.valid_count == 2
    assert result.invalid_count == 2

def test_circuit_breaker_on_high_error_rate():
    rules = [ValidationRule("id", "not_null")]
    validator = DataValidator(rules)
    # All records invalid
    records = [{"id": None}] * 100
    result = validator.validate(records)
    assert result.error_rate == 1.0
```

"I write unit tests for each rule type independently, integration tests for rule combinations, and property-based tests with Hypothesis for edge cases (empty strings, unicode, very large numbers)."

---

### Exercise 2: Implement a Rate-Limited API Client with Backpressure

**Interviewer says:** "You need to call an API that has rate limits (100 requests/minute). Write a client that respects the limit, handles 429 responses, and processes records in parallel where possible."

```python
import time
import asyncio
import aiohttp
from collections import deque
from typing import AsyncIterator

class RateLimiter:
    """Token bucket rate limiter."""

    def __init__(self, max_requests: int, time_window: float = 60.0):
        self.max_requests = max_requests
        self.time_window = time_window
        self.timestamps: deque = deque()

    async def acquire(self):
        """Wait until a request slot is available."""
        while True:
            now = time.monotonic()
            # Remove timestamps outside the window
            while self.timestamps and self.timestamps[0] <= now - self.time_window:
                self.timestamps.popleft()

            if len(self.timestamps) < self.max_requests:
                self.timestamps.append(now)
                return
            else:
                # Wait until the oldest request exits the window
                sleep_time = self.timestamps[0] + self.time_window - now + 0.1
                await asyncio.sleep(sleep_time)


class ResilientAPIClient:
    """Production API client with rate limiting, retries, and backpressure."""

    def __init__(self, base_url: str, api_key: str, max_rps: int = 100):
        self.base_url = base_url
        self.api_key = api_key
        self.rate_limiter = RateLimiter(max_rps)
        self.max_retries = 3
        self._session: Optional[aiohttp.ClientSession] = None

    async def __aenter__(self):
        self._session = aiohttp.ClientSession(
            headers={"Authorization": f"Bearer {self.api_key}"},
            timeout=aiohttp.ClientTimeout(total=30)
        )
        return self

    async def __aexit__(self, *args):
        if self._session:
            await self._session.close()

    async def fetch(self, endpoint: str, params: dict = None) -> dict:
        """Single request with rate limiting and retry."""
        for attempt in range(self.max_retries):
            await self.rate_limiter.acquire()

            try:
                async with self._session.get(
                    f"{self.base_url}/{endpoint}", params=params
                ) as resp:
                    if resp.status == 200:
                        return await resp.json()
                    elif resp.status == 429:
                        # Rate limited — respect Retry-After header
                        retry_after = int(resp.headers.get("Retry-After", 60))
                        logger.warning(f"Rate limited. Sleeping {retry_after}s")
                        await asyncio.sleep(retry_after)
                    elif resp.status >= 500:
                        # Server error — retry with backoff
                        wait = 2 ** attempt
                        logger.warning(f"Server error {resp.status}. Retry in {wait}s")
                        await asyncio.sleep(wait)
                    else:
                        # Client error — don't retry
                        text = await resp.text()
                        raise ValueError(f"Client error {resp.status}: {text}")
            except asyncio.TimeoutError:
                logger.warning(f"Timeout on attempt {attempt + 1}")
                await asyncio.sleep(2 ** attempt)

        raise RuntimeError(f"Failed after {self.max_retries} attempts: {endpoint}")

    async def fetch_many(self, requests: list[dict], concurrency: int = 10) -> list[dict]:
        """Fetch multiple endpoints concurrently with bounded parallelism."""
        semaphore = asyncio.Semaphore(concurrency)
        results = []

        async def bounded_fetch(req):
            async with semaphore:
                return await self.fetch(req["endpoint"], req.get("params"))

        tasks = [bounded_fetch(req) for req in requests]
        results = await asyncio.gather(*tasks, return_exceptions=True)

        # Separate successes from failures
        successes = [r for r in results if not isinstance(r, Exception)]
        failures = [r for r in results if isinstance(r, Exception)]

        if failures:
            logger.error(f"{len(failures)} requests failed out of {len(results)}")

        return successes


# Usage:
async def extract_product_details(product_ids: list[str]) -> list[dict]:
    """Extract details for a list of product IDs with rate limiting."""
    async with ResilientAPIClient(
        "https://api.nike.internal",
        api_key="secret",
        max_rps=80  # Stay under 100 limit with safety margin
    ) as client:
        requests = [
            {"endpoint": f"products/{pid}", "params": {"include": "inventory"}}
            for pid in product_ids
        ]
        return await client.fetch_many(requests, concurrency=20)
```

### Follow-Up Probes:

**Probe:** "Why 80 requests/sec when the limit is 100?"

**Strong answer:** "Safety margin. Rate limits are often per-minute rolling windows, not per-second. If I burst to 100/sec for a second but the window hasn't rolled, I'll get 429s. Also, if multiple instances of my service are running, they share the limit. I'd rather under-utilize slightly than trigger rate limiting and pay the exponential backoff penalty. In production I'd use a distributed rate limiter (Redis token bucket) if multiple workers share the quota."

**Probe:** "When would you use async vs threading vs multiprocessing?"

**Strong answer:**
- **Async (asyncio):** IO-bound tasks like API calls, database queries. One thread, cooperative multitasking. Best for 100+ concurrent IO operations. This is what I'd use for bulk API extraction.
- **Threading:** IO-bound tasks when the library doesn't support async (e.g., some database drivers). Limited by GIL for CPU work.
- **Multiprocessing:** CPU-bound tasks like data transformation, parsing, hash computation. Bypasses GIL. But IPC overhead is high — only worth it for heavy computation.
- "For data engineering pipelines: async for extraction (network IO), multiprocessing for CPU-heavy transforms (JSON parsing millions of records), and neither needed for loads (usually one bulk operation)."

---

### Exercise 3: Implement a Schema Evolution Handler

**Interviewer says:** "Your pipeline receives JSON data from a source that occasionally adds new fields or changes field types. Write a Python module that detects schema changes, handles them gracefully, and alerts on breaking changes."

```python
import json
from datetime import datetime
from enum import Enum
from typing import Any

class ChangeType(Enum):
    FIELD_ADDED = "field_added"           # Non-breaking
    FIELD_REMOVED = "field_removed"       # Breaking
    TYPE_CHANGED = "type_changed"         # Breaking
    NULLABLE_CHANGED = "nullable_changed" # Potentially breaking
    FIELD_RENAMED = "field_renamed"       # Breaking (detected heuristically)

class SchemaChange:
    def __init__(self, change_type: ChangeType, field: str, details: dict):
        self.change_type = change_type
        self.field = field
        self.details = details
        self.is_breaking = change_type in (
            ChangeType.FIELD_REMOVED,
            ChangeType.TYPE_CHANGED,
        )
        self.timestamp = datetime.utcnow()

    def __repr__(self):
        severity = "BREAKING" if self.is_breaking else "non-breaking"
        return f"[{severity}] {self.change_type.value}: {self.field} - {self.details}"


class SchemaEvolutionHandler:
    """
    Detects and handles schema changes between expected and actual data.
    Production pattern: compare incoming batch schema against registered schema.
    """

    def __init__(self, registered_schema: dict[str, type]):
        """
        registered_schema: {"field_name": expected_python_type, ...}
        Example: {"user_id": str, "amount": float, "is_active": bool}
        """
        self.registered_schema = registered_schema
        self.changes_log: list[SchemaChange] = []

    def detect_changes(self, sample_records: list[dict]) -> list[SchemaChange]:
        """Detect schema changes from a sample of incoming records."""
        if not sample_records:
            return []

        # Infer actual schema from sample
        actual_schema = self._infer_schema(sample_records)
        changes = []

        # Check for removed fields (in registered, not in actual)
        for field in self.registered_schema:
            if field not in actual_schema:
                changes.append(SchemaChange(
                    ChangeType.FIELD_REMOVED, field,
                    {"expected_type": self.registered_schema[field].__name__}
                ))

        # Check for new fields (in actual, not in registered)
        for field in actual_schema:
            if field not in self.registered_schema:
                changes.append(SchemaChange(
                    ChangeType.FIELD_ADDED, field,
                    {"detected_type": actual_schema[field].__name__}
                ))

        # Check for type changes
        for field in set(self.registered_schema) & set(actual_schema):
            expected_type = self.registered_schema[field]
            actual_type = actual_schema[field]
            if expected_type != actual_type:
                changes.append(SchemaChange(
                    ChangeType.TYPE_CHANGED, field,
                    {"expected": expected_type.__name__, "actual": actual_type.__name__}
                ))

        self.changes_log.extend(changes)
        return changes

    def apply_strategy(self, records: list[dict], changes: list[SchemaChange]) -> list[dict]:
        """Apply schema evolution strategy to records."""
        breaking_changes = [c for c in changes if c.is_breaking]

        if breaking_changes:
            # Strategy: fail fast on breaking changes
            raise SchemaBreakingChangeError(
                f"Breaking schema changes detected: {breaking_changes}. "
                f"Manual intervention required."
            )

        # For non-breaking (new fields): pass through — add to schema registry
        new_fields = [c for c in changes if c.change_type == ChangeType.FIELD_ADDED]
        for change in new_fields:
            # In production: auto-register new fields, alert team, add to Delta with mergeSchema
            logger.info(f"New field detected: {change.field}. Auto-registering.")

        return records  # Pass through — downstream handles new columns

    def _infer_schema(self, records: list[dict]) -> dict[str, type]:
        """Infer schema from sample records (majority type wins per field)."""
        field_types: dict[str, dict[str, int]] = {}

        for record in records:
            for field, value in record.items():
                if value is not None:
                    type_name = type(value).__name__
                    field_types.setdefault(field, {})
                    field_types[field][type_name] = field_types[field].get(type_name, 0) + 1

        # Pick majority type per field
        inferred = {}
        type_map = {"str": str, "int": int, "float": float, "bool": bool, "list": list, "dict": dict}
        for field, type_counts in field_types.items():
            dominant_type = max(type_counts, key=type_counts.get)
            inferred[field] = type_map.get(dominant_type, str)

        return inferred


class SchemaBreakingChangeError(Exception):
    pass
```

### Production Integration:

**How this fits in a pipeline:**
```python
# In the pipeline's transform step:
handler = SchemaEvolutionHandler(registered_schema=load_schema_from_registry())

# Sample first 100 records for schema detection
changes = handler.detect_changes(raw_records[:100])

if changes:
    logger.warning(f"Schema changes detected: {changes}")
    send_alert(channel="data-eng-alerts", changes=changes)

    # Apply strategy (will raise on breaking changes)
    processed = handler.apply_strategy(raw_records, changes)
else:
    processed = raw_records
```

**Bridge to your experience:** "In DBT, schema testing is post-hoc (dbt test catches issues after the run). This pattern is PRE-RUN validation — catch schema drift before it enters the pipeline. It's the equivalent of Delta's `mergeSchema` option, but as application-level logic for non-Delta sources."

---

## SECTION C: PYTHON PERFORMANCE PATTERNS FOR DATA ENGINEERING

### Pattern: Generator-Based Processing for Large Files

**Problem:** Process a 50GB JSON-lines file without loading it all into memory.

```python
import json
from typing import Generator, Iterator

def stream_jsonl(file_path: str) -> Generator[dict, None, None]:
    """Memory-efficient line-by-line JSON processing."""
    with open(file_path, 'r') as f:
        for line_num, line in enumerate(f, 1):
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError as e:
                logger.warning(f"Malformed JSON at line {line_num}: {e}")
                continue  # Skip bad lines, don't crash


def batch_records(records: Iterator[dict], batch_size: int = 10000) -> Generator[list[dict], None, None]:
    """Group records into batches for bulk operations."""
    batch = []
    for record in records:
        batch.append(record)
        if len(batch) >= batch_size:
            yield batch
            batch = []
    if batch:  # Don't forget the last partial batch
        yield batch


# Usage: process 50GB file in 10K-record batches
def process_large_file(file_path: str, output_path: str):
    records = stream_jsonl(file_path)
    transformed = (transform(r) for r in records)  # Lazy — no memory spike

    for i, batch in enumerate(batch_records(transformed, 10000)):
        # Write each batch (e.g., to Parquet, to DB, to API)
        write_batch(batch, output_path, partition=i)
        logger.info(f"Processed batch {i}: {len(batch)} records")
```

**Why generators matter in interview:** "Generators are Python's answer to streaming semantics. Instead of `records = [transform(r) for r in huge_file]` (loads everything into memory), I use generator chains that process one record at a time with constant memory. This is the Python equivalent of Spark's lazy evaluation — the pipeline only materializes at the 'action' point (writing the batch)."

### Pattern: Multiprocessing for CPU-Bound Transforms

```python
from multiprocessing import Pool, cpu_count
from functools import partial

def heavy_transform(record: dict, config: dict) -> dict:
    """CPU-intensive transformation (e.g., parsing, hashing, NLP)."""
    # Expensive operation
    record["hash"] = hashlib.sha256(json.dumps(record, sort_keys=True).encode()).hexdigest()
    record["parsed_address"] = parse_address(record.get("address", ""))
    return record

def parallel_transform(records: list[dict], config: dict, workers: int = None) -> list[dict]:
    """Process records in parallel using multiprocessing."""
    workers = workers or max(1, cpu_count() - 1)
    transform_fn = partial(heavy_transform, config=config)

    with Pool(workers) as pool:
        results = pool.map(transform_fn, records, chunksize=1000)

    return results
```

**When to use this:** "Only for CPU-bound work where records are independent. For IO-bound (API calls, DB queries), use asyncio. For PySpark workloads, the parallelism is already handled by Spark executors — don't add multiprocessing inside a UDF."

---

## SECTION D: ERROR HANDLING & OBSERVABILITY PATTERNS

### The Production Error Handling Hierarchy

```python
import traceback
from contextlib import contextmanager

@contextmanager
def pipeline_error_handler(pipeline_name: str, execution_date: str):
    """
    Centralized error handling for pipeline execution.
    Catches, logs, classifies, and re-raises with context.
    """
    start_time = time.time()
    try:
        yield
        duration = time.time() - start_time
        logger.info(f"Pipeline {pipeline_name} completed in {duration:.1f}s")
        emit_metric("pipeline.success", tags={"pipeline": pipeline_name})

    except requests.exceptions.ConnectionError as e:
        emit_metric("pipeline.failure", tags={"pipeline": pipeline_name, "type": "connection"})
        send_alert(f"🔴 {pipeline_name}: Connection failed. Likely upstream outage.", severity="high")
        raise

    except requests.exceptions.HTTPError as e:
        status = e.response.status_code
        if status == 401:
            send_alert(f"🔴 {pipeline_name}: Auth failed. Credentials may have rotated.", severity="critical")
        elif status == 429:
            send_alert(f"🟡 {pipeline_name}: Rate limited. Will retry.", severity="medium")
        raise

    except SchemaBreakingChangeError as e:
        emit_metric("pipeline.failure", tags={"pipeline": pipeline_name, "type": "schema_drift"})
        send_alert(f"🔴 {pipeline_name}: Breaking schema change. Manual fix needed.\n{e}", severity="critical")
        raise

    except ValueError as e:
        # Data quality failures
        emit_metric("pipeline.failure", tags={"pipeline": pipeline_name, "type": "data_quality"})
        send_alert(f"🟡 {pipeline_name}: Data quality threshold breached.\n{e}", severity="high")
        raise

    except Exception as e:
        # Unexpected errors
        emit_metric("pipeline.failure", tags={"pipeline": pipeline_name, "type": "unexpected"})
        send_alert(
            f"🔴 {pipeline_name}: Unexpected error: {type(e).__name__}\n"
            f"{traceback.format_exc()[-500:]}",  # Last 500 chars of traceback
            severity="critical"
        )
        raise


# Usage:
with pipeline_error_handler("inventory_etl", "2024-06-15"):
    run_pipeline("2024-06-15", config)
```

### Interview Talking Point:

"In production, I classify errors into:
1. **Transient** (connection timeouts, 429s, spot interruption) → auto-retry with backoff
2. **Data quality** (too many nulls, schema drift) → alert team, don't retry (retrying won't fix bad data)
3. **Configuration** (expired credentials, wrong endpoint) → alert immediately, no retry
4. **Unexpected** (unhandled exceptions) → alert critical, on-call investigates

Each class gets different retry behavior, different alert severity, and different runbook actions. This is what separates a script from a production pipeline."

---

## SECTION E: PYTHON INTERVIEW QUICK-FIRE QUESTIONS

### Q: "Difference between `deepcopy` and regular assignment?"

```python
import copy

original = {"users": [{"name": "Alice"}]}
shallow = original.copy()        # New dict, but inner list is SAME reference
deep = copy.deepcopy(original)   # Completely independent copy

original["users"][0]["name"] = "Bob"
# shallow["users"][0]["name"] == "Bob"  (shared reference!)
# deep["users"][0]["name"] == "Alice"   (independent)
```

"In data pipelines: if I transform a record and need to keep the original for audit, I deepcopy before transforming. Otherwise mutations propagate and debugging becomes impossible."

### Q: "How do you handle memory when processing large DataFrames in Pandas?"

**Strong answer:**
1. **Read in chunks:** `pd.read_csv(path, chunksize=100000)` → iterator of DataFrames
2. **Downcast types:** `df['col'].astype('int32')` instead of default int64 — 50% memory savings
3. **Drop columns early:** `df.drop(columns=[...], inplace=True)`
4. **Use categorical for low-cardinality strings:** `df['status'] = df['status'].astype('category')` — 90% savings on repeated strings
5. **Process and write incrementally:** don't accumulate results in memory
6. "But honestly — if data exceeds ~10GB, Pandas is the wrong tool. That's where PySpark takes over. Pandas is for single-machine data exploration and small transforms."

### Q: "What's a context manager and when do you use them in pipelines?"

```python
# Custom context manager for database connections
from contextlib import contextmanager

@contextmanager
def db_connection(connection_string: str):
    """Ensures connection is always closed, even on error."""
    conn = psycopg2.connect(connection_string)
    try:
        yield conn
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()

# Usage:
with db_connection(DB_URL) as conn:
    cursor = conn.cursor()
    cursor.execute("INSERT INTO ...")
    # Connection auto-closes and commits/rollbacks properly
```

"I use context managers everywhere resources need cleanup: DB connections, file handles, temp directories, API sessions, Spark sessions. It's defensive coding — guarantees cleanup even when exceptions fly."

### Q: "Explain decorators with a practical data engineering example."

```python
import functools
import time

def log_execution(func):
    """Decorator that logs function execution time and arguments."""
    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        start = time.time()
        logger.info(f"Starting {func.__name__} with args={args[:2]}...")  # Truncate large args
        try:
            result = func(*args, **kwargs)
            duration = time.time() - start
            logger.info(f"Completed {func.__name__} in {duration:.2f}s")
            return result
        except Exception as e:
            duration = time.time() - start
            logger.error(f"Failed {func.__name__} after {duration:.2f}s: {e}")
            raise
    return wrapper

def validate_output(min_rows: int = 1):
    """Decorator that validates the output DataFrame has minimum rows."""
    def decorator(func):
        @functools.wraps(func)
        def wrapper(*args, **kwargs):
            result = func(*args, **kwargs)
            if hasattr(result, '__len__') and len(result) < min_rows:
                raise ValueError(
                    f"{func.__name__} produced {len(result)} rows, "
                    f"minimum expected: {min_rows}"
                )
            return result
        return wrapper
    return decorator

@log_execution
@validate_output(min_rows=100)
def transform_daily_sales(raw_data: list[dict]) -> list[dict]:
    """Transform raw sales data. Auto-logged and validated."""
    return [process(r) for r in raw_data if r.get("amount", 0) > 0]
```

"Decorators let me add cross-cutting concerns (logging, validation, retries, metrics) without polluting business logic. In a pipeline with 20 transform functions, I decorate all of them with `@log_execution` and `@validate_output` — observability for free."
