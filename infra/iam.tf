# A. Dedicated least-privilege runtime SA — never use the default Compute SA.

resource "google_service_account" "opencost_cloudcost" {
  account_id   = "${var.name_prefix}-cloudcost"
  display_name = "OpenCost Cloud Cost (Cloud Run)"
  description  = "Runtime identity for cloud-cost-only OpenCost on Cloud Run"
  project      = var.project_id

  depends_on = [google_project_service.required]
}

# BigQuery access for billing export (project-scoped jobUser is typical for BQ jobs).
resource "google_project_iam_member" "opencost_bq_data_viewer" {
  project = local.billing_project
  role    = "roles/bigquery.dataViewer"
  member  = "serviceAccount:${google_service_account.opencost_cloudcost.email}"
}

resource "google_project_iam_member" "opencost_bq_job_user" {
  project = local.billing_project
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.opencost_cloudcost.email}"
}

resource "google_project_iam_member" "opencost_bq_user" {
  project = local.billing_project
  role    = "roles/bigquery.user"
  member  = "serviceAccount:${google_service_account.opencost_cloudcost.email}"
}

# H. Observability
resource "google_project_iam_member" "opencost_trace_agent" {
  project = var.project_id
  role    = "roles/cloudtrace.agent"
  member  = "serviceAccount:${google_service_account.opencost_cloudcost.email}"
}

resource "google_project_iam_member" "opencost_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.opencost_cloudcost.email}"
}

# Allow Cloud Run runtime SA to pull from Artifact Registry in this project.
resource "google_project_iam_member" "opencost_ar_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.opencost_cloudcost.email}"
}
