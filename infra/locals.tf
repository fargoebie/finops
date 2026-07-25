locals {
  billing_project = coalesce(var.billing_export_project_id, var.project_id)

  labels = {
    app        = "finops"
    managed_by = "opentofu"
    prefix     = var.name_prefix
  }
}
