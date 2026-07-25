# GCP FinOps Rebase Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace OpenCost + React SPA with dbt FOCUS billing models + self-hosted Metabase on an e2-medium GCE VM, preserving full GCP credit/discount granularity.

**Architecture:** GCP FOCUS billing export stays in BigQuery; dbt Core transforms it into views (spend waterfall, credit breakdown, commitment discounts, showback); Metabase connects to those views via ADC on the VM service account; nginx terminates TLS. All GCP infra managed by OpenTofu in `infra/`.

**Tech Stack:** OpenTofu ≥1.11.5, hashicorp/google ≥7.26.0, dbt-bigquery ≥1.8, Metabase latest (Docker), PostgreSQL 16 (Docker), nginx + Certbot.

## Global Constraints

- Never commit secrets or private key material.
- All GCP resources managed by OpenTofu in `infra/`; no ad-hoc `gcloud` for prod resources.
- `infra/` stays flat (`*.tf` files, no subdirs for modules).
- VM service account `finops-vm@<PROJECT>.iam.gserviceaccount.com` — BigQuery read + Secret Manager access only.
- SSH via IAP only; no public port 22.
- HTTPS only; HTTP redirects to HTTPS.
- dbt models output as BigQuery **views** (not materialised tables) by default.
- `name_prefix` defaults to `finops` (was `opencost`).
- Keep `infra/scripts/auth-from-secret.sh`, `bootstrap-state-bucket.sh`, `create-deployer-sa.sh` unchanged.

---

## File Map

### Deleted
| Path | Reason |
|------|--------|
| `pkg/`, `cmd/`, `core/`, `modules/` | OpenCost Go source |
| `ui-finops/` | Custom React SPA |
| `go.mod`, `go.sum`, `Makefile`, `justfile` | Go/build tooling |
| `Dockerfile`, `Dockerfile.cross`, `Dockerfile.debug` | OpenCost images |
| `Tiltfile`, `Tiltfile.opencost`, `tilt-values.yaml` | Tilt dev orchestration |
| `generate.sh` | Go codegen |
| `configs/`, `spec/` | OpenCost pricing/spec |
| `sonar-project.properties` | OpenCost CI |
| `COMMUNITY.md`, `ADOPTERS.MD`, `GOVERNANCE.md`, `MAINTAINERS.md`, `ROADMAP.md`, `PROMETHEUS.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `NOTICE`, `THIRD_PARTY_LICENSES.txt` | Upstream community files |
| `infra/cloud_run.tf` | Cloud Run service |
| `infra/artifact_registry.tf` | AR repo for OpenCost images |
| `infra/monitoring_dashboard.tf` | OpenCost-specific dashboard |

### Modified
| Path | Change |
|------|--------|
| `infra/variables.tf` | Remove Cloud Run / OpenCost vars; add `allowed_ingress_cidrs`, `iap_ssh_members`, `metabase_db_password` |
| `infra/locals.tf` | Remove AR/image locals; update labels `app = "finops"` |
| `infra/iam.tf` | Replace `opencost_cloudcost` SA with `finops_vm` SA + IAP binding |
| `infra/secret_manager.tf` | Replace OpenCost secrets with `finops-metabase-db-password` |
| `infra/outputs.tf` | Remove Cloud Run / AR outputs; add VM IP, SA email, secret name |
| `infra/apis.tf` | Remove `run.googleapis.com`, `artifactregistry.googleapis.com`, `cloudtrace.googleapis.com`; add `iap.googleapis.com` |
| `infra/vpc.tf` | Add firewall comment update (no logic change) |
| `infra/terraform.tfvars.example` | Reflect new variables |
| `infra/scripts/env.sh` | Update SA names, remove Cloud Run vars, add VM/secret vars |
| `infra/scripts/deploy.sh` | Rewrite: VM sync + restart instead of Cloud Run update |
| `AGENTS.md` | Update for new stack |

### Created
| Path | Purpose |
|------|---------|
| `infra/compute.tf` | e2-medium VM, static IP, firewall rules (80/443 + IAP SSH) |
| `infra/scripts/vm-startup.sh` | First-boot: Docker, dbt-bigquery, nginx, ops agent |
| `docker-compose.yml` | Metabase + PostgreSQL services |
| `nginx/metabase.conf` | TLS reverse proxy to localhost:3000 |
| `dbt/dbt_project.yml` | dbt project config |
| `dbt/profiles.yml.example` | BigQuery ADC connection profile |
| `dbt/packages.yml` | dbt-utils dependency |
| `dbt/models/staging/sources.yml` | FOCUS table source declaration |
| `dbt/models/staging/schema.yml` | Staging model tests |
| `dbt/models/staging/stg_focus_billing.sql` | Raw FOCUS export → clean staging view |
| `dbt/models/intermediate/int_charges.sql` | Usage/Purchase/Tax rows |
| `dbt/models/intermediate/int_credits.sql` | Credit rows with full subcategory |
| `dbt/models/marts/schema.yml` | Mart model tests |
| `dbt/models/marts/fct_spend_waterfall.sql` | ListCost→ContractedCost→EffectiveCost→BilledCost |
| `dbt/models/marts/fct_credit_breakdown.sql` | Credits by type/project/service/month |
| `dbt/models/marts/fct_commitment_discounts.sql` | CUD utilisation and coverage |
| `dbt/models/marts/fct_monthly_showback.sql` | Project-level net vs gross with credit attribution |

---

## Task 1: Strip OpenCost

**Files:** Delete everything in the table above under "Deleted".

**Interfaces:**
- Produces: clean working tree with only `infra/`, `docs/`, `AGENTS.md`, `CLAUDE.md`, `.github/` (if any), root config files remaining.

- [ ] **Step 1: Delete Go source and build tooling**

```bash
git rm -r pkg/ cmd/ core/ modules/ || true
git rm -f go.mod go.sum Makefile justfile generate.sh || true
git rm -f Dockerfile Dockerfile.cross Dockerfile.debug || true
git rm -f Tiltfile Tiltfile.opencost tilt-values.yaml || true
```

- [ ] **Step 2: Delete OpenCost-specific content**

```bash
git rm -r ui-finops/ configs/ spec/ || true
git rm -f sonar-project.properties || true
```

- [ ] **Step 3: Delete upstream community files**

```bash
git rm -f COMMUNITY.md ADOPTERS.MD GOVERNANCE.md MAINTAINERS.md ROADMAP.md \
           PROMETHEUS.md CONTRIBUTING.md CODE_OF_CONDUCT.md \
           NOTICE THIRD_PARTY_LICENSES.txt || true
```

- [ ] **Step 4: Delete obsolete infra files**

```bash
git rm -f infra/cloud_run.tf infra/artifact_registry.tf infra/monitoring_dashboard.tf || true
```

- [ ] **Step 5: Verify clean state**

```bash
git status --short
```

Expected: only `D` (deleted) lines; no unexpected modifications.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "chore: strip OpenCost Go source, ui-finops, and upstream community files"
```

---

## Task 2: Rewrite infra/ core files

**Files:**
- Modify: `infra/variables.tf`
- Modify: `infra/locals.tf`
- Modify: `infra/apis.tf`
- Modify: `infra/iam.tf`
- Modify: `infra/secret_manager.tf`
- Modify: `infra/outputs.tf`

**Interfaces:**
- Produces: `google_service_account.finops_vm` (referenced by Task 3 compute.tf and Task 3 secret accessor)

- [ ] **Step 1: Rewrite variables.tf**

Replace the entire file:

```hcl
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
```

- [ ] **Step 2: Rewrite locals.tf**

```hcl
locals {
  billing_project = coalesce(var.billing_export_project_id, var.project_id)

  labels = {
    app        = "finops"
    managed_by = "opentofu"
    prefix     = var.name_prefix
  }
}
```

