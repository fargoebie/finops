# GCP FinOps Stack — Rebase Design

**Date:** 2026-07-25  
**Status:** Approved for implementation  
**Replaces:** OpenCost-based Cloud Run deploy (Plans A/B in AGENTS.md)

---

## Problem

OpenCost ingests the GCP detailed billing export but collapses the `credits[]` array into net cost, discarding the granularity required for FinOps analysis: breakdown of EDP discounts, promotional credits, committed-use discounts, reseller rebates, and product-level discounts. The data exists in BigQuery; OpenCost throws it away.

---

## Goal

Replace the OpenCost Go backend and custom React SPA with a stack that:

1. Preserves full credit/discount granularity from the GCP FOCUS billing export
2. Exposes it through a user-configurable BI tool (Metabase)
3. Runs on a single e2-medium VM (~$42/month) with no cold-start latency
4. Keeps the existing GCP infrastructure patterns (VPC, Secret Manager, IAM, OpenTofu)

---

## Architecture

```
GCP FOCUS Billing Export
  BigQuery: gcp_billing_export_focus_v1_<BILLING_ACCOUNT_ID>
            ↓
      dbt Core  (runs as VM crontab, daily)
  outputs BigQuery views in a dedicated dataset
            ↓
  Metabase  (Docker, port 3000, VM-local)
  BigQuery native connector — ADC via VM service account
            ↓
  nginx  (port 443, Let's Encrypt / Certbot)
            ↓
  User-configured dashboards
  (credit waterfall, EDP rate, showback, commitment utilisation)
```

---

## What Gets Stripped

All OpenCost-specific code and tooling is removed from the repository:

| Path | Reason |
|------|--------|
| `pkg/`, `cmd/`, `core/`, `modules/` | OpenCost Go source — replaced by dbt + Metabase |
| `ui-finops/` | Custom React SPA — replaced by Metabase |
| `go.mod`, `go.sum` | Go module files — no Go code remains |
| `Makefile`, `justfile` | OpenCost build targets |
| `Dockerfile`, `Dockerfile.cross`, `Dockerfile.debug` | OpenCost container images |
| `Tiltfile`, `Tiltfile.opencost`, `tilt-values.yaml` | Local dev orchestration |
| `generate.sh` | OpenCost code generation |
| `configs/` | OpenCost cloud pricing CSVs and provider JSONs |
| `spec/` | OpenCost spec |
| `sonar-project.properties` | OpenCost CI config |
| `infra/cloud_run.tf` | Cloud Run service — replaced by VM |
| `infra/artifact_registry.tf` | AR repo for OpenCost images — no longer needed |
| `infra/monitoring_dashboard.tf` | OpenCost-specific dashboard |
| Upstream community docs (`COMMUNITY.md`, `ADOPTERS.MD`, `GOVERNANCE.md`, `MAINTAINERS.md`, `ROADMAP.md`, `PROMETHEUS.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`, `NOTICE`, `THIRD_PARTY_LICENSES.txt`) | Upstream OpenCost community files |

---

## What Gets Kept

| Path | Notes |
|------|-------|
| `infra/vpc.tf` | VPC + subnet + Private Google Access — unchanged |
| `infra/iam.tf` | Updated: Metabase VM SA replaces OpenCost runtime SA |
| `infra/secret_manager.tf` | Updated: Metabase DB password replaces OpenCost secrets |
| `infra/provider.tf`, `variables.tf`, `locals.tf`, `outputs.tf`, `apis.tf` | Minimal changes to remove OpenCost-specific variables |
| `infra/backend.hcl.example`, `terraform.tfvars.example` | Updated for new variables |
| `infra/scripts/env.sh` | Project/region defaults — unchanged |
| `infra/scripts/deploy.sh` | Rewritten for VM deploy (SSH + docker compose pull + up) |
| `infra/scripts/auth-from-secret.sh` | Unchanged |
| `infra/scripts/bootstrap-state-bucket.sh`, `create-deployer-sa.sh` | Unchanged |
| `docs/architecture-compliance.md` | Principles still apply |
| `AGENTS.md`, `CLAUDE.md` | Rewritten for new stack |
| `infra/examples/` | Updated with FOCUS export config example |

---

## What Gets Added

### `dbt/` — transformation layer

```
dbt/
├── dbt_project.yml                   # project: finops, target-path: target/
├── profiles.yml.example              # BigQuery via oauth / ADC
├── packages.yml                      # dbt-bigquery adapter
└── models/
    ├── staging/
    │   └── stg_focus_billing.sql
    │       # Source: gcp_billing_export_focus_v1_*
    │       # Selects all FOCUS columns; casts types; renames to snake_case
    │       # No filtering — full fidelity preserved
    ├── intermediate/
    │   ├── int_charges.sql
    │   │   # ChargeType IN ('Usage', 'Purchase', 'Tax')
    │   │   # Adds: service_bucket (compute/storage/network/data/other)
    │   └── int_credits.sql
    │       # ChargeType = 'Credit'
    │       # Preserves: ChargeSubcategory (EDP, CUD, promotional, reseller, etc.)
    │       # Preserves: CommitmentDiscountName, CommitmentDiscountType, CommitmentDiscountCategory
    └── marts/
        ├── fct_spend_waterfall.sql
        │   # Per service/project/sku/month:
        │   #   list_cost, contracted_cost, effective_cost, billed_cost
        │   #   discount_from_edp, discount_from_cud, discount_from_credits
        ├── fct_credit_breakdown.sql
        │   # One row per credit line: type, subtype, project, service, month, amount
        │   # Primary table for "what are my credits?" dashboard questions
        ├── fct_commitment_discounts.sql
        │   # CommitmentDiscountName/Type/Category/Status per project/month
        │   # Supports commitment utilisation and coverage analysis
        └── fct_monthly_showback.sql
            # Project-level rollup:
            #   gross_cost (list), net_cost (billed), total_credits, edp_savings,
            #   cud_savings, promotional_credits, reseller_credits
            # One row per project per month
```

