# AGENTS.md - GCP FinOps AI Agent Guide

This document provides guidance for AI assistants working with this repository.

## AI Assistant Behaviour

- Never include AI assistant session links or URLs (e.g. claude.ai) in commit messages or pull request bodies.
- Prefer graphify (`graphify query` / `path` / `explain`) when `graphify-out/` exists before broad Grep/Read exploration.
- For this repo, default to **dbt/analytics-first** work (FOCUS billing models + Metabase). Do not expand into Kubernetes allocation/Prometheus unless the user asks.

## Project Objective (Primary)

This repository runs a **GCP FinOps analytics stack**:

1. Ingest **GCP FOCUS billing export** from BigQuery
2. Transform it with **dbt Core** into spend waterfall, credit breakdown, CUD, and showback marts
3. Visualise via **self-hosted Metabase** on an e2-medium VM (~$42/month)

Kubernetes cost allocation, OpenCost API, and Prometheus are **out of primary scope**.

### Agent priorities

When implementing or debugging, prefer these code areas first:

1. `dbt/models/` — staging → intermediate → marts
2. `infra/` — OpenTofu for VM, VPC, IAM, Secret Manager
3. `docker-compose.yml` — Metabase + PostgreSQL containers
4. `nginx/` — TLS proxy config

## Project Overview

A GCP-native FinOps analytics stack built on the FOCUS billing standard:

- **Data source:** GCP FOCUS billing export (`gcp_billing_export_focus_v1_*`) in BigQuery
- **Transform:** dbt Core in `dbt/` — staging → intermediate → marts
- **Visualisation:** self-hosted Metabase (Docker, port 3000) behind nginx TLS
- **Deploy target:** e2-medium VM (`finops-vm`) on GCP, managed with OpenTofu in `infra/`
- **Auth:** VM service account (`finops-vm@...`) with BigQuery read + Secret Manager access via ADC; IAP SSH only

### Reseller / multi-customer model

The FOCUS export is a **multi-customer reseller export**: it contains ~108 billing accounts with `BillingAccountType` of either `Resold` (107 customer accounts) or `Reseller` (1 — Terralogiq itself, a GCP + GMP partner). Customer identity is resolved in `int_customer_map` by joining `dbt/seeds/customer_accounts.csv` (explicit overrides) with org-ancestry from `x_Project.Ancestors`; unrecognised accounts fall back to `(unmapped)`. A `platform` column (`GCP` vs `GMP`, derived from `ServiceName`) flows from staging through intermediates into all mart tables. To onboard a new customer, add a row to `dbt/seeds/customer_accounts.csv` then run `dbt seed && dbt run`.

## Repository Structure

```
finops/
├── dbt/                    # PRIMARY: dbt FOCUS billing models
│   ├── models/
│   │   ├── staging/        # stg_focus_billing — raw FOCUS columns + platform
│   │   ├── intermediate/   # int_charges, int_credits, int_customer_map
│   │   └── marts/          # fct_spend_waterfall, fct_credit_breakdown,
│   │                       #   fct_commitment_discounts, fct_monthly_showback,
│   │                       #   fct_customer_monthly, fct_customer_service_month
│   ├── seeds/              # customer_accounts.csv — billing_account_id → customer mapping
│   ├── tests/              # assert_no_unmapped_resold_accounts.sql (severity warn)
│   ├── profiles.yml        # BigQuery ADC profile (env-var driven)
│   └── dbt_project.yml
├── metabase/               # build_dashboards.py — Terralogiq BOD dashboard builder
├── infra/                  # PRIMARY: OpenTofu IaC — VM, VPC, IAM, secrets
│   ├── *.tf                # Flat layout: vm.tf, vpc.tf, iam.tf, secrets.tf, …
│   ├── scripts/
│   │   ├── deploy.sh       # sync / restart / dbt-run / sync-secrets / ssh
│   │   ├── vm-startup.sh   # Docker, dbt-bigquery, nginx, ops agent, dbt cron
│   │   └── env.sh          # Shared defaults (PROJECT_ID=gcp-coe-492507)
│   └── examples/
│       └── metabase-bigquery-setup.md
├── docker-compose.yml      # Metabase + PostgreSQL (port 127.0.0.1:3000)
├── nginx/                  # HTTP→HTTPS redirect, TLS proxy to Metabase
├── ROADMAP.md              # Deferred features and future work
└── docs/                   # architecture-compliance.md baseline
```

