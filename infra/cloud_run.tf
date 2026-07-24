# E/G/H. Cloud Run service — IAM auth required, secrets by reference, private AR image, VPC egress.

resource "google_cloud_run_v2_service" "opencost" {
  name     = "${var.name_prefix}-cloudcost"
  project  = var.project_id
  location = var.region
  ingress  = "INGRESS_TRAFFIC_ALL"

  labels = local.labels

  # Do not allow unauthenticated access (principle E).
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

    containers {
      name  = "opencost"
      image = local.opencost_image_ref

      ports {
        container_port = 9003
      }

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
    # deploy.sh updates image tags; avoid thrash if apply uses a stale default tag.
    ignore_changes = [
      client,
      client_version,
      template[0].containers[0].image,
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