- [ ] **Step 3: Update apis.tf — remove Cloud Run/AR/Trace, add IAP**

```hcl
locals {
  required_apis = toset([
    "secretmanager.googleapis.com",
    "bigquery.googleapis.com",
    "iam.googleapis.com",
    "compute.googleapis.com",
    "iap.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "monitoring.googleapis.com",
    "logging.googleapis.com",
  ])
}

resource "google_project_service" "required" {
  for_each = local.required_apis

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}
```

- [ ] **Step 4: Rewrite iam.tf**

```hcl
# A. Dedicated least-privilege VM service account.

resource "google_service_account" "finops_vm" {
  account_id   = "${var.name_prefix}-vm"
  display_name = "FinOps VM (Metabase + dbt)"
  description  = "Runtime identity for Metabase and dbt on the FinOps e2-medium VM"
  project      = var.project_id

  depends_on = [google_project_service.required]
}

resource "google_project_iam_member" "finops_vm_bq_data_viewer" {
  project = local.billing_project
  role    = "roles/bigquery.dataViewer"
  member  = "serviceAccount:${google_service_account.finops_vm.email}"
}

resource "google_project_iam_member" "finops_vm_bq_job_user" {
  project = local.billing_project
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.finops_vm.email}"
}

resource "google_project_iam_member" "finops_vm_bq_user" {
  project = local.billing_project
  role    = "roles/bigquery.user"
  member  = "serviceAccount:${google_service_account.finops_vm.email}"
}

# H. Observability
resource "google_project_iam_member" "finops_vm_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.finops_vm.email}"
}

resource "google_project_iam_member" "finops_vm_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.finops_vm.email}"
}

# D. IAP SSH — no public port 22.
resource "google_iap_tunnel_instance_iam_binding" "ssh" {
  project  = var.project_id
  zone     = var.zone
  instance = google_compute_instance.finops_vm.name
  role     = "roles/iap.tunnelResourceAccessor"
  members  = var.iap_ssh_members

  depends_on = [google_project_service.required]
}
```

- [ ] **Step 5: Rewrite secret_manager.tf**

```hcl
# B. Managed secrets — value injected by reference; per-secret accessor only.

resource "google_secret_manager_secret" "metabase_db_password" {
  secret_id = "${var.name_prefix}-metabase-db-password"
  project   = var.project_id

  replication {
    auto {}
  }

  labels = local.labels

  depends_on = [google_project_service.required]
}

resource "google_secret_manager_secret_iam_member" "metabase_db_password_accessor" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.metabase_db_password.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.finops_vm.email}"
}

resource "google_secret_manager_secret_version" "metabase_db_password" {
  count = var.metabase_db_password == null ? 0 : 1

  secret      = google_secret_manager_secret.metabase_db_password.id
  secret_data = var.metabase_db_password

  lifecycle {
    ignore_changes = [secret_data]
  }
}

# Seed a random placeholder when no initial value is provided.
resource "terraform_data" "seed_metabase_db_password" {
  input = {
    project = var.project_id
    secret  = google_secret_manager_secret.metabase_db_password.secret_id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-ce"]
    environment = {
      PROJECT = var.project_id
      SECRET  = google_secret_manager_secret.metabase_db_password.secret_id
    }
    command = <<-EOT
      enabled="$(gcloud secrets versions list "$${SECRET}" \
        --project="$${PROJECT}" \
        --filter='state:ENABLED' \
        --format='value(name)' 2>/dev/null | wc -l | tr -d ' ')"
      if [[ "$${enabled}" -eq 0 ]]; then
        openssl rand -base64 32 | tr -d '\n' | \
          gcloud secrets versions add "$${SECRET}" --project="$${PROJECT}" --data-file=-
        echo "Seeded random password for $${SECRET}"
      else
        echo "Secret $${SECRET} already has $${enabled} version(s); skip seed"
      fi
    EOT
  }

  depends_on = [
    google_secret_manager_secret.metabase_db_password,
    google_secret_manager_secret_version.metabase_db_password,
  ]
}
```

- [ ] **Step 6: Rewrite outputs.tf**

```hcl
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
```

- [ ] **Step 7: Validate**

```bash
cd infra && tofu validate
```

Expected: `Success! The configuration is valid.`
Note: `tofu validate` will fail if `compute.tf` (which defines `google_compute_instance.finops_vm` and `google_compute_address.finops_vm`) doesn't exist yet — complete Task 3 first, then re-run.

- [ ] **Step 8: Commit**

```bash
git add infra/variables.tf infra/locals.tf infra/apis.tf infra/iam.tf \
        infra/secret_manager.tf infra/outputs.tf
git commit -m "feat(infra): rewrite core tf files for VM-based finops stack"
```

---

## Task 3: Add infra/compute.tf

**Files:**
- Create: `infra/compute.tf`
- Create: `infra/terraform.tfvars.example` (replace)

**Interfaces:**
- Produces: `google_compute_instance.finops_vm`, `google_compute_address.finops_vm` (referenced in iam.tf IAP binding and outputs.tf)

- [ ] **Step 1: Create infra/compute.tf**

```hcl
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
```

- [ ] **Step 2: Replace terraform.tfvars.example**

```hcl
# demogcp-terra2021 — deploy + BigQuery billing export in the SAME project.
# Copy to terraform.tfvars (gitignored). Never commit secrets.

project_id  = "demogcp-terra2021"
region      = "us-central1"
zone        = "us-central1-a"
name_prefix = "finops"

# Same project: leave billing_export_project_id unset (defaults to project_id).
# billing_export_project_id = "demogcp-terra2021"

vpc_cidr = "10.20.0.0/24"

# Restrict to your team VPN or office CIDR. "0.0.0.0/0" opens to the internet.
allowed_ingress_cidrs = ["0.0.0.0/0"]

# IAM members who can SSH via IAP tunnel.
iap_ssh_members = [
  "user:farry@terralogiq.com",
]

# Seed Metabase DB password via scripts, not tfvars:
#   ./scripts/deploy.sh sync-secrets
```

- [ ] **Step 3: Validate full infra**

```bash
cd infra && tofu validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Commit**

```bash
git add infra/compute.tf infra/terraform.tfvars.example
git commit -m "feat(infra): add e2-medium VM with IAP SSH and HTTPS firewall rules"
```

---

## Task 4: Rewrite infra scripts

**Files:**
- Modify: `infra/scripts/env.sh`
- Modify: `infra/scripts/deploy.sh`
- Create: `infra/scripts/vm-startup.sh`

**Interfaces:**
- `env.sh` exports: `PROJECT_ID`, `BILLING_PROJECT_ID`, `REGION`, `ZONE`, `NAME_PREFIX`, `VM_NAME`, `RUNTIME_SA_EMAIL`, `SECRET_MB_DB_PASS`, `STATE_BUCKET`
- `deploy.sh` commands: `sync`, `restart`, `dbt-run`, `sync-secrets`, `all`, `ssh`, `print-env`
- `vm-startup.sh` is uploaded to GCE metadata; runs once on first boot

- [ ] **Step 1: Rewrite infra/scripts/env.sh**

```bash
#!/usr/bin/env bash
# Shared defaults for demogcp-terra2021.
# Source: source "$(dirname "${BASH_SOURCE[0]}")/env.sh"

export PROJECT_ID="${PROJECT_ID:-demogcp-terra2021}"
export BILLING_PROJECT_ID="${BILLING_PROJECT_ID:-${PROJECT_ID}}"
export REGION="${REGION:-us-central1}"
export ZONE="${ZONE:-us-central1-a}"
export NAME_PREFIX="${NAME_PREFIX:-finops}"

