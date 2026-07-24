# B. Managed secrets — values injected by reference; per-secret accessor only.

resource "google_secret_manager_secret" "cloud_integration" {
  secret_id = "${var.name_prefix}-cloud-integration"
  project   = var.project_id

  replication {
    auto {}
  }

  labels = local.labels

  depends_on = [google_project_service.required]
}

resource "google_secret_manager_secret" "admin_token" {
  secret_id = "${var.name_prefix}-admin-token"
  project   = var.project_id

  replication {
    auto {}
  }

  labels = local.labels

  depends_on = [google_project_service.required]
}

resource "google_secret_manager_secret_iam_member" "cloud_integration_accessor" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.cloud_integration.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.opencost_cloudcost.email}"
}

resource "google_secret_manager_secret_iam_member" "admin_token_accessor" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.admin_token.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.opencost_cloudcost.email}"
}

# Optional seed versions (pass -var=... at apply). Prefer deploy.sh for day-2 updates.
resource "google_secret_manager_secret_version" "cloud_integration" {
  count = var.cloud_integration_json == null ? 0 : 1

  secret      = google_secret_manager_secret.cloud_integration.id
  secret_data = var.cloud_integration_json
}

resource "google_secret_manager_secret_version" "admin_token" {
  count = var.admin_token == null ? 0 : 1

  secret      = google_secret_manager_secret.admin_token.id
  secret_data = var.admin_token
}