**Compliance baseline:** [`docs/architecture-compliance.md`](docs/architecture-compliance.md) — project-agnostic GCP architecture principles. All deploy work must satisfy those principles.

## Architecture (FinOps Analytics Path)

```
GCP Billing Account
        │
        ▼
BigQuery FOCUS export table
  gcp_billing_export_focus_v1_*
        │
        ▼
dbt Core  (dbt/models/)
  stg_focus_billing
  int_charges / int_credits
  fct_spend_waterfall / fct_credit_breakdown
  fct_commitment_discounts / fct_monthly_showback
  fct_customer_monthly / fct_customer_service_month
        │  (BigQuery views/tables in finops_dbt dataset)
        ▼
Metabase (Docker, port 3000)
  ← nginx TLS proxy (port 443)
        │
        ▼
e2-medium VM  finops-vm  (Cloud Run / Kubernetes: not used)
```

**Active project:** `gcp-coe-492507`  
**BQ export table:** `terra-coe-finops.gcp_billing_immutable_01A09A_A37EA6_F0AC6C_asia_southeast2.gcp_billing_export_focus_01A09A_A37EA6_F0AC6C`  
**Tofu state prefix:** `tofu/finops` on `gs://gcp-coe-492507-tofu-state`

---

## Plan A — Connect GCP BigQuery FOCUS billing export

Use this checklist when wiring billing accounts.

### A1. Enable FOCUS billing export

1. Choose a GCP project to host the export dataset (billing must be enabled).
2. Create a BigQuery dataset (note location: `US`, `EU`, `us-central1`, …).
3. In **Billing → Billing export**, enable **FOCUS export** (not standard or resource-level) into that dataset.
4. Confirm the table exists and has rows, e.g.  
   `gcp_billing_export_focus_v1_<BILLING_ACCOUNT_ID>`  
   Export lag is normal; empty tables look like dbt failures.

### A2. Create a reader service account

On the project that owns the dataset:

```bash
export PROJECT_ID="$(gcloud config get-value project)"
export SA_NAME="finops-vm"
export SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud iam service-accounts create "${SA_NAME}" \
  --display-name="GCP FinOps VM"

for ROLE in roles/bigquery.dataViewer roles/bigquery.jobUser roles/bigquery.user; do
  gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
    --member="serviceAccount:${SA_EMAIL}" \
    --role="${ROLE}"
done
```

**Preferred auth:** run the VM as this SA and use Application Default Credentials (ADC). No JSON key needed on the VM.

### A3. Required dbt env vars (`profiles.yml` or VM environment)

| Variable | Example |
|----------|---------|
| `DBT_PROJECT_ID` | `gcp-coe-492507` |
| `DBT_BILLING_PROJECT_ID` | `terra-coe-finops` |
| `DBT_BILLING_DATASET` | `gcp_billing_immutable_01A09A_A37EA6_F0AC6C_asia_southeast2` |
| `DBT_FOCUS_TABLE` | `gcp_billing_export_focus_01A09A_A37EA6_F0AC6C` |
| `DBT_OUTPUT_DATASET` | `finops_dbt` |

### A4. Common pitfalls

1. Using standard usage export or resource-level export instead of **FOCUS export**
2. Wrong `location` vs dataset region
3. Missing `bigquery.jobUser` (can read metadata but cannot run queries)
4. Empty FOCUS table — export lag can be 24–48 h for a new billing export
5. dbt profile pointing at wrong project or dataset

---

## Plan B — Deploy to GCP (VM, compliance-aligned)

Target: dbt + Metabase on **e2-medium VM**, implemented with **OpenTofu** under `infra/` per [`docs/architecture-compliance.md`](docs/architecture-compliance.md).

