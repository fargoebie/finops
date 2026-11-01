# Read-only BigQuery identity for grokbot (finops_dbt marts only).

resource "google_service_account" "grokbot" {
  account_id   = "${var.name_prefix}-grokbot"
  display_name = "Grokbot (read-only BigQuery)"
  description  = "Read-only BigQuery access to the finops_dbt marts for grokbot"
  project      = var.project_id

  depends_on = [google_project_service.required]
}

# Run query jobs in this project. Nothing else at project level.
resource "google_project_iam_member" "grokbot_bq_job_user" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.grokbot.email}"
}

# Dataset-level read only. Member resource on purpose: dbt owns the dataset, so
# never use _iam_policy / _iam_binding / dataset_access here.
resource "google_bigquery_dataset_iam_member" "grokbot_dataset_viewer" {
  project    = var.project_id
  dataset_id = var.grokbot_dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = "serviceAccount:${google_service_account.grokbot.email}"
}

# No google_service_account_key here: it would write the private key into state.
# The key is created out-of-band (see docs/plans/grokbot-bq-integration.md, Phase 2).