export DEPLOY_SA_ID="${DEPLOY_SA_ID:-opencost-deployer}"
export DEPLOY_SA_EMAIL="${DEPLOY_SA_EMAIL:-${DEPLOY_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com}"
export RUNTIME_SA_ID="${RUNTIME_SA_ID:-${NAME_PREFIX}-vm}"
export RUNTIME_SA_EMAIL="${RUNTIME_SA_EMAIL:-${RUNTIME_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com}"

export STATE_BUCKET="${STATE_BUCKET:-${PROJECT_ID}-tofu-state}"
export VM_NAME="${VM_NAME:-${NAME_PREFIX}-vm}"
export SECRET_MB_DB_PASS="${SECRET_MB_DB_PASS:-${NAME_PREFIX}-metabase-db-password}"

# Cloud Agent secret name (base64 of deployer SA JSON)
export GCP_SA_KEY_B64_VAR="${GCP_SA_KEY_B64_VAR:-GCP_SA_KEY_B64}"
export GOOGLE_APPLICATION_CREDENTIALS="${GOOGLE_APPLICATION_CREDENTIALS:-${HOME}/.config/gcloud/opencost-deployer.json}"
```

- [ ] **Step 2: Rewrite infra/scripts/deploy.sh**

```bash
#!/usr/bin/env bash
# deploy.sh — sync files to VM and manage services
# Typical flow:
#   ./infra/scripts/auth-from-secret.sh   # from GCP_SA_KEY_B64
#   cd infra && tofu apply                # provision VM + secrets
#   ./infra/scripts/deploy.sh all         # sync files + start stack
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=env.sh
source "${SCRIPT_DIR}/env.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command>

Project: ${PROJECT_ID}  Zone: ${ZONE}  VM: ${VM_NAME}

Commands:
  sync          Copy docker-compose.yml, nginx/, dbt/ to VM at /opt/finops
  restart       Pull latest images and restart docker compose stack on VM
  dbt-run       Trigger dbt run on VM (tail last 20 lines)
  sync-secrets  Rotate Metabase DB password in Secret Manager
  all           sync && restart
  ssh           Open IAP SSH session to VM
  print-env     Show resolved env vars

Env overrides: PROJECT_ID REGION ZONE NAME_PREFIX VM_NAME SECRET_MB_DB_PASS
EOF
}

require_auth() {
  if [[ -z "${GOOGLE_APPLICATION_CREDENTIALS:-}" || ! -f "${GOOGLE_APPLICATION_CREDENTIALS}" ]]; then
    if [[ -n "${GCP_SA_KEY_B64:-}" ]]; then
      echo "GOOGLE_APPLICATION_CREDENTIALS missing; running auth-from-secret.sh"
      "${SCRIPT_DIR}/auth-from-secret.sh"
      source "${SCRIPT_DIR}/env.sh"
    else
      echo "No credentials. Set GCP_SA_KEY_B64 or run ./auth-from-secret.sh" >&2
      exit 1
    fi
  fi
  command -v gcloud >/dev/null 2>&1 || { echo "gcloud required" >&2; exit 1; }
  gcloud config set project "${PROJECT_ID}" --quiet
}

cmd_ssh() {
  require_auth
  gcloud compute ssh "${VM_NAME}" \
    --zone="${ZONE}" --tunnel-through-iap --project="${PROJECT_ID}"
}

cmd_sync() {
  require_auth
  gcloud compute ssh "${VM_NAME}" \
    --zone="${ZONE}" --tunnel-through-iap --project="${PROJECT_ID}" \
    --command="mkdir -p /opt/finops/nginx /opt/finops/dbt"
  gcloud compute scp --recurse \
    --tunnel-through-iap --zone="${ZONE}" --project="${PROJECT_ID}" \
    "${ROOT_DIR}/docker-compose.yml" \
    "${VM_NAME}:/opt/finops/docker-compose.yml"
  gcloud compute scp --recurse \
    --tunnel-through-iap --zone="${ZONE}" --project="${PROJECT_ID}" \
    "${ROOT_DIR}/nginx/." \
    "${VM_NAME}:/opt/finops/nginx/"
  gcloud compute scp --recurse \
    --tunnel-through-iap --zone="${ZONE}" --project="${PROJECT_ID}" \
    "${ROOT_DIR}/dbt/." \
    "${VM_NAME}:/opt/finops/dbt/"
  echo "Synced to ${VM_NAME}:/opt/finops/"
}

cmd_restart() {
  require_auth
  gcloud compute ssh "${VM_NAME}" \
    --zone="${ZONE}" --tunnel-through-iap --project="${PROJECT_ID}" \
    --command="$(cat <<'REMOTE'
set -euo pipefail
MB_DB_PASS="$(gcloud secrets versions access latest \
  --secret="${SECRET_MB_DB_PASS}" --project="${PROJECT_ID}")"
export MB_DB_PASS
cd /opt/finops
docker compose pull --quiet
docker compose up -d
docker compose ps
REMOTE
)"
}

cmd_dbt_run() {
  require_auth
  gcloud compute ssh "${VM_NAME}" \
    --zone="${ZONE}" --tunnel-through-iap --project="${PROJECT_ID}" \
    --command="cd /opt/finops/dbt && dbt run --profiles-dir . 2>&1 | tail -30"
}

cmd_sync_secrets() {
  require_auth
  local password
  password="$(openssl rand -base64 32 | tr -d '\n=')"
  printf '%s' "${password}" | \
    gcloud secrets versions add "${SECRET_MB_DB_PASS}" \
      --project="${PROJECT_ID}" --data-file=-
  echo "Rotated ${SECRET_MB_DB_PASS}. Run './deploy.sh restart' to apply."
}

cmd_print_env() {
  cat <<EOF
PROJECT_ID=${PROJECT_ID}
BILLING_PROJECT_ID=${BILLING_PROJECT_ID}
REGION=${REGION}
ZONE=${ZONE}
VM_NAME=${VM_NAME}
RUNTIME_SA_EMAIL=${RUNTIME_SA_EMAIL}
SECRET_MB_DB_PASS=${SECRET_MB_DB_PASS}
STATE_BUCKET=${STATE_BUCKET}
EOF
}

main() {
  local cmd="${1:-}"
  case "${cmd}" in
    sync)          cmd_sync ;;
    restart)       cmd_restart ;;
    dbt-run)       cmd_dbt_run ;;
    sync-secrets)  cmd_sync_secrets ;;
    all)           cmd_sync && cmd_restart ;;
    ssh)           cmd_ssh ;;
    print-env)     cmd_print_env ;;
    -h|--help|help|"") usage; [[ -n "${cmd}" ]] || exit 1 ;;
    *) echo "Unknown: ${cmd}" >&2; usage; exit 1 ;;
  esac
}

main "$@"
```

- [ ] **Step 3: Create infra/scripts/vm-startup.sh**

```bash
#!/usr/bin/env bash
# First-boot startup script for the FinOps e2-medium VM.
# Runs as root via GCE metadata. Idempotent — safe to re-run.
set -euo pipefail

# ── Docker ──────────────────────────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/debian $(lsb_release -cs) stable" \
    | tee /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable docker
fi

# ── Cloud Ops Agent ──────────────────────────────────────────────────────────
if ! systemctl is-active --quiet google-cloud-ops-agent 2>/dev/null; then
  curl -sSO https://dl.google.com/cloudagents/add-google-cloud-ops-agent-repo.sh
  bash add-google-cloud-ops-agent-repo.sh --also-install
fi

# ── nginx + Certbot ──────────────────────────────────────────────────────────
if ! command -v nginx >/dev/null 2>&1; then
  apt-get install -y -qq nginx certbot python3-certbot-nginx
  systemctl enable nginx
fi

