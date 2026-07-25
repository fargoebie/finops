output "vm_external_ip" {
  description = "Static external IP of the FinOps VM."
  value       = google_compute_address.finops_vm.address
}

output "vm_name" {
  description = "GCE instance name."
  value       = google_compute_instance.finops_vm.name
}

output "runtime_service_account_email" {
  description = "VM service account email."
  value       = google_service_account.finops_vm.email
}

output "secret_metabase_db_password_id" {
  description = "Secret Manager secret ID for the Metabase DB password."
  value       = google_secret_manager_secret.metabase_db_password.id
}

output "vpc_network" {
  value = google_compute_network.main.name
}

output "vpc_subnet" {
  value = google_compute_subnetwork.main.name
}
