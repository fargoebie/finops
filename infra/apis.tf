locals {
  required_apis = toset([
    "secretmanager.googleapis.com",
    "bigquery.googleapis.com",
    "iam.googleapis.com",
    "compute.googleapis.com",
    "iap.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
    "cloudtrace.googleapis.com",
  ])
}

resource "google_project_service" "required" {
  for_each = local.required_apis

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}
