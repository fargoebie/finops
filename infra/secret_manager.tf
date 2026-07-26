# B. Managed secrets — value injected by reference; per-secret accessor only.

resource "google_secret_manager_secret" "metabase_db_password" {
  secret_id = "${var.name_prefix}-metabase-db-password"
  project   = var.project_id

  replication {
    auto {}
  }

  labels = local.labels

  depends_on = [google_project_service.required]
}

resource "google_secret_manager_secret_iam_member" "metabase_db_password_accessor" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.metabase_db_password.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.finops_vm.email}"
}

resource "google_secret_manager_secret_version" "metabase_db_password" {
  count = var.metabase_db_password == null ? 0 : 1

  secret      = google_secret_manager_secret.metabase_db_password.id
  secret_data = var.metabase_db_password

  lifecycle {
    ignore_changes = [secret_data]
  }
}

# Metabase BigQuery SA key — created manually; import with:
#   tofu import google_secret_manager_secret.metabase_bq_key \
#     projects/gcp-coe-492507/secrets/finops-metabase-bq-key
resource "google_secret_manager_secret" "metabase_bq_key" {
  secret_id = "${var.name_prefix}-metabase-bq-key"
  project   = var.project_id

  replication {
    auto {}
  }

  labels = local.labels

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.required]
}

resource "google_secret_manager_secret_iam_member" "metabase_bq_key_accessor" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.metabase_bq_key.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.finops_vm.email}"
}

# Seed a random placeholder when no initial value is provided.
resource "terraform_data" "seed_metabase_db_password" {
  input = {
    project = var.project_id
    secret  = google_secret_manager_secret.metabase_db_password.secret_id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-ce"]
    environment = {
      PROJECT = var.project_id
      SECRET  = google_secret_manager_secret.metabase_db_password.secret_id
    }
    command = <<-EOT
      enabled="$(gcloud secrets versions list "$${SECRET}" \
        --project="$${PROJECT}" \
        --filter='state:ENABLED' \
        --format='value(name)' 2>/dev/null | wc -l | tr -d ' ')"
      if [[ "$${enabled}" -eq 0 ]]; then
        openssl rand -base64 32 | tr -d '\n' | \
          gcloud secrets versions add "$${SECRET}" --project="$${PROJECT}" --data-file=-
        echo "Seeded random password for $${SECRET}"
      else
        echo "Secret $${SECRET} already has $${enabled} version(s); skip seed"
      fi
    EOT
  }

  depends_on = [
    google_secret_manager_secret.metabase_db_password,
    google_secret_manager_secret_version.metabase_db_password,
  ]
}