# ── dbt-bigquery ────────────────────────────────────────────────────────────
if [[ ! -x /opt/dbt-venv/bin/dbt ]]; then
  apt-get install -y -qq python3-pip python3-venv
  python3 -m venv /opt/dbt-venv
  /opt/dbt-venv/bin/pip install --quiet "dbt-bigquery>=1.8,<2.0"
  ln -sf /opt/dbt-venv/bin/dbt /usr/local/bin/dbt
fi

# ── App directory ────────────────────────────────────────────────────────────
mkdir -p /opt/finops/nginx /opt/finops/dbt

# ── dbt daily cron ───────────────────────────────────────────────────────────
CRON_LINE="0 6 * * * root cd /opt/finops/dbt && /usr/local/bin/dbt run --profiles-dir . >> /var/log/dbt.log 2>&1"
if ! grep -qF "dbt run" /etc/cron.d/finops-dbt 2>/dev/null; then
  echo "${CRON_LINE}" > /etc/cron.d/finops-dbt
  chmod 0644 /etc/cron.d/finops-dbt
fi

echo "VM startup complete"
```

- [ ] **Step 4: Verify scripts are executable**

```bash
chmod +x infra/scripts/vm-startup.sh infra/scripts/deploy.sh
```

- [ ] **Step 5: Commit**

```bash
git add infra/scripts/env.sh infra/scripts/deploy.sh infra/scripts/vm-startup.sh
git commit -m "feat(infra): rewrite deploy.sh for VM, add vm-startup.sh"
```

---

## Task 5: dbt scaffold + staging model

**Files:**
- Create: `dbt/dbt_project.yml`
- Create: `dbt/profiles.yml.example`
- Create: `dbt/packages.yml`
- Create: `dbt/models/staging/sources.yml`
- Create: `dbt/models/staging/schema.yml`
- Create: `dbt/models/staging/stg_focus_billing.sql`
- Create: `dbt/.gitignore`

**Interfaces:**
- Produces: `ref('stg_focus_billing')` — columns: `billing_account_id`, `project_id`, `project_name`, `service_name`, `service_category`, `region_id`, `charge_date` (DATE), `charge_month` (TIMESTAMP, month-truncated), `charge_period_start`, `charge_type`, `charge_category`, `charge_subcategory`, `sku_id`, `billing_currency`, `list_cost`, `contracted_cost`, `effective_cost`, `billed_cost`, `commitment_discount_id`, `commitment_discount_name`, `commitment_discount_type`, `commitment_discount_category`, `commitment_discount_status`, `resource_id`, `resource_name`

- [ ] **Step 1: Create dbt/dbt_project.yml**

```yaml
name: 'finops'
version: '1.0.0'
config-version: 2

profile: 'finops'

model-paths: ["models"]
test-paths: ["tests"]
seed-paths: ["seeds"]
macro-paths: ["macros"]
analysis-paths: ["analyses"]

target-path: "target"
clean-targets:
  - "target"
  - "dbt_packages"

models:
  finops:
    staging:
      +materialized: view
      +schema: dbt_staging
    intermediate:
      +materialized: view
      +schema: dbt_intermediate
    marts:
      +materialized: view
      +schema: finops_dbt
```

- [ ] **Step 2: Create dbt/profiles.yml.example**

```yaml
# Copy to profiles.yml (gitignored) and fill in your project ID and dataset.
# Authentication uses Application Default Credentials (VM service account).
finops:
  target: prod
  outputs:
    prod:
      type: bigquery
      method: oauth
      project: "YOUR_GCP_PROJECT_ID"
      dataset: dbt_staging
      location: US
      timeout_seconds: 300
      threads: 4
```

- [ ] **Step 3: Create dbt/packages.yml**

```yaml
packages:
  - package: dbt-labs/dbt_utils
    version: [">=1.0.0", "<2.0.0"]
```

- [ ] **Step 4: Create dbt/.gitignore**

```
target/
dbt_packages/
logs/
profiles.yml
.user.yml
```

- [ ] **Step 5: Create dbt/models/staging/sources.yml**

```yaml
version: 2

sources:
  - name: gcp_billing
    description: "GCP FOCUS billing export in BigQuery."
    database: "{{ env_var('DBT_BILLING_PROJECT_ID', env_var('DBT_PROJECT_ID', 'YOUR_PROJECT_ID')) }}"
    schema: "{{ env_var('DBT_BILLING_DATASET', 'YOUR_BILLING_DATASET') }}"
    tables:
      - name: focus_export
        identifier: "{{ env_var('DBT_FOCUS_TABLE', 'gcp_billing_export_focus_v1_XXXXXX') }}"
        description: >
          GCP FOCUS 1.0 billing export. Table name format:
          gcp_billing_export_focus_v1_<BILLING_ACCOUNT_ID_NO_DASHES>.
          Enable via GCP Console → Billing → Billing export → FOCUS export.
```

- [ ] **Step 6: Create dbt/models/staging/schema.yml**

```yaml
version: 2

models:
  - name: stg_focus_billing
    description: "Staging view over the GCP FOCUS billing export. Full fidelity — no rows dropped."
    columns:
      - name: charge_type
        description: "FOCUS ChargeType: Usage, Purchase, Tax, Credit, Adjustment."
        tests:
          - not_null
          - accepted_values:
              values: ['Usage', 'Purchase', 'Tax', 'Credit', 'Adjustment']
      - name: billed_cost
        description: "Amount charged to the billing account (negative for credits)."
        tests:
          - not_null
      - name: project_id
        description: "GCP project ID (FOCUS SubAccountId)."
```

- [ ] **Step 7: Create dbt/models/staging/stg_focus_billing.sql**

```sql
-- Staging view over GCP FOCUS billing export.
-- Renames FOCUS columns to snake_case, coalesces nulls on cost columns,
-- and adds charge_date / charge_month for grouping.
-- No rows are filtered — full fidelity is the point.

select
    billing_account_id,
    billing_account_name,

    -- SubAccount = GCP project
    sub_account_id                                          as project_id,
    sub_account_name                                        as project_name,

    service_name,
    service_category,
    region_id,
    availability_zone_id,

    -- Time dimensions
    date(charge_period_start)                               as charge_date,
    timestamp_trunc(charge_period_start, month)             as charge_month,
    charge_period_start,
    charge_period_end,
    billing_period_start,
    billing_period_end,

    -- Charge classification
    charge_type,
    charge_category,
    charge_subcategory,
    charge_description,
    charge_frequency,

    -- SKU
    sku_id,
    sku_price_id,
    billing_currency,

    -- Unit prices
    coalesce(list_unit_price, 0)                            as list_unit_price,
    coalesce(contracted_unit_price, 0)                      as contracted_unit_price,

    -- Cost waterfall (credits are negative; coalesce avoids NULL propagation)
    coalesce(list_cost, 0)                                  as list_cost,
    coalesce(contracted_cost, 0)                            as contracted_cost,
    coalesce(effective_cost, 0)                             as effective_cost,
    coalesce(billed_cost, 0)                                as billed_cost,

    -- Quantity
    pricing_quantity,
    pricing_unit,
    consumed_quantity,
    consumed_unit,

    -- Commitment discounts
    commitment_discount_id,
    commitment_discount_name,
    commitment_discount_type,
    commitment_discount_category,
    commitment_discount_status,

    -- Resource
    resource_id,
    resource_name,
    resource_type

