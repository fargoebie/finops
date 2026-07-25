output "runtime_service_account_email" {
  description = "Dedicated Cloud Run runtime service account."
  value       = google_service_account.opencost_cloudcost.email
}

output "artifact_registry_repository" {
  description = "Artifact Registry repository ID."
  value       = google_artifact_registry_repository.opencost.id
}

output "opencost_image" {
  description = "Fully-qualified API image name (without tag)."
  value       = local.opencost_image
}

output "opencost_ui_image" {
  description = "Fully-qualified UI image name (without tag)."
  value       = local.opencost_ui_image
}

output "cloud_run_service_uri" {
  description = "Cloud Run service URI (FinOps SPA ingress; use /model/cloudCost* for API)."
  value       = google_cloud_run_v2_service.opencost.uri
}

output "cloud_run_ui_url" {
  description = "FinOps SPA home on the public service URL."
  value       = "${google_cloud_run_v2_service.opencost.uri}/"
}

output "cloud_run_service_name" {
  value = google_cloud_run_v2_service.opencost.name
}

output "vpc_network" {
  value = google_compute_network.main.name
}

output "vpc_subnet" {
  value = google_compute_subnetwork.main.name
}

output "secret_cloud_integration_id" {
  value = google_secret_manager_secret.cloud_integration.id
}

output "secret_admin_token_id" {
  value = google_secret_manager_secret.admin_token.id
}

output "monitoring_dashboard_id" {
  value = google_monitoring_dashboard.opencost.id
}
