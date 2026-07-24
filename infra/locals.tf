locals {
  billing_project = coalesce(var.billing_export_project_id, var.project_id)

  ar_hostname        = "${var.region}-docker.pkg.dev"
  opencost_image     = "${local.ar_hostname}/${var.project_id}/${google_artifact_registry_repository.opencost.repository_id}/opencost"
  opencost_image_ref = "${local.opencost_image}:${var.image_tag}"

  labels = {
    app         = "opencost"
    component   = "cloudcost"
    managed_by  = "opentofu"
    name_prefix = var.name_prefix
  }
}
