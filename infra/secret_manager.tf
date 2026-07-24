# B. Managed secrets — values injected by reference; per-secret accessor only.
#
# Bootstrap: empty secret shells cannot be mounted by Cloud Run (version=latest).
# terraform_data.seed_secret_versions adds an enabled version only when the secret
# has none — safe for greenfield and for re-apply on an already-seeded project.
# Day-2 updates: ./scripts/deploy.sh sync-secrets (not tofu vars).

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

# Optional explicit first version via -var (ignore later drift from deploy.sh).
resource "google_secret_manager_secret_version" "cloud_integration" {
  count = var.cloud_integration_json == null ? 0 : 1

  secret      = google_secret_manager_secret.cloud_integration.id
  secret_data = var.cloud_integration_json

  lifecycle {
    ignore_changes = [secret_data]
  }
}

resource "google_secret_manager_secret_version" "admin_token" {
  count = var.admin_token == null ? 0 : 1

  secret      = google_secret_manager_secret.admin_token.id
  secret_data = var.admin_token

  lifecycle {
    ignore_changes = [secret_data]
  }
}

# Seed enabled versions when secrets are empty so Cloud Run can mount latest.
# Skips when versions already exist (does not clobber deploy.sh / live tokens).
resource "terraform_data" "seed_secret_versions" {
  input = {
    project            = var.project_id
    integration_secret = google_secret_manager_secret.cloud_integration.secret_id
    admin_secret       = google_secret_manager_secret.admin_token.secret_id
    integration_file   = "${path.module}/examples/cloud-integration.demogcp-terra2021.json"
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-ce"]
    environment = {
      PROJECT          = var.project_id
      INT_SECRET       = google_secret_manager_secret.cloud_integration.secret_id
      ADM_SECRET       = google_secret_manager_secret.admin_token.secret_id
      INT_FILE         = "${path.module}/examples/cloud-integration.demogcp-terra2021.json"
      ADMIN_TOKEN_SEED = coalesce(var.admin_token, "bootstrap-replace-via-deploy-sh")
    }
    command = <<-EOT
      seed_if_empty() {
        local secret="$1"
        local data_file="$2"
        local enabled
        enabled="$(gcloud secrets versions list "$${secret}" \
          --project="$${PROJECT}" \
          --filter='state:ENABLED' \
          --format='value(name)' 2>/dev/null | wc -l | tr -d ' ')"
        if [[ "$${enabled}" -eq 0 ]]; then
          gcloud secrets versions add "$${secret}" \
            --project="$${PROJECT}" \
            --data-file="$${data_file}"
          echo "Seeded secret $${secret}"
        else
          echo "Secret $${secret} already has $${enabled} enabled version(s); skip seed"
        fi
      }

      if [[ ! -f "$${INT_FILE}" ]]; then
        echo "Missing cloud-integration seed file: $${INT_FILE}" >&2
        exit 1
      fi
      if grep -q 'PRIVATE KEY' "$${INT_FILE}"; then
        echo "Refusing to seed cloud-integration with a private key." >&2
        exit 1
      fi
      seed_if_empty "$${INT_SECRET}" "$${INT_FILE}"

      ADM_TMP="$(mktemp)"
      printf '%s' "$${ADMIN_TOKEN_SEED}" > "$${ADM_TMP}"
      seed_if_empty "$${ADM_SECRET}" "$${ADM_TMP}"
      rm -f "$${ADM_TMP}"
    EOT
  }

  depends_on = [
    google_secret_manager_secret.cloud_integration,
    google_secret_manager_secret.admin_token,
    google_secret_manager_secret_version.cloud_integration,
    google_secret_manager_secret_version.admin_token,
  ]
}