**Active project:** `gcp-coe-492507`  
Scripts default there via [`infra/scripts/env.sh`](infra/scripts/env.sh).  
**Tofu state prefix:** `tofu/finops` on `gs://gcp-coe-492507-tofu-state`.

### B0. Compliance constraints (non-negotiable)

| Principle | Required for this fork |
|-----------|------------------------|
| **A** Dedicated least-privilege SA | Runtime SA `finops-vm@…` only; never default Compute SA |
| **B** Secrets by reference | `metabase-db-password` in Secret Manager; mounted/injected by ref on the VM |
| **C** Network isolation | Custom VPC + subnet; Private Google Access for BQ APIs; no public port 22 |
| **D** IAP admin | IAP SSH only for VM access; no public SSH port |
| **E** App-layer auth on public surface | nginx handles TLS; Metabase has its own auth; no anonymous data exposure |
| **F** Durability | BQ FOCUS export is system of record; dbt outputs are rebuildable |
| **G** IaC + private registry | OpenTofu remote state; `infra/scripts/vm-startup.sh` for VM config |
| **H** Observability | VM SA gets `roles/cloudtrace.agent` + `roles/monitoring.metricWriter`; Ops Agent installed |
| **I** Layout | Flat `infra/*.tf` as specified in the baseline |

### B1. Bootstrap (out-of-band, once)

```bash
export PROJECT_ID="gcp-coe-492507"
export REGION="asia-southeast2"
export STATE_BUCKET="${PROJECT_ID}-tofu-state"

gcloud config set project "${PROJECT_ID}"

# Remote OpenTofu state bucket (versioned)
gcloud storage buckets create "gs://${STATE_BUCKET}" --location="${REGION}" --uniform-bucket-level-access
gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning
```

Complete **Plan A** (FOCUS billing export + BQ reader roles for the runtime SA).

### B2. `infra/` layout

Implemented under [`infra/`](infra/) (see [`infra/README.md`](infra/README.md)):

```
infra/
├── provider.tf / variables.tf / outputs.tf / locals.tf / apis.tf
├── iam.tf / secrets.tf / vpc.tf
├── vm.tf / firewall.tf
├── scripts/
│   ├── deploy.sh           # sync / restart / dbt-run / sync-secrets / ssh
│   ├── vm-startup.sh       # Docker, dbt-bigquery, nginx, ops agent, dbt cron
│   └── env.sh              # Shared defaults
├── examples/
│   └── metabase-bigquery-setup.md
├── terraform.tfvars.example / backend.hcl.example
└── README.md
```

Omitted on purpose for v1: `cloud_run.tf`, `artifact_registry.tf`, `cloud_sql.tf`, `redis_vm.tf`.

### B3. Identity & secrets (principle A/B)

- **One SA per workload:** `finops-vm@${PROJECT_ID}.iam.gserviceaccount.com`
- **Grants (minimum):**
  - `roles/bigquery.dataViewer`, `roles/bigquery.jobUser`, `roles/bigquery.user` for FOCUS export access
  - Per-secret: `roles/secretmanager.secretAccessor` on `metabase-db-password` only
  - Observability: `roles/cloudtrace.agent`, `roles/monitoring.metricWriter`
- **Never** attach `roles/owner`, `roles/editor`, or the default Compute Engine SA to the VM
- **Human access:** IAP SSH only; no public port 22; grant `roles/iap.tunnelResourceAccessor` to individual user emails

### B4. Network (principle C/D)

1. Custom VPC + subnet (no default network).
2. Enable **Private Google Access** on the subnet.
3. Firewall: allow HTTP (80) and HTTPS (443) from internet; allow IAP SSH (35.235.240.0/20 on port 22); deny everything else.
4. No public SSH port — all shell access via `gcloud compute ssh --tunnel-through-iap` or `deploy.sh ssh`.

### B5. VM shape (principle G)