All models output as BigQuery **views** in a dedicated dataset (e.g. `finops_dbt`). No data is materialised by default — BigQuery re-evaluates on each Metabase query. Switch to `materialized='table'` for marts if query latency becomes an issue.

### `docker-compose.yml` — VM services

```yaml
# Metabase + PostgreSQL (Metabase state DB)
# Metabase connects to BigQuery via Application Default Credentials
# PostgreSQL stores Metabase questions, dashboards, users
```

Services: `metabase` (metabase/metabase:latest, port 3000), `postgres` (postgres:16-alpine, internal only).

### `nginx/metabase.conf` — reverse proxy

- Listens on 443 (TLS via Certbot / Let's Encrypt)
- Redirects 80 → 443
- Proxies to `localhost:3000`
- Recommended: restrict by IP allowlist in firewall rules rather than exposing publicly

### `infra/compute.tf` — VM

- **Machine type:** e2-medium (2 vCPU / 4 GB)
- **OS:** Debian 12 (latest public image)
- **Boot disk:** 50 GB SSD pd-balanced
- **Static external IP:** reserved, attached to instance
- **Firewall:** ingress 80/443 from allowed CIDRs only; no SSH from public internet (use IAP)
- **Service account:** `finops-vm@<PROJECT>.iam.gserviceaccount.com`
  - `roles/bigquery.dataViewer` on billing export dataset
  - `roles/bigquery.jobUser` on project
  - `roles/bigquery.user` on project
  - `roles/secretmanager.secretAccessor` on Metabase DB password secret
- **Startup script:** installs Docker, docker-compose, dbt-bigquery, nginx, certbot; pulls compose stack; adds dbt crontab

### Updated `infra/secret_manager.tf`

Secrets:
- `finops-metabase-db-password` — PostgreSQL password for Metabase state DB
- Remove: `opencost-cloud-integration`, `opencost-admin-token`

### Updated `infra/iam.tf`

- Add `finops-vm` service account with BigQuery + Secret Manager bindings
- Remove `opencost-cloudcost` service account and its bindings

---

## VM Operations

### dbt schedule

```cron
0 6 * * * cd /opt/finops && dbt run --profiles-dir . 2>&1 >> /var/log/dbt.log
```

Runs daily at 06:00 UTC. BQ FOCUS export lags ~24h so daily is sufficient. Manual re-run: `dbt run` via SSH (IAP tunnel).

### Metabase BigQuery connection

- Connection type: BigQuery
- Authentication: Application Default Credentials (VM service account — no JSON key)
- Project: `<PROJECT_ID>`
- Dataset: `finops_dbt` (the dbt output dataset)

### Deployments

```bash
# SSH via IAP (no public SSH port)
gcloud compute ssh finops-vm --tunnel-through-iap

# Update Metabase
docker compose pull && docker compose up -d

# Re-run dbt manually
dbt run --profiles-dir /opt/finops
```

---

## Access Control

- Firewall allows 443 only from specified CIDR ranges (team IP/VPN)
- Metabase has its own user accounts + permission groups
- No anonymous access
- SSH: IAP only (`roles/iap.tunnelResourceAccessor` per user)

---

## Cost Estimate (us-central1, on-demand)

| Item | $/month |
|------|---------|
| e2-medium VM | $24 |
| 50 GB SSD (pd-balanced) | $9 |
| Static external IP | $3 |
| BigQuery (storage + queries) | $2 |
| Secret Manager | $1 |
| VPC egress | $3 |
| **Total** | **~$42/month** |

1-year CUD on VM: ~$17 → **total ~$32/month**.

---

## Architecture Compliance (docs/architecture-compliance.md)

| Principle | Status |
|-----------|--------|
| A — Dedicated least-privilege SA | `finops-vm` SA; BQ read + secret access only |
| B — Secrets by reference | Metabase DB password from Secret Manager at startup |
| C — No public data store IPs | PostgreSQL is VM-local (Docker internal network only) |
| D — IAP admin access | SSH via IAP; no public port 22 |
| E — App-layer auth on public surface | Metabase user auth + firewall CIDR restriction |
| F — Data durability | BQ FOCUS export is system of record; Postgres backed up via disk snapshot |
| G — IaC + private registry | OpenTofu manages all GCP resources; Metabase from Docker Hub (acceptable for OSS tool) |
| H — Observability | VM Cloud Ops agent for system metrics; dbt log → Cloud Logging optional |
| I — `infra/` OpenTofu layout | Flat `infra/*.tf` maintained |

---

## Out of Scope

- Multi-VM / HA setup — single VM is sufficient for internal team dashboards
- Kubernetes / GKE — not needed for this workload
- OpenCost Kubernetes allocation — removed entirely
- Custom React SPA — Metabase covers the visualisation need
- AWS / Azure billing — GCP FOCUS only for now
