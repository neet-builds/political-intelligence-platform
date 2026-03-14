provider "google" {
  project = var.project_id
  region  = var.region
}

# 1. Create the GCS Bucket (Data Lake)
resource "google_storage_bucket" "data_lake" {
  name          = "${var.project_id}-data-lake"
  location      = var.region
  force_destroy = true

  public_access_prevention = "enforced"
}

# 2. Create BigQuery Datasets
resource "google_bigquery_dataset" "raw_dataset" {
  dataset_id = "political_raw"
  location   = var.region
}

resource "google_bigquery_dataset" "staging_dataset" {
  dataset_id = "political_staging"
  location   = var.region
}

resource "google_bigquery_dataset" "marts_dataset" {
  dataset_id = "political_marts"
  location   = var.region
}