- Machine type: `e2-medium` (2 vCPU, 4 GB RAM; ~$42/month)
- Boot disk: 50 GB SSD (`pd-balanced`)
- Shielded VM enabled (Secure Boot + vTPM + Integrity Monitoring)
- Startup script: `infra/scripts/vm-startup.sh`
  - Installs Docker, Docker Compose, dbt-bigquery, nginx, Ops Agent
  - Writes `docker-compose.yml` and nginx config
  - Configures daily dbt cron job
- Static external IP for DNS/TLS

### B6. Service shape (principle E/H)

- `docker-compose.yml`: Metabase + PostgreSQL, port `127.0.0.1:3000` (localhost only)
- nginx: HTTP → HTTPS redirect; TLS proxy to Metabase at `127.0.0.1:3000`
- dbt: runs via cron (`0 6 * * *`); outputs to `finops_dbt` BigQuery dataset
- Metabase connects to BigQuery via ADC (VM SA identity — no JSON key)

### B7. Deploy flow

```bash
cd infra

# First time
cp terraform.tfvars.example terraform.tfvars
cp backend.hcl.example backend.hcl
tofu init -backend-config=backend.hcl
tofu apply

# Day-2 / code changes
./scripts/deploy.sh all           # sync files, restart services, run dbt
./scripts/deploy.sh dbt-run       # run dbt only
./scripts/deploy.sh restart       # restart Metabase/nginx only
./scripts/deploy.sh sync-secrets  # re-pull secrets from Secret Manager
./scripts/deploy.sh ssh           # IAP tunnel shell
```

### B8. Data lifecycle (principle F)

| Store | Policy |
|-------|--------|
| BigQuery FOCUS export | System of record; set dataset/table retention to match finance policy |
| dbt output dataset (`finops_dbt`) | Rebuildable; define BQ retention |
| Metabase metadata DB (PostgreSQL) | On-VM volume; back up if customising heavily |
| Secret versions | Enable versioning; disable old versions after rotation |
| Tofu state bucket | Versioning on; uniform bucket-level access; no force-destroy |

### B9. Smoke test checklist

- [ ] `tofu plan` clean; state in versioned GCS bucket
- [ ] VM healthy; Metabase accessible at `https://YOUR_DOMAIN`
- [ ] dbt run succeeds: `./scripts/deploy.sh dbt-run`
- [ ] All six mart tables present in `finops_dbt` BigQuery dataset
- [ ] Metabase connected to BigQuery; mart tables visible in Admin → Databases
- [ ] Runtime SA is dedicated (not default Compute); IAM bindings match B3
- [ ] Secrets mounted by reference; no secret literals in tfvars
- [ ] IAP SSH works; no public port 22 reachable
- [ ] Ops Agent shipping logs + metrics to Cloud Monitoring

---

## Architecture Compliance Review

Reviewed against [`docs/architecture-compliance.md`](docs/architecture-compliance.md) for the **dbt + Metabase on e2-medium VM** design.

### Non-negotiables

| ID | Principle | Status | Notes |
|----|-----------|--------|-------|
| **A** | Dedicated least-privilege SAs | **Required / designed** | One VM SA; no default Compute SA; BQ + per-secret + observability roles only |
| **B** | Managed secrets by reference | **Required / designed** | Secret Manager for `metabase-db-password`; ADC for BQ (no key material) |
| **C** | No public IP on data stores | **N/A (v1)** | No Cloud SQL/Redis; BQ is Google-managed. Custom VPC + PGA still required |
| **D** | IAP-only admin access | **Required / designed** | IAP SSH for VM; no public port 22 |
| **E** | App-layer auth on public services | **Required / designed** | nginx TLS + Metabase auth; no anonymous data exposure |

### Other principles

| ID | Principle | Status |
|----|-----------|--------|
| **F** | Data durability & lifecycle | **Defined** — BQ FOCUS export is system of record; dbt outputs are rebuildable |
| **G** | Declarative deploy + IaC | **Satisfied** — OpenTofu manages all infra; startup script bootstraps VM |
| **H** | Traces & metrics on runtime SA | **Satisfied** — Ops Agent + `cloudtrace.agent` + `monitoring.metricWriter` |
| **I** | `infra/` OpenTofu layout | **Satisfied** — flat `infra/*.tf` per baseline |

