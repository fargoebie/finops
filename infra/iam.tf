# A. Dedicated least-privilege VM service account.

resource "google_service_account" "finops_vm" {
  account_id   = "${var.name_prefix}-vm"
  display_name = "FinOps VM (Metabase + dbt)"
  description  = "Runtime identity for Metabase and dbt on the FinOps e2-medium VM"
  project      = var.project_id

  depends_on = [google_project_service.required]
}

resource "google_project_iam_member" "finops_vm_bq_data_viewer" {
  project = local.billing_project
  role    = "roles/bigquery.dataViewer"
  member  = "serviceAccount:${google_service_account.finops_vm.email}"
}

resource "google_project_iam_member" "finops_vm_bq_job_user" {
  project = local.billing_project
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.finops_vm.email}"
}

resource "google_project_iam_member" "finops_vm_bq_user" {
  project = local.billing_project
  role    = "roles/bigquery.user"
  member  = "serviceAccount:${google_service_account.finops_vm.email}"
}

# H. Observability
resource "google_project_iam_member" "finops_vm_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.finops_vm.email}"
}

resource "google_project_iam_member" "finops_vm_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.finops_vm.email}"
}

# D. IAP SSH — no public port 22.
resource "google_iap_tunnel_instance_iam_binding" "ssh" {
  project  = var.project_id
  zone     = var.zone
  instance = google_compute_instance.finops_vm.name
  role     = "roles/iap.tunnelResourceAccessor"
  members  = var.iap_ssh_members

  depends_on = [google_project_service.required]
}
