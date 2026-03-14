# Phase 2 — Infrastructure Design (GCP)

## 1. GCP Project Structure
* **Project Name:** `political-intelligence-platform`
* **Region:** `asia-south1` (Mumbai) or `us-central1`
* **Environment:** `dev` (Single project for portfolio scope)

## 2. Cloud Storage Design (Data Lake)
**Bucket Name:** `political-data-lake`

### Folder Layout:
* `gs://political-data-lake/raw/`: Original, immutable source data (JSON/CSV).
* `gs://political-data-lake/processed/`: Cleaned data, converted to Parquet for Spark.
* `gs://political-data-lake/analytics/`: Aggregated exports for external tools.

## 3. BigQuery Dataset Structure
Following a layered warehouse design to ensure data quality and lineage.

| Dataset | Purpose |
| :--- | :--- |
| `political_raw` | Landing zone for raw GCS data. |
| `political_staging` | Cleaned, casted, and deduplicated tables. |
| `political_marts` | Final Star Schema (Facts and Dimensions) for BI. |

## 4. Service Accounts & Security
**Service Account Name:** `data-platform-sa`

### IAM Roles Assigned:
* **BigQuery Admin:** Full access to manage datasets and run queries.
* **Storage Admin:** Full access to read/write from GCS buckets.
* **Composer Worker:** Required for Airflow to execute tasks.

## 5. Airflow Environment (Cloud Composer)
**Environment Name:** `political-data-composer`

### Core DAGs:
1. **data_ingestion:** Fetches data from APIs to GCS Raw.
2. **load_bigquery_raw:** Transfers GCS files to BigQuery Raw tables.
3. **run_dbt_transformation:** Triggers dbt to move data from Raw -> Staging -> Marts.

## 6. Infrastructure Flow Summary
1. **External APIs** -> **Airflow** -> **GCS (Raw)**
2. **GCS (Raw)** -> **Spark/NLP** -> **GCS (Processed)**
3. **GCS (Processed)** -> **BigQuery (Raw/Staging)**
4. **BigQuery (Staging)** -> **dbt** -> **BigQuery (Marts)**
5. **BigQuery (Marts)** -> **Power BI / Tableau**
