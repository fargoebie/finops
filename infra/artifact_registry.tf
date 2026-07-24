# G. Private, project-owned container registry.

resource "google_artifact_registry_repository" "opencost" {
  project       = var.project_id
  location      = var.region
  repository_id = var.name_prefix
  description   = "Private OpenCost images for Cloud Run"
  format        = "DOCKER"

  labels = local.labels

  depends_on = [google_project_service.required]
}