from {{ source('gcp_billing', 'focus_export') }}
```

- [ ] **Step 8: Verify dbt parses correctly**

First copy and configure a minimal profiles.yml:
```bash
cd dbt
cp profiles.yml.example profiles.yml
# Edit profiles.yml: set project to your GCP project ID
```

Then parse (no DB connection required):
```bash
dbt parse --profiles-dir .
```

Expected: `Done.` with no errors.

- [ ] **Step 9: Commit**

```bash
git add dbt/
git commit -m "feat(dbt): scaffold project and staging FOCUS billing model"
```

---

## Task 6: dbt intermediate models

**Files:**
- Create: `dbt/models/intermediate/int_charges.sql`
- Create: `dbt/models/intermediate/int_credits.sql`

**Interfaces:**
- Consumes: `ref('stg_focus_billing')` — all columns from Task 5
- Produces `ref('int_charges')` — charge rows (non-credit): `project_id`, `project_name`, `service_name`, `service_category`, `region_id`, `charge_date`, `charge_month`, `charge_type`, `charge_category`, `charge_description`, `sku_id`, `billing_currency`, `list_cost`, `contracted_cost`, `effective_cost`, `billed_cost`, `pricing_quantity`, `pricing_unit`, `consumed_quantity`, `consumed_unit`, `commitment_discount_id`, `commitment_discount_name`, `commitment_discount_type`, `commitment_discount_status`
- Produces `ref('int_credits')` — credit rows: `project_id`, `project_name`, `service_name`, `service_category`, `region_id`, `charge_date`, `charge_month`, `credit_type` (= charge_subcategory), `charge_description`, `sku_id`, `billing_currency`, `credit_amount` (= billed_cost, negative), `commitment_discount_id`, `commitment_discount_name`, `commitment_discount_type`, `commitment_discount_category`

- [ ] **Step 1: Create dbt/models/intermediate/int_charges.sql**

```sql
-- Usage, Purchase, and Tax charges — excludes Credit and Adjustment rows.
-- These are the rows that drive list_cost → contracted_cost → effective_cost → billed_cost.

select
    billing_account_id,
    project_id,
    project_name,
    service_name,
    service_category,
    region_id,
    charge_date,
    charge_month,
    charge_type,
    charge_category,
    charge_description,
    sku_id,
    billing_currency,
    list_cost,
    contracted_cost,
    effective_cost,
    billed_cost,
    pricing_quantity,
    pricing_unit,
    consumed_quantity,
    consumed_unit,
    commitment_discount_id,
    commitment_discount_name,
    commitment_discount_type,
    commitment_discount_status
from {{ ref('stg_focus_billing') }}
where charge_type in ('Usage', 'Purchase', 'Tax')
```

- [ ] **Step 2: Create dbt/models/intermediate/int_credits.sql**

```sql
-- Credit rows only — preserves the full ChargeSubcategory label.
--
-- GCP credit subcategories include (non-exhaustive):
--   'Enterprise Discount Program'
--   'Committed Use Discount: Spend'
--   'Committed Use Discount: Usage'
--   'Sustained Use Discount'
--   'Promotion'
--   'Reseller Discount'
--   'Free Tier'
--
-- credit_amount is always negative (reduces billed cost).

select
    billing_account_id,
    project_id,
    project_name,
    service_name,
    service_category,
    region_id,
    charge_date,
    charge_month,
    charge_subcategory                  as credit_type,
    charge_description,
    sku_id,
    billing_currency,
    billed_cost                         as credit_amount,
    commitment_discount_id,
    commitment_discount_name,
    commitment_discount_type,
    commitment_discount_category
from {{ ref('stg_focus_billing') }}
where charge_type = 'Credit'
```

- [ ] **Step 3: Parse**

```bash
cd dbt && dbt parse --profiles-dir .
```

Expected: `Done.` with no errors.

- [ ] **Step 4: Commit**

```bash
git add dbt/models/intermediate/
git commit -m "feat(dbt): add intermediate charge and credit models"
```

---

## Task 7: dbt mart models

**Files:**
- Create: `dbt/models/marts/fct_spend_waterfall.sql`
- Create: `dbt/models/marts/fct_credit_breakdown.sql`
- Create: `dbt/models/marts/fct_commitment_discounts.sql`
- Create: `dbt/models/marts/fct_monthly_showback.sql`
- Create: `dbt/models/marts/schema.yml`

**Interfaces:**
- Consumes: `ref('int_charges')`, `ref('int_credits')` from Task 6

- [ ] **Step 1: Create dbt/models/marts/fct_spend_waterfall.sql**

```sql
-- Monthly spend waterfall per project/service/sku.
-- Shows exactly where money goes at each discount step:
--   list_cost          → gross price (no discounts)
--   contracted_cost    → after EDP / negotiated rate
--   effective_cost     → after CUDs and other pre-credit adjustments
--   billed_cost        → final amount charged
--
-- edp_savings = list_cost - contracted_cost (value of EDP/negotiated rate)
-- credit_savings = contracted_cost - effective_cost (CUD + promotional credits applied to charges)
-- total_discount = list_cost - billed_cost

select
    project_id,
    project_name,
    service_name,
    service_category,
    region_id,
    sku_id,
    charge_month,
    billing_currency,

    sum(list_cost)                                  as list_cost,
    sum(contracted_cost)                            as contracted_cost,
    sum(effective_cost)                             as effective_cost,
    sum(billed_cost)                                as billed_cost,

    sum(list_cost) - sum(contracted_cost)           as edp_savings,
    sum(contracted_cost) - sum(effective_cost)      as credit_savings,
    sum(effective_cost) - sum(billed_cost)          as other_adjustments,
    sum(list_cost) - sum(billed_cost)               as total_discount

from {{ ref('int_charges') }}
group by 1, 2, 3, 4, 5, 6, 7, 8
```

- [ ] **Step 2: Create dbt/models/marts/fct_credit_breakdown.sql**

```sql
-- One row per credit type per project/service/month.
-- Primary Metabase source for "what credits am I getting and why?" questions.

select
    project_id,
    project_name,
    service_name,
    service_category,
    region_id,
    charge_month,
    credit_type,
    billing_currency,
    count(*)                            as credit_line_count,
    sum(credit_amount)                  as total_credit_amount

from {{ ref('int_credits') }}
group by 1, 2, 3, 4, 5, 6, 7, 8
```

- [ ] **Step 3: Create dbt/models/marts/fct_commitment_discounts.sql**

```sql
-- Committed Use Discount (CUD) utilisation and coverage.
-- Covers both spend-based (Spend) and resource-based (Usage) CUDs.
-- commitment_discount_status = 'Used' | 'Unused' shows utilisation.

select
    project_id,
    project_name,
    service_name,
    charge_month,
    commitment_discount_id,
    commitment_discount_name,
    commitment_discount_type,
    commitment_discount_category,
    commitment_discount_status,
    billing_currency,
    count(*)                            as line_count,
    sum(list_cost)                      as list_cost,
    sum(contracted_cost)                as contracted_cost,
    sum(billed_cost)                    as billed_cost

from {{ ref('int_charges') }}
where commitment_discount_id is not null
group by 1, 2, 3, 4, 5, 6, 7, 8, 9, 10
```

- [ ] **Step 4: Create dbt/models/marts/fct_monthly_showback.sql**

```sql
-- Project-level monthly showback with full credit attribution.
-- Join charges + credits to produce a single summary row per project/month.

with charges as (
    select
        project_id,
        project_name,
        charge_month,
        billing_currency,
        sum(list_cost)          as gross_cost,
        sum(contracted_cost)    as contracted_cost,
        sum(effective_cost)     as effective_cost,
        sum(billed_cost)        as net_cost
    from {{ ref('int_charges') }}
    group by 1, 2, 3, 4
),

