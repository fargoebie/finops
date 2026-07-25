# GCP FinOps — `infra/` (`demogcp-terra2021`)

**Project:** `demogcp-terra2021` (deploy **and** BigQuery FOCUS billing export)  
**Tooling:** OpenTofu + scripts under `scripts/`  
**Baseline:** [`../docs/architecture-compliance.md`](../docs/architecture-compliance.md)

## Identities

| SA | Key? | Role |
|----|------|------|
| `finops-deployer@demogcp-terra2021.iam.gserviceaccount.com` | Yes — base64 in agent secret `GCP_SA_KEY_B64` | tofu / deploy.sh |
| `finops-vm@demogcp-terra2021.iam.gserviceaccount.com` | **No** (ADC on VM) | Read BQ FOCUS export, access secrets |

## BigQuery FOCUS billing export

| Field | Value |
|-------|-------|
| Dataset | `export_billing_demogcp_detailed` (location `US`) |
| Table | `gcp_billing_export_focus_v1_01E5F4_66804E_8286B7` |
| Fully qualified | `demogcp-terra2021.export_billing_demogcp_detailed.gcp_billing_export_focus_v1_01E5F4_66804E_8286B7` |

See `examples/metabase-bigquery-setup.md` for Metabase connection steps.

OpenTofu remote state prefix must be **`tofu/finops`** (see `backend.hcl.example`) — do not reuse `tofu/state`.

## One-time on an admin machine

```bash
# 1) Create deployer SA + print base64 for agent secret GCP_SA_KEY_B64
./scripts/create-deployer-sa.sh

# 2) Create tofu state bucket
./scripts/bootstrap-state-bucket.sh

# 3) Confirm FOCUS export table exists:
#    export_billing_demogcp_detailed.gcp_billing_export_focus_v1_01E5F4_66804E_8286B7
```

Add agent secret:

- **Name:** `GCP_SA_KEY_B64`
- **Value:** single-line base64 from `create-deployer-sa.sh` output

## Standard deploy flow

```bash
cp terraform.tfvars.example terraform.tfvars
cp backend.hcl.example backend.hcl

./scripts/auth-from-secret.sh          # decodes GCP_SA_KEY_B64 → ADC file
tofu init -backend-config=backend.hcl
tofu apply                             # provisions VM, VPC, IAM, secrets

# Day-2 operations
./scripts/deploy.sh all                # sync files + restart services + run dbt
./scripts/deploy.sh dbt-run            # run dbt models only
./scripts/deploy.sh restart            # restart Metabase/nginx
./scripts/deploy.sh sync-secrets       # re-pull secrets from Secret Manager
./scripts/deploy.sh ssh                # IAP tunnel shell into finops-vm
```

## Scripts

| Script | Purpose |
|--------|---------|
| `env.sh` | Shared defaults (`PROJECT_ID=demogcp-terra2021`) |
| `create-deployer-sa.sh` | Create deployer SA + roles + base64 for agent secret |
| `auth-from-secret.sh` | Decode `GCP_SA_KEY_B64` → `GOOGLE_APPLICATION_CREDENTIALS` |
| `bootstrap-state-bucket.sh` | `gs://demogcp-terra2021-tofu-state` + versioning |
| `deploy.sh` | Sync files, restart services, run dbt, manage secrets, IAP SSH |
| `vm-startup.sh` | VM startup: Docker, dbt-bigquery, nginx, Ops Agent, dbt cron |

## VM architecture

The stack runs on a single **e2-medium** VM (`finops-vm`):

| Component | Port | Role |
|-----------|------|------|
| Metabase | `127.0.0.1:3000` | Analytics UI (Docker) |
| PostgreSQL | `127.0.0.1:5432` | Metabase metadata DB (Docker) |
| nginx | 80, 443 | HTTP→HTTPS redirect; TLS proxy to Metabase |
| dbt | cron (`0 6 * * *`) | Rebuild mart tables in `finops_dbt` BigQuery dataset |

Metabase connects to BigQuery via ADC (VM service account — no JSON key). See `examples/metabase-bigquery-setup.md`.

## Smoke test

```bash
# VM accessible via IAP
./scripts/deploy.sh ssh -- echo "OK"

# dbt run clean
./scripts/deploy.sh dbt-run

# Metabase up
curl -sS -o /dev/null -w '%{http_code}\n' https://YOUR_DOMAIN/

# Mart tables present in BigQuery
bq ls demogcp-terra2021:finops_dbt
```

## Intentionally omitted (v1)

`cloud_run.tf`, `artifact_registry.tf`, `cloud_sql.tf`, `redis_vm.tf`, `cloud_scheduler.tf` — not required for the dbt + Metabase VM stack.
