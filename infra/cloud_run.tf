# E/G/H. Cloud Run service — UI+API multi-container, secrets by reference, private AR, VPC egress.
#
# Option B: UI (nginx :9090) is the ingress container and proxies /model/* to the
# API sidecar at http://127.0.0.1:9003 (stock UI image is HTTP-only upstream).

resource "google_cloud_run_v2_service" "opencost" {
  name     = "${var.name_prefix}-cloudcost"
  project  = var.project_id
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  labels = local.labels

  invoker_iam_disabled = false

  template {
    service_account = google_service_account.opencost_cloudcost.email

    scaling {
      min_instance_count = var.cloud_run_min_instances
      max_instance_count = var.cloud_run_max_instances
    }

    # C. Direct VPC egress + Private Google Access on subnet for BigQuery APIs.
    vpc_access {
      egress = "PRIVATE_RANGES_ONLY"
      network_interfaces {
        network    = google_compute_network.main.name
        subnetwork = google_compute_subnetwork.main.name
      }
    }

    # Ingress container — OpenCost UI (public URL serves SPA + /model proxy).
    containers {
      name  = "opencost-ui"
      image = local.opencost_ui_image_ref

      ports {
        container_port = 9090
      }

      resources {
        limits = {
          cpu    = var.cloud_run_ui_cpu
          memory = var.cloud_run_ui_memory
        }
      }

      env {
        name  = "API_SERVER"
        value = "127.0.0.1"
      }
      env {
        name  = "API_PORT"
        value = "9003"
      }
      env {
        name  = "UI_PORT"
        value = "9090"
      }
      env {
        name  = "BASE_URL"
        value = "/model"
      }
      env {
        name  = "UI_PATH"
        value = "/"
      }
      # New default UI (React Router) has no /cloud route. Legacy UI exposes
      # Cloud Costs at /cloud, which is what cloud-cost-only deploys need.
      env {
        name  = "LEGACY_MODE"
        value = "true"
      }

      depends_on = ["opencost"]

      startup_probe {
        http_get {
          path = "/healthz"
          port = 9090
        }
        initial_delay_seconds = 2
        period_seconds        = 5
        failure_threshold     = 5
      }
    }

    # Sidecar — OpenCost cloud-cost API (no ports; reached via localhost only).
    containers {
      name  = "opencost"
      image = local.opencost_image_ref

      resources {
        limits = {
          cpu    = var.cloud_run_cpu
          memory = var.cloud_run_memory
        }
      }

      env {
        name  = "CLOUD_COST_ENABLED"
        value = "true"
      }
      env {
        name  = "CONFIG_PATH"
        value = "/var/configs"
      }
      env {
        name  = "API_PORT"
        value = "9003"
      }
      env {
        name  = "CLOUD_COST_REFRESH_RATE_HOURS"
        value = tostring(var.cloud_cost_refresh_rate_hours)
      }
      env {
        name  = "CLOUD_COST_RUN_WINDOW_DAYS"
        value = tostring(var.cloud_cost_run_window_days)
      }
      env {
        name  = "CLOUD_COST_QUERY_WINDOW_DAYS"
        value = tostring(var.cloud_cost_query_window_days)
      }

      # B. ADMIN_TOKEN by secret reference (not a literal).
      env {
        name = "ADMIN_TOKEN"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.admin_token.secret_id
            version = "latest"
          }
        }
      }

      volume_mounts {
        name       = "cloud-integration"
        mount_path = "/var/configs"
      }

      startup_probe {
        tcp_socket {
          port = 9003
        }
        initial_delay_seconds = 2
        period_seconds        = 5
        failure_threshold     = 12
      }
    }

    volumes {
      name = "cloud-integration"
      secret {
        secret = google_secret_manager_secret.cloud_integration.secret_id
        items {
          path    = "cloud-integration.json"
          version = "latest"
        }
      }
    }
  }

  traffic {
    type    = "TRAFFIC_TARGET_ALLOCATION_TYPE_LATEST"
    percent = 100
  }

  depends_on = [
    google_project_service.required,
    google_secret_manager_secret_iam_member.cloud_integration_accessor,
    google_secret_manager_secret_iam_member.admin_token_accessor,
    google_artifact_registry_repository.opencost,
  ]

  lifecycle {
    ignore_changes = [
      client,
      client_version,
      # Images are updated by deploy.sh (git sha tags). Do not ignore by container
      # index — reordering (e.g. adding the UI ingress) previously left the UI
      # container stuck on the API image digest.
    ]
  }
}

resource "google_cloud_run_v2_service_iam_member" "invokers" {
  for_each = toset(var.invoker_members)

  project  = var.project_id
  location = google_cloud_run_v2_service.opencost.location
  name     = google_cloud_run_v2_service.opencost.name
  role     = "roles/run.invoker"
  member   = each.value
}