credits_pivot as (
    select
        project_id,
        charge_month,
        sum(credit_amount)                                                          as total_credits,
        sum(case when credit_type = 'Enterprise Discount Program'
                 then credit_amount else 0 end)                                     as edp_credits,
        sum(case when credit_type like 'Committed Use Discount%'
                 then credit_amount else 0 end)                                     as cud_credits,
        sum(case when credit_type = 'Sustained Use Discount'
                 then credit_amount else 0 end)                                     as sud_credits,
        sum(case when credit_type = 'Promotion'
                 then credit_amount else 0 end)                                     as promotional_credits,
        sum(case when credit_type = 'Reseller Discount'
                 then credit_amount else 0 end)                                     as reseller_credits,
        sum(case when credit_type not in (
                     'Enterprise Discount Program',
                     'Sustained Use Discount',
                     'Promotion',
                     'Reseller Discount'
                 ) and credit_type not like 'Committed Use Discount%'
                 then credit_amount else 0 end)                                     as other_credits
    from {{ ref('int_credits') }}
    group by 1, 2
)

select
    c.project_id,
    c.project_name,
    c.charge_month,
    c.billing_currency,
    c.gross_cost,
    c.contracted_cost,
    c.effective_cost,
    c.net_cost,
    coalesce(cr.total_credits, 0)           as total_credits,
    coalesce(cr.edp_credits, 0)             as edp_credits,
    coalesce(cr.cud_credits, 0)             as cud_credits,
    coalesce(cr.sud_credits, 0)             as sud_credits,
    coalesce(cr.promotional_credits, 0)     as promotional_credits,
    coalesce(cr.reseller_credits, 0)        as reseller_credits,
    coalesce(cr.other_credits, 0)           as other_credits,
    c.gross_cost - c.contracted_cost        as edp_savings
from charges c
left join credits_pivot cr
    on  c.project_id   = cr.project_id
    and c.charge_month = cr.charge_month
```

- [ ] **Step 5: Create dbt/models/marts/schema.yml**

```yaml
version: 2

models:
  - name: fct_spend_waterfall
    description: "Monthly spend waterfall per project/service/sku: list→contracted→effective→billed."
    columns:
      - name: project_id
        tests: [not_null]
      - name: charge_month
        tests: [not_null]
      - name: billed_cost
        tests: [not_null]

  - name: fct_credit_breakdown
    description: "Credits by type/project/service/month. credit_amount is negative."
    columns:
      - name: project_id
        tests: [not_null]
      - name: credit_type
        tests: [not_null]
      - name: total_credit_amount
        tests: [not_null]

  - name: fct_commitment_discounts
    description: "CUD utilisation and coverage by commitment/project/month."
    columns:
      - name: commitment_discount_id
        tests: [not_null]

  - name: fct_monthly_showback
    description: "Project-level monthly showback with credit attribution waterfall."
    columns:
      - name: project_id
        tests: [not_null]
      - name: charge_month
        tests: [not_null]
      - name: net_cost
        tests: [not_null]
```

- [ ] **Step 6: Parse all models**

```bash
cd dbt && dbt parse --profiles-dir .
```

Expected: `Done.` — all 8 models parsed, 0 errors.

- [ ] **Step 7: Commit**

```bash
git add dbt/models/marts/
git commit -m "feat(dbt): add mart models for spend waterfall, credits, CUDs, and showback"
```

---

## Task 8: Docker Compose + nginx

**Files:**
- Create: `docker-compose.yml`
- Create: `nginx/metabase.conf`

**Interfaces:**
- `docker-compose.yml` reads `MB_DB_PASS` from environment (set by deploy.sh from Secret Manager)
- `nginx/metabase.conf` proxies `localhost:3000`; requires `DOMAIN` substitution before use

- [ ] **Step 1: Create docker-compose.yml**

```yaml
# FinOps VM — Metabase + PostgreSQL (Metabase state DB)
# MB_DB_PASS is injected at runtime from Secret Manager by deploy.sh restart.
# Metabase connects to BigQuery via Application Default Credentials (VM SA).

services:
  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: metabase
      POSTGRES_PASSWORD: "${MB_DB_PASS}"
      POSTGRES_DB: metabase
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U metabase"]
      interval: 10s
      timeout: 5s
      retries: 5

  metabase:
    image: metabase/metabase:latest
    restart: unless-stopped
    ports:
      - "127.0.0.1:3000:3000"
    environment:
      MB_DB_TYPE: postgres
      MB_DB_DBNAME: metabase
      MB_DB_PORT: 5432
      MB_DB_USER: metabase
      MB_DB_PASS: "${MB_DB_PASS}"
      MB_DB_HOST: postgres
      # Cap JVM heap — leave ~512 MB for OS + dbt on e2-medium (4 GB total).
      JAVA_OPTS: "-Xmx1536m -Xms512m"
    depends_on:
      postgres:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/api/health"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 90s

volumes:
  postgres_data:
```

- [ ] **Step 2: Create nginx/metabase.conf**

```nginx
# Redirect HTTP → HTTPS
server {
    listen 80;
    server_name _;
    return 301 https://$host$request_uri;
}

# HTTPS reverse proxy to Metabase on localhost:3000
# Before enabling: run certbot --nginx -d YOUR_DOMAIN
server {
    listen 443 ssl;
    server_name _;

    # Certbot populates these paths after: certbot --nginx -d YOUR_DOMAIN
    ssl_certificate     /etc/letsencrypt/live/YOUR_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/YOUR_DOMAIN/privkey.pem;

    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 10m;

    # Metabase requires large payloads for dashboard exports
    client_max_body_size 16m;

    location / {
        proxy_pass         http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_read_timeout 120s;
    }
}
```

- [ ] **Step 3: Validate docker-compose.yml**

```bash
MB_DB_PASS=test docker compose config --quiet
```

Expected: no errors (exits 0).

- [ ] **Step 4: Commit**

```bash
git add docker-compose.yml nginx/
git commit -m "feat: add Docker Compose stack and nginx TLS config for Metabase"
```

---

## Task 9: Update project docs

**Files:**
- Modify: `AGENTS.md`
- Modify: `infra/README.md` (if exists)
- Create or update: `infra/examples/bigquery-focus-connection.md`

- [ ] **Step 1: Update AGENTS.md header and stack sections**

Replace the fork objective, architecture diagram, and agent priorities sections to reflect the new stack. Key changes:
- Fork objective: "Run a GCP FinOps analytics stack — dbt FOCUS billing models + Metabase on e2-medium VM"
- Architecture: FOCUS export → dbt → BigQuery views → Metabase
- Agent priorities: `dbt/models/` first, then `infra/`, then `docker-compose.yml`
- Remove: all OpenCost API endpoint tables, Plan A/B Cloud Run sections, Go code conventions
- Keep: GCP BigQuery billing export setup (Plan A steps), architecture compliance section (B5/B6 updated for VM)

- [ ] **Step 2: Add Metabase BigQuery connection instructions to infra/examples/**

Create `infra/examples/metabase-bigquery-setup.md`:

```markdown
# Metabase → BigQuery Connection Setup

After Metabase first boots:

1. Open https://YOUR_DOMAIN, complete the Metabase setup wizard.
2. Go to **Admin → Databases → Add database**.
3. Select **BigQuery**.
4. **Authentication:** Use Application Default Credentials (the VM service account handles this automatically — no JSON key needed).
5. **Project ID:** `YOUR_GCP_PROJECT_ID`
6. **Dataset filters:** add `finops_dbt` to restrict Metabase to the dbt output dataset.
7. Click **Save**.

Metabase will sync the schema. You should see the four mart tables:
- `fct_spend_waterfall`
- `fct_credit_breakdown`
- `fct_commitment_discounts`
- `fct_monthly_showback`

## Required dbt env vars (profiles.yml or VM environment)