### Verdict

Documented target: e2-medium VM + OpenTofu + Secret Manager + dedicated SA + IAP SSH + nginx TLS satisfies A/B/D/E/G/H/I in design; C via custom VPC + PGA.

---

## Local development (dbt + Metabase)

### Prerequisites

- Python 3.9+ with `dbt-bigquery` (`pip install dbt-bigquery`)
- Docker + Docker Compose
- `gcloud` authenticated to `gcp-coe-492507` with access to `terra-coe-finops`
- FOCUS export table populated (see Plan A)

### Run dbt locally

```bash
cd dbt

# Set required env vars (or export them in your shell profile)
export DBT_PROJECT_ID=gcp-coe-492507
export DBT_BILLING_PROJECT_ID=terra-coe-finops
export DBT_BILLING_DATASET=gcp_billing_immutable_01A09A_A37EA6_F0AC6C_asia_southeast2
export DBT_FOCUS_TABLE=gcp_billing_export_focus_01A09A_A37EA6_F0AC6C
export DBT_OUTPUT_DATASET=finops_dbt

dbt debug        # verify BigQuery connection
dbt run          # build all models
dbt test         # run data tests
dbt docs generate && dbt docs serve   # browse lineage
```

### Run Metabase locally

```bash
# From repo root
docker compose up -d
# Metabase: http://localhost:3000
```

On first boot, complete the setup wizard and connect to BigQuery (see `infra/examples/metabase-bigquery-setup.md`).

### Quick commands

```bash
# dbt
dbt run --select staging          # run only staging models
dbt run --select marts            # run only mart models
dbt run --select fct_spend_waterfall

# Deploy (from infra/)
./scripts/deploy.sh all
./scripts/deploy.sh dbt-run
./scripts/deploy.sh ssh
```

## Key Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DBT_PROJECT_ID` | (required) | GCP project for dbt output |
| `DBT_BILLING_PROJECT_ID` | (required) | GCP project holding FOCUS export |
| `DBT_BILLING_DATASET` | (required) | BigQuery dataset containing FOCUS export |
| `DBT_FOCUS_TABLE` | (required) | FOCUS export table name |
| `DBT_OUTPUT_DATASET` | `finops_dbt` | BigQuery dataset for dbt outputs |
| `METABASE_DB_PASSWORD` | (from Secret Manager) | PostgreSQL password for Metabase metadata DB |

## Key Types (dbt mart schema)

| Table | Description |
|-------|-------------|
| `stg_focus_billing` | Staging — raw FOCUS columns with charge_date/month |
| `int_charges` | Intermediate — Usage/Purchase/Tax charge types |
| `int_credits` | Intermediate — ChargeType=Credit, preserves ChargeSubcategory |
| `int_customer_map` | Intermediate — resolves billing_account_id → customer via seed + org-ancestry |
| `fct_spend_waterfall` | List → contracted → effective → billed + delta columns |
| `fct_credit_breakdown` | Credits by credit_type/project/service/month |
| `fct_commitment_discounts` | CUD utilisation |
| `fct_monthly_showback` | Project net vs gross with credit attribution |
| `fct_customer_monthly` | Customer × platform × month; IDR + USD; credit splits; MoM delta |
| `fct_customer_service_month` | Customer × platform × service × month; service-level spend trends |

## Pull Request Guidelines

1. Link related issues: `Fixes #123`, `Closes #456`
2. Describe user-facing / breaking changes
3. Run `dbt run && dbt test` before submitting
4. Use signed commits (`Signed-off-by` required)

## Useful Links

- [Architecture compliance baseline](docs/architecture-compliance.md)
- [FOCUS billing standard](https://focus.finops.org/)
- [dbt BigQuery adapter docs](https://docs.getdbt.com/docs/core/connect-data-platform/bigquery-setup)
- [Metabase BigQuery setup](infra/examples/metabase-bigquery-setup.md)
- [GCP FOCUS billing export docs](https://cloud.google.com/billing/docs/how-to/export-data-bigquery-tables/focus-export)
