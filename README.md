# Indian Political Intelligence Platform (IPIP)

## Overview
The Indian Political Intelligence Platform (IPIP) is a production-style data engineering project that builds an end-to-end political analytics platform on Google Cloud.

The platform aggregates political datasets such as election results, media coverage, and public discourse to generate insights about political trends, media narratives, and sentiment around key political figures.

The system demonstrates a modern data engineering stack with batch ingestion, warehouse modeling, orchestration, data quality, and BI analytics.

## Problem Statement
Political datasets are distributed across multiple sources and formats:
* Election results released by the Election Commission of India
* Political news articles from major media outlets
* Public political discourse and commentary

These datasets are difficult to analyze together because they are fragmented, partially unstructured, and updated independently. This project builds a scalable data platform that ingests these datasets, processes structured and unstructured information, performs sentiment analysis on political discourse, and delivers insights through analytics dashboards.

## Key Objectives
The platform is designed to answer questions such as:

### Election Analysis
* How has vote share changed across elections?
* Which parties dominate specific states?

### Media Coverage Analysis
* Which politicians receive the most media coverage?
* Which media outlets publish the most political articles?

### Sentiment Analysis
* How does sentiment toward a political leader change over time?
* Which political events trigger sentiment spikes?

## High-Level Architecture
The platform follows a modern lakehouse-style data architecture. Data flows through the following stages:

1. **Data Sources:** Election results, News articles, Public discourse.
2. **Ingestion Layer:** Python ingestion pipelines / Airflow.
3. **Data Lake:** Raw data stored in Google Cloud Storage (GCS).
4. **Processing Layer:** Spark / Python for text processing and NLP.
5. **Data Warehouse:** Structured analytical storage in BigQuery.
6. **Transformation Layer:** dbt models for warehouse modeling.
7. **Analytics Layer:** BI dashboards using Power BI or Tableau.

> Detailed architecture diagram: [architecture/diagram.md](architecture/diagram.md)

## Data Warehouse Schema
The warehouse follows a star schema with fact and dimension tables.

**Fact Tables:** `fact_election_results`, `fact_news_sentiment`, `fact_politician_mentions`
**Dimension Tables:** `dim_politicians`, `dim_parties`, `dim_states`, `dim_dates`

> Full schema design: [docs/schema_design.md](docs/schema_design.md)

## Technology Stack
* **Cloud:** Google Cloud Platform (GCP)
* **Storage:** GCS, BigQuery
* **Processing:** Python, Apache Spark
* **Orchestration:** Apache Airflow
* **Transformation:** dbt
* **Infrastructure:** Terraform
* **Analytics:** Power BI / Tableau

## Development Phases
- [x] **Phase 1:** Architecture design and warehouse schema
- [ ] **Phase 2:** Infrastructure setup on Google Cloud
- [ ] **Phase 3:** Data ingestion pipelines
- [ ] **Phase 4:** Data lake and raw warehouse layer
- [ ] **Phase 5:** dbt transformations and data modeling
- [ ] **Phase 6:** Orchestration and data quality
- [ ] **Phase 7:** BI dashboards and analytics layer