| Variable | Example |
|----------|---------|
| `DBT_PROJECT_ID` | `demogcp-terra2021` |
| `DBT_BILLING_PROJECT_ID` | `demogcp-terra2021` |
| `DBT_BILLING_DATASET` | `export_billing_demogcp_detailed` |
| `DBT_FOCUS_TABLE` | `gcp_billing_export_focus_v1_01E5F4_66804E_8286B7` |
```

- [ ] **Step 3: Commit**

```bash
git add AGENTS.md infra/examples/metabase-bigquery-setup.md
git commit -m "docs: update AGENTS.md and add Metabase BigQuery setup guide"
```

---

## Self-Review

### Spec coverage check

| Spec requirement | Task |
|-----------------|------|
| Strip all OpenCost Go / ui-finops / upstream docs | Task 1 |
| Remove cloud_run.tf, artifact_registry.tf, monitoring_dashboard.tf | Task 1 |
| Rewrite variables.tf (remove Cloud Run vars, add VM vars) | Task 2 |
| Update apis.tf (add IAP, remove Cloud Run/AR) | Task 2 |
| Rename SA to finops-vm with BQ + SM roles | Task 2 |
| Replace OpenCost secrets with metabase-db-password | Task 2 |
| Add e2-medium VM, static IP, 50 GB SSD, firewall 80/443 + IAP | Task 3 |
| IAP SSH only (no public port 22) | Task 3 |
| Shielded VM | Task 3 |
| vm-startup.sh: Docker, dbt-bigquery, nginx, ops agent, dbt cron | Task 4 |
| deploy.sh: sync/restart/dbt-run/sync-secrets/ssh commands | Task 4 |
| dbt project scaffold + BigQuery ADC profile | Task 5 |
| FOCUS source declaration | Task 5 |
| stg_focus_billing: full FOCUS column fidelity, charge_date/month | Task 5 |
| int_charges: Usage/Purchase/Tax | Task 6 |
| int_credits: ChargeType=Credit, preserves ChargeSubcategory | Task 6 |
| fct_spend_waterfall: list→contracted→effective→billed + delta cols | Task 7 |
| fct_credit_breakdown: by credit_type/project/service/month | Task 7 |
| fct_commitment_discounts: CUD utilisation | Task 7 |
| fct_monthly_showback: project net vs gross with credit attribution | Task 7 |
| Docker Compose: Metabase + PostgreSQL, port 127.0.0.1:3000 | Task 8 |
| nginx: HTTP→HTTPS redirect, TLS proxy | Task 8 |
| AGENTS.md update | Task 9 |
| Verify actual GCP FOCUS BQ schema before rewriting dbt models | Task 10 |
| Rewrite dbt staging + intermediate + mart SQL to actual FOCUS schema | Task 10 |
| Wire DBT_BILLING_PROJECT_ID / DBT_BILLING_DATASET / DBT_FOCUS_TABLE on VM | Task 11 |
| Add generate_schema_name macro to prevent dataset name doubling | Task 11 |

---

## Task 10: Verify BQ FOCUS Schema and Rewrite dbt Models

**Context:** Opus 5 code review found that the dbt models (Tasks 5–7) were written against an assumed snake_case FOCUS schema. GCP's actual FOCUS BigQuery export uses PascalCase columns (`ChargeCategory`, `BilledCost`, `SubAccountId`, …) and stores credits in a **repeated record** `x_Credits{Type, Name, Amount}`, not a flat `charge_subcategory` column. Credit type values are also GCP tokens (`COMMITTED_USAGE_DISCOUNT`, `PROMOTION`, `SUSTAINED_USAGE_DISCOUNT`) not human-readable strings.

**Files:**
- Read: actual BQ schema via `bq show --schema`
- Modify: `dbt/models/staging/stg_focus_billing.sql`
- Modify: `dbt/models/staging/sources.yml`
- Modify: `dbt/models/staging/schema.yml`
- Modify: `dbt/models/intermediate/int_charges.sql`
- Modify: `dbt/models/intermediate/int_credits.sql`
- Modify: `dbt/models/marts/fct_spend_waterfall.sql`
- Modify: `dbt/models/marts/fct_credit_breakdown.sql`
- Modify: `dbt/models/marts/fct_commitment_discounts.sql`
- Modify: `dbt/models/marts/fct_monthly_showback.sql`
- Modify: `dbt/models/marts/schema.yml`

**Interfaces:**
- Produces: corrected column names/types flowing through staging→intermediate→marts
- Produces: credit type strings matching GCP's actual token values

- [ ] **Step 1: Dump the actual FOCUS table schema**

```bash
bq show --schema --format=prettyjson \
  demogcp-terra2021:export_billing_demogcp_detailed.gcp_billing_export_focus_v1_01E5F4_66804E_8286B7 \
  > /tmp/focus_schema.json
