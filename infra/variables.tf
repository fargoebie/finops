variable "project_id" {
  description = "GCP project ID that hosts the VM, secrets, and BigQuery."
  type        = string
}

variable "region" {
  description = "Primary GCP region."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCE zone for the VM."
  type        = string
  default     = "us-central1-a"
}

variable "name_prefix" {
  description = "Short prefix for all resource names."
  type        = string
  default     = "finops"
}

variable "billing_export_project_id" {
  description = "Project owning the BigQuery FOCUS billing export (defaults to project_id)."
  type        = string
  default     = null
}

variable "vpc_cidr" {
  description = "CIDR for the custom subnet."
  type        = string
  default     = "10.20.0.0/24"
}

variable "allowed_ingress_cidrs" {
  description = "CIDRs allowed to reach the VM on ports 80/443. Restrict to team VPN/office IPs."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "iap_ssh_members" {
  description = "IAM members granted IAP tunnel access for SSH (e.g. 'user:you@example.com')."
  type        = list(string)
  default     = []
}

variable "metabase_db_password" {
  description = "Optional initial Metabase PostgreSQL password. null = seed a random placeholder (replace via deploy.sh sync-secrets)."
  type        = string
  default     = null
  sensitive   = true
}
