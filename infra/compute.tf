# G/D. e2-medium VM — Metabase + dbt. IAP SSH only; no public port 22.

resource "google_compute_address" "finops_vm" {
  name    = "${var.name_prefix}-vm-ip"
  project = var.project_id
  region  = var.region

  depends_on = [google_project_service.required]
}

resource "google_compute_instance" "finops_vm" {
  name         = "${var.name_prefix}-vm"
  machine_type = "e2-medium"
  zone         = var.zone
  project      = var.project_id

  tags = ["finops-vm"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 50
      type  = "pd-balanced"
    }
  }

  network_interface {
    network    = google_compute_network.main.id
    subnetwork = google_compute_subnetwork.main.id

    access_config {
      nat_ip = google_compute_address.finops_vm.address
    }
  }

  service_account {
    email  = google_service_account.finops_vm.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    startup-script         = file("${path.module}/scripts/vm-startup.sh")
    block-project-ssh-keys = "true"
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  labels = local.labels

  depends_on = [
    google_project_service.required,
    google_service_account.finops_vm,
  ]
}

# Firewall: allow HTTPS from approved CIDRs only.
resource "google_compute_firewall" "allow_https" {
  name    = "${var.name_prefix}-allow-https"
  project = var.project_id
  network = google_compute_network.main.id

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  source_ranges = var.allowed_ingress_cidrs
  target_tags   = ["finops-vm"]
}

# Firewall: IAP SSH tunnel source range (Google-managed).
resource "google_compute_firewall" "allow_iap_ssh" {
  name    = "${var.name_prefix}-allow-iap-ssh"
  project = var.project_id
  network = google_compute_network.main.id

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["finops-vm"]
}