cat /tmp/focus_schema.json | python3 -c "
import json, sys
schema = json.load(sys.stdin)
for f in schema:
    mode = f.get('mode','NULLABLE')
    if f['type'] == 'RECORD':
        print(f\"{f['name']} ({f['type']}, {mode})\")
        for sf in f.get('fields', []):
            print(f\"  .{sf['name']} ({sf['type']})\")
    else:
        print(f\"{f['name']} ({f['type']}, {mode})\")
"
```

Expected: list of top-level column names with types. Look specifically for:
- How `Charge*` columns are named and typed
- Whether there is an `x_Credits` or `Credits` repeated record and its sub-fields
- The exact values in `ChargeCategory` or equivalent

- [ ] **Step 2: Identify the correct column mapping**

From the schema dump, fill in this mapping (update as needed):

| Assumed name | Actual GCP FOCUS column | Notes |
|---|---|---|
| `charge_type` | `ChargeCategory` | Values: `Usage`, `Purchase`, `Tax`, `Credit`, `Adjustment` |
| `charge_subcategory` | `x_Credits` repeated record | Must be unnested; `Type` field is the credit token |
| `sub_account_id` | `SubAccountId` or `ProjectId` | Verify |
| `service_name` | `ServiceName` | Verify |
| `billed_cost` | `BilledCost` | Verify |
| `list_cost` | `ListCost` | Verify — may not be populated by GCP |
| `contracted_cost` | `ContractedCost` | Verify — may not be populated by GCP |
| `effective_cost` | `EffectiveCost` | Verify |
| `commitment_discount_id` | Check schema | May not exist as top-level column |

Also enumerate the actual credit `Type` token values from your data:
```sql
SELECT DISTINCT credit.Type
FROM `demogcp-terra2021.export_billing_demogcp_detailed.gcp_billing_export_focus_v1_01E5F4_66804E_8286B7`,
UNNEST(x_Credits) AS credit
LIMIT 100
```

- [ ] **Step 3: Rewrite `stg_focus_billing.sql`**

Use the actual column names from Step 2. Key changes:
- Replace snake_case column refs with actual PascalCase names
- Unnest the credits record into a separate staging layer OR handle credits in intermediate
- Alias to snake_case output names for consistency downstream (column aliasing is fine)
- Keep `coalesce(BilledCost, 0) as billed_cost` pattern

Verify: `dbt compile --select stg_focus_billing` must exit 0.

- [ ] **Step 4: Rewrite `int_charges.sql` and `int_credits.sql`**

`int_charges.sql`:
- Change `where charge_type in ('Usage','Purchase','Tax')` to use the actual column name from Step 2 (likely `charge_category` after the staging alias)
- Keep consuming `ref('stg_focus_billing')`

`int_credits.sql`:
- Change `where charge_type = 'Credit'` to correct column/value
- If credits come from an unnested record in staging, adjust the join/source accordingly
- `credit_type` alias must use actual GCP token values in the data

Verify: `dbt compile --select int_charges int_credits` must exit 0.

- [ ] **Step 5: Rewrite `fct_monthly_showback.sql` credit pivot**

Replace the human-readable string matches with actual GCP token values from Step 2:

```sql
-- Replace these (wrong — human-readable strings):
sum(case when credit_type = 'Enterprise Discount Program' ...)
sum(case when credit_type like 'Committed Use Discount%' ...)
sum(case when credit_type = 'Sustained Use Discount' ...)
sum(case when credit_type = 'Promotion' ...)
sum(case when credit_type = 'Reseller Discount' ...)

-- With actual token values, e.g.:
sum(case when credit_type = 'COMMITTED_USAGE_DISCOUNT' ...)
sum(case when credit_type = 'PROMOTION' ...)
-- etc. — derived from Step 2's token enumeration query
```

- [ ] **Step 6: Update schema tests**

Update `dbt/models/staging/schema.yml` `accepted_values` for the charge category/type column to use the correct column name and actual values.

- [ ] **Step 7: Run dbt against live table**

```bash
cd dbt
# Ensure env vars are set (Task 11 must be done first)
dbt run --select stg_focus_billing
dbt run --select int_charges int_credits
dbt run --select fct_spend_waterfall fct_credit_breakdown fct_commitment_discounts fct_monthly_showback
dbt test
```

Expected: all models run clean, all schema tests pass. Verify in BigQuery console that `finops_dbt` dataset has the 4 mart views with rows.

- [ ] **Step 8: Commit**

```bash
git add dbt/
git commit -m "fix(dbt): rewrite models against actual GCP FOCUS BQ schema"
```

---

## Task 11: Wire Billing Source Env Vars and Fix Dataset Naming

**Context:** Two issues found in Opus 5 review:
1. `sources.yml` resolves billing table from env vars (`DBT_BILLING_PROJECT_ID`, `DBT_BILLING_DATASET`, `DBT_FOCUS_TABLE`) but nothing sets them on the VM — cron and `dbt-run` fail with "table not found".
2. dbt's default `generate_schema_name` macro concatenates `target.schema` + `custom_schema`, so marts land in `dbt_staging_finops_dbt` instead of `finops_dbt`.

**Files:**
- Create: `dbt/macros/generate_schema_name.sql`
- Modify: `infra/scripts/deploy.sh` — `cmd_profiles` to also write env vars
- Modify: `infra/scripts/vm-startup.sh` — cron to source env file
- Modify: `infra/scripts/env.sh` — add billing source vars
- Modify: `dbt/profiles.yml.example` — note the required env vars

**Interfaces:**
- Consumes: `BILLING_PROJECT_ID`, `DBT_BILLING_DATASET`, `DBT_FOCUS_TABLE` from `env.sh`
- Produces: `/opt/finops/dbt/.env` on VM with all required dbt env vars
- Produces: dbt models materialising into correct dataset names

- [ ] **Step 1: Add billing source vars to `infra/scripts/env.sh`**

Append after the existing `SECRET_MB_DB_PASS` line:

```bash
# dbt billing source — set these to match your actual BQ export
export DBT_BILLING_DATASET="${DBT_BILLING_DATASET:-export_billing_demogcp_detailed}"
export DBT_FOCUS_TABLE="${DBT_FOCUS_TABLE:-gcp_billing_export_focus_v1_01E5F4_66804E_8286B7}"
export DBT_OUTPUT_PROJECT_ID="${DBT_OUTPUT_PROJECT_ID:-${PROJECT_ID}}"
```

Note: `DBT_BILLING_PROJECT_ID` defaults to `BILLING_PROJECT_ID` (already in env.sh).

- [ ] **Step 2: Update `cmd_profiles` in `deploy.sh` to write a `.env` file**

Replace `cmd_profiles` with a version that writes both `profiles.yml` AND `/opt/finops/dbt/.env`:

```bash
cmd_profiles() {
  require_auth
  local project="${PROJECT_ID}"
  local billing_project="${BILLING_PROJECT_ID}"
  local billing_dataset="${DBT_BILLING_DATASET}"
  local focus_table="${DBT_FOCUS_TABLE}"
  gcloud compute ssh "${VM_NAME}" \
    --zone="${ZONE}" --tunnel-through-iap --project="${PROJECT_ID}" \
    --command="mkdir -p /opt/finops/dbt
printf 'finops:\n  target: prod\n  outputs:\n    prod:\n      type: bigquery\n      method: oauth\n      project: ${project}\n      dataset: dbt_staging\n      location: US\n      timeout_seconds: 300\n      threads: 4\n' > /opt/finops/dbt/profiles.yml
printf 'DBT_PROJECT_ID=${project}\nDBT_BILLING_PROJECT_ID=${billing_project}\nDBT_BILLING_DATASET=${billing_dataset}\nDBT_FOCUS_TABLE=${focus_table}\n' > /opt/finops/dbt/.env
echo 'profiles.yml and .env written'"
}
```

- [ ] **Step 3: Update the dbt cron in `vm-startup.sh` to source the `.env` file**

Change the cron line from:
```
0 6 * * * root cd /opt/finops/dbt && /usr/local/bin/dbt run --profiles-dir . >> /var/log/dbt.log 2>&1
```
To:
```
0 6 * * * root set -a; [ -f /opt/finops/dbt/.env ] && . /opt/finops/dbt/.env; set +a; cd /opt/finops/dbt && /usr/local/bin/dbt run --profiles-dir . >> /var/log/dbt.log 2>&1
```

- [ ] **Step 4: Create `dbt/macros/generate_schema_name.sql`**

This macro makes dbt use the custom schema name verbatim (not concatenated with target schema):

```sql
{% macro generate_schema_name(custom_schema_name, node) -%}
    {%- if custom_schema_name is none -%}
        {{ target.schema }}
    {%- else -%}
        {{ custom_schema_name | trim }}
    {%- endif -%}
{%- endmacro %}
```

Effect: staging → `dbt_staging`, intermediate → `dbt_intermediate`, marts → `finops_dbt` (matching what Metabase and the setup guide expect).

- [ ] **Step 5: Update `dbt/profiles.yml.example` to document the env vars**

Add a comment block above the profile definition:

```yaml
# Required environment variables (set by deploy.sh profiles command):
#   DBT_PROJECT_ID          — GCP project for dbt job execution
#   DBT_BILLING_PROJECT_ID  — GCP project owning the FOCUS billing export dataset
#   DBT_BILLING_DATASET     — BigQuery dataset containing the FOCUS export table
#   DBT_FOCUS_TABLE         — FOCUS export table name (gcp_billing_export_focus_v1_*)
```

- [ ] **Step 6: Verify the fix locally**

```bash
# Confirm macro produces correct schema names
cd dbt && dbt compile --profiles-dir . 2>&1 | grep -E "(dbt_staging|dbt_intermediate|finops_dbt)"
```

Expected: staging targets `dbt_staging`, intermediate targets `dbt_intermediate`, marts target `finops_dbt`.

- [ ] **Step 7: Run `deploy.sh profiles` and verify on VM**

```bash
./infra/scripts/deploy.sh profiles
gcloud compute ssh finops-vm --zone=us-central1-a --tunnel-through-iap \
  --command="cat /opt/finops/dbt/.env && cat /opt/finops/dbt/profiles.yml"
```

Expected: both files present with correct values.

- [ ] **Step 8: Commit**

```bash
git add dbt/macros/ dbt/profiles.yml.example infra/scripts/env.sh \
        infra/scripts/deploy.sh infra/scripts/vm-startup.sh
git commit -m "fix: wire dbt billing source env vars and fix dataset name generation"
```

**Note:** Task 10 (schema verification and SQL rewrite) must be done alongside or before Task 11 — the env vars in Task 11 are required for `dbt run` in Task 10's Step 7.
| Architecture compliance (A/B/C/D/E/G/H/I) | Tasks 2–4 |
