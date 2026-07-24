terraform {
  required_version = ">= 1.11.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 7.26.0"
    }
  }

  # Configure with: tofu init -backend-config=backend.hcl
  # See backend.hcl.example. Create gs://${project_id}-tofu-state (versioned) out-of-band.
  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}
