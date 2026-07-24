variable "project_id" {
  description = "GCP project ID that hosts Cloud Run, Artifact Registry, and secrets."
  type        = string
}

variable "region" {
  description = "Primary region for Cloud Run, subnet, and Artifact Registry."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Primary zone (reserved for future zonal resources)."
  type        = string
  default     = "us-central1-a"
}

variable "name_prefix" {
  description = "Short prefix for resource names."
  type        = string
  default     = "opencost"
}

variable "billing_export_project_id" {
  description = "Project that owns the BigQuery billing export dataset (may equal project_id)."
  type        = string
  default     = null
}

variable "invoker_members" {
  description = "IAM members granted roles/run.invoker on the Cloud Run service (user: or serviceAccount:)."
  type        = list(string)
  default     = []
}

variable "image_tag" {
  description = "Immutable image tag in Artifact Registry (git sha or semver). Avoid 'latest' in prod."
  type        = string
  default     = "bootstrap"
}

variable "cloud_run_cpu" {
  description = "Cloud Run CPU limit for the API sidecar."
  type        = string
  default     = "1"
}

variable "cloud_run_memory" {
  description = "Cloud Run memory limit for the API sidecar."
  type        = string
  default     = "1Gi"
}

variable "cloud_run_ui_cpu" {
  description = "Cloud Run CPU limit for the UI ingress container."
  type        = string
  default     = "0.5"
}

variable "cloud_run_ui_memory" {
  description = "Cloud Run memory limit for the UI ingress container."
  type        = string
  default     = "256Mi"
}

variable "cloud_run_min_instances" {
  description = "Minimum Cloud Run instances."
  type        = number
  default     = 0
}

variable "cloud_run_max_instances" {
  description = "Maximum Cloud Run instances."
  type        = number
  default     = 2
}

variable "vpc_cidr" {
  description = "CIDR for the custom subnet."
  type        = string
  default     = "10.20.0.0/24"
}

variable "cloud_cost_refresh_rate_hours" {
  type    = number
  default = 6
}

variable "cloud_cost_run_window_days" {
  type    = number
  default = 3
}

variable "cloud_cost_query_window_days" {
  type    = number
  default = 7
}

# Optional: seed secret versions at apply time. Prefer deploy.sh / gcloud secrets versions add.
# Never commit real values in terraform.tfvars.
variable "cloud_integration_json" {
  description = "Optional initial cloud-integration.json body. null = create empty secret only."
  type        = string
  default     = null
  sensitive   = true
}

variable "admin_token" {
  description = "Optional initial ADMIN_TOKEN. null = create empty secret only."
  type        = string
  default     = null
  sensitive   = true
}
